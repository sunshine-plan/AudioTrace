import Foundation
import AVFoundation
import AudioToolbox
import Accelerate

class AudioCapturePipeline {
    let stream: String
    private let baseName: String
    private let folder: URL
    private let diagnostics: CaptureDiagnostics
    private(set) var report = AudioReport()
    private var file: ExtAudioFileRef?
    private var inputFormat: AVAudioFormat?
    private var converter: AVAudioConverter?
    private var floatFormat: AVAudioFormat?
    private var expectedPTS: CMTime?
    private var bucketSum: Double = 0
    private var bucketSamples: Int64 = 0
    private var bucketPeak: Double = 0
    private var bucketFrames: Int64 = 0
    private var bucketCallbacks: Int64 = 0
    private var bucketStart: MediaTime?
    private var bucketEnd: MediaTime?
    private var disabled = false
    private var resetSegment = false

    init(stream: String, baseName: String, folder: URL, diagnostics: CaptureDiagnostics) {
        self.stream = stream; self.baseName = baseName; self.folder = folder; self.diagnostics = diagnostics
    }

    func consume(_ sample: CMSampleBuffer) {
        let now = ProcessInfo.processInfo.systemUptime
        report.callbacks += 1; bucketCallbacks += 1; report.lastCallbackUptime = now
        guard !disabled else { report.droppedBuffers += 1; return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        let frames = CMSampleBufferGetNumSamples(sample)
        guard CMSampleBufferDataIsReady(sample), pts.isNumeric, frames > 0, frames <= 16_384,
              let description = CMSampleBufferGetFormatDescription(sample),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description),
              asbd.pointee.mFormatID == kAudioFormatLinearPCM,
              asbd.pointee.mChannelsPerFrame > 0, asbd.pointee.mChannelsPerFrame <= 8,
              (8_000...192_000).contains(asbd.pointee.mSampleRate),
              let format = AVAudioFormat(streamDescription: asbd) else {
            fail("AUDIO_FORMAT_INVALID", "Invalid PCM format, timestamp, or oversized buffer", pts: pts); return
        }
        report.receivedFrames += Int64(frames)
        var discontinuity = resetSegment
        if let expected = expectedPTS {
            if pts.epoch != expected.epoch {
                discontinuity = true
                diagnostics.event("AUDIO_CLOCK_EPOCH_CHANGED", stream, pts: pts)
            } else {
                let delta = CMTimeGetSeconds(CMTimeSubtract(pts, expected))
                let tolerance = max(0.002, 2 / format.sampleRate)
                if delta < -tolerance {
                    // A fresh file starts a new source timeline span; no false monotonic timestamp.
                    discontinuity = true
                    diagnostics.event("AUDIO_PTS_BACKWARDS", "\(stream): delta=\(delta)s", pts: pts)
                } else if delta > tolerance {
                    report.detectedGapSeconds += delta
                    diagnostics.event("AUDIO_PTS_GAP", "\(stream): \(delta)s missing; no silence inserted", pts: pts)
                }
            }
        }
        do {
            if inputFormat != format || discontinuity || file == nil || (report.segments.last?.frames ?? 0) > Int64(format.sampleRate * 60) {
                try openSegment(format: format, pts: pts)
                resetSegment = false
            }
            guard let floatFormat, let converter,
                  let original = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
                  let converted = AVAudioPCMBuffer(pcmFormat: floatFormat, frameCapacity: AVAudioFrameCount(frames)) else {
                throw TraceFailure.message("PCM_ALLOCATION_FAILED")
            }
            original.frameLength = AVAudioFrameCount(frames)
            let copied = CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: 0, frameCount: Int32(frames), into: original.mutableAudioBufferList)
            guard copied == noErr else { throw TraceFailure.message("PCM_COPY_FAILED OSStatus=\(copied)") }
            try converter.convert(to: converted, from: original)
            let count = Int(converted.frameLength)
            guard count == frames, let channels = converted.floatChannelData else { throw TraceFailure.message("PCM_CONVERSION_EMPTY_OR_TRUNCATED") }
            var sum: Double = 0, peak: Double = 0
            for channel in 0..<Int(floatFormat.channelCount) {
                var squares: Float = 0, maximum: Float = 0
                vDSP_svesq(channels[channel], 1, &squares, vDSP_Length(count))
                vDSP_maxmgv(channels[channel], 1, &maximum, vDSP_Length(count))
                guard squares.isFinite, maximum.isFinite else { throw TraceFailure.message("PCM_NONFINITE_VALUES") }
                sum += Double(squares); peak = max(peak, Double(maximum))
            }
            let duration = CMTime(value: Int64(count), timescale: Int32(format.sampleRate.rounded()))
            let end = CMTimeAdd(pts, duration)
            let previousState = report.state
            report.validBuffers += 1; report.lastValidUptime = now
            if peak > 0.0001 {
                report.nonSilentBuffers += 1; report.consecutiveSilenceSeconds = 0
                report.lastNonSilentPts = MediaTime(pts); report.state = "RECEIVING_SIGNAL"
            } else {
                report.consecutiveSilenceSeconds += Double(count) / format.sampleRate
                report.state = report.consecutiveSilenceSeconds >= 2 ? "SILENT" : "RECEIVING_LOW_LEVEL"
            }
            if previousState != report.state {
                diagnostics.event(stream == "microphone" && report.state == "SILENT" ? "MIC_CAPTURE_SILENT" : "AUDIO_STATE_CHANGED", "\(stream): \(previousState) -> \(report.state)", pts: pts)
            }
            guard let file else { throw TraceFailure.message("WAV_NOT_OPEN") }
            let status = ExtAudioFileWrite(file, converted.frameLength, converted.audioBufferList)
            guard status == noErr else { throw TraceFailure.message("WAV_WRITE_FAILED OSStatus=\(status)") }
            let index = report.segments.count - 1
            try diagnostics.timestamps.append(TimestampRecord(stream: stream, sourcePts: MediaTime(pts), duration: MediaTime(duration), filename: report.segments[index].filename, fileFrameOffset: report.segments[index].frames, frameCount: count))
            report.segments[index].frames += Int64(count); report.segments[index].endPts = MediaTime(end)
            report.writtenFrames += Int64(count)
            report.durationSeconds += Double(count) / format.sampleRate
            report.available = report.available || peak > 0.0001
            if report.startPts == nil { report.startPts = MediaTime(pts) }
            report.endPts = MediaTime(end); expectedPTS = end
            bucketSum += sum; bucketSamples += Int64(count) * Int64(floatFormat.channelCount)
            bucketPeak = max(bucketPeak, peak); bucketFrames += Int64(count)
            if bucketStart == nil { bucketStart = MediaTime(pts) }; bucketEnd = MediaTime(end)
        } catch {
            fail(error.localizedDescription.contains("WRITE") ? "AUDIO_FILE_WRITE_FAILED" : "AUDIO_CONVERSION_FAILED", error.localizedDescription, pts: pts)
        }
    }

    private func openSegment(format: AVAudioFormat, pts: CMTime) throws {
        closeSegment()
        guard report.segments.count < 1024 else { throw TraceFailure.message("AUDIO_SEGMENT_LIMIT") }
        let filename = report.segments.isEmpty ? "\(baseName).wav" : String(format: "%@_part%03d.wav", baseName, report.segments.count + 1)
        guard let float = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: format.sampleRate, channels: format.channelCount, interleaved: false),
              let conversion = AVAudioConverter(from: format, to: float) else { throw TraceFailure.message("AUDIO_CONVERTER_CREATE_FAILED") }
        var output = AudioStreamBasicDescription(mSampleRate: format.sampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked, mBytesPerPacket: format.channelCount * 2,
            mFramesPerPacket: 1, mBytesPerFrame: format.channelCount * 2, mChannelsPerFrame: format.channelCount, mBitsPerChannel: 16, mReserved: 0)
        var created: ExtAudioFileRef?
        let status = ExtAudioFileCreateWithURL(folder.appendingPathComponent(filename) as CFURL, kAudioFileWAVEType, &output, nil, AudioFileFlags.eraseFile.rawValue, &created)
        guard status == noErr, let created else { throw TraceFailure.message("WAV_CREATE_FAILED OSStatus=\(status)") }
        var client = float.streamDescription.pointee
        let clientStatus = ExtAudioFileSetProperty(created, kExtAudioFileProperty_ClientDataFormat, UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &client)
        guard clientStatus == noErr else { ExtAudioFileDispose(created); throw TraceFailure.message("WAV_CLIENT_FORMAT_FAILED OSStatus=\(clientStatus)") }
        file = created; inputFormat = format; floatFormat = float; converter = conversion
        report.segments.append(AudioSegment(filename: filename, sampleRate: format.sampleRate, channels: format.channelCount, startPts: MediaTime(pts), endPts: MediaTime(pts), inputFormat: format.description))
        diagnostics.event("AUDIO_FILE_OPENED", "\(stream): \(filename), \(format)", pts: pts)
    }

    func tick(now: Double, captureStarted: Double, paused: Bool) {
        if !paused && !disabled {
            let since = now - (report.lastCallbackUptime ?? captureStarted)
            if since >= 3 && report.state != "INTERRUPTED" && report.state != "UNAVAILABLE" {
                report.state = report.callbacks == 0 ? "UNAVAILABLE" : "INTERRUPTED"
                diagnostics.event(stream == "microphone" ? (report.callbacks == 0 ? "MIC_AUDIO_UNAVAILABLE" : "MIC_CAPTURE_INTERRUPTED") : "SYSTEM_AUDIO_UNAVAILABLE", "\(stream): no callbacks for \(since)s; cause requires device investigation")
            }
        }
        report.rms = bucketSamples > 0 ? sqrt(bucketSum / Double(bucketSamples)) : 0
        report.peak = bucketPeak
        do {
            try diagnostics.levels.append(AudioLevelRecord(stream: stream, uptime: now, firstPts: bucketStart, lastPts: bucketEnd, frames: bucketFrames, callbacks: bucketCallbacks, rms: report.rms, peak: report.peak, silenceSeconds: report.consecutiveSilenceSeconds, state: paused ? "PAUSED" : report.state))
        } catch { fail("LEVEL_LOG_WRITE_FAILED", error.localizedDescription, pts: nil) }
        bucketSum = 0; bucketSamples = 0; bucketPeak = 0; bucketFrames = 0; bucketCallbacks = 0; bucketStart = nil; bucketEnd = nil
    }

    func pauseBoundary() { resetSegment = true }
    func finish() {
        closeSegment()
        if !report.available {
            diagnostics.event(stream == "system" ? "SYSTEM_AUDIO_UNAVAILABLE" : "MIC_AUDIO_UNAVAILABLE", "\(stream): callbacks=\(report.callbacks), valid=\(report.validBuffers), signal=\(report.nonSilentBuffers); real silence retained if supplied by ReplayKit")
        }
    }
    private func closeSegment() {
        if let file {
            let status = ExtAudioFileDispose(file)
            if !report.segments.isEmpty { report.segments[report.segments.count - 1].finalized = status == noErr }
            if status != noErr { diagnostics.event("WAV_FINALIZE_FAILED", "\(stream): OSStatus=\(status)") }
        }
        file = nil; converter = nil; inputFormat = nil; floatFormat = nil
    }
    private func fail(_ code: String, _ detail: String, pts: CMTime?) {
        report.droppedBuffers += 1
        report.state = code
        diagnostics.event(code, "\(stream): \(detail)", pts: pts)
        // Fail this track once; keep other streams. Prevent per-buffer error storms.
        disabled = true; closeSegment()
    }
    deinit { if let file { ExtAudioFileDispose(file) } }
}

final class SystemAudioPipeline: AudioCapturePipeline {
    init(folder: URL, diagnostics: CaptureDiagnostics) { super.init(stream: "system", baseName: "system_audio", folder: folder, diagnostics: diagnostics) }
}
final class MicrophoneAudioPipeline: AudioCapturePipeline {
    init(folder: URL, diagnostics: CaptureDiagnostics) { super.init(stream: "microphone", baseName: "microphone_audio", folder: folder, diagnostics: diagnostics) }
}
