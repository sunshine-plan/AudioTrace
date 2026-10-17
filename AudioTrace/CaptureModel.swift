import SwiftUI
import ReplayKit
import AVFoundation
#if canImport(ScreenCaptureKit) && os(iOS)
@preconcurrency import ScreenCaptureKit
#endif

struct SessionItem: Identifiable {
    let folder: URL
    let metadata: SessionMetadata
    let videoBytes: Int64
    var id: String { folder.path }
}

@MainActor
final class CaptureModel: NSObject, ObservableObject, RPScreenRecorderDelegate {
    @Published var sessions: [SessionItem] = []
    @Published var error: String?
    @Published var working = false
    @Published var localRecording = false
    @Published var microphoneEnabled = true
    @Published var scenario = "1 · AudioTrace 屏幕与麦克风"
    @Published var selectedScope: RecordingScope = .appOnly
    @Published var preflight: CapturePreflight?
    @Published var preparedBroadcast = false
    @Published var launchStatus: String?
    @Published var preflightURL: URL?
    @Published var historyLimit = 100
    @Published var hasMoreHistory = false
    private var engine: CaptureEngine?
    private var nativeController: AnyObject?
    private var pendingRequest: BroadcastLaunchRequest?
    private var tonePlayer: AVAudioPlayer?
    private var refreshRunning = false
    private var foreground = true
    private let queue = DispatchQueue(label: "AudioTrace.local.control", qos: .userInitiated)

    override init() {
        super.init()
        if let url = try? CaptureConfiguration.preflightURL(), let saved = try? SessionStorage.read(CapturePreflight.self, from: url) {
            selectedScope = saved.requestedScope; preflight = saved; preflightURL = url
        }
    }

    var active: SessionItem? { sessions.first { ["recording", "paused", "finalizing"].contains($0.metadata.state) } }
    var sharedAvailable: Bool { CaptureConfiguration.sharedRoot != nil }
    var nativeFullDisplayAvailable: Bool {
        #if canImport(ScreenCaptureKit) && os(iOS)
        if #available(iOS 27.0, *) { return true }
        #endif
        return false
    }
    var fullDisplayConfirmed: Bool {
        guard let active, active.metadata.mode == "broadcast" || active.metadata.mode == "screen_capture_kit" else { return false }
        return active.metadata.video.writtenFrames > 0 && active.metadata.state == "recording" && Date().timeIntervalSince(active.metadata.heartbeat) < 8
    }

    func checkConditions() {
        let report = CaptureConfiguration.preflight(scope: selectedScope, nativeAvailable: nativeFullDisplayAvailable, osVersion: UIDevice.current.systemVersion)
        preflight = report
        do {
            let url = try CaptureConfiguration.preflightURL()
            try SessionStorage.write(report, to: url); preflightURL = url
        } catch { self.error = "无法保存启动诊断：\(error.localizedDescription)" }
    }

    func scopeChanged() {
        guard active == nil else { return }
        preparedBroadcast = false; pendingRequest = nil; launchStatus = nil
        checkConditions()
    }

    func cancelBroadcastPreparation() {
        guard active == nil else { return }
        preparedBroadcast = false; pendingRequest = nil; launchStatus = "已取消本次准备；未标记为录制成功。"
    }
    func loadMoreHistory() { historyLimit += 100; Task { await refresh() } }

    func startSelectedRecording() {
        checkConditions()
        guard preflight?.ready == true else { return }
        if selectedScope == .appOnly { startLocal(); return }
        #if canImport(ScreenCaptureKit) && os(iOS)
        if #available(iOS 27.0, *) {
            guard active == nil, !working else { return }
            let controller = NativeFullDisplayController()
            nativeController = controller
            working = true
            launchStatus = "等待系统全屏捕获授权…"
            controller.present(scope: selectedScope, scenario: "用户录制 · \(selectedScope.title)", requestId: UUID().uuidString,
                onCreated: { [weak self] engine in
                    self?.engine = engine; self?.working = false; self?.launchStatus = "系统授权完成，等待真实画面数据…"
                    if self?.foreground == false { engine.noteHostActivity(background: true) }
                },
                onStopped: { [weak self] in self?.engine = nil; self?.nativeController = nil; self?.working = false; self?.launchStatus = nil },
                onError: { [weak self] error in self?.error = error.localizedDescription })
            return
        }
        #endif
        do {
            let root = try CaptureConfiguration.recordingRoot(broadcast: true)
            let request = BroadcastLaunchRequest(requestId: UUID().uuidString, scope: selectedScope, scenario: "用户录制 · \(selectedScope.title)", createdAt: Date())
            try SessionStorage.write(request, to: root.appendingPathComponent("launch_request.json"))
            pendingRequest = request; preparedBroadcast = true
            launchStatus = "请点击下方系统录屏按钮，选择 AudioTrace 并开始广播。等本页确认收到视频，再切换 App。"
        } catch { self.error = error.localizedDescription }
    }

    func refresh() async {
        guard !refreshRunning else { return }
        refreshRunning = true
        let limit = historyLimit
        let result = await Task.detached(priority: .utility) { () -> ([SessionItem], Bool) in
            let folders = SessionStorage.folders()
            let items = folders.prefix(limit).compactMap { folder -> SessionItem? in
                if !SessionStorage.isWriterAlive(root: folder.deletingLastPathComponent()) { try? SessionStorage.recoverAbandoned(folder) }
                guard var metadata = try? SessionStorage.read(SessionMetadata.self, from: folder.appendingPathComponent("metadata.json")) else { return nil }
                metadata.totalFileBytes = SessionStorage.bytes(in: folder)
                let videoBytes = metadata.video.segments.reduce(Int64(0)) { result, segment in
                    result + Int64((try? folder.appendingPathComponent(segment.filename).resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                }
                return SessionItem(folder: folder, metadata: metadata, videoBytes: videoBytes)
            }
            return (items, folders.count > limit)
        }.value
        sessions = result.0; hasMoreHistory = result.1; refreshRunning = false
        if let request = pendingRequest {
            if let matching = sessions.first(where: { $0.metadata.captureRequestId == request.requestId }) {
                preparedBroadcast = false
                if matching.metadata.video.writtenFrames > 0 {
                    launchStatus = "已收到系统全屏视频。现在可以切换 App，返回后检查后台采集日志。"
                    pendingRequest = nil
                } else if !["recording", "paused", "finalizing"].contains(matching.metadata.state) {
                    launchStatus = "广播已结束，但没有成功写入视频；请到诊断页查看这个 Session。"
                    pendingRequest = nil
                }
            } else if Date().timeIntervalSince(request.createdAt) > 45 {
                launchStatus = "尚未收到扩展创建的 Session。请检查是否在系统面板真正开始了 AudioTrace 广播，以及扩展的 App Groups 签名。"
            }
        }
    }

    func saveScenario() {
        guard let root = CaptureConfiguration.sharedRoot else { return }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try scenario.write(to: root.appendingPathComponent("test_scenario.txt"), atomically: true, encoding: .utf8)
        } catch { self.error = error.localizedDescription }
    }

    func startLocal(test: Bool = false) {
        guard !working, engine == nil, active == nil else { return }
        working = true
        Task {
            do {
                let created = try CaptureEngine(root: CaptureConfiguration.recordingRoot(broadcast: false), mode: test ? "in_app_self_test" : "in_app", scenario: test ? scenario : "用户录制 · 仅 App 内",
                    device: HardwareInfo.machine, os: UIDevice.current.systemVersion, requestedScope: .appOnly)
                engine = created
                var allowed = false
                if microphoneEnabled { allowed = await AVAudioApplication.requestRecordPermission() }
                if microphoneEnabled && !allowed { created.event("MIC_PERMISSION_DENIED", "Continue screen capture with microphone disabled") }
                let recorder = RPScreenRecorder.shared()
                guard recorder.isAvailable else { throw TraceFailure.message("REPLAYKIT_UNAVAILABLE：真机、系统限制或已有录屏可能导致不可用。") }
                recorder.delegate = self; recorder.isMicrophoneEnabled = microphoneEnabled && allowed
                created.onStopRequired = { [weak self] _ in Task { @MainActor in self?.stopLocalFramework() } }
                let controlQueue = queue
                recorder.startCapture(handler: { sample, type, error in
                    if let error { created.event("REPLAYKIT_SAMPLE_ERROR", error.localizedDescription) }
                    else {
                        // Synchronous processing protects ReplayKit's buffer lifetime.
                        controlQueue.sync { created.consume(sample, type: type) }
                    }
                }, completionHandler: { [weak self] error in
                    Task { @MainActor in
                        guard let self else { return }
                        self.working = false
                        if let error {
                            created.event("CAPTURE_START_FAILED", error.localizedDescription)
                            created.finish(reason: "CAPTURE_START_FAILED") { [weak self] in Task { @MainActor in self?.engine = nil } }
                            self.error = error.localizedDescription
                        } else {
                            self.localRecording = true; created.startMonitoring()
                            if !self.foreground { self.stop(reason: "IN_APP_BACKGROUND_STOP") }
                        }
                        await self.refresh()
                    }
                })
            } catch {
                engine?.event("CAPTURE_SETUP_FAILED", error.localizedDescription)
                engine?.finish(reason: "CAPTURE_SETUP_FAILED") { [weak self] in Task { @MainActor in self?.engine = nil } }
                self.error = error.localizedDescription; working = false
            }
        }
    }

    func stop(reason: String = "user") {
        #if canImport(ScreenCaptureKit) && os(iOS)
        if #available(iOS 27.0, *), let controller = nativeController as? NativeFullDisplayController {
            working = true; controller.stop(reason: reason); return
        }
        #endif
        if let engine {
            guard !working else { return }
            working = true
            RPScreenRecorder.shared().stopCapture { [weak self] error in
                if let error { engine.event("REPLAYKIT_STOP_ERROR", error.localizedDescription) }
                engine.finish(reason: reason) { [weak self] in
                    Task { @MainActor in self?.engine = nil; self?.working = false; self?.localRecording = false; await self?.refresh() }
                }
            }
        } else if let active {
            do { try active.metadata.sessionId.write(to: active.folder.deletingLastPathComponent().appendingPathComponent("stop_request.txt"), atomically: true, encoding: .utf8) }
            catch { self.error = error.localizedDescription }
        }
    }
    private func stopLocalFramework() {
        RPScreenRecorder.shared().stopCapture { [weak self] error in
            Task { @MainActor in
                if let error { self?.error = error.localizedDescription }
                self?.localRecording = false; self?.engine = nil; self?.working = false
                await self?.refresh()
            }
        }
    }
    func enteredBackground() {
        foreground = false
        if localRecording { engine?.event("APP_BACKGROUNDED", "In-app test stops here; use SharedCapture for third-party apps"); stop(reason: "IN_APP_BACKGROUND_STOP") }
        else { recordHostActivity(background: true) }
        tonePlayer?.stop()
    }
    func enteredForeground() { foreground = true; saveScenario(); recordHostActivity(background: false) }
    private func recordHostActivity(background: Bool) {
        if engine != nil, !localRecording { engine?.noteHostActivity(background: background); return }
        guard let active, active.metadata.mode == "broadcast" else { return }
        do {
            try SessionStorage.write(HostActivity(sessionId: active.metadata.sessionId, background: background, observedAt: Date(), uptime: ProcessInfo.processInfo.systemUptime),
                to: active.folder.deletingLastPathComponent().appendingPathComponent("host_activity.json"))
        } catch { self.error = "无法记录前后台状态：\(error.localizedDescription)" }
    }
    nonisolated func screenRecorder(_ screenRecorder: RPScreenRecorder, didStopRecordingWith previewViewController: RPPreviewViewController?, error: Error?) {
        Task { @MainActor in
            guard let engine = self.engine, self.localRecording else { return }
            engine.event("REPLAYKIT_INTERRUPTED", error?.localizedDescription ?? "System stopped recorder")
            engine.finish(reason: "REPLAYKIT_INTERRUPTED") { [weak self] in
                Task { @MainActor in self?.engine = nil; self?.localRecording = false; self?.working = false; await self?.refresh() }
            }
        }
    }
    func playTestTone() {
        // A labeled stimulus for real ReplayKit self-tests, never a replacement capture track.
        var data = Data()
        func bytes(_ text: String) { data.append(contentsOf: text.utf8) }
        func le<T: FixedWidthInteger>(_ number: T) { var v = number.littleEndian; withUnsafeBytes(of: &v) { data.append(contentsOf: $0) } }
        let count = 48_000 * 2
        bytes("RIFF"); le(UInt32(36 + count * 2)); bytes("WAVEfmt "); le(UInt32(16)); le(UInt16(1)); le(UInt16(1)); le(UInt32(48_000)); le(UInt32(96_000)); le(UInt16(2)); le(UInt16(16)); bytes("data"); le(UInt32(count * 2))
        for n in 0..<count { le(Int16(sin(2 * Double.pi * 440 * Double(n) / 48_000) * 3276)) }
        do {
            tonePlayer = try AVAudioPlayer(data: data); tonePlayer?.volume = 0.4
            guard tonePlayer?.play() == true else { throw TraceFailure.message("测试音播放失败，请检查静音模式和音频路由。") }
            engine?.event("SELF_TEST_TONE", "User played a labeled 440 Hz, 2 second in-app stimulus")
        } catch { self.error = error.localizedDescription }
    }
}

#if canImport(ScreenCaptureKit) && os(iOS)
// Requires the public iOS 27 SDK. With an older SDK this implementation is excluded,
// and preflight reports the missing capability instead of falling back to app-only capture.
@available(iOS 27.0, *)
@MainActor
final class NativeFullDisplayController: NSObject, SCContentSharingPickerObserver, SCStreamDelegate {
    private var stream: SCStream?
    private var sink: NativeCaptureSink?
    private var engine: CaptureEngine?
    private var scope: RecordingScope = .crossApp
    private var scenario = ""
    private var requestId = ""
    private var stopping = false
    private var audioSessionActivated = false
    private var onCreated: ((CaptureEngine) -> Void)?
    private var onStopped: (() -> Void)?
    private var onError: ((Error) -> Void)?

    func present(scope: RecordingScope, scenario: String, requestId: String,
                 onCreated: @escaping (CaptureEngine) -> Void, onStopped: @escaping () -> Void, onError: @escaping (Error) -> Void) {
        self.scope = scope; self.scenario = scenario; self.requestId = requestId
        self.onCreated = onCreated; self.onStopped = onStopped; self.onError = onError
        var configuration = SCContentSharingPickerConfiguration()
        configuration.showsMicrophoneControl = true
        let picker = SCContentSharingPicker.shared
        picker.defaultConfiguration = configuration
        picker.add(self)
        picker.isActive = true
        picker.present() // Full display. Never use presentForCurrentApplication for these modes.
    }

    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didUpdateWith filter: SCContentFilter, for stream: SCStream?) {
        Task { @MainActor in await self.startOrUpdate(filter) }
    }
    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
        Task { @MainActor in if self.stream == nil { self.stop(reason: "PICKER_CANCELLED") } }
    }
    nonisolated func contentSharingPickerStartDidFailWithError(_ error: Error) {
        Task { @MainActor in self.onError?(error); self.stop(reason: "PICKER_START_FAILED") }
    }
    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor in
            self.engine?.event("SCREEN_CAPTURE_KIT_INTERRUPTED", error.localizedDescription)
            self.onError?(error)
            self.stop(reason: "SCREEN_CAPTURE_KIT_INTERRUPTED")
        }
    }

    private func startOrUpdate(_ filter: SCContentFilter) async {
        guard !stopping else { return }
        if let stream {
            do { try await stream.updateContentFilter(filter); engine?.event("CAPTURE_FILTER_UPDATED", "System picker updated the existing full-display stream") }
            catch { onError?(error) }
            return
        }
        do {
            let created = try CaptureEngine(root: CaptureConfiguration.recordingRoot(broadcast: false), mode: "screen_capture_kit", scenario: scenario,
                device: HardwareInfo.machine, os: UIDevice.current.systemVersion, requestedScope: scope, requestId: requestId, framework: "ScreenCaptureKit")
            engine = created
            created.event("NATIVE_FULL_DISPLAY_AUTHORIZED", "microphoneEnabled=\(filter.isMicrophoneEnabled); scope=\(scope.rawValue)")
            if filter.isMicrophoneEnabled {
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(.playAndRecord, mode: .default, options: [.mixWithOthers, .defaultToSpeaker])
                try session.setActive(true)
                audioSessionActivated = true
                created.event("CAPTURE_AUDIO_SESSION_ACTIVE", "playAndRecord + mixWithOthers; microphone concurrency still requires device verification")
            } else { created.event("MICROPHONE_NOT_SELECTED", "System picker microphone toggle is off") }
            let config = SCStreamConfiguration()
            config.capturesAudio = true
            config.captureMicrophone = filter.isMicrophoneEnabled
            config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
            config.queueDepth = 3
            let size = UIScreen.main.bounds.size
            let scale = min(1, 1280 / max(size.width * UIScreen.main.scale, size.height * UIScreen.main.scale))
            config.width = max(2, Int(size.width * UIScreen.main.scale * scale) / 2 * 2)
            config.height = max(2, Int(size.height * UIScreen.main.scale * scale) / 2 * 2)
            let output = NativeCaptureSink(engine: created)
            let newStream = SCStream(filter: filter, configuration: config, delegate: self)
            let queue = DispatchQueue(label: "AudioTrace.full-display.samples", qos: .userInitiated)
            try newStream.addStreamOutput(output, type: .screen, sampleHandlerQueue: queue)
            try newStream.addStreamOutput(output, type: .audio, sampleHandlerQueue: queue)
            if filter.isMicrophoneEnabled { try newStream.addStreamOutput(output, type: .microphone, sampleHandlerQueue: queue) }
            sink = output; stream = newStream
            created.onStopRequired = { [weak self] reason in Task { @MainActor in self?.stop(reason: reason) } }
            try await newStream.startCapture()
            created.startMonitoring()
            onCreated?(created)
        } catch {
            engine?.event("NATIVE_CAPTURE_START_FAILED", error.localizedDescription)
            onError?(error)
            stop(reason: "NATIVE_CAPTURE_START_FAILED")
        }
    }

    func stop(reason: String) {
        guard !stopping else { return }
        stopping = true
        Task { @MainActor in
            if let stream {
                do { try await stream.stopCapture() } catch { engine?.event("NATIVE_CAPTURE_STOP_FAILED", error.localizedDescription) }
            }
            if let engine {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    engine.finish(reason: reason) { continuation.resume() }
                }
            }
            let picker = SCContentSharingPicker.shared
            picker.remove(self); picker.isActive = false
            if audioSessionActivated { try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }
            stream = nil; sink = nil; engine = nil
            onStopped?()
        }
    }
}

@available(iOS 27.0, *)
private final class NativeCaptureSink: NSObject, SCStreamOutput {
    let engine: CaptureEngine
    init(engine: CaptureEngine) { self.engine = engine }
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard CMSampleBufferIsValid(sampleBuffer), CMSampleBufferDataIsReady(sampleBuffer) else { return }
        // Fully synchronous: the sample buffer never escapes this delegate callback.
        switch type {
        case .screen: engine.consume(sampleBuffer, type: .video)
        case .audio: engine.consume(sampleBuffer, type: .audioApp)
        case .microphone: engine.consume(sampleBuffer, type: .audioMic)
        @unknown default: engine.event("UNKNOWN_NATIVE_OUTPUT", "Unknown ScreenCaptureKit stream output")
        }
    }
}
#endif
