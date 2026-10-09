import CoreGraphics
import Foundation
import ImageIO
import Synchronization
import Testing
import UniformTypeIdentifiers
@testable import StillsetCore

@Suite(.timeLimit(.minutes(1)))
struct EvidenceReuseTests {
    @Test func preparedEvidenceSurvivesLocalAIAndAliasesWithOne800PixelThumbnail() async throws {
        let images = try EvidenceImages()
        defer { images.remove() }
        let counts = Mutex<[Data: Int]>([:])
        let thumbnails = Mutex<[Data: Int]>([:])
        let recognize: ScreenCatalogAnalyzer.Recognition = { data, image in
            counts.withLock { $0[data, default: 0] += 1 }
            #expect(image.width == 400 && image.height == 800)
            return ScreenVisionFallback.Recognition(title: images.names[data], pickerName: nil, lines: [], titleConfidence: 1)
        }
        let thumbnail: ScreenCatalogAnalyzer.Thumbnail = { data in
            thumbnails.withLock { $0[data, default: 0] += 1 }
            return try ScreenCatalogAnalyzer.proxyImage(data)
        }
        let prepared = ScreenCatalogAnalyzer.PreparedRecognition(recognizeImage: recognize, thumbnail: thumbnail)
        prepared.start(fileURL: images.files[0])
        let analyzer = ScreenCatalogAnalyzer(recognizeImage: recognize, thumbnail: thumbnail)
        let files = [images.files[0], images.files[1], images.files[0], images.files[2]]
        let expected = [
            ScreenClassification(screenID: 1, name: "Accueil"),
            ScreenClassification(screenID: 2, name: "Profil"),
            ScreenClassification(screenID: 1, name: "Accueil"),
            ScreenClassification(screenID: 3, name: "Compte", stateID: 4)
        ]
        let local = try await analyzer.analyze(fileURLs: files, useFoundationModels: false, preparedRecognition: prepared)
        #expect(local.classifications == expected && local.recognitionFailures == 0)
        let aliases = try ScreenshotExporter.prepareNamedFiles(files: files, screenNames: Array(repeating: "Alias", count: 4))
        for mode in [true, false] {
            let result = try await analyzer.analyze(fileURLs: aliases, useFoundationModels: mode)
            #expect(result.classifications == expected && result.errorDescription == nil)
        }
        #expect(counts.withLock { $0 } == Dictionary(uniqueKeysWithValues: images.bytes.map { ($0, 1) }))
        #expect(thumbnails.withLock { $0 } == Dictionary(uniqueKeysWithValues: images.bytes.map { ($0, 1) }))
        let reordered = try await analyzer.analyze(fileURLs: [aliases[3], aliases[1], aliases[0], aliases[3]], useFoundationModels: false)
        #expect(reordered.classifications == [
            ScreenClassification(screenID: 1, name: "Compte"),
            ScreenClassification(screenID: 2, name: "Profil"),
            ScreenClassification(screenID: 3, name: "Accueil"),
            ScreenClassification(screenID: 1, name: "Compte")
        ])
        #expect(counts.withLock { $0.values.reduce(0, +) } == 3)
    }

    @Test func changedContentExtractsOnlyItsNewEvidence() async throws {
        let images = try EvidenceImages()
        defer { images.remove() }
        let counts = Mutex<[Data: Int]>([:])
        let analyzer = ScreenCatalogAnalyzer(recognizeImage: { data, _ in
            counts.withLock { $0[data, default: 0] += 1 }
            return ScreenVisionFallback.Recognition(title: images.names[data], pickerName: nil, lines: [], titleConfidence: 1)
        })
        let inputs = [images.files[0], images.files[1], images.files[0]]
        let first = try await analyzer.analyze(fileURLs: inputs, useFoundationModels: false)
        #expect(first.classifications.map(\.name) == ["Accueil", "Profil", "Accueil"])
        try images.bytes[2].write(to: images.files[0])
        let changed = try await analyzer.analyze(fileURLs: inputs, useFoundationModels: false)
        #expect(changed.classifications == [
            ScreenClassification(screenID: 1, name: "Compte"),
            ScreenClassification(screenID: 2, name: "Profil"),
            ScreenClassification(screenID: 1, name: "Compte")
        ])
        #expect(counts.withLock { $0 } == Dictionary(uniqueKeysWithValues: images.bytes.map { ($0, 1) }))
    }

    @Test func failedRecognitionRetriesWithoutRepeatingSuccessfulExtraction() async throws {
        let images = try EvidenceImages()
        defer { images.remove() }
        let counts = Mutex<[Data: Int]>([:])
        let thumbnails = Mutex<[Data: Int]>([:])
        let analyzer = ScreenCatalogAnalyzer(recognizeImage: { data, _ in
            let count = counts.withLock { counts in
                counts[data, default: 0] += 1
                return counts[data, default: 0]
            }
            if data == images.bytes[1] && count == 1 { throw CocoaError(.fileReadCorruptFile) }
            return ScreenVisionFallback.Recognition(title: images.names[data], pickerName: nil, lines: [], titleConfidence: 1)
        }, thumbnail: { data in
            thumbnails.withLock { $0[data, default: 0] += 1 }
            return try ScreenCatalogAnalyzer.proxyImage(data)
        })
        let first = try await analyzer.analyze(fileURLs: images.files, useFoundationModels: false)
        #expect(first.classifications.map(\.name) == ["Accueil", "Capture à examiner", "Compte"])
        #expect(first.recognitionFailures == 1)
        let retried = try await analyzer.analyze(fileURLs: images.files, useFoundationModels: false)
        #expect(retried.classifications.map(\.name) == ["Accueil", "Profil", "Compte"])
        #expect(retried.recognitionFailures == 0 && retried.errorDescription == nil)
        let expected = [images.bytes[0]: 1, images.bytes[1]: 2, images.bytes[2]: 1]
        #expect(counts.withLock { $0 } == expected)
        #expect(thumbnails.withLock { $0 } == expected)
    }

    @Test func successfulEmptyTitleEvidenceIsReusedDespiteIncompleteNames() async throws {
        let images = try EvidenceImages()
        defer { images.remove() }
        let calls = Mutex<Int>(0)
        let analyzer = ScreenCatalogAnalyzer(recognizeImage: { _, _ in
            calls.withLock { $0 += 1 }
            return ScreenVisionFallback.Recognition(title: nil, pickerName: nil, lines: [])
        })
        let files = [images.files[0], images.files[0]]
        for contextual in [true, false, true] {
            let result = try await analyzer.analyze(fileURLs: files, useContextualNaming: contextual, useFoundationModels: false)
            #expect(result.classifications == Array(repeating: ScreenClassification(screenID: 1, name: "Capture à examiner"), count: 2))
            #expect(result.recognitionFailures == (contextual ? 2 : 0))
        }
        #expect(calls.withLock { $0 } == 1)
    }

    @Test func realVisionUsesTheShared800PixelImageAcrossModes() async throws {
        let video = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/scroll-stops-navigation-return.mov")
        let result = try await AnalysisPipeline.run(url: video, onProgress: { _ in })
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let files = try await ScreenshotExporter.export(states: [result.states[0]], from: video, to: folder)
        let counts = Mutex<Int>(0)
        let analyzer = ScreenCatalogAnalyzer(recognizeImage: { _, image in
            counts.withLock { $0 += 1 }
            return try await ScreenVisionFallback.recognize(image)
        })
        let local = try await analyzer.analyze(fileURLs: files, useFoundationModels: false)
        let baseline = try await ScreenCatalogAnalyzer().analyze(fileURLs: files, useFoundationModels: false)
        #expect(local.classifications == baseline.classifications)
        _ = try await analyzer.analyze(fileURLs: files, useContextualNaming: false)
        let localAgain = try await analyzer.analyze(fileURLs: files, useFoundationModels: false)
        #expect(localAgain.classifications == baseline.classifications)
        #expect(counts.withLock { $0 } == 1)
    }
}

private struct EvidenceImages: Sendable {
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
            let context = try #require(CGContext(data: nil, width: 800, height: 1600, bitsPerComponent: 8,
                bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
            context.setFillColor(CGColor(gray: CGFloat(index) * 0.4, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 800, height: 1600))
            let destination = try #require(CGImageDestinationCreateWithURL(file as CFURL, UTType.png.identifier as CFString, 1, nil))
            CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
            try #require(CGImageDestinationFinalize(destination))
        }
        bytes = try files.map { try Data(contentsOf: $0) }
        names = Dictionary(uniqueKeysWithValues: zip(bytes, ["Accueil", "Profil", "Compte"]))
    }
    func remove() { try? FileManager.default.removeItem(at: folder) }
}
