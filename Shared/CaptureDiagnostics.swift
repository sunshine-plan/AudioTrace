import Foundation
import CoreMedia

// Accessed under CaptureEngine's lock. History streams to disk; RAM history is bounded.
final class CaptureDiagnostics {
    private let events: JSONLineWriter
    let levels: JSONLineWriter
    let timestamps: JSONLineWriter
    private(set) var recent: [CaptureEvent] = []
    private(set) var count: Int64 = 0
    private(set) var errorCount: Int64 = 0
    private(set) var warningCount: Int64 = 0
    private(set) var logError: String?
    init(folder: URL) throws {
        events = try JSONLineWriter(url: folder.appendingPathComponent("events.jsonl"))
        levels = try JSONLineWriter(url: folder.appendingPathComponent("levels.jsonl"))
        timestamps = try JSONLineWriter(url: folder.appendingPathComponent("timestamps.jsonl"))
    }
    func event(_ code: String, _ detail: String, pts: CMTime? = nil) {
        var event = CaptureEvent(uptime: ProcessInfo.processInfo.systemUptime, code: code, detail: detail, pts: pts.flatMap { $0.isNumeric ? MediaTime($0) : nil })
        if ["FAILED", "INVALID", "TIMEOUT", "CRITICAL"].contains(where: code.contains) { event.level = "error"; errorCount += 1 }
        else if ["UNAVAILABLE", "INTERRUPTED", "SILENT", "GAP", "BACKWARDS", "DENIED", "LOW_STORAGE", "MEMORY_PRESSURE", "MEMORY_BUDGET"].contains(where: code.contains) { event.level = "warning"; warningCount += 1 }
        count += 1
        if recent.count == 128 { recent.removeFirst() }
        recent.append(event)
        do { try events.append(event) } catch { logError = "EVENT_LOG_WRITE_FAILED: \(error.localizedDescription)" }
    }
    func sync() throws { try events.sync(); try levels.sync(); try timestamps.sync() }
}

struct TimestampRecord: Codable {
    var stream: String
    var sourcePts: MediaTime
    var duration: MediaTime?
    var filename: String
    var fileFrameOffset: Int64
    var frameCount: Int
}

struct AudioLevelRecord: Codable {
    var stream: String
    var uptime: Double
    var firstPts: MediaTime?
    var lastPts: MediaTime?
    var frames: Int64
    var callbacks: Int64
    var rms: Double
    var peak: Double
    var silenceSeconds: Double
    var state: String
}

struct PerformanceRecord: Codable {
    var stream = "performance"
    var uptime: Double
    var thermalState: Int
    var physicalFootprintBytes: UInt64?
    var freeDiskBytes: Int64?
    var videoWrittenFrames: Int64
    var videoDroppedFrames: Int64
    var maximumCallbackProcessingMilliseconds: Double
}
