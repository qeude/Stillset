import CoreGraphics
import Foundation
import ImageIO
@testable import StillsetCore
import Testing
import UniformTypeIdentifiers

@Suite(.timeLimit(.minutes(1)))
struct PreparedRecognitionTests {
    @Test func exportContinuesWhileFirstRecognitionIsPending() async throws {
        let video = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Fixtures/scroll-stops-navigation-return.mov")
        let result = try await AnalysisPipeline.run(url: video, onProgress: { _ in })
        let states = Array(repeating: try #require(result.states.first), count: 5)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let probe = RecognitionProbe(names: [:], blockedFirst: true)
        let recognize: @Sendable (Data) async throws -> ScreenVisionFallback.Recognition = { data in
            _ = try await probe.recognize(data)
            return ScreenVisionFallback.Recognition(title: "Accueil", pickerName: nil, lines: [], titleConfidence: 1)
        }
        let prepared = ScreenCatalogAnalyzer.PreparedRecognition(recognize: recognize)
        defer { prepared.cancel() }
        let files = try await ScreenshotExporter.export(states: states, from: video, to: folder, onScreenshot: { index, url in
            if index == 0 {
                prepared.start(fileURL: url)
                await probe.waitForCalls(1)
            }
        })
        #expect(files.count == 5)
        #expect(await probe.active == 1)
        let firstBytes = try Data(contentsOf: files[0])
        #expect(await probe.inputs == [firstBytes])
        await probe.release()
        let catalog = try await ScreenCatalogAnalyzer(recognize: recognize).analyze(
            fileURLs: files, useFoundationModels: false, preparedRecognition: prepared)
        #expect(catalog.classifications == Array(repeating: ScreenClassification(screenID: 1, name: "Accueil"), count: 5))
        #expect(catalog.recognitionFailures == 0 && catalog.errorDescription == nil)
        #expect(await probe.inputs == [firstBytes])
    }

    @Test func startsBeforeAnalysisReusesBytesAndPreservesOccurrences() async throws {
        let fixture = try Images()
        defer { fixture.remove() }
        let probe = RecognitionProbe(names: fixture.names, blockedFirst: true)
        let prepared = ScreenCatalogAnalyzer.PreparedRecognition(recognize: probe.recognize)
        defer { prepared.cancel() }
        prepared.start(fileURL: fixture.files[0])
        await probe.waitForCalls(1)
        #expect(await probe.inputs == [fixture.bytes[0]])
        prepared.start(fileURL: fixture.files[1])
        let analyzer = ScreenCatalogAnalyzer(recognize: probe.recognize)
        let renamed = fixture.folder.appendingPathComponent("renamed.png")
        try FileManager.default.copyItem(at: fixture.files[0], to: renamed)
        let inputs = [renamed, fixture.files[1], renamed, fixture.files[2]]
        let analysis = Task {
            try await analyzer.analyze(fileURLs: inputs, useFoundationModels: false, preparedRecognition: prepared)
        }
        await probe.waitForCalls(3)
        #expect(await probe.peak == 2)
        await probe.release()
        let result = try await analysis.value
        #expect(result.classifications == [
            ScreenClassification(screenID: 1, name: "Accueil"),
            ScreenClassification(screenID: 2, name: "Profil"),
            ScreenClassification(screenID: 1, name: "Accueil"),
            ScreenClassification(screenID: 3, name: "Compte", stateID: 4)
        ])
        #expect(await probe.inputs.filter { $0 == fixture.bytes[0] }.count == 1)
        let baseline = try await ScreenCatalogAnalyzer(recognize: RecognitionProbe(names: fixture.names).recognize)
            .analyze(fileURLs: inputs, useFoundationModels: false)
        #expect(result.classifications == baseline.classifications)
        #expect(result.visionNames == baseline.visionNames && result.errorDescription == nil)
        #expect(result.recognitionFailures == 0)
    }

    @Test func changedBytesDrainStaleWorkBeforeReplacement() async throws {
        let fixture = try Images()
        defer { fixture.remove() }
        let probe = RecognitionProbe(names: fixture.names, blockedFirst: true)
        let prepared = ScreenCatalogAnalyzer.PreparedRecognition(recognize: probe.recognize)
        defer { prepared.cancel() }
        prepared.start(fileURL: fixture.files[0])
        await probe.waitForCalls(1)
        try fixture.bytes[1].write(to: fixture.files[0])
        let analysis = Task {
            try await ScreenCatalogAnalyzer(recognize: probe.recognize).analyze(
                fileURLs: [fixture.files[0], fixture.files[2]], useFoundationModels: false,
                preparedRecognition: prepared)
        }
        await probe.waitForCancellation()
        #expect(await probe.inputs == [fixture.bytes[0]])
        await probe.release()
        let result = try await analysis.value
        #expect(result.classifications.map(\.name) == ["Profil", "Compte"])
        #expect(result.recognitionFailures == 0 && result.errorDescription == nil)
        #expect(await probe.inputs.count == 3)
        #expect(await probe.peak <= 2)
    }

    @Test func cancellationReleasesWorkPreventsRestartAndIsolatesImports() async throws {
        let fixture = try Images()
        defer { fixture.remove() }
        let probe = RecognitionProbe(names: fixture.names, blockedFirst: true)
        let prepared = ScreenCatalogAnalyzer.PreparedRecognition(recognize: probe.recognize)
        prepared.start(fileURL: fixture.files[0])
        await probe.waitForCalls(1)
        let analysis = Task {
            try await ScreenCatalogAnalyzer(recognize: probe.recognize).analyze(
                fileURLs: [fixture.files[0]], useFoundationModels: false, preparedRecognition: prepared)
        }
        analysis.cancel()
        await probe.waitForCancellation()
        await probe.release()
        await #expect(throws: CancellationError.self) { try await analysis.value }
        prepared.start(fileURL: fixture.files[1])
        let next = ScreenCatalogAnalyzer.PreparedRecognition(recognize: probe.recognize)
        next.start(fileURL: fixture.files[1])
        let catalog = try await ScreenCatalogAnalyzer(recognize: probe.recognize).analyze(
            fileURLs: [fixture.files[1]], useFoundationModels: false, preparedRecognition: next)
        #expect(catalog.classifications == [ScreenClassification(screenID: 1, name: "Profil")])
        #expect(await probe.inputs == [fixture.bytes[0], fixture.bytes[1]])
        #expect(await probe.active == 0)
        let cancelled = ScreenCatalogAnalyzer.PreparedRecognition(recognize: probe.recognize)
        cancelled.cancel()
        cancelled.start(fileURL: fixture.files[2])
        await #expect(throws: CancellationError.self) {
            try await ScreenCatalogAnalyzer().analyze(fileURLs: fixture.files, preparedRecognition: cancelled)
        }
        #expect(await probe.inputs.count == 2)
        let beforeStart = ScreenCatalogAnalyzer.PreparedRecognition(recognize: probe.recognize)
        let (gate, release) = AsyncStream<Void>.makeStream()
        let start = Task {
            for await _ in gate { break }
            beforeStart.start(fileURL: fixture.files[2])
        }
        start.cancel()
        release.finish()
        await start.value
        beforeStart.start(fileURL: fixture.files[2])
        await #expect(throws: CancellationError.self) {
            try await ScreenCatalogAnalyzer().analyze(fileURLs: fixture.files, preparedRecognition: beforeStart)
        }
        #expect(await probe.inputs.count == 2)
    }

    @Test func emptyInputAndCacheHitDrainUnusedPreparation() async throws {
        let fixture = try Images()
        defer { fixture.remove() }
        let analyzer = ScreenCatalogAnalyzer(recognize: RecognitionProbe(names: fixture.names).recognize)
        let original = try await analyzer.analyze(fileURLs: fixture.files, useFoundationModels: false)
        for files in [fixture.files, []] {
            let probe = RecognitionProbe(names: fixture.names, blockedFirst: true)
            let prepared = ScreenCatalogAnalyzer.PreparedRecognition(recognize: probe.recognize)
            prepared.start(fileURL: fixture.files[0])
            await probe.waitForCalls(1)
            let analysis = Task {
                try await analyzer.analyze(fileURLs: files, useFoundationModels: false, preparedRecognition: prepared)
            }
            await probe.waitForCancellation()
            await probe.release()
            let result = try await analysis.value
            #expect(result.classifications == (files.isEmpty ? [] : original.classifications))
            #expect(await probe.active == 0)
            #expect(await probe.inputs.count == 1)
        }
    }

    @Test func preparationFailureFollowsExistingFallback() async throws {
        let fixture = try Images()
        defer { fixture.remove() }
        let prepared = ScreenCatalogAnalyzer.PreparedRecognition { _ in throw CocoaError(.fileReadCorruptFile) }
        prepared.start(fileURL: fixture.files[0])
        let result = try await ScreenCatalogAnalyzer().analyze(
            fileURLs: [fixture.files[0]], useFoundationModels: false, preparedRecognition: prepared)
        #expect(result.classifications == [ScreenClassification(screenID: 1, name: "Capture à examiner")])
        #expect(result.errorDescription != nil)
        #expect(result.recognitionFailures == 1)
    }

    @Test func cancelAndDrainRetainsOwnershipUntilRecognitionActuallyStops() async throws {
        let fixture = try Images()
        defer { fixture.remove() }
        let probe = RecognitionProbe(names: fixture.names, blockedFirst: true)
        let prepared = ScreenCatalogAnalyzer.PreparedRecognition(recognize: probe.recognize)
        prepared.start(fileURL: fixture.files[0])
        await probe.waitForCalls(1)
        prepared.cancel()
        let drain = Task { await prepared.cancelAndDrain() }
        await probe.waitForCancellation()
        #expect(await probe.active == 1)
        prepared.start(fileURL: fixture.files[1])
        await probe.release()
        await drain.value
        #expect(await probe.active == 0)
        #expect(await probe.inputs == [fixture.bytes[0]])
    }

    private struct Images {
        let folder: URL
        let files: [URL]
        let bytes: [Data]
        let names: [Data: String]

        init() throws {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            self.folder = folder
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            files = (0..<3).map { folder.appendingPathComponent("\($0).png") }
            for (index, file) in files.enumerated() {
                let context = try #require(CGContext(data: nil, width: 4, height: 8, bitsPerComponent: 8,
                    bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
                context.setFillColor(CGColor(gray: CGFloat(index) * 0.4, alpha: 1))
                context.fill(CGRect(x: 0, y: 0, width: 4, height: 8))
                let destination = try #require(CGImageDestinationCreateWithURL(file as CFURL,
                    UTType.png.identifier as CFString, 1, nil))
                CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
                try #require(CGImageDestinationFinalize(destination))
            }
            bytes = try files.map { try Data(contentsOf: $0) }
            names = Dictionary(uniqueKeysWithValues: zip(bytes, ["Accueil", "Profil", "Compte"]))
        }

        func remove() { try? FileManager.default.removeItem(at: folder) }
    }
}

private actor RecognitionProbe {
    let names: [Data: String]
    let blockedFirst: Bool
    private(set) var inputs: [Data] = []
    private(set) var active = 0
    private(set) var peak = 0
    private var gate: CheckedContinuation<Void, Never>?
    private var released = false
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var cancellation: CheckedContinuation<Void, Never>?
    private var wasCancelled = false

    init(names: [Data: String], blockedFirst: Bool = false) {
        self.names = names
        self.blockedFirst = blockedFirst
    }

    func recognize(_ data: Data) async throws -> ScreenVisionFallback.Recognition {
        inputs.append(data)
        active += 1
        peak = max(peak, active)
        defer { active -= 1 }
        for (count, waiter) in waiters where inputs.count >= count { waiter.resume() }
        waiters.removeAll { inputs.count >= $0.0 }
        if blockedFirst && inputs.count == 1 {
            await withTaskCancellationHandler {
                if !released { await withCheckedContinuation { gate = $0 } }
            } onCancel: { Task { await self.cancelled() } }
        }
        try Task.checkCancellation()
        return ScreenVisionFallback.Recognition(title: names[data], pickerName: nil, lines: [], titleConfidence: 1)
    }

    func waitForCalls(_ count: Int) async {
        if inputs.count < count { await withCheckedContinuation { waiters.append((count, $0)) } }
    }

    func waitForCancellation() async {
        if !wasCancelled { await withCheckedContinuation { cancellation = $0 } }
    }

    private func cancelled() {
        wasCancelled = true
        cancellation?.resume()
        cancellation = nil
    }

    func release() {
        released = true
        gate?.resume()
        gate = nil
    }
}
