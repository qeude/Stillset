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
    private static let frameBatchSize = 8
    private static let proxyConcurrencyLimit = min(4, max(1, ProcessInfo.processInfo.activeProcessorCount / 2))

    public static func decode(
        url: URL,
        onFrames: @Sendable ([Frame]) async throws -> Void,
        onProgress: @Sendable (AnalysisProgress) -> Void,
        onPrepared: @Sendable (TimeInterval) async -> Void = { _ in }
    ) async throws -> TimeInterval {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard let track = tracks.first else { throw VideoAnalysisError.noVideoTrack }

        let preferredTransform = try await track.load(.preferredTransform)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw VideoAnalysisError.cannotReadVideo }
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? VideoAnalysisError.cannotReadVideo }
        await onPrepared(duration.isFinite ? max(0, duration) : 0)

        let proxyGenerator = FrameProxyGenerator()
        var frameCount = 0
        var sampleBatch: [VideoSample] = []
        sampleBatch.reserveCapacity(frameBatchSize)
        var lastProgressTime: TimeInterval = -.infinity

        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            let timestamp = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            guard timestamp.isFinite else { continue }
            let image = CIImage(cvPixelBuffer: pixelBuffer).transformed(by: preferredTransform)
            sampleBatch.append(VideoSample(timestamp: timestamp, image: image))
            if sampleBatch.count == frameBatchSize {
                let frames = try await proxyGenerator.makeFrames(from: sampleBatch, maxConcurrent: proxyConcurrencyLimit)
                try await onFrames(frames)
                frameCount += frames.count
                sampleBatch.removeAll(keepingCapacity: true)
                if timestamp - lastProgressTime >= 0.25 {
                    let fraction = duration > 0 ? min(0.99, max(0, timestamp / duration)) : 0
                    onProgress(AnalysisProgress(stage: .decoding, fraction: fraction, detail: "\(frameCount.formatted()) frames analyzed"))
                    lastProgressTime = timestamp
                }
            }
        }

        guard reader.status == .completed else {
            if Task.isCancelled { throw CancellationError() }
            throw reader.error ?? VideoAnalysisError.cannotReadVideo
        }
        if !sampleBatch.isEmpty {
            let frames = try await proxyGenerator.makeFrames(from: sampleBatch, maxConcurrent: proxyConcurrencyLimit)
            try await onFrames(frames)
            frameCount += frames.count
            if let lastSample = sampleBatch.last, lastSample.timestamp - lastProgressTime >= 0.25 {
                let fraction = duration > 0 ? min(0.99, max(0, lastSample.timestamp / duration)) : 0
                onProgress(AnalysisProgress(stage: .decoding, fraction: fraction, detail: "\(frameCount.formatted()) frames analyzed"))
            }
        }
        guard frameCount > 0 else { throw VideoAnalysisError.noVideoFrames }
        return duration.isFinite ? duration : 0
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

    func makeFrames(from samples: [VideoSample], maxConcurrent: Int) async throws -> [Frame] {
        guard !samples.isEmpty else { return [] }
        return try await withThrowingTaskGroup(of: (Int, Frame?).self) { group in
            var nextIndex = 0
            for _ in 0..<min(maxConcurrent, samples.count) {
                let sample = samples[nextIndex]
                let taskIndex = nextIndex
                group.addTask {
                    try Task.checkCancellation()
                    let frame = makeFrame(image: sample.image, timestamp: sample.timestamp)
                    try Task.checkCancellation()
                    return (taskIndex, frame)
                }
                nextIndex += 1
            }

            var orderedFrames = [Frame?](repeating: nil, count: samples.count)
            while let (index, frame) = try await group.next() {
                try Task.checkCancellation()
                orderedFrames[index] = frame
                if nextIndex < samples.count {
                    let sample = samples[nextIndex]
                    let taskIndex = nextIndex
                    group.addTask {
                        try Task.checkCancellation()
                        let frame = makeFrame(image: sample.image, timestamp: sample.timestamp)
                        try Task.checkCancellation()
                        return (taskIndex, frame)
                    }
                    nextIndex += 1
                }
            }
            var frames = orderedFrames.compactMap { $0 }
            if let lastFrame = frames.indices.last,
               let sample = samples.last,
               let preview = makeColorPreview(image: sample.image) {
                let frame = frames[lastFrame]
                frames[lastFrame] = Frame(
                    timestamp: frame.timestamp,
                    width: frame.width,
                    height: frame.height,
                    luma: frame.luma,
                    previewWidth: preview.width,
                    previewHeight: preview.height,
                    previewRGBA: preview.pixels
                )
            }
            return frames
        }
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
        return Frame(timestamp: timestamp, width: width, height: height, luma: luma)
    }

    private func makeColorPreview(image: CIImage) -> (width: Int, height: Int, pixels: Data)? {
        let bounds = image.extent.integral
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let scale: CGFloat = 1
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
