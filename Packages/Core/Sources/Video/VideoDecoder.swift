import AVFoundation
import CoreImage
import CoreVideo
import Foundation

public enum AnalysisStage: String, Sendable, Equatable {
    case decoding = "Analyzing every frame"
    case exporting = "Exporting screenshots"
    case annotating = "Recognizing screens"
    case complete = "Export complete"
    case cancelled = "Cancelled"
}

public struct AnalysisProgress: Sendable {
    public let stage: AnalysisStage
    public let fraction: Double
    public let detail: String

    public init(stage: AnalysisStage, fraction: Double, detail: String) {
        self.stage = stage
        self.fraction = fraction
        self.detail = detail
    }
}

public enum VideoDecoder {
    public static func decode(
        url: URL,
        work: ProcessingLane = .standalone(),
        previewRequest: @escaping @Sendable () -> PreviewRequest? = { PreviewRequest() },
        onFrames: @Sendable ([Frame]) async throws -> Void,
        onProgress: @Sendable (AnalysisProgress) async throws -> Void,
        onPrepared: @Sendable (TimeInterval) async throws -> Void = { _ in }
    ) async throws -> TimeInterval {
        let source = try await work.perform { VideoFrameSource() }
        let duration = try await work.perform { try await source.prepare(url) }
        try await onPrepared(duration)
        var frameCount = 0
        var lastProgressTime: TimeInterval = -.infinity
        while let frames = try await work.perform({ try await source.next(previewRequest: previewRequest) }) {
            try Task.checkCancellation()
            try await onFrames(frames)
            frameCount += frames.count
            if let timestamp = frames.last?.timestamp, timestamp - lastProgressTime >= 0.25 {
                let fraction = duration > 0 ? min(0.99, max(0, timestamp / duration)) : 0
                try await onProgress(AnalysisProgress(stage: .decoding, fraction: fraction,
                    detail: "\(frameCount.formatted()) frames analyzed"))
                lastProgressTime = timestamp
            }
        }
        guard frameCount > 0 else { throw VideoAnalysisError.noVideoFrames }
        return duration
    }
}

private actor VideoFrameSource {
    private var reader: AVAssetReader?
    private var output: AVAssetReaderTrackOutput?
    private var transform = CGAffineTransform.identity
    private let generator = FrameProxyGenerator()
    private var lastColor: ContinuousClock.Instant?

    func prepare(_ url: URL) async throws -> TimeInterval {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw VideoAnalysisError.noVideoTrack
        }
        transform = try await track.load(.preferredTransform)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw VideoAnalysisError.cannotReadVideo }
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? VideoAnalysisError.cannotReadVideo }
        self.reader = reader
        self.output = output
        return duration.isFinite ? max(0, duration) : 0
    }

    func next(previewRequest: @Sendable () -> PreviewRequest?) throws -> [Frame]? {
        guard let reader, let output else { throw VideoAnalysisError.cannotReadVideo }
        var samples: [VideoSample] = []
        while samples.count < 8, let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let pixels = CMSampleBufferGetImageBuffer(sample) else { continue }
            let timestamp = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            guard timestamp.isFinite else { continue }
            samples.append(VideoSample(timestamp: timestamp,
                image: CIImage(cvPixelBuffer: pixels).transformed(by: transform)))
        }
        if samples.isEmpty {
            guard reader.status == .completed else {
                try Task.checkCancellation()
                throw reader.error ?? VideoAnalysisError.cannotReadVideo
            }
            return nil
        }
        let frames = try generator.makeFrames(from: samples, previewRequest: previewRequest, lastColor: lastColor)
        if frames.contains(where: { $0.previewRGBA != nil }) { lastColor = .now }
        return frames
    }
}

private struct VideoSample: Sendable {
    let timestamp: TimeInterval
    let image: CIImage
}

private struct FrameProxyGenerator {
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let grayColorSpace = CGColorSpaceCreateDeviceGray()
    private let rgbColorSpace = CGColorSpaceCreateDeviceRGB()

    func makeFrames(from samples: [VideoSample], previewRequest: @Sendable () -> PreviewRequest?,
                    lastColor: ContinuousClock.Instant?) throws -> [Frame] {
        var frames: [Frame] = []
        for sample in samples {
            try Task.checkCancellation()
            if let frame = makeFrame(image: sample.image, timestamp: sample.timestamp) { frames.append(frame) }
        }
        let eligible = lastColor.map { $0.duration(to: .now) >= .milliseconds(125) } ?? true
        if eligible, let request = previewRequest(), let index = frames.indices.last, let sample = samples.last,
           let preview = makeColorPreview(image: sample.image, maximumPixelSize: request.maximumPixelSize) {
            let frame = frames[index]
            frames[index] = Frame(timestamp: frame.timestamp, width: frame.width, height: frame.height,
                luma: frame.luma, sourceAspectRatio: frame.sourceAspectRatio,
                previewWidth: preview.width, previewHeight: preview.height, previewRGBA: preview.pixels)
        }
        return frames
    }

    func makeFrame(image: CIImage, timestamp: TimeInterval) -> Frame? {
        let bounds = image.extent.integral
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let longSide = max(bounds.width, bounds.height)
        let scale = min(1, 400 / longSide)
        let width = max(1, Int((bounds.width * scale).rounded()))
        let height = max(1, Int((bounds.height * scale).rounded()))
        let translated = image.transformed(by: CGAffineTransform(translationX: -bounds.minX, y: -bounds.minY))
        let scaled = translated.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        var luma = Data(count: width * height)
        luma.withUnsafeMutableBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            context.render(
                scaled,
                toBitmap: baseAddress,
                rowBytes: width,
                bounds: CGRect(x: 0, y: 0, width: width, height: height),
                format: .L8,
                colorSpace: grayColorSpace
            )
        }
        return Frame(timestamp: timestamp, width: width, height: height, luma: luma, sourceAspectRatio: Double(bounds.width / bounds.height))
    }

    private func makeColorPreview(image: CIImage, maximumPixelSize: Int) -> (width: Int, height: Int, pixels: Data)? {
        let bounds = image.extent.integral
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let scale = min(1, CGFloat(maximumPixelSize) / max(bounds.width, bounds.height))
        let width = max(1, Int((bounds.width * scale).rounded()))
        let height = max(1, Int((bounds.height * scale).rounded()))
        let translated = image.transformed(by: CGAffineTransform(translationX: -bounds.minX, y: -bounds.minY))
        let scaled = translated.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        var pixels = Data(count: width * height * 4)
        pixels.withUnsafeMutableBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            context.render(
                scaled,
                toBitmap: baseAddress,
                rowBytes: width * 4,
                bounds: CGRect(x: 0, y: 0, width: width, height: height),
                format: .RGBA8,
                colorSpace: rgbColorSpace
            )
        }
        return (width, height, pixels)
    }
}

public enum VideoAnalysisError: LocalizedError {
    case noVideoTrack
    case noVideoFrames
    case noStableStates
    case cannotReadVideo

    public var errorDescription: String? {
        switch self {
        case .noVideoTrack: "This recording has no video track."
        case .noVideoFrames: "No video frames could be decoded."
        case .noStableStates: "No stable screen states were detected."
        case .cannotReadVideo: "The video could not be decoded."
        }
    }
}
