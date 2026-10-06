import AVFoundation
import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import StillsetCore
import Testing

struct AnalysisTests {
    @Test func persistentLocalMotionDoesNotMakeTheWholeFrameUnstable() {
        var analyzer = MotionAnalyzer()
        let first = frame(time: 0, color: (0, 0, 0))
        var luma = [UInt8](repeating: 0, count: first.width * first.height)
        for y in 24..<30 {
            for x in 24..<30 {
                luma[y * first.width + x] = 255
            }
        }
        let blinking = Frame(timestamp: 0.02, width: first.width, height: first.height, luma: Data(luma))
        let sample = analyzer.sample(current: blinking, previous: first)
        #expect(sample.globalEnergy < 0.10)
        #expect(sample.movingAreaRatio < 0.14)
        #expect(!StabilityAnalyzer.isMoving(sample))
    }

    @Test func persistentAnimatedRegionIsExcludedFromGlobalEnergy() throws {
        var analyzer = MotionAnalyzer()
        var previous = frame(time: 0, color: (0, 0, 0))
        var lastSample: MotionSample?
        for step in 1...60 {
            var luma = [UInt8](repeating: 0, count: previous.width * previous.height)
            let value: UInt8 = step.isMultiple(of: 2) ? 0 : 255
            for y in 10..<30 {
                for x in 10..<30 {
                    luma[y * previous.width + x] = value
                }
            }
            let current = Frame(timestamp: Double(step) * 0.02, width: previous.width, height: previous.height, luma: Data(luma))
            lastSample = analyzer.sample(current: current, previous: previous)
            previous = current
        }
        let sample = try #require(lastSample)
        #expect(sample.globalEnergy < 0.01)
        #expect(!StabilityAnalyzer.isMoving(sample))
    }

    @Test func stabilityUsesAreaAndEnergyHysteresisInputs() {
        let localized = MotionSample(timestamp: 1, globalEnergy: 0.02, movingAreaRatio: 0.08, regionalEnergy: [])
        let broad = MotionSample(timestamp: 2, globalEnergy: 0.03, movingAreaRatio: 0.20, regionalEnergy: [])
        let flash = MotionSample(timestamp: 3, globalEnergy: 0.12, movingAreaRatio: 0.05, regionalEnergy: [])
        #expect(!StabilityAnalyzer.isMoving(localized))
        #expect(StabilityAnalyzer.isMoving(broad))
        #expect(StabilityAnalyzer.isMoving(flash))
    }

    @Test func stateDetectorKeepsRepeatedVisualStatesAsOccurrences() throws {
        var detector = StableStateDetector(minimumStableDuration: 0.1)
        let samples: [(Double, UInt8)] = [
            (0.0, 20), (0.1, 20), (0.2, 20),
            (0.3, 80), (0.4, 170),
            (0.5, 220), (0.6, 220), (0.7, 220),
            (0.8, 170),
            (0.9, 20), (1.0, 20), (1.1, 20), (1.2, 20)
        ]
        var candidates: [StateCandidate] = []
        for (time, gray) in samples {
            if let candidate = detector.consume(frame(time: time, color: (gray, gray, gray))) { candidates.append(candidate) }
        }
        if let final = detector.finish() { candidates.append(final) }

        #expect(candidates.count == 3)
        let first = try #require(candidates.first)
        let second = try #require(candidates.dropFirst().first)
        let third = try #require(candidates.dropFirst(2).first)
        #expect(first.frame.luma != second.frame.luma)
        #expect(first.frame.luma == third.frame.luma)
    }

    @Test func shortStablePauseIsRetainedAsUncertain() throws {
        var detector = StableStateDetector(minimumStableDuration: 0.12, minimumCandidateDuration: 0.04)
        _ = detector.consume(frame(time: 0, color: (30, 30, 30)))
        _ = detector.consume(frame(time: 0.06, color: (30, 30, 30)))
        let emittedCandidate = detector.consume(frame(time: 0.10, color: (210, 210, 210)))
        let candidate = try #require(emittedCandidate)
        #expect(candidate.interval.upperBound - candidate.interval.lowerBound < 0.12)
        #expect(!candidate.isConfirmed)
    }

    @Test func representativeSelectionPrefersSharpStableContent() {
        let selector = RepresentativeFrameSelector()
        let stable = MotionSample(timestamp: 1, globalEnergy: 0, movingAreaRatio: 0, regionalEnergy: [])
        let blurry = frame(time: 1, color: (120, 120, 120))
        let sharp = checkerboard(time: 1)
        #expect(selector.score(frame: sharp, motion: stable, secondsFromTransition: 0.2)
            > selector.score(frame: blurry, motion: stable, secondsFromTransition: 0.2))
    }

    @Test func decoderAndExporterUseARecordedSyntheticWorkflow() async throws {
        let videoURL = try recordingFixture()

        let streamCounter = FrameStreamCounter()
        let streamedResult = try await AnalysisPipeline.run(
            url: videoURL,
            onProgress: { _ in },
            onAnalyzedFrames: { frames in await streamCounter.record(frames) },
            onPrepared: { duration in await streamCounter.prepare(duration) },
            onDetectedScreens: { screens in await streamCounter.recordScreens(screens) }
        )
        let (streamedFrameCount, timestampsAreOrdered, hasColorPreview) = await streamCounter.snapshot()
        #expect(streamedResult.states.count == 5)
        #expect(streamedFrameCount >= 30)
        #expect(timestampsAreOrdered)
        #expect(hasColorPreview)
        let (detectedScreens, preparedDuration, firstDetectionFrameCount) = await streamCounter.detectionSnapshot()
        #expect(preparedDuration == streamedResult.duration)
        #expect(detectedScreens.map(\.id) == streamedResult.states.map(\.id))
        #expect(detectedScreens.map(\.representativeTimestamp) == streamedResult.states.map(\.representativeTimestamp))
        #expect(firstDetectionFrameCount < streamedFrameCount)
        #expect(detectedScreens.allSatisfy { (0...preparedDuration).contains($0.representativeTimestamp) })

        let collector = RecordingCollector()
        let duration = try await VideoDecoder.decode(url: videoURL, onFrames: { frames in
            await collector.consume(frames)
        }, onProgress: { _ in })
        let candidates = await collector.finish()
        #expect(duration >= 1.9)
        #expect(candidates.count == 5)
        let first = try #require(candidates.first)
        let second = try #require(candidates.dropFirst().first)
        let third = try #require(candidates.dropFirst(2).first)
        let fourth = try #require(candidates.dropFirst(3).first)
        let fifth = try #require(candidates.dropFirst(4).first)
        #expect(first.interval.lowerBound < 0.5)
        #expect(second.interval.lowerBound > 0.6 && second.interval.lowerBound < 1.2)
        #expect(third.interval.lowerBound > 1.4 && third.interval.lowerBound < 2.1)
        #expect(fourth.interval.lowerBound > 2.0 && fourth.interval.lowerBound < 2.7)
        #expect(fifth.interval.lowerBound > 2.5)
        let expectedIntervals: [Range<TimeInterval>] = [0..<0.5, 0.6..<1.2, 1.4..<2.1, 2.0..<2.7, 2.5..<3.2]
        var matchedIntervals = Set<Int>()
        var truePositives = 0
        for candidate in candidates {
            if let match = expectedIntervals.indices.first(where: {
                !matchedIntervals.contains($0) && expectedIntervals[$0].contains(candidate.interval.lowerBound)
            }) {
                truePositives += 1
                matchedIntervals.insert(match)
            }
        }
        let recall = Double(truePositives) / Double(expectedIntervals.count)
        let precision = Double(truePositives) / Double(candidates.count)
        #expect(recall == 1)
        #expect(precision == 1)

        let states = candidates.map { candidate in
            UIState(
                interval: candidate.interval,
                representativeTimestamp: candidate.frame.timestamp,
                stabilityScore: candidate.stabilityScore
            )
        }
        let outputFolder = FileManager.default.temporaryDirectory.appendingPathComponent("StillsetExport-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: outputFolder) }
        try FileManager.default.createDirectory(at: outputFolder, withIntermediateDirectories: true)
        let recorder = ScreenshotRecorder()
        let outputs = try await ScreenshotExporter.export(
            states: states,
            from: videoURL,
            to: outputFolder,
            onScreenshot: { index, url in await recorder.record(index: index, url: url) }
        )
        #expect(outputs.count == 5)
        let (emittedIndices, existedWhenEmitted) = await recorder.snapshot()
        #expect(emittedIndices == Array(0..<5))
        #expect(existedWhenEmitted)

        let source = try #require(CGImageSourceCreateWithURL(outputs[0] as CFURL, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(image.width == 128)
        #expect(image.height == 192)

        let duplicateRecorder = ScreenshotRecorder()
        let duplicateOutputs = try await ScreenshotExporter.export(
            states: [states[0], states[0], states[1]], from: videoURL, to: outputFolder,
            onScreenshot: { index, url in await duplicateRecorder.record(index: index, url: url) }
        )
        #expect(duplicateOutputs.count == 3)
        #expect(try Data(contentsOf: duplicateOutputs[0]) == Data(contentsOf: duplicateOutputs[1]))
        let (duplicateIndices, duplicateFilesExisted) = await duplicateRecorder.snapshot()
        #expect(duplicateIndices == [0, 1, 2])
        #expect(duplicateFilesExisted)
        await #expect(throws: CancellationError.self) {
            try await withThrowingTaskGroup(of: [URL].self) { group in
                group.addTask {
                    try await ScreenshotExporter.export(states: states, from: videoURL, to: outputFolder)
                }
                group.cancelAll()
                _ = try await group.next()
            }
        }

        let copyFolder = FileManager.default.temporaryDirectory.appendingPathComponent("StillsetCopy-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: copyFolder) }
        try FileManager.default.createDirectory(at: copyFolder, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: outputs[0], to: copyFolder.appendingPathComponent(outputs[0].lastPathComponent))
        let copied = try ScreenshotExporter.copy(files: outputs, to: copyFolder)
        #expect(copied.count == outputs.count)
        #expect(copied[0].lastPathComponent != outputs[0].lastPathComponent)
        #expect(copied.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
    }

    private func frame(time: Double, color: (UInt8, UInt8, UInt8), width: Int = 60, height: Int = 60) -> Frame {
        let gray = UInt8((UInt16(color.0) * 54 + UInt16(color.1) * 183 + UInt16(color.2) * 19) / 256)
        return Frame(timestamp: time, width: width, height: height, luma: Data(repeating: gray, count: width * height))
    }

    private func checkerboard(time: Double, width: Int = 60, height: Int = 60) -> Frame {
        var bytes = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                let value: UInt8 = ((x / 4 + y / 4) % 2 == 0) ? 245 : 12
                bytes[y * width + x] = value
            }
        }
        return Frame(timestamp: time, width: width, height: height, luma: Data(bytes))
    }

    private func recordingFixture() throws -> URL {
        let fixtures = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures", isDirectory: true)
        let url = fixtures.appendingPathComponent("scroll-stops-navigation-return.mov")
        if FileManager.default.fileExists(atPath: url.path) { return url }
        return try makeSyntheticRecording(at: url)
    }

    private func makeSyntheticRecording(at url: URL) throws -> URL {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let width = 128
        let height = 192
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 600_000]
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
        ])
        writer.add(input)
        #expect(writer.startWriting())
        writer.startSession(atSourceTime: .zero)

        var plan: [(CorpusScreen, Int)] = Array(repeating: (.home, 0), count: 5)
        plan += [( .home, 8), (.home, 16), (.home, 24)]
        plan += Array(repeating: (.home, 24), count: 5)
        plan += [(.home, 32), (.home, 40), (.home, 48)]
        plan += Array(repeating: (.home, 48), count: 5)
        plan += Array(repeating: (.details, 0), count: 5)
        plan += Array(repeating: (.home, 0), count: 5)
        for (index, spec) in plan.enumerated() {
            while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.001) }
            var pixelBuffer: CVPixelBuffer?
            let status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, try #require(adaptor.pixelBufferPool), &pixelBuffer)
            #expect(status == kCVReturnSuccess)
            let buffer = try #require(pixelBuffer)
            let rgba = rasterize(spec.0, scrollOffset: spec.1, width: width, height: height)
            CVPixelBufferLockBaseAddress(buffer, [])
            if let base = CVPixelBufferGetBaseAddress(buffer) {
                let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
                for y in 0..<height {
                    let row = base.advanced(by: y * bytesPerRow).assumingMemoryBound(to: UInt8.self)
                    for x in 0..<width {
                        let offset = x * 4
                        let source = (y * width + x) * 4
                        row[offset] = rgba[source + 2]
                        row[offset + 1] = rgba[source + 1]
                        row[offset + 2] = rgba[source]
                        row[offset + 3] = rgba[source + 3]
                    }
                }
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            #expect(adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(index), timescale: 10)))
        }
        input.markAsFinished()
        let finished = DispatchSemaphore(value: 0)
        writer.finishWriting { finished.signal() }
        finished.wait()
        #expect(writer.status == .completed)
        return url
    }

    private func rasterize(_ screen: CorpusScreen, scrollOffset: Int, width: Int, height: Int) -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for pixel in 0..<(width * height) {
            pixels[pixel * 4] = 242
            pixels[pixel * 4 + 1] = 245
            pixels[pixel * 4 + 2] = 249
            pixels[pixel * 4 + 3] = 255
        }
        func fill(_ x: Int, _ y: Int, _ rectWidth: Int, _ rectHeight: Int, _ color: (UInt8, UInt8, UInt8)) {
            let left = max(0, x), right = min(width, x + rectWidth)
            let top = max(0, y), bottom = min(height, y + rectHeight)
            guard right > left, bottom > top else { return }
            for row in top..<bottom {
                for column in left..<right {
                    let index = (row * width + column) * 4
                    pixels[index] = color.0
                    pixels[index + 1] = color.1
                    pixels[index + 2] = color.2
                }
            }
        }

        fill(0, 0, width, 34, (29, 37, 53))
        fill(10, 11, 30, 4, (248, 250, 255))
        fill(10, 20, 17, 2, (137, 154, 180))
        fill(90, 12, 27, 3, (137, 154, 180))
        if screen == .home {
            for row in 0..<7 {
                let y = 42 + row * 32 - scrollOffset
                fill(7, y, 114, 27, (255, 255, 255))
                fill(7, y, 3, 27, (55, 123, 210))
                fill(18, y + 6, 43 + (row % 3) * 10, 3, (39, 51, 69))
                fill(18, y + 14, 70 - (row % 2) * 13, 2, (143, 154, 170))
                fill(98, y + 10, 12, 5, (222, 231, 244))
            }
        } else {
            fill(8, 44, 112, 52, (79, 130, 189))
            fill(18, 57, 58, 5, (255, 255, 255))
            fill(18, 68, 83, 3, (206, 222, 241))
            for row in 0..<4 {
                let y = 108 + row * 18
                fill(9, y, 110, 13, (255, 255, 255))
                fill(17, y + 5, 63 - (row % 2) * 12, 3, (56, 69, 88))
            }
        }
        return pixels
    }
}

private actor ScreenshotRecorder {
    private var indices: [Int] = []
    private var existedWhenEmitted = true

    func record(index: Int, url: URL) {
        indices.append(index)
        existedWhenEmitted = existedWhenEmitted && FileManager.default.fileExists(atPath: url.path)
    }

    func snapshot() -> ([Int], Bool) {
        (indices, existedWhenEmitted)
    }
}

private actor FrameStreamCounter {
    private var timestamps: [TimeInterval] = []
    private var hasColorPreview = false
    private var duration: TimeInterval = 0
    private var detectedScreens: [UIState] = []
    private var firstDetectionFrameCount: Int?

    func prepare(_ duration: TimeInterval) {
        #expect(timestamps.isEmpty)
        self.duration = duration
    }

    func recordScreens(_ screens: [UIState]) {
        #expect(duration > 0)
        #expect(!screens.isEmpty)
        if firstDetectionFrameCount == nil { firstDetectionFrameCount = timestamps.count }
        detectedScreens.append(contentsOf: screens)
    }

    func detectionSnapshot() -> ([UIState], TimeInterval, Int) {
        (detectedScreens, duration, firstDetectionFrameCount ?? timestamps.count)
    }

    func record(_ frames: [Frame]) {
        timestamps.append(contentsOf: frames.map(\.timestamp))
        hasColorPreview = hasColorPreview || frames.contains {
            guard let pixels = $0.previewRGBA, let width = $0.previewWidth, let height = $0.previewHeight else { return false }
            return pixels.count == width * height * 4
        }
    }

    func snapshot() -> (Int, Bool, Bool) {
        let ordered = zip(timestamps, timestamps.dropFirst()).allSatisfy { $0.0 <= $0.1 }
        return (timestamps.count, ordered, hasColorPreview)
    }
}

private enum CorpusScreen { case home, details }

private actor RecordingCollector {
    private var detector = StableStateDetector(minimumStableDuration: 0.12)
    private var candidates: [StateCandidate] = []

    func consume(_ frames: [Frame]) {
        for frame in frames {
            if let candidate = detector.consume(frame) { candidates.append(candidate) }
        }
    }

    func finish() -> [StateCandidate] {
        if let candidate = detector.finish() { candidates.append(candidate) }
        return candidates
    }
}
