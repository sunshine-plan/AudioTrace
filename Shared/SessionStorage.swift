import Foundation
import Darwin

enum TraceFailure: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

enum HardwareInfo {
    static var machine: String {
        var info = utsname(); uname(&info)
        let size = MemoryLayout.size(ofValue: info.machine)
        return withUnsafePointer(to: &info.machine) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: size) { String(cString: $0) }
        }
    }
}

enum CaptureConfiguration {
    static var groupEnabled: Bool { (Bundle.main.object(forInfoDictionaryKey: "AudioTraceSharedCapture") as? String) == "YES" }
    static var groupID: String { Bundle.main.object(forInfoDictionaryKey: "AudioTraceAppGroup") as? String ?? "" }
    static var extensionID: String { Bundle.main.object(forInfoDictionaryKey: "AudioTraceBroadcastExtension") as? String ?? "" }
    static var sharedRoot: URL? {
        guard groupEnabled, !groupID.isEmpty else { return nil }
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID)?.appendingPathComponent("AudioTrace", isDirectory: true)
    }
    static func localRoot() throws -> URL {
        try FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("AudioTrace", isDirectory: true)
    }
    static func recordingRoot(broadcast: Bool) throws -> URL {
        if broadcast {
            guard let url = sharedRoot else { throw TraceFailure.message("APP_GROUP_UNAVAILABLE：当前签名未提供可用的共享容器。不能进行可导出的跨 App 录制；请使用 App 内自检或配置 SharedCapture。") }
            return url
        }
        return try localRoot()
    }

    static func preflight(scope: RecordingScope, nativeAvailable: Bool, osVersion: String, localRootOverride: URL? = nil) -> CapturePreflight {
        var report = CapturePreflight(requestedScope: scope, ready: false, backend: "none", code: "NOT_CHECKED", message: "",
            bundleIdentifier: Bundle.main.bundleIdentifier ?? "unknown", extensionIdentifier: extensionID, appGroupIdentifier: groupID,
            sharedCaptureBuild: groupEnabled, buildSDK: Bundle.main.object(forInfoDictionaryKey: "DTSDKName") as? String ?? "unknown", osVersion: osVersion)
        do {
            let local: URL
            if let localRootOverride { local = localRootOverride } else { local = try localRoot() }
            try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
            report.freeDiskBytes = SessionStorage.freeBytes(at: local)
            if let free = report.freeDiskBytes, free < 250_000_000 {
                report.code = "INSUFFICIENT_STORAGE"; report.message = "开始录制至少需要 250 MB 可用空间。"; return report
            }
            if !scope.needsFullDisplay {
                report.ready = true; report.backend = "ReplayKit.RPScreenRecorder"; report.code = "APP_ONLY_READY"
                report.message = "仅采集本 App；切出会结束。后台与跨 App 采集请在录制页另选对应模式。"; return report
            }
            if nativeAvailable {
                let modes = Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String] ?? []
                guard modes.contains("screen-capture"), modes.contains("audio") else {
                    report.code = "NATIVE_BACKGROUND_MODES_MISSING"; report.message = "当前构建缺少 iOS 27 全屏捕获的后台配置，需要重新构建。"; return report
                }
                report.ready = true; report.backend = "ScreenCaptureKit"; report.code = "NATIVE_FULL_DISPLAY_READY"
                report.message = "可打开系统全屏捕获授权。收到真实画面后才会显示可以切换 App。"; return report
            }
            guard groupEnabled else {
                report.code = "FULL_DISPLAY_BUILD_NOT_CONFIGURED"
                report.message = "当前安装包未开启屏幕广播配置。请用默认 AudioTrace Scheme 重新构建安装，并让主 App 和广播扩展签署同一个 App Group。此广播方案支持当前 Xcode，无需先升级到 iOS 27 SDK。诊断场景不会改变安装包能力。"
                return report
            }
            guard let root = sharedRoot else {
                report.code = "APP_GROUP_UNAVAILABLE"; report.message = "共享容器不可用。请确认主 App 与广播扩展使用同一 Team、同一已授权 App Group；不能以 App 内录制代替。"; return report
            }
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let probe = root.appendingPathComponent(".probe_\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: probe) }
            let token = Data(UUID().uuidString.utf8)
            try token.write(to: probe, options: .atomic)
            guard try Data(contentsOf: probe) == token else { throw TraceFailure.message("共享容器读写校验不一致。") }
            let extensionBundle = (Bundle.main.builtInPlugInsURL?.appendingPathComponent("AudioTraceBroadcast.appex")).flatMap { Bundle(url: $0) }
            guard extensionBundle?.bundleIdentifier == extensionID, extensionID.hasPrefix(report.bundleIdentifier + ".") else {
                report.code = "BROADCAST_EXTENSION_MISMATCH"; report.message = "广播扩展未嵌入或 Bundle Identifier 与主 App 配置不一致。"; return report
            }
            report.ready = true; report.backend = "ReplayKit.BroadcastUploadExtension"; report.code = "BROADCAST_READY"
            report.message = "共享容器读写与扩展标识符通过检查。仍需系统广播授权和真实样本确认。"
        } catch { report.code = "PREFLIGHT_STORAGE_FAILED"; report.message = error.localizedDescription }
        return report
    }

    static func preflightURL() throws -> URL {
        let root = try localRoot().deletingLastPathComponent().appendingPathComponent("AudioTraceReports", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root.appendingPathComponent("latest_preflight.json")
    }
}

final class SessionLease {
    private var descriptor: Int32
    init(root: URL) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        descriptor = open(root.appendingPathComponent(".capture.lock").path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw TraceFailure.message("LOCK_OPEN_FAILED: \(errno)") }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor); descriptor = -1
            throw TraceFailure.message("CAPTURE_ALREADY_ACTIVE：已有录制进程占用此容器。")
        }
    }
    deinit { if descriptor >= 0 { flock(descriptor, LOCK_UN); close(descriptor) } }
}

enum SessionStorage {
    static func write<T: Encodable>(_ value: T, to url: URL) throws {
        try TraceJSON.encoder(pretty: true).encode(value).write(to: url, options: .atomic)
    }
    static func read<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        try TraceJSON.decoder().decode(type, from: Data(contentsOf: url))
    }
    static func files(in folder: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey])) ?? [])
            .filter { !$0.lastPathComponent.hasPrefix(".") && (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
    static func bytes(in folder: URL) -> Int64 {
        files(in: folder).reduce(0) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }
    static func freeBytes(at folder: URL) -> Int64? {
        guard let values = try? FileManager.default.attributesOfFileSystem(forPath: folder.path), let number = values[.systemFreeSize] as? NSNumber else { return nil }
        return number.int64Value
    }
    static func roots() -> [URL] {
        var roots = [URL]()
        if let local = try? CaptureConfiguration.localRoot() { roots.append(local) }
        if let shared = CaptureConfiguration.sharedRoot { roots.append(shared) }
        return roots
    }
    static func folders() -> [URL] {
        roots().flatMap { (try? FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil)) ?? [] }
            .filter { $0.lastPathComponent.hasPrefix("session_") }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }
    static func isWriterAlive(root: URL) -> Bool {
        let fd = open(root.appendingPathComponent(".capture.lock").path, O_RDWR)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        if flock(fd, LOCK_EX | LOCK_NB) != 0 { return true }
        flock(fd, LOCK_UN)
        return false
    }
    // Never infer a dead extension from a silent media stream alone. Check the OS file lock.
    static func recoverAbandoned(_ folder: URL) throws {
        let root = folder.deletingLastPathComponent()
        let lease = try SessionLease(root: root)
        defer { withExtendedLifetime(lease) {} }
        var metadata = try read(SessionMetadata.self, from: folder.appendingPathComponent("metadata.json"))
        guard ["recording", "paused", "finalizing"].contains(metadata.state) else { return }
        metadata.state = "interrupted"
        metadata.stopReason = "WRITER_TERMINATED_WITHOUT_FINALIZATION"
        metadata.recordingEndTime = metadata.heartbeat
        metadata.errors.append(CaptureEvent(uptime: ProcessInfo.processInfo.systemUptime, code: metadata.mode == "broadcast" ? "EXTENSION_TERMINATED" : "CAPTURE_PROCESS_TERMINATED", detail: "OS writer lock released; preserving all existing files. Last checkpoint may precede final samples.", pts: nil, level: "warning"))
        metadata.warningCount += 1
        metadata.errors = Array(metadata.errors.suffix(128))
        metadata.totalEventCount += 1
        metadata.integrity = "unverified after interruption; last MP4/WAV may be incomplete"
        try write(metadata, to: folder.appendingPathComponent("metadata.json"))
        if var diagnostic = try? read(DiagnosticSnapshot.self, from: folder.appendingPathComponent("diagnostics.json")) {
            diagnostic.state = metadata.state; diagnostic.recentEvents = metadata.errors
            diagnostic.totalEventCount = metadata.totalEventCount
            try write(diagnostic, to: folder.appendingPathComponent("diagnostics.json"))
        }
    }
}

final class JSONLineWriter {
    private let handle: FileHandle
    init(url: URL) throws {
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else { throw TraceFailure.message("LOG_CREATE_FAILED: \(url.lastPathComponent)") }
        handle = try FileHandle(forWritingTo: url)
    }
    func append<T: Encodable>(_ value: T) throws {
        var data = try TraceJSON.encoder().encode(value); data.append(0x0a)
        try handle.write(contentsOf: data)
    }
    func sync() throws { try handle.synchronize() }
    deinit { try? handle.close() }
}
