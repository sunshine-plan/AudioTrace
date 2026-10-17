import Foundation
import AVFoundation
import CryptoKit

@main struct CaptureFlowTests {
    static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let session = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        try require(RecordingScope.allCases.count == 3, "three independent recording intentions")
        let appCheck = CaptureConfiguration.preflight(scope: .appOnly, nativeAvailable: false, osVersion: "test", localRootOverride: root.appendingPathComponent("preflight"))
        let fullCheck = CaptureConfiguration.preflight(scope: .crossApp, nativeAvailable: false, osVersion: "27.0.1", localRootOverride: root.appendingPathComponent("preflight"))
        try require(appCheck.ready && !fullCheck.ready, "missing full-display capability must not fall back to app-only")
        try require(fullCheck.backend == "none", "no imaginary full-display backend")
        let metadata = try SessionStorage.read(SessionMetadata.self, from: session.appendingPathComponent("metadata.json"))
        try require(metadata.mode == "in_app_self_test", "uploaded session decodes without new optional fields")
        try require(metadata.stopReason == "IN_APP_BACKGROUND_STOP", "uploaded evidence identifies actual stop path")
        let originals = SessionStorage.files(in: session).filter { ["mp4", "wav"].contains($0.pathExtension) }
        var hashes: [String: SHA256.Digest] = [:]
        for file in originals { hashes[file.lastPathComponent] = SHA256.hash(data: try Data(contentsOf: file)) }
        let output = try await MultiTrackExporter.create(folder: session, progress: { message in print(message); fflush(stdout) })
        let asset = AVURLAsset(url: output)
        let video = try await asset.loadTracks(withMediaType: .video)
        let audio = try await asset.loadTracks(withMediaType: .audio)
        try require(video.count == 1 && audio.count == 2, "MOV must preserve one video and TWO independent audio tracks")
        let manifest = try SessionStorage.read(MultiTrackManifest.self, from: session.appendingPathComponent("synchronized_tracks.json"))
        try require(manifest.audioTrackOrder == ["system", "microphone"], "independent track order recorded")
        let earliest = min(metadata.video.startPts!.seconds, metadata.systemAudio.startPts!.seconds, metadata.microphoneAudio.startPts!.seconds)
        try require(abs(manifest.exportTimeOrigin.seconds - earliest) < 0.000_001, "negative microphone offset preserved by rebasing export timeline")
        let videoRange = try await video[0].load(.timeRange)
        let sourceVideoOffset = metadata.video.startPts!.seconds - earliest
        let reader = try AVAssetReader(asset: asset)
        let trackOutput = AVAssetReaderTrackOutput(track: video[0], outputSettings: nil)
        reader.add(trackOutput)
        try require(reader.startReading(), "read synchronized video timestamps")
        let firstVideoSample = trackOutput.copyNextSampleBuffer()!
        let outputVideoStart = CMSampleBufferGetPresentationTimeStamp(firstVideoSample).seconds
        let outputPTS = CMSampleBufferGetOutputPresentationTimeStamp(firstVideoSample).seconds
        let segments = try await video[0].load(.segments)
        print("MOV timing: videoRangeStart=\(videoRange.start.seconds), mediaPTS=\(outputVideoStart), outputPTS=\(outputPTS), expectedOffset=\(sourceVideoOffset)")
        for segment in segments { print("edit empty=\(segment.isEmpty) source=\(segment.timeMapping.source.start.seconds) target=\(segment.timeMapping.target.start.seconds) duration=\(segment.timeMapping.target.duration.seconds)") }
        fflush(stdout)
        reader.cancelReading()
        guard let firstMediaEdit = segments.first(where: { !$0.isEmpty }) else { throw TraceFailure.message("TEST_FAILED: video has no real media edit") }
        let presentedVideoStart = outputVideoStart - firstMediaEdit.timeMapping.source.start.seconds + firstMediaEdit.timeMapping.target.start.seconds
        try require(abs(presentedVideoStart - sourceVideoOffset) < 0.000_01, "movie presentation edit preserves video offset within 10 microseconds")
        let expectedFrames = [metadata.systemAudio.writtenFrames, metadata.microphoneAudio.writtenFrames]
        let expectedOffsets = [metadata.systemAudio.startPts!.seconds - earliest, metadata.microphoneAudio.startPts!.seconds - earliest]
        for index in audio.indices {
            let edits = try await audio[index].load(.segments)
            guard let first = edits.first(where: { !$0.isEmpty }) else { throw TraceFailure.message("TEST_FAILED: missing audio edit") }
            let expectedRate = index == 0 ? metadata.systemAudio.segments[0].sampleRate : metadata.microphoneAudio.segments[0].sampleRate
            try require(abs(first.timeMapping.target.start.seconds - expectedOffsets[index]) <= 1 / expectedRate + 0.000_001, "audio movie edit preserves each source offset to sample precision")
            let audioReader = try AVAssetReader(asset: asset)
            let audioOutput = AVAssetReaderTrackOutput(track: audio[index], outputSettings: nil)
            audioReader.add(audioOutput)
            try require(audioReader.startReading(), "read each independent PCM track")
            var frames: Int64 = 0
            while let sample = audioOutput.copyNextSampleBuffer() { frames += Int64(CMSampleBufferGetNumSamples(sample)) }
            try require(frames == expectedFrames[index], "synchronized MOV must preserve exact captured PCM frame count")
        }
        for file in originals { let hash = SHA256.hash(data: try Data(contentsOf: file)); try require(hash == hashes[file.lastPathComponent]!, "original media must remain unchanged") }
        let repeated = try await MultiTrackExporter.create(folder: session, progress: { message in print(message); fflush(stdout) })
        try require(FileManager.default.fileExists(atPath: repeated.path), "repeated generation atomically replaces the derived file")
        print("PASS: uploaded-session compatibility / actual evidence / MOV video+2 independent PCM tracks / exact timeline origin / original SHA256 unchanged / repeat export")

        let engine = try CaptureEngine(root: root.appendingPathComponent(UUID().uuidString), mode: "synthetic_background_test", scenario: "SYNTHETIC ONLY", device: "macOS test", os: "test", requestedScope: .crossApp, requestId: "unit-background")
        engine.startMonitoring()
        for i in 0..<3 { engine.consume(try videoFrame(pts: 100 + Double(i)/30), type: .video); try await Task.sleep(for: .milliseconds(40)) }
        engine.noteHostActivity(background: true)
        for i in 3..<6 { engine.consume(try videoFrame(pts: 100 + Double(i)/30), type: .video); try await Task.sleep(for: .milliseconds(40)) }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in engine.finish(reason: "user") { continuation.resume() } }
        let events = try String(contentsOf: engine.folder.appendingPathComponent("events.jsonl"), encoding: .utf8)
        try require(events.contains("HOST_ENTERED_BACKGROUND") && events.contains("BACKGROUND_VIDEO_CONFIRMED"), "background success requires an actual written frame after the lifecycle event")
        try require(!events.contains("IN_APP_BACKGROUND_STOP"), "full-display capture must not use app-only stop reason")
        let result = try SessionStorage.read(SessionMetadata.self, from: engine.folder.appendingPathComponent("metadata.json"))
        try require(result.requestedScope == .crossApp && result.captureRequestId == "unit-background", "recording scope and handshake roundtrip")
        print("PASS: scope and request handshake / genuine frame required for background evidence / no app-only fallback")
    }
}
