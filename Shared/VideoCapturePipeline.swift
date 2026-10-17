import Foundation
import AVFoundation
import ReplayKit
import CoreImage
import ImageIO

final class VideoCapturePipeline {
    private let folder: URL
    private let diagnostics: CaptureDiagnostics
    private(set) var report = VideoReport()
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var closingWriter: AVAssetWriter?
    private var closingIndex: Int?
    private var sourceSize = CGSize.zero
    private var orientation: UInt32 = 1
    private var lastPts: CMTime?
    private var resetSegment = false
    private var disabled = false
    private let context = CIContext(options: [.cacheIntermediates: false])
    private var targetFps = 30
    private var memoryConstrained = false

    init(folder: URL, diagnostics: CaptureDiagnostics) { self.folder = folder; self.diagnostics = diagnostics }

    func consume(_ sample: CMSampleBuffer) {
        report.callbacks += 1
        guard !disabled else { report.droppedFrames += 1; return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        guard CMSampleBufferDataIsReady(sample), pts.isNumeric, let pixel = CMSampleBufferGetImageBuffer(sample) else {
            report.droppedFrames += 1; return
        }
        let size = CGSize(width: CVPixelBufferGetWidth(pixel), height: CVPixelBufferGetHeight(pixel))
        let orient = (CMGetAttachment(sample, key: RPVideoSampleOrientationKey as CFString, attachmentModeOut: nil) as? NSNumber)?.uint32Value ?? 0
        let desiredFPS: Int = ProcessInfo.processInfo.thermalState == .serious || memoryConstrained ? 15 : 30
        var discontinuity = false
        if let lastPts {
            let delta = CMTimeGetSeconds(CMTimeSubtract(pts, lastPts))
            discontinuity = pts.epoch != lastPts.epoch || delta < 0 || delta > 2
            if !discontinuity && delta < 1 / Double(targetFps) - 0.001 {
                report.rateLimitedFrames += 1; return
            }
        }
        pollClosedWriter()
        guard closingWriter == nil else { report.droppedFrames += 1; return }
        do {
            let age = report.segments.last.map { pts.seconds - $0.startPts.seconds } ?? 0
            if writer != nil && (resetSegment || size != sourceSize || orient != orientation || desiredFPS != targetFps || discontinuity || age >= 60) {
                diagnostics.event("VIDEO_SEGMENT_BOUNDARY", "orientation=\(orient), source=\(size), targetFps=\(desiredFPS), ptsDiscontinuity=\(discontinuity)", pts: pts)
                closeCurrent()
                report.droppedFrames += 1
                return
            }
            if writer == nil {
                targetFps = desiredFPS
                try openSegment(size: size, orientation: orient, pts: pts)
                resetSegment = false
            }
            guard let writer, writer.status == .writing, let input, let adaptor else {
                throw TraceFailure.message("VIDEO_WRITER_NOT_WRITING: \(self.writer?.error?.localizedDescription ?? "unknown")")
            }
            guard input.isReadyForMoreMediaData else { report.droppedFrames += 1; return }
            guard let pool = adaptor.pixelBufferPool else { throw TraceFailure.message("VIDEO_PIXEL_POOL_MISSING") }
            var scaled: CVPixelBuffer?
            let allocation = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(kCFAllocatorDefault, pool,
                [kCVPixelBufferPoolAllocationThresholdKey: 3] as CFDictionary, &scaled)
            guard allocation == kCVReturnSuccess, let scaled else { report.droppedFrames += 1; return }
            let width = CVPixelBufferGetWidth(scaled), height = CVPixelBufferGetHeight(scaled)
            let image = CIImage(cvPixelBuffer: pixel).transformed(by: CGAffineTransform(scaleX: CGFloat(width) / size.width, y: CGFloat(height) / size.height))
            context.render(image, to: scaled, bounds: CGRect(x: 0, y: 0, width: width, height: height), colorSpace: CGColorSpaceCreateDeviceRGB())
            guard adaptor.append(scaled, withPresentationTime: pts) else {
                throw TraceFailure.message("VIDEO_APPEND_FAILED: \(writer.error?.localizedDescription ?? "unknown")")
            }
            let index = report.segments.count - 1
            try diagnostics.timestamps.append(TimestampRecord(stream: "video", sourcePts: MediaTime(pts), duration: nil, filename: report.segments[index].filename, fileFrameOffset: report.segments[index].frames, frameCount: 1))
            report.segments[index].frames += 1; report.segments[index].endPts = MediaTime(pts)
            let elapsed = pts.seconds - report.segments[index].startPts.seconds
            report.segments[index].actualFps = elapsed > 0 ? Double(max(0, report.segments[index].frames - 1)) / elapsed : 0
            report.writtenFrames += 1; report.available = true
            if report.startPts == nil { report.startPts = MediaTime(pts) }
            report.endPts = MediaTime(pts); lastPts = pts
        } catch {
            report.droppedFrames += 1; disabled = true
            diagnostics.event("VIDEO_WRITE_FAILED", error.localizedDescription, pts: pts)
            closeCurrent()
        }
    }

    private func openSegment(size: CGSize, orientation: UInt32, pts: CMTime) throws {
        guard report.segments.count < 1024, size.width > 0, size.height > 0 else { throw TraceFailure.message("VIDEO_SEGMENT_LIMIT_OR_INVALID_SIZE") }
        // Cap the long side at 1280 to leave room for ReplayKit and the hardware encoder in the extension.
        let scale = min(1, 1280 / max(size.width, size.height))
        let width = max(2, Int(size.width * scale) / 2 * 2), height = max(2, Int(size.height * scale) / 2 * 2)
        let filename = report.segments.isEmpty ? "screen.mp4" : String(format: "screen_part%03d.mp4", report.segments.count + 1)
        let created = try AVAssetWriter(outputURL: folder.appendingPathComponent(filename), fileType: .mp4)
        created.movieFragmentInterval = CMTime(seconds: 2, preferredTimescale: 600)
        let settings: [String: Any] = [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 2_500_000, AVVideoExpectedSourceFrameRateKey: targetFps,
                AVVideoMaxKeyFrameIntervalKey: targetFps * 2, AVVideoAllowFrameReorderingKey: false]]
        guard created.canApply(outputSettings: settings, forMediaType: .video) else { throw TraceFailure.message("H264_SETTINGS_UNSUPPORTED") }
        let track = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        track.expectsMediaDataInRealTime = true
        track.transform = Self.transform(orientation, width: CGFloat(width), height: CGFloat(height))
        let adapter = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: track, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]])
        guard created.canAdd(track) else { throw TraceFailure.message("VIDEO_INPUT_UNSUPPORTED") }
        created.add(track)
        guard created.startWriting() else { throw TraceFailure.message("VIDEO_START_FAILED: \(created.error?.localizedDescription ?? "unknown")") }
        created.startSession(atSourceTime: pts)
        writer = created; input = track; adaptor = adapter; sourceSize = size; self.orientation = orientation
        report.segments.append(VideoSegment(filename: filename, width: width, height: height, orientation: orientation, targetFps: targetFps, startPts: MediaTime(pts), endPts: MediaTime(pts)))
        diagnostics.event("VIDEO_FILE_OPENED", "\(filename): \(width)x\(height), H264, \(targetFps)fps limit", pts: pts)
    }

    static func transform(_ orientation: UInt32, width: CGFloat, height: CGFloat) -> CGAffineTransform {
        switch orientation {
        case 2: return CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: width, ty: 0)
        case 3: return CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: width, ty: height)
        case 4: return CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: height)
        case 5: return CGAffineTransform(a: 0, b: 1, c: 1, d: 0, tx: 0, ty: 0)
        case 6: return CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: height, ty: 0)
        case 7: return CGAffineTransform(a: 0, b: -1, c: -1, d: 0, tx: height, ty: width)
        case 8: return CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: width)
        default: return .identity
        }
    }

    private func closeCurrent() {
        guard let writer else { return }
        input?.markAsFinished()
        if writer.status == .writing { writer.finishWriting {} }
        closingWriter = writer; closingIndex = report.segments.count - 1
        self.writer = nil; input = nil; adaptor = nil
        context.clearCaches()
    }
    private func pollClosedWriter() {
        guard let closingWriter, let closingIndex else { return }
        guard closingWriter.status != .writing else { return }
        let complete = closingWriter.status == .completed
        report.segments[closingIndex].status = complete ? "completed" : "failed"
        report.available = report.segments.contains { $0.status == "completed" && $0.frames > 0 }
        if !complete { diagnostics.event("VIDEO_FINALIZE_FAILED", closingWriter.error?.localizedDescription ?? "writer did not complete") }
        self.closingWriter = nil; self.closingIndex = nil
    }
    func boundary() { resetSegment = true }
    func memoryWarning() { memoryConstrained = true; context.clearCaches() }
    func beginFinish() { closeCurrent() }
    func finishReady() -> Bool { pollClosedWriter(); return closingWriter == nil }
    func cancelPendingFinish() {
        closingWriter?.cancelWriting(); pollClosedWriter()
        diagnostics.event("VIDEO_FINALIZE_TIMEOUT", "Timed out after 8 seconds; preserving existing files")
    }
}
