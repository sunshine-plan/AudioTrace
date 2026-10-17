import Foundation
import CoreMedia

enum RecordingScope: String, CaseIterable, Codable, Identifiable {
    case appOnly = "app_only"
    case background = "background_screen"
    case crossApp = "cross_app"
    var id: String { rawValue }
    var title: String {
        switch self { case .appOnly: return "仅 App 内录制"; case .background: return "切出 App 后继续录屏"; case .crossApp: return "跨 App 采集" }
    }
    var explanation: String {
        switch self {
        case .appOnly: return "采集 AudioTrace 的画面与音频，切出时结束。"
        case .background: return "通过系统全屏捕获录制主屏幕和其他界面；AudioTrace 可进入后台。"
        case .crossApp: return "通过系统全屏捕获，切到豆包等 App 后继续采集；各音轨能否取得由实际回调判断。"
        }
    }
    var needsFullDisplay: Bool { self != .appOnly }
}

struct CapturePreflight: Codable {
    var checkedAt = Date()
    var requestedScope: RecordingScope
    var ready: Bool
    var backend: String
    var code: String
    var message: String
    var bundleIdentifier: String
    var extensionIdentifier: String
    var appGroupIdentifier: String
    var sharedCaptureBuild: Bool
    var buildSDK: String
    var osVersion: String
    var freeDiskBytes: Int64?
}

struct BroadcastLaunchRequest: Codable {
    var requestId: String
    var scope: RecordingScope
    var scenario: String
    var createdAt: Date
}

struct HostActivity: Codable {
    var sessionId: String
    var background: Bool
    var observedAt: Date
    var uptime: Double
}

// CMTime remains rational; seconds are a convenience, never the synchronization source.
struct MediaTime: Codable, Equatable {
    var value: Int64
    var timescale: Int32
    var epoch: Int64
    init(_ time: CMTime) { value = time.value; timescale = time.timescale; epoch = time.epoch }
    var cmTime: CMTime { CMTime(value: value, timescale: timescale, flags: .valid, epoch: epoch) }
    var seconds: Double { CMTimeGetSeconds(cmTime) }
}

struct CaptureEvent: Codable {
    var uptime: Double
    var code: String
    var detail: String
    var pts: MediaTime?
    var level = "info"
}

struct AudioSegment: Codable {
    var filename: String
    var sampleRate: Double
    var channels: UInt32
    var frames: Int64 = 0
    var startPts: MediaTime
    var endPts: MediaTime
    var finalized = false
    var inputFormat: String
}

struct AudioReport: Codable {
    var available = false // At least one non-silent buffer successfully written.
    var state = "WAITING_FOR_DATA"
    var callbacks: Int64 = 0
    var validBuffers: Int64 = 0
    var nonSilentBuffers: Int64 = 0
    var receivedFrames: Int64 = 0
    var writtenFrames: Int64 = 0
    var droppedBuffers: Int64 = 0
    var detectedGapSeconds: Double = 0
    var rms: Double = 0
    var peak: Double = 0
    var consecutiveSilenceSeconds: Double = 0
    var lastCallbackUptime: Double?
    var lastValidUptime: Double?
    var lastNonSilentPts: MediaTime?
    var startPts: MediaTime?
    var endPts: MediaTime?
    var segments: [AudioSegment] = []
    var durationSeconds: Double = 0
}

struct VideoSegment: Codable {
    var filename: String
    var width: Int
    var height: Int
    var orientation: UInt32
    var targetFps: Int
    var frames: Int64 = 0
    var startPts: MediaTime
    var endPts: MediaTime
    var status = "writing"
    var actualFps: Double = 0
}

struct VideoReport: Codable {
    var available = false
    var callbacks: Int64 = 0
    var writtenFrames: Int64 = 0
    var droppedFrames: Int64 = 0
    var rateLimitedFrames: Int64 = 0
    var startPts: MediaTime?
    var endPts: MediaTime?
    var segments: [VideoSegment] = []
}

struct Synchronization: Codable {
    var sessionTimeOrigin: MediaTime?
    var clock = "ReplayKit CMSampleBuffer presentation time; shared media clock"
    var relativeTimeRule = "CMTimeSubtract(sourcePts, sessionTimeOrigin); negative offsets allowed"
    var audioTimeline = "Concatenated real samples only; timestamps.jsonl maps every written audio buffer to fileFrameOffset. No inserted silence."
    var videoTimeline = "Each MP4 starts at local zero; segments[].startPts places it on the source timeline. Orientation/time jumps/60s boundaries create parts."
    var systemAudioVideoOffset: Double?
    var microphoneVideoOffset: Double?
    var insertedSilenceIntervals: [String] = []
}

struct SessionMetadata: Codable, Identifiable {
    var schemaVersion = 1
    var sessionId: String
    var id: String { sessionId }
    var deviceModel: String
    var iosVersion: String
    var appVersion: String
    var captureFramework: String
    var mode: String
    var requestedScope: RecordingScope?
    var captureRequestId: String?
    var testScenario: String
    var recordingStartTime: Date
    var recordingEndTime: Date?
    var durationSeconds: Double = 0
    var heartbeat: Date
    var state = "recording"
    var stopReason: String?
    var video = VideoReport()
    var systemAudio = AudioReport()
    var microphoneAudio = AudioReport()
    var synchronization = Synchronization()
    var errors: [CaptureEvent] = [] // bounded recent events; complete stream in events.jsonl
    var totalEventCount: Int64 = 0
    var errorCount: Int64 = 0
    var warningCount: Int64 = 0
    var totalFileBytes: Int64 = 0
    var integrity = "pending; use the in-app integrity check after recording"
}

struct DiagnosticSnapshot: Codable {
    var schemaVersion = 1
    var state: String
    var captureFramework: String
    var video: VideoReport
    var systemAudio: AudioReport
    var microphoneAudio: AudioReport
    var fileBytes: Int64
    var recentEvents: [CaptureEvent]
    var totalEventCount: Int64
    var eventLog = "events.jsonl"
    var perSecondMetrics = "levels.jsonl"
    var timestampLog = "timestamps.jsonl"
    var heartbeat: Date
}

enum TraceJSON {
    static func encoder(pretty: Bool = false) -> JSONEncoder {
        let result = JSONEncoder()
        result.dateEncodingStrategy = .iso8601
        result.keyEncodingStrategy = .convertToSnakeCase
        if pretty { result.outputFormatting = [.prettyPrinted, .sortedKeys] }
        return result
    }
    static func decoder() -> JSONDecoder {
        let result = JSONDecoder()
        result.dateDecodingStrategy = .iso8601
        result.keyDecodingStrategy = .convertFromSnakeCase
        return result
    }
}
