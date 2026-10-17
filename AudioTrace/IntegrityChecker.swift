import Foundation
import AVFoundation
import CryptoKit

struct IntegrityFile: Codable {
    var filename: String
    var bytes: Int64
    var sha256: String
    var valid: Bool
    var detail: String
}
struct IntegrityReport: Codable {
    var checkedAt: Date
    var passed: Bool
    var files: [IntegrityFile]
    var issues: [String]
}

enum IntegrityChecker {
    static func check(folder: URL) async throws -> IntegrityReport {
        guard !SessionStorage.isWriterAlive(root: folder.deletingLastPathComponent()) else { throw TraceFailure.message("录制进程仍在写入，请停止后再校验。") }
        let metadata = try SessionStorage.read(SessionMetadata.self, from: folder.appendingPathComponent("metadata.json"))
        var issues: [String] = []
        let expected = metadata.video.segments.map(\.filename) + metadata.systemAudio.segments.map(\.filename) + metadata.microphoneAudio.segments.map(\.filename)
        for name in expected where !FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path) { issues.append("MISSING_FILE: \(name)") }
        var results: [IntegrityFile] = []
        for file in SessionStorage.files(in: folder) where file.lastPathComponent != "integrity.json" {
            var hash = SHA256()
            let handle = try FileHandle(forReadingFrom: file)
            do {
                while let data = try handle.read(upToCount: 65_536), !data.isEmpty { hash.update(data: data) }
                try handle.close()
            } catch { try? handle.close(); throw error }
            let bytes = Int64((try file.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0)
            var valid = bytes > 0, detail = "SHA256 recorded"
            do {
                switch file.pathExtension {
                case "wav":
                    let audio = try AVAudioFile(forReading: file)
                    guard audio.length > 0, let buffer = AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: 4096) else { throw TraceFailure.message("EMPTY_WAV") }
                    var frames: Int64 = 0
                    while audio.framePosition < audio.length {
                        try audio.read(into: buffer)
                        guard buffer.frameLength > 0 else { throw TraceFailure.message("WAV_PREMATURE_EOF") }
                        frames += Int64(buffer.frameLength)
                    }
                    if let segment = (metadata.systemAudio.segments + metadata.microphoneAudio.segments).first(where: { $0.filename == file.lastPathComponent }), segment.finalized, segment.frames != frames {
                        throw TraceFailure.message("WAV_FRAME_COUNT_MISMATCH expected=\(segment.frames) actual=\(frames)")
                    }
                    detail = "Decoded \(frames) frames, \(audio.fileFormat.sampleRate) Hz, \(audio.fileFormat.channelCount) channels"
                case "mp4", "mov":
                    let asset = AVURLAsset(url: file)
                    let tracks = try await asset.loadTracks(withMediaType: .video)
                    guard let track = tracks.first else { throw TraceFailure.message("VIDEO_TRACK_MISSING") }
                    let reader = try AVAssetReader(asset: asset)
                    let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
                    output.alwaysCopiesSampleData = false; reader.add(output)
                    guard reader.startReading() else { throw reader.error ?? TraceFailure.message("VIDEO_READER_FAILED") }
                    var count: Int64 = 0
                    while let sample = output.copyNextSampleBuffer() { count += Int64(CMSampleBufferGetNumSamples(sample)) }
                    guard reader.status == .completed, count > 0 else { throw reader.error ?? TraceFailure.message("VIDEO_DEMUX_FAILED") }
                    if let segment = metadata.video.segments.first(where: { $0.filename == file.lastPathComponent }), segment.status == "completed", segment.frames != count { throw TraceFailure.message("VIDEO_FRAME_COUNT_MISMATCH") }
                    if file.pathExtension == "mov", file.lastPathComponent == "synchronized_tracks.mov" {
                        let manifest = try SessionStorage.read(MultiTrackManifest.self, from: folder.appendingPathComponent("synchronized_tracks.json"))
                        let audio = try await asset.loadTracks(withMediaType: .audio)
                        guard audio.count == manifest.audioTracks else { throw TraceFailure.message("SYNC_AUDIO_TRACK_COUNT_MISMATCH") }
                    }
                    detail = "Demuxed \(count) compressed frames; playback/decode must still be checked on device"
                case "json":
                    _ = try JSONSerialization.jsonObject(with: Data(contentsOf: file)); detail = "JSON parsed"
                case "jsonl":
                    // Empty event/timing logs are valid when permission was denied or no data arrived.
                    valid = true; detail = "Stream log hash recorded; inspect records for capture gaps"
                default: break
                }
            } catch { valid = false; detail = error.localizedDescription }
            if !valid { issues.append("\(file.lastPathComponent): \(detail)") }
            results.append(IntegrityFile(filename: file.lastPathComponent, bytes: bytes, sha256: hash.finalize().map { String(format: "%02x", $0) }.joined(), valid: valid, detail: detail))
        }
        if metadata.video.writtenFrames == 0 { issues.append("NO_VIDEO_CAPTURED") }
        let report = IntegrityReport(checkedAt: Date(), passed: issues.isEmpty, files: results, issues: issues)
        try SessionStorage.write(report, to: folder.appendingPathComponent("integrity.json"))
        return report
    }
}

struct MultiTrackManifest: Codable {
    var createdAt: Date
    var filename: String
    var sourceSessionId: String
    var exportTimeOrigin: MediaTime
    var videoTracks: Int
    var audioTracks: Int
    var audioTrackOrder: [String]
    var sourceFiles: [String]
    var gapPolicy = "Source PTS gaps remain unfilled intervals in MOV. No synthetic PCM is written into the source WAV files."
}

// MOV is used because it can preserve H.264 plus two independent lossless PCM tracks.
// This is a derived file; the original MP4 and WAV parts remain untouched.
enum MultiTrackExporter {
    private struct Span {
        var stream: String
        var filename: String
        var start: CMTime
        var fileOffset: Int64
        var frames: Int64
        var rate: Int32
        var duration: CMTime { CMTime(value: frames, timescale: rate) }
    }
    static func create(folder: URL, progress: @Sendable (String) -> Void = { _ in }) async throws -> URL {
        guard !SessionStorage.isWriterAlive(root: folder.deletingLastPathComponent()) else { throw TraceFailure.message("请在录制结束后生成同步素材。") }
        let metadata = try SessionStorage.read(SessionMetadata.self, from: folder.appendingPathComponent("metadata.json"))
        let videos = metadata.video.segments.filter { $0.frames > 0 && $0.status == "completed" }
        guard !videos.isEmpty else { throw TraceFailure.message("没有已完成的视频片段，不能生成同步音视频。独立音轨仍可播放和导出。") }
        guard Set(videos.map(\.orientation)).count == 1 else { throw TraceFailure.message("本次录制包含不同方向的视频片段；当前同步 MOV 生成仅支持同一方向。请分别播放或导出原始视频与音轨。") }
        guard Set(videos.map { "\($0.width)x\($0.height)" }).count == 1 else { throw TraceFailure.message("视频尺寸在录制中改变，当前无法无损合成同一视频轨；请分别导出原始片段。") }
        let audioSegments = metadata.systemAudio.segments + metadata.microphoneAudio.segments
        let formats = Dictionary(uniqueKeysWithValues: audioSegments.map { ($0.filename, $0.sampleRate) })
        var spans: [Span] = []
        // Coalesce contiguous buffers to keep AVComposition edit count bounded. Every
        // discontinuity and every source-file rollover remains an explicit separate span.
        let handle = try FileHandle(forReadingFrom: folder.appendingPathComponent("timestamps.jsonl"))
        defer { try? handle.close() }
        var pending = Data()
        func consumeLine(_ line: Data) throws {
            guard !line.isEmpty else { return }
            let record = try TraceJSON.decoder().decode(TimestampRecord.self, from: line)
            guard record.stream == "system" || record.stream == "microphone", let rate = formats[record.filename], rate > 0 else { return }
            let current = Span(stream: record.stream, filename: record.filename, start: record.sourcePts.cmTime, fileOffset: record.fileFrameOffset, frames: Int64(record.frameCount), rate: Int32(rate.rounded()))
            if let index = spans.lastIndex(where: { $0.stream == current.stream }) {
                let previous = spans[index]
                let distance = CMTimeGetSeconds(CMTimeSubtract(current.start, CMTimeAdd(previous.start, previous.duration)))
                if previous.filename == current.filename, previous.start.epoch == current.start.epoch,
                   previous.fileOffset + previous.frames == current.fileOffset, abs(distance) <= 2 / rate {
                    spans[index].frames += current.frames
                    return
                }
            }
            guard spans.count < 20_000 else { throw TraceFailure.message("时间轴碎片过多，请导出原始素材进行后期处理。") }
            spans.append(current)
        }
        while let chunk = try handle.read(upToCount: 65_536), !chunk.isEmpty {
            pending.append(chunk)
            while let newline = pending.firstIndex(of: 10) {
                try consumeLine(Data(pending[..<newline])); pending.removeSubrange(...newline)
            }
            guard pending.count < 1_000_000 else { throw TraceFailure.message("TIMESTAMP_LOG_LINE_TOO_LARGE") }
        }
        if !pending.isEmpty { try consumeLine(pending) }
        let points = videos.map { $0.startPts.cmTime } + spans.map(\.start)
        guard Set(points.map(\.epoch)).count == 1, let origin = points.min(by: { CMTimeCompare($0, $1) < 0 }) else {
            throw TraceFailure.message("源媒体时钟 epoch 发生变化，不能把不同 epoch 自动拼成连续录制。请分别导出原始素材。")
        }
        let expectedBytes = videos.reduce(Int64(0)) { $0 + Int64((try? folder.appendingPathComponent($1.filename).resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
            + audioSegments.reduce(Int64(0)) { $0 + $1.frames * Int64($1.channels) * 2 }
        if let free = SessionStorage.freeBytes(at: folder), free < expectedBytes + 50_000_000 { throw TraceFailure.message("空间不足以生成同步素材；可分别导出原始文件。") }
        var jobs: [[SourceJob]] = []
        var videoJobs: [SourceJob] = []
        for segment in videos {
            let asset = AVURLAsset(url: folder.appendingPathComponent(segment.filename))
            guard let source = try await asset.loadTracks(withMediaType: .video).first else { throw TraceFailure.message("VIDEO_TRACK_MISSING") }
            videoJobs.append(SourceJob(asset: asset, track: source, range: try await source.load(.timeRange), targetStart: CMTimeSubtract(segment.startPts.cmTime, origin)))
        }
        jobs.append(videoJobs)
        var trackOrder: [String] = []
        for stream in ["system", "microphone"] {
            var audioJobs: [SourceJob] = []
            let streamSegments = stream == "system" ? metadata.systemAudio.segments : metadata.microphoneAudio.segments
            guard Set(streamSegments.map { "\($0.sampleRate):\($0.channels)" }).count <= 1 else { throw TraceFailure.message("\(stream) 的采样率或声道在录制中改变，当前同步 MOV 不会强行混合这些格式；请导出独立音轨片段。") }
            for span in spans where span.stream == stream {
                let asset = AVURLAsset(url: folder.appendingPathComponent(span.filename))
                guard let source = try await asset.loadTracks(withMediaType: .audio).first else { throw TraceFailure.message("AUDIO_TRACK_MISSING") }
                audioJobs.append(SourceJob(asset: asset, track: source, range: CMTimeRange(start: CMTime(value: span.fileOffset, timescale: span.rate), duration: span.duration), targetStart: CMTimeSubtract(span.start, origin)))
            }
            if !audioJobs.isEmpty { jobs.append(audioJobs); trackOrder.append(stream) }
        }
        let temporary = folder.appendingPathComponent(".synchronized_\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: temporary) }
        progress("write MOV with explicit per-sample timeline; video and audio passthrough")
        try await writeSources(jobs, to: temporary, audioTrackNames: trackOrder)
        let resultAsset = AVURLAsset(url: temporary)
        let audioCount = try await resultAsset.loadTracks(withMediaType: .audio).count
        let videoCount = try await resultAsset.loadTracks(withMediaType: .video).count
        guard audioCount == trackOrder.count, videoCount == 1 else { throw TraceFailure.message("导出器没有保留预期的独立音轨，未将结果标记为成功。") }
        let destination = folder.appendingPathComponent("synchronized_tracks.mov")
        if FileManager.default.fileExists(atPath: destination.path) { _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary) }
        else { try FileManager.default.moveItem(at: temporary, to: destination) }
        let manifest = MultiTrackManifest(createdAt: Date(), filename: destination.lastPathComponent, sourceSessionId: metadata.sessionId,
            exportTimeOrigin: MediaTime(origin), videoTracks: videoCount, audioTracks: audioCount, audioTrackOrder: trackOrder,
            sourceFiles: videos.map(\.filename) + audioSegments.map(\.filename))
        try SessionStorage.write(manifest, to: folder.appendingPathComponent("synchronized_tracks.json"))
        return destination
    }
    private struct SourceJob {
        // AVAssetTrack.asset is weak. Retain its asset for the complete transfer.
        var asset: AVURLAsset
        var track: AVAssetTrack
        var range: CMTimeRange
        var targetStart: CMTime
    }
    private struct Transfer {
        var input: AVAssetWriterInput
        var jobs: [SourceJob]
        var index = 0
        var reader: AVAssetReader?
        var output: AVAssetReaderTrackOutput?
        var done = false
    }
    private static func shifted(_ sample: CMSampleBuffer, by delta: CMTime) throws -> CMSampleBuffer {
        // AVAssetReader delivers one video sample or a constant-rate PCM buffer.
        // One timing entry preserves the per-frame duration without allocating a
        // timing array proportional to every PCM sample in a large WAV read.
        var timing = CMSampleTimingInfo()
        let status = CMSampleBufferGetSampleTimingInfo(sample, at: 0, timingInfoOut: &timing)
        guard status == noErr, timing.presentationTimeStamp.isNumeric else { throw TraceFailure.message("SYNC_SAMPLE_TIMING_INVALID: OSStatus=\(status)") }
        timing.presentationTimeStamp = CMTimeAdd(timing.presentationTimeStamp, delta)
        if timing.decodeTimeStamp.isNumeric { timing.decodeTimeStamp = CMTimeAdd(timing.decodeTimeStamp, delta) }
        var retimed: CMSampleBuffer?
        guard CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault, sampleBuffer: sample, sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleBufferOut: &retimed) == noErr, let retimed else { throw TraceFailure.message("SYNC_SAMPLE_RETIME_FAILED") }
        return retimed
    }

    private static func writeSources(_ jobs: [[SourceJob]], to url: URL, audioTrackNames: [String]) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        writer.movieTimeScale = 1_000_000_000
        var transfers: [Transfer] = []
        var audioIndex = 0
        for sourceJobs in jobs {
            guard let first = sourceJobs.first else { continue }
            let formats = try await first.track.load(.formatDescriptions)
            guard let format = formats.first else { throw TraceFailure.message("SYNC_SOURCE_FORMAT_MISSING") }
            let type = first.track.mediaType
            let input = AVAssetWriterInput(mediaType: type, outputSettings: nil, sourceFormatHint: format)
            input.expectsMediaDataInRealTime = false
            if type == .video {
                input.transform = try await first.track.load(.preferredTransform)
                input.mediaTimeScale = 600_000
            } else {
                let title = AVMutableMetadataItem(); title.identifier = .commonIdentifierTitle
                title.value = (audioIndex < audioTrackNames.count ? audioTrackNames[audioIndex] : "audio") as NSString
                input.metadata = [title]; audioIndex += 1
            }
            guard writer.canAdd(input) else { throw TraceFailure.message("SYNC_PASSTHROUGH_FORMAT_UNSUPPORTED") }
            writer.add(input); transfers.append(Transfer(input: input, jobs: sourceJobs))
        }
        guard writer.startWriting() else { throw writer.error ?? TraceFailure.message("SYNC_WRITER_START_FAILED") }
        writer.startSession(atSourceTime: .zero)
        let deadline = Date().addingTimeInterval(120)
        do {
            while transfers.contains(where: { !$0.done }) {
                try Task.checkCancellation()
                guard Date() < deadline else { throw TraceFailure.message("SYNC_WRITE_TIMEOUT") }
                guard writer.status == .writing else { throw writer.error ?? TraceFailure.message("SYNC_WRITER_FAILED") }
                var progressed = false
                for index in transfers.indices where !transfers[index].done {
                    guard transfers[index].input.isReadyForMoreMediaData else { continue }
                    if transfers[index].reader == nil {
                        guard transfers[index].index < transfers[index].jobs.count else {
                            transfers[index].input.markAsFinished(); transfers[index].done = true; progressed = true; continue
                        }
                        let job = transfers[index].jobs[transfers[index].index]
                        let reader = try AVAssetReader(asset: job.asset)
                        reader.timeRange = job.range
                        let output = AVAssetReaderTrackOutput(track: job.track, outputSettings: nil)
                        output.alwaysCopiesSampleData = false
                        guard reader.canAdd(output) else { throw TraceFailure.message("SYNC_READER_OUTPUT_UNSUPPORTED") }
                        reader.add(output)
                        guard reader.startReading() else { throw reader.error ?? TraceFailure.message("SYNC_READER_START_FAILED") }
                        transfers[index].reader = reader; transfers[index].output = output
                    }
                    if let sample = transfers[index].output?.copyNextSampleBuffer() {
                        guard CMSampleBufferGetNumSamples(sample) > 0 else { progressed = true; continue }
                        let job = transfers[index].jobs[transfers[index].index]
                        let retimed = try shifted(sample, by: CMTimeSubtract(job.targetStart, job.range.start))
                        guard transfers[index].input.append(retimed) else { throw writer.error ?? TraceFailure.message("SYNC_SAMPLE_APPEND_FAILED") }
                    } else {
                        if transfers[index].reader?.status == .failed { throw transfers[index].reader?.error ?? TraceFailure.message("SYNC_READER_FAILED") }
                        transfers[index].reader = nil; transfers[index].output = nil; transfers[index].index += 1
                    }
                    progressed = true
                }
                if !progressed { try await Task.sleep(for: .milliseconds(2)) }
            }
        } catch { transfers.forEach { $0.reader?.cancelReading() }; writer.cancelWriting(); throw error }
        await withCheckedContinuation { continuation in writer.finishWriting { continuation.resume() } }
        guard writer.status == .completed else { throw writer.error ?? TraceFailure.message("SYNC_FINALIZE_FAILED") }
    }
}
