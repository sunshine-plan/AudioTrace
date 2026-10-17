import Foundation
import CoreMedia
import AVFoundation
import ReplayKit

// Synthetic fixtures are kept under work/. They are NEVER claimed as ReplayKit captures.
func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw TraceFailure.message("TEST_FAILED: \(message)") }
}

func pcm(rate: Double = 48_000, channels: AVAudioChannelCount = 1, frames: Int = 4800,
         pts: Double, amplitude: Float = 0.2, frequency: Double = 440,
         integer: Bool = false) throws -> CMSampleBuffer {
    let format = AVAudioFormat(commonFormat: integer ? .pcmFormatInt16 : .pcmFormatFloat32, sampleRate: rate, channels: channels, interleaved: integer)!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
    buffer.frameLength = AVAudioFrameCount(frames)
    if integer {
        let pointer = buffer.int16ChannelData![0]
        for i in 0..<frames { for c in 0..<Int(channels) { pointer[i * Int(channels) + c] = Int16(sin(2 * .pi * frequency * Double(i) / rate) * Double(amplitude) * 32_767) } }
    } else {
        for c in 0..<Int(channels) { for i in 0..<frames { buffer.floatChannelData![c][i] = Float(sin(2 * .pi * frequency * Double(i) / rate)) * amplitude } }
    }
    var description: CMAudioFormatDescription?
    var asbd = format.streamDescription.pointee
    try require(CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &description) == noErr, "audio description")
    var sample: CMSampleBuffer?
    let createStatus = CMAudioSampleBufferCreateWithPacketDescriptions(allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: false, makeDataReadyCallback: nil, refcon: nil, formatDescription: description!, sampleCount: frames, presentationTimeStamp: CMTime(seconds: pts, preferredTimescale: 48_000), packetDescriptions: nil, sampleBufferOut: &sample)
    try require(createStatus == noErr, "audio sample create status=\(createStatus)")
    let setStatus = CMSampleBufferSetDataBufferFromAudioBufferList(sample!, blockBufferAllocator: kCFAllocatorDefault, blockBufferMemoryAllocator: kCFAllocatorDefault, flags: 0, bufferList: buffer.audioBufferList)
    try require(setStatus == noErr, "audio sample data status=\(setStatus)")
    CMSampleBufferSetDataReady(sample!)
    return sample!
}

func videoFrame(pts: Double, orientation: UInt32 = 1) throws -> CMSampleBuffer {
    var pixel: CVPixelBuffer?
    try require(CVPixelBufferCreate(kCFAllocatorDefault, 128, 96, kCVPixelFormatType_32BGRA,
        [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary, &pixel) == kCVReturnSuccess, "video pixel")
    CVPixelBufferLockBaseAddress(pixel!, [])
    memset(CVPixelBufferGetBaseAddress(pixel!), 127, CVPixelBufferGetDataSize(pixel!))
    CVPixelBufferUnlockBaseAddress(pixel!, [])
    var description: CMVideoFormatDescription?
    CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixel!, formatDescriptionOut: &description)
    var sample: CMSampleBuffer?
    var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30), presentationTimeStamp: CMTime(seconds: pts, preferredTimescale: 600), decodeTimeStamp: .invalid)
    CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixel!, formatDescription: description!, sampleTiming: &timing, sampleBufferOut: &sample)
    CMSetAttachment(sample!, key: RPVideoSampleOrientationKey as CFString, value: NSNumber(value: orientation), attachmentMode: kCMAttachmentMode_ShouldPropagate)
    return sample!
}

@main struct CoreTests {
    static func main() async throws {
        let base = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let root = base.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let engine = try CaptureEngine(root: root, mode: "synthetic_unit_test", scenario: "SYNTHETIC_FIXTURES_ONLY", device: "macOS test harness", os: ProcessInfo.processInfo.operatingSystemVersionString)
        engine.startMonitoring()
        try require(SessionStorage.isWriterAlive(root: root), "writer lease is visible across handles")
        do {
            _ = try SessionExporter.zip(folder: engine.folder, destination: base.appendingPathComponent("must-not-exist.zip"))
            throw TraceFailure.message("TEST_FAILED: exported active recording")
        } catch let error as TraceFailure { if error.localizedDescription.contains("TEST_FAILED") { throw error } }
        do { _ = try SessionLease(root: root); throw TraceFailure.message("TEST_FAILED: duplicate writer allowed") }
        catch let error as TraceFailure { if error.localizedDescription.contains("TEST_FAILED") { throw error } }
        engine.consume(try pcm(pts: 100), type: .audioApp)
        engine.consume(try pcm(pts: 100.05, frequency: 880), type: .audioMic)
        engine.consume(try pcm(pts: 100.2), type: .audioApp) // real gap: no inserted samples
        engine.consume(try pcm(rate: 44_100, channels: 2, frames: 4410, pts: 100.3, integer: true), type: .audioApp)
        engine.consume(try pcm(pts: 100.15, amplitude: 0), type: .audioMic)
        for i in 0..<12 {
            engine.consume(try videoFrame(pts: 100 + Double(i) / 30), type: .video)
            try await Task.sleep(for: .milliseconds(40))
        }
        // Exercise orientation boundary, asynchronous writer draining, and pause/resume.
        engine.consume(try videoFrame(pts: 100.5, orientation: 6), type: .video)
        try await Task.sleep(for: .milliseconds(150))
        engine.consume(try videoFrame(pts: 100.6, orientation: 6), type: .video)
        engine.setPaused(true); engine.setPaused(false)
        engine.consume(try pcm(pts: 101.0, frequency: 880), type: .audioMic)
        // Ten minutes of source audio time, accelerated, two independent pipelines. This
        // tests bounded processing and rollover, NOT ten minutes of actual iPhone recording.
        for i in 0..<6000 {
            try autoreleasepool {
                engine.consume(try pcm(pts: 102 + Double(i) / 10), type: .audioApp)
                engine.consume(try pcm(pts: 102.05 + Double(i) / 10, frequency: 880), type: .audioMic)
            }
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            engine.finish(reason: "user") { continuation.resume() }
        }
        try require(!SessionStorage.isWriterAlive(root: root), "lease released after finalize")
        let metadata = try SessionStorage.read(SessionMetadata.self, from: engine.folder.appendingPathComponent("metadata.json"))
        try require(metadata.state == "completed", "state serialized and decoded")
        try require(metadata.sessionId == engine.folder.lastPathComponent, "snake_case identifier roundtrip")
        try require(metadata.systemAudio.writtenFrames == 4800 * 2 + 4410 + 6000 * 4800, "system PCM frames exactly preserved")
        try require(metadata.microphoneAudio.writtenFrames == 4800 * 3 + 6000 * 4800, "microphone PCM frames exactly preserved")
        try require(metadata.systemAudio.segments.count > 10, "periodic WAV recovery segments")
        try require(metadata.video.writtenFrames > 0, "H264 encoded video")
        try require(metadata.video.segments.count >= 2, "orientation segmentation")
        try require(metadata.synchronization.sessionTimeOrigin?.seconds == 100, "media clock origin")
        try require(abs((metadata.synchronization.microphoneVideoOffset ?? 0) - 0.05) < 0.0001, "cross-stream offset")
        try require(metadata.systemAudio.detectedGapSeconds > 0.1, "missing interval detected")
        try require(metadata.synchronization.insertedSilenceIntervals.isEmpty, "no gap hidden with fabricated samples")
        let integrity = try await IntegrityChecker.check(folder: engine.folder)
        try require(integrity.passed, "integrity check: \(integrity.issues)")
        try "UTF-8 filename and payload ✓".write(to: engine.folder.appendingPathComponent("测试说明.txt"), atomically: true, encoding: .utf8)
        _ = try SessionExporter.zip(folder: engine.folder, destination: base.appendingPathComponent("verified-session.zip"))
        print("PASS: real CoreMedia fixtures -> independent WAV conversion / H264 / timestamps / format changes / orientation / locks / integrity / streaming ZIP")
        print("TEST_SESSION=\(engine.folder.path)")
        // Separate watchdog test: no media callbacks must stay distinguishable from silence.
        let diagFolder = base.appendingPathComponent("watchdog-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: diagFolder, withIntermediateDirectories: true)
        let diagnostics = try CaptureDiagnostics(folder: diagFolder)
        let mic = MicrophoneAudioPipeline(folder: diagFolder, diagnostics: diagnostics)
        mic.tick(now: 4, captureStarted: 0, paused: false)
        try require(mic.report.state == "UNAVAILABLE", "missing callbacks")
        try require(!FileManager.default.fileExists(atPath: diagFolder.appendingPathComponent("microphone_audio.wav").path), "no callback produces no fabricated WAV")
        let start = ProcessInfo.processInfo.systemUptime
        for i in 0..<25 { mic.consume(try pcm(pts: Double(i)/10, amplitude: 0)) }
        try require(mic.report.state == "SILENT", "real silent PCM distinguished")
        mic.tick(now: start + 8, captureStarted: start, paused: false)
        try require(mic.report.state == "INTERRUPTED", "callback watchdog")
        mic.finish()
        try require(!mic.report.available, "silent track does not claim a captured voice")
        try require(diagnostics.recent.contains { $0.code == "MIC_CAPTURE_SILENT" }, "silent event")
        try require(diagnostics.recent.contains { $0.code == "MIC_CAPTURE_INTERRUPTED" }, "interruption event")
        let rejected = SystemAudioPipeline(folder: diagFolder, diagnostics: diagnostics)
        rejected.consume(try pcm(frames: 20_000, pts: 0))
        try require(rejected.report.state == "AUDIO_FORMAT_INVALID", "oversized callback rejected with bounded allocation")
        var abandoned = metadata
        abandoned.state = "recording"
        try SessionStorage.write(abandoned, to: engine.folder.appendingPathComponent("metadata.json"))
        try SessionStorage.recoverAbandoned(engine.folder)
        let recovered = try SessionStorage.read(SessionMetadata.self, from: engine.folder.appendingPathComponent("metadata.json"))
        try require(recovered.state == "interrupted", "abandoned session marked after OS lock release")
        try require(FileManager.default.fileExists(atPath: engine.folder.appendingPathComponent("screen.mp4").path), "recovery preserves files")
        print("PASS: no callbacks / real silence / callback interruption remain distinguishable")
        print("PASS: active export blocked / no fabricated WAV / oversized PCM bounded / abandoned session recovery")
    }
}
