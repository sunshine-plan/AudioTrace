import Foundation
import AVFoundation
import ReplayKit
import Darwin

// No sample buffer crosses an async boundary. Callers synchronously return it to ReplayKit.
// The lock also protects timer work. There is no unbounded frame or PCM queue.
final class CaptureEngine: @unchecked Sendable {
    let folder: URL
    private let root: URL
    private var lease: SessionLease?
    private let lock = NSRecursiveLock()
    private let diagnostics: CaptureDiagnostics
    private let video: VideoCapturePipeline
    private let system: SystemAudioPipeline
    private let mic: MicrophoneAudioPipeline
    private var metadata: SessionMetadata
    private let startedUptime = ProcessInfo.processInfo.systemUptime
    private var finishUptime: Double?
    private var timer: DispatchSourceTimer?
    private var memorySource: DispatchSourceMemoryPressure?
    private let monitorQueue = DispatchQueue(label: "AudioTrace.health", qos: .utility)
    private var tickNumber = 0
    private var maximumProcessingMilliseconds: Double = 0
    private var finishCallbacks: [() -> Void] = []
    private var lastHostActivity: Double?
    private var backgroundVideoBaseline: Int64?
    var onStopRequired: ((String) -> Void)?

    init(root: URL, mode: String, scenario: String, device: String, os: String, requestedScope: RecordingScope? = nil, requestId: String? = nil, framework: String? = nil) throws {
        self.root = root
        lease = try SessionLease(root: root)
        if let free = SessionStorage.freeBytes(at: root), free < 250_000_000 { throw TraceFailure.message("INSUFFICIENT_STORAGE：开始录制至少需要 250 MB 可用空间。") }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyyMMdd_HHmmss"
        let id = "session_\(formatter.string(from: Date()))_\(UUID().uuidString.prefix(8))"
        folder = root.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        var resource = URLResourceValues(); resource.isExcludedFromBackup = true
        var mutableFolder = folder; try mutableFolder.setResourceValues(resource)
        diagnostics = try CaptureDiagnostics(folder: folder)
        video = VideoCapturePipeline(folder: folder, diagnostics: diagnostics)
        system = SystemAudioPipeline(folder: folder, diagnostics: diagnostics)
        mic = MicrophoneAudioPipeline(folder: folder, diagnostics: diagnostics)
        metadata = SessionMetadata(sessionId: id, deviceModel: device, iosVersion: os,
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0",
            captureFramework: framework ?? (mode == "broadcast" ? "ReplayKit.BroadcastUploadExtension" : "ReplayKit.RPScreenRecorder"),
            mode: mode, requestedScope: requestedScope, captureRequestId: requestId, testScenario: scenario, recordingStartTime: Date(), heartbeat: Date())
        if framework == "ScreenCaptureKit" { metadata.synchronization.clock = "ScreenCaptureKit CMSampleBuffer presentation time; shared media clock" }
        diagnostics.event("SESSION_CREATED", "\(mode); scenario=\(scenario); capture authorization may still be pending")
        try checkpoint()
    }

    func startMonitoring() {
        lock.lock(); defer { lock.unlock() }
        guard timer == nil else { return }
        let source = DispatchSource.makeTimerSource(queue: monitorQueue)
        source.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(150))
        source.setEventHandler { [weak self] in self?.tick() }
        timer = source; source.resume()
        let pressure = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: monitorQueue)
        pressure.setEventHandler { [weak self] in
            guard let self, let pressure = self.memorySource else { return }
            self.lock.lock(); defer { self.lock.unlock() }
            self.diagnostics.event("MEMORY_PRESSURE", "\(pressure.data.rawValue)")
            self.video.memoryWarning()
            if pressure.data.contains(.critical) { self.requestStop("MEMORY_PRESSURE_CRITICAL") }
        }
        memorySource = pressure; pressure.resume()
    }

    func consume(_ sample: CMSampleBuffer, type: RPSampleBufferType) {
        lock.lock(); defer { lock.unlock() }
        guard metadata.state == "recording" else { return }
        let processingStart = ProcessInfo.processInfo.systemUptime
        defer { maximumProcessingMilliseconds = max(maximumProcessingMilliseconds, (ProcessInfo.processInfo.systemUptime - processingStart) * 1000) }
        autoreleasepool {
            let pts = CMSampleBufferGetPresentationTimeStamp(sample)
            if metadata.synchronization.sessionTimeOrigin == nil && pts.isNumeric { metadata.synchronization.sessionTimeOrigin = MediaTime(pts) }
            switch type {
            case .video:
                video.consume(sample)
                if let baseline = backgroundVideoBaseline, video.report.writtenFrames > baseline {
                    let latestActivity = metadata.mode == "broadcast" ? try? SessionStorage.read(HostActivity.self, from: root.appendingPathComponent("host_activity.json")) : nil
                    if latestActivity?.background != false {
                        diagnostics.event("BACKGROUND_VIDEO_CONFIRMED", "A real video frame was written after the observed containing-app background event", pts: pts)
                    }
                    backgroundVideoBaseline = nil
                }
            case .audioApp: system.consume(sample)
            case .audioMic: mic.consume(sample)
            @unknown default: diagnostics.event("UNKNOWN_SAMPLE_TYPE", "\(type.rawValue)", pts: pts)
            }
        }
    }

    func event(_ code: String, _ detail: String) {
        lock.lock(); defer { lock.unlock() }
        diagnostics.event(code, detail)
    }

    func noteHostActivity(background: Bool) {
        lock.lock(); defer { lock.unlock() }
        diagnostics.event(background ? "HOST_ENTERED_BACKGROUND" : "HOST_ENTERED_FOREGROUND", "scope=\(metadata.requestedScope?.rawValue ?? metadata.mode); capture remains controlled by its framework")
        backgroundVideoBaseline = background ? video.report.writtenFrames : nil
        do { try checkpoint() } catch { diagnostics.event("CHECKPOINT_WRITE_FAILED", error.localizedDescription) }
    }

    func setPaused(_ paused: Bool) {
        lock.lock(); defer { lock.unlock() }
        guard ["recording", "paused"].contains(metadata.state) else { return }
        metadata.state = paused ? "paused" : "recording"
        video.boundary(); system.pauseBoundary(); mic.pauseBoundary()
        diagnostics.event(paused ? "BROADCAST_PAUSED" : "BROADCAST_RESUMED", "Original media timestamps retained; no gap filling")
        do { try checkpoint() } catch { diagnostics.event("CHECKPOINT_FAILED", error.localizedDescription) }
    }

    func finish(reason: String, completion: (() -> Void)? = nil) {
        lock.lock(); defer { lock.unlock() }
        if metadata.state == "finalizing" { if let completion { finishCallbacks.append(completion) }; return }
        guard ["recording", "paused"].contains(metadata.state) else { completion?(); return }
        if let completion { finishCallbacks.append(completion) }
        metadata.state = "finalizing"; metadata.stopReason = reason
        metadata.recordingEndTime = Date(); finishUptime = ProcessInfo.processInfo.systemUptime
        diagnostics.event("CAPTURE_STOPPED", reason)
        system.finish(); mic.finish(); video.beginFinish()
        do { try checkpoint() } catch { diagnostics.event("CHECKPOINT_FAILED", error.localizedDescription) }
        if timer == nil { startMonitoring() }
    }

    private func tick() {
        lock.lock(); defer { lock.unlock() }
        autoreleasepool {
            let now = ProcessInfo.processInfo.systemUptime
            if metadata.state == "finalizing" {
                if now - (finishUptime ?? now) > 8 && !video.finishReady() { video.cancelPendingFinish() }
                guard video.finishReady() else { return }
                metadata.state = metadata.stopReason == "user" || metadata.stopReason == "broadcast_finished" ? "completed" : "interrupted"
                metadata.integrity = "container_finalization_recorded; run file integrity check for independent verification"
                do { try checkpoint(); try diagnostics.sync() } catch { diagnostics.event("FINAL_CHECKPOINT_FAILED", error.localizedDescription) }
                timer?.cancel(); timer = nil; memorySource?.cancel(); memorySource = nil; lease = nil
                let callbacks = finishCallbacks; finishCallbacks = []; callbacks.forEach { $0() }
                return
            }
            guard ["recording", "paused"].contains(metadata.state) else { return }
            tickNumber += 1
            if metadata.mode == "broadcast", let activity = try? SessionStorage.read(HostActivity.self, from: root.appendingPathComponent("host_activity.json")),
               activity.sessionId == metadata.sessionId, activity.uptime != lastHostActivity {
                lastHostActivity = activity.uptime
                noteHostActivity(background: activity.background)
            }
            system.tick(now: now, captureStarted: startedUptime, paused: metadata.state == "paused")
            mic.tick(now: now, captureStarted: startedUptime, paused: metadata.state == "paused")
            do {
                try diagnostics.levels.append(PerformanceRecord(uptime: now, thermalState: ProcessInfo.processInfo.thermalState.rawValue,
                    physicalFootprintBytes: Self.footprint(), freeDiskBytes: SessionStorage.freeBytes(at: folder),
                    videoWrittenFrames: video.report.writtenFrames, videoDroppedFrames: video.report.droppedFrames,
                    maximumCallbackProcessingMilliseconds: maximumProcessingMilliseconds))
                maximumProcessingMilliseconds = 0
            } catch { diagnostics.event("PERFORMANCE_LOG_WRITE_FAILED", error.localizedDescription) }
            var stop: String?
            if metadata.mode == "broadcast", let bytes = Self.footprint() {
                if bytes > 36_000_000 { video.memoryWarning() }
                if bytes > 44_000_000 { stop = "EXTENSION_MEMORY_BUDGET" }
            }
            if let request = try? String(contentsOf: root.appendingPathComponent("stop_request.txt"), encoding: .utf8), request == metadata.sessionId { stop = "user" }
            if ProcessInfo.processInfo.thermalState == .critical { stop = "THERMAL_CRITICAL" }
            if tickNumber % 3 == 0, let free = SessionStorage.freeBytes(at: folder), free < 100_000_000 { stop = "LOW_STORAGE" }
            if diagnostics.logError != nil { stop = "DIAGNOSTIC_WRITE_FAILED" }
            if tickNumber % 2 == 0 {
                do { try checkpoint() } catch { diagnostics.event("CHECKPOINT_WRITE_FAILED", error.localizedDescription); stop = "CHECKPOINT_WRITE_FAILED" }
            }
            if let stop {
                diagnostics.event(stop, "Capture engine requested a controlled stop")
                requestStop(stop)
            }
        }
    }

    private static func footprint() -> UInt64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : nil
    }

    private func requestStop(_ reason: String) {
        let callback = onStopRequired
        let queue = monitorQueue
        finish(reason: reason) { if let callback { queue.async { callback(reason) } } }
    }

    private func checkpoint() throws {
        metadata.video = video.report; metadata.systemAudio = system.report; metadata.microphoneAudio = mic.report
        metadata.heartbeat = Date()
        metadata.durationSeconds = (finishUptime ?? ProcessInfo.processInfo.systemUptime) - startedUptime
        metadata.totalFileBytes = SessionStorage.bytes(in: folder)
        metadata.errors = diagnostics.recent.filter { $0.level != "info" }; metadata.totalEventCount = diagnostics.count
        metadata.errorCount = diagnostics.errorCount; metadata.warningCount = diagnostics.warningCount
        if let videoPTS = metadata.video.startPts {
            if let audio = metadata.systemAudio.startPts, audio.epoch == videoPTS.epoch { metadata.synchronization.systemAudioVideoOffset = audio.seconds - videoPTS.seconds }
            if let audio = metadata.microphoneAudio.startPts, audio.epoch == videoPTS.epoch { metadata.synchronization.microphoneVideoOffset = audio.seconds - videoPTS.seconds }
        }
        try SessionStorage.write(metadata, to: folder.appendingPathComponent("metadata.json"))
        try SessionStorage.write(DiagnosticSnapshot(state: metadata.state, captureFramework: metadata.captureFramework,
            video: metadata.video, systemAudio: metadata.systemAudio, microphoneAudio: metadata.microphoneAudio,
            fileBytes: metadata.totalFileBytes, recentEvents: diagnostics.recent, totalEventCount: diagnostics.count, heartbeat: metadata.heartbeat), to: folder.appendingPathComponent("diagnostics.json"))
    }
    deinit { timer?.cancel(); memorySource?.cancel() }
}
