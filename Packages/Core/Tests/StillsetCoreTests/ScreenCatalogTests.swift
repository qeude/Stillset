import CryptoKit
import CoreGraphics
import CoreText
import Foundation
import FoundationModels
import ImageIO
@testable import StillsetCore
import Synchronization
import Testing
import Synchronization
import UniformTypeIdentifiers

struct ScreenCatalogTests {
    @Test func successfulRecognitionIsReusedAcrossChangedCatalogs() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = try screenshot(title: "Page A", offset: 0, folder: folder)
        let second = try screenshot(title: "Page B", offset: 0, folder: folder)
        let copiedFirst = folder.appendingPathComponent("copied-page-a.png")
        try Data(contentsOf: first).write(to: copiedFirst)
        let counter = RecognitionCounter()
        let cache = ScreenRecognitionCache()
        let makeRecognition: @Sendable (URL) async throws -> ScreenVisionFallback.Recognition = { url in
            await counter.increment()
            let title = url == second ? "Page B" : "Page A"
            return ScreenVisionFallback.Recognition(title: title, pickerName: nil,
                lines: [ScreenVisionFallback.TextLine(text: title, box: CGRect(x: 0.2, y: 0.8, width: 0.6, height: 0.04), confidence: 1)],
                titleConfidence: 1)
        }
        let videoAnalyzer = ScreenCatalogAnalyzer(recognitionOperation: makeRecognition, recognitionCache: cache)
        let sessionAnalyzer = ScreenCatalogAnalyzer(recognitionOperation: makeRecognition, recognitionCache: cache)

        _ = try await videoAnalyzer.analyze(fileURLs: [first], useFoundationModels: false)
        let changed = try await sessionAnalyzer.analyze(fileURLs: [copiedFirst, second], useFoundationModels: false)

        #expect(await counter.value == 2)
        #expect(changed.classifications.map(\.name) == ["Page A", "Page B"])
        #expect(changed.classifications[0].stateID != changed.classifications[1].stateID)
    }

    @Test(.timeLimit(.minutes(2))) func largeCatalogKeepsCachedSuffixAvailableWhileFillingUncachedPrefix() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let template = try screenshot(title: "Shared page", offset: 0, folder: folder)
        let templateData = try Data(contentsOf: template)
        let files = try (0..<256).map { index -> URL in
            let destination = folder.appendingPathComponent(String(format: "screen-%03d.png", index))
            var bytes = templateData
            bytes.append(contentsOf: [0x53, UInt8((index >> 8) & 0xff), UInt8(index & 0xff)])
            try bytes.write(to: destination)
            return destination
        }
        let counter = RecognitionCounter()
        let cache = ScreenRecognitionCache()
        let recognize: @Sendable (URL) async throws -> ScreenVisionFallback.Recognition = { _ in
            await counter.increment()
            let title = "Shared page"
            let rowPixels = [UInt8](repeating: 0, count: 128 * 24 * 4)
            return ScreenVisionFallback.Recognition(title: title, pickerName: nil,
                lines: [
                    ScreenVisionFallback.TextLine(text: title, box: CGRect(x: 0.2, y: 0.8, width: 0.6, height: 0.04), confidence: 1, rowPixels: rowPixels),
                    ScreenVisionFallback.TextLine(text: "100", box: CGRect(x: 0.1, y: 0.65, width: 0.25, height: 0.03), confidence: 1, rowPixels: rowPixels),
                    ScreenVisionFallback.TextLine(text: "200", box: CGRect(x: 0.1, y: 0.5, width: 0.25, height: 0.03), confidence: 1, rowPixels: rowPixels),
                    ScreenVisionFallback.TextLine(text: "300", box: CGRect(x: 0.1, y: 0.35, width: 0.25, height: 0.03), confidence: 1, rowPixels: rowPixels)
                ], titleConfidence: 1)
        }

        _ = try await ScreenCatalogAnalyzer(recognitionOperation: recognize, recognitionCache: cache)
            .analyze(fileURLs: Array(files.suffix(128)), useFoundationModels: false)
        let result = try await ScreenCatalogAnalyzer(recognitionOperation: recognize, recognitionCache: cache)
            .analyze(fileURLs: files, useFoundationModels: false)

        let calls = await counter.value
        #expect(calls == 256)
        #expect(result.classifications.count == files.count)
        #expect(result.classifications.allSatisfy { $0.name == "Shared page" })
        #expect(Set(result.classifications.map(\.stateID)).count == 1)
    }

    @Test func requestCancellationHandlesBothRegistrationOrdersExactlyOnce() {
        let enqueueImmediately: @Sendable (@escaping @Sendable () -> Void) -> Void = { $0() }
        let cancelBeforeInstall = RequestCancellation(enqueue: enqueueImmediately)
        let firstCancelCount = Mutex(0)
        cancelBeforeInstall.cancel()
        let shouldStart = cancelBeforeInstall.install { firstCancelCount.withLock { $0 += 1 } }
        #expect(!shouldStart)
        #expect(firstCancelCount.withLock { $0 } == 1)
        cancelBeforeInstall.cancel()
        #expect(firstCancelCount.withLock { $0 } == 1)

        let installBeforeCancel = RequestCancellation(enqueue: enqueueImmediately)
        let secondCancelCount = Mutex(0)
        #expect(installBeforeCancel.install { secondCancelCount.withLock { $0 += 1 } })
        installBeforeCancel.cancel()
        installBeforeCancel.cancel()
        #expect(secondCancelCount.withLock { $0 } == 1)

        let completedRequest = RequestCancellation(enqueue: enqueueImmediately)
        let completedCancelCount = Mutex(0)
        #expect(completedRequest.install { completedCancelCount.withLock { $0 += 1 } })
        completedRequest.finish()
        completedRequest.cancel()
        #expect(completedCancelCount.withLock { $0 } == 0)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["STILLSET_TEST_LOCAL_MODEL"] == "1"))
    func hybridNamesWholeScreens() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let home = try screenshot(title: "Accueil", offset: 0, folder: folder)
        let result = try await ScreenCatalogAnalyzer().analyze(fileURLs: [home, home])
        #expect(result.visionNames == 2)
        #expect(result.classifications[0].name == "Accueil")
        #expect(result.errorDescription == nil)
        #expect(result.classifications.count == 2)
        #expect(result.classifications[0] == result.classifications[1])
        #expect(!result.classifications[0].name.isEmpty)
        #expect(!result.classifications[0].name.contains("—"))
    }

    @Test func exactDuplicatesReuseIdentityWithoutImageUnderstanding() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let home = try screenshot(title: "Accueil", offset: 0, folder: folder)
        let scroll = try screenshot(title: "Accueil", offset: 90, folder: folder)
        let details = try screenshot(title: "Details", offset: 0, folder: folder)
        let blank = try screenshot(title: nil, offset: 0, folder: folder)
        let missing = folder.appendingPathComponent("missing.png")
        let files = [home, home, details, home, blank, missing]
        let result = try await ScreenCatalogAnalyzer().analyze(fileURLs: files, useContextualNaming: false)
        #expect(result.classifications.count == files.count)
        #expect(result.usedContextualNaming == false)
        #expect(result.recognitionFailures == 1)
        let labels = result.classifications
        #expect(labels[0].name == String(localized: "Screenshot to Review", bundle: .module))
        #expect(labels[0].screenID == labels[1].screenID)
        #expect(labels[0].screenID != labels[2].screenID)
        #expect(labels[0].screenID == labels[3].screenID)
        #expect(labels[4].screenID != labels[5].screenID)
        let named = try await ScreenshotExporter.prepareNamedFiles(files: Array(files.prefix(4)), screenNames: Array(labels.prefix(4)).map(\.name))
        let slug = Bundle.module.preferredLocalizations.first == "fr" ? "capture-a-examiner" : "screenshot-to-review"
        #expect(named.map(\.lastPathComponent) == (1...4).map { String(format: "%03d_", $0) + slug + ".png" })
        #expect(try Data(contentsOf: named[0]) == Data(contentsOf: home))
        #expect(FileManager.default.fileExists(atPath: home.path))
        let scrollResult = try await ScreenCatalogAnalyzer().analyze(fileURLs: [home, scroll], useContextualNaming: false)
        #expect(scrollResult.classifications.count == 2)
        #expect(scrollResult.classifications[0].stateID != scrollResult.classifications[1].stateID)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["STILLSET_TEST_IMAGE_DIRECTORY"] != nil))
    func changedAccountContentKeepsSeparateStates() async throws {
        let directory = try #require(ProcessInfo.processInfo.environment["STILLSET_TEST_IMAGE_DIRECTORY"])
        let first = URL(fileURLWithPath: directory).appendingPathComponent("005_compte.png")
        let second = URL(fileURLWithPath: directory).appendingPathComponent("006_compte.png")
        let result = try await ScreenCatalogAnalyzer().analyze(fileURLs: [first, second, second])
        #expect(result.recognitionFailures == 0)
        #expect(result.visionNames == 3)
        #expect(result.classifications.allSatisfy { $0.name == "Compte" })
        #expect(result.classifications[0].stateID != result.classifications[1].stateID)
        #expect(result.classifications[1].stateID == result.classifications[2].stateID)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["STILLSET_TEST_IMAGE_DIRECTORY"] != nil))
    func mileageSmallScrollKeepsOneUniqueState() async throws {
        let directory = try #require(ProcessInfo.processInfo.environment["STILLSET_TEST_IMAGE_DIRECTORY"])
        let files = ["001_kilometrage.png", "002_kilometrage.png", "003_kilometrage.png"].map {
            URL(fileURLWithPath: directory).appendingPathComponent($0)
        }
        let result = try await ScreenCatalogAnalyzer().analyze(fileURLs: files)
        #expect(result.recognitionFailures == 0)
        #expect(result.visionNames >= 2)
        #expect(result.classifications[0].stateID == result.classifications[2].stateID)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["STILLSET_TEST_MILEAGE_PAIR_DIRECTORY"] != nil))
    func mileageScrollGroupsLocallyWithoutFoundationModels() async throws {
        let directory = try #require(ProcessInfo.processInfo.environment["STILLSET_TEST_MILEAGE_PAIR_DIRECTORY"])
        let inputs = ["018_choix-de-kilometrage.png", "020_choix-de-kilometrage.png"].map {
            URL(fileURLWithPath: directory).appendingPathComponent($0)
        }
        let catalog = try await ScreenCatalogAnalyzer().analyze(fileURLs: inputs, useFoundationModels: false)
        #expect(catalog.errorDescription == nil && catalog.recognitionFailures == 0)
        #expect(catalog.classifications[0].stateID == catalog.classifications[1].stateID)
    }

    @Test func knownEmptyRecognitionDoesNotRepeatOCRAfterModelFailure() async throws {
        let url = URL(fileURLWithPath: "/stillset-missing-file.png")
        let fallback = AttemptCount()
        let recognize: @Sendable (URL) async throws -> String? = { input in
            #expect(input == url)
            await fallback.record()
            return "Profil"
        }
        let knownEmpty = try await ScreenSemanticNamer.nameWithFallback(url, recognizedTitle: .known(nil),
                                                                       recognizeTitle: recognize) {
            throw LanguageModelError.guardrailViolation(.init(debugDescription: "Blocked"))
        }
        #expect(knownEmpty.name == String(localized: "Screenshot to Review", bundle: .module) && knownEmpty.error != nil && !knownEmpty.usedVision)
        #expect(await fallback.value == 0)
        let missing = try await ScreenSemanticNamer.nameWithFallback(url, recognizedTitle: .missing,
                                                                    recognizeTitle: recognize) {
            throw LanguageModelError.guardrailViolation(.init(debugDescription: "Blocked"))
        }
        #expect(missing.name == "Profil" && missing.error == nil && missing.usedVision)
        #expect(await fallback.value == 1)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["STILLSET_TEST_FRONTMOST_DIRECTORY"] != nil))
    func foregroundPickerAndRepeatedFormHaveOneStateEach() async throws {
        let directory = try #require(ProcessInfo.processInfo.environment["STILLSET_TEST_FRONTMOST_DIRECTORY"])
        let files = ["001_picker.png", "003_picker.png", "006_form.png", "008_form.png"].map {
            URL(fileURLWithPath: directory).appendingPathComponent($0)
        }
        let result = try await ScreenCatalogAnalyzer().analyze(fileURLs: files)
        #expect(result.errorDescription == nil)
        #expect(result.visionNames == 2)
        #expect(result.classifications.count == 4)
        #expect(result.classifications[0].stateID == result.classifications[1].stateID)
        #expect(result.classifications[2].stateID == result.classifications[3].stateID)
        #expect(result.classifications[0].stateID != result.classifications[2].stateID)
        #expect(result.classifications[0].name.folding(options: .diacriticInsensitive, locale: nil).lowercased().contains("kilometr"))
        #expect(result.classifications[2].name.hasSuffix("partiellement rempli"))
    }

    @Test func parallelRecognitionHandlesEmptyInputAndCancellation() async throws {
        let analyzer = ScreenCatalogAnalyzer()
        let empty = try await analyzer.analyze(fileURLs: [], useContextualNaming: false)
        #expect(empty.classifications.isEmpty)
        #expect(empty.recognitionFailures == 0)
        let missing = URL(fileURLWithPath: "/stillset-missing-file.png")
        await #expect(throws: CancellationError.self) {
            try await withThrowingTaskGroup(of: ScreenCatalog.self) { group in
                group.addTask {
                    try await analyzer.analyze(fileURLs: Array(repeating: missing, count: 100), useContextualNaming: false)
                }
                group.cancelAll()
                _ = try await group.next()
            }
        }
    }

    @Test func catalogCacheUsesImageContentAndInvalidatesChangedFiles() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let home = try screenshot(title: "Accueil", offset: 0, folder: folder)
        let details = try screenshot(title: "Details", offset: 0, folder: folder)
        let renamed = folder.appendingPathComponent("renamed.png")
        try FileManager.default.copyItem(at: home, to: renamed)
        let analyzer = ScreenCatalogAnalyzer()
        let original = try await analyzer.analyze(fileURLs: [home, renamed], useContextualNaming: false)
        let progress = CatalogProgress()
        let reused = try await analyzer.analyze(fileURLs: [home, renamed], useContextualNaming: false) { fraction, _ in
            await progress.record(fraction)
        }
        #expect(reused.classifications == original.classifications)
        #expect(await progress.values == [1])
        try FileManager.default.removeItem(at: renamed)
        try FileManager.default.copyItem(at: details, to: renamed)
        let changed = try await analyzer.analyze(fileURLs: [home, renamed], useContextualNaming: false)
        #expect(changed.classifications[0].stateID != changed.classifications[1].stateID)
    }

    @Test func retriesTransientErrorsOnceAndUsesRecognizedTitleAfterFailure() async throws {
        let home = URL(fileURLWithPath: "/stillset-missing-file.png")
        let attempts = AttemptCount()
        let result = try await ScreenSemanticNamer.nameWithFallback(home, recognizedTitle: .known("Accueil")) {
            await attempts.record()
            throw LanguageModelError.timeout(.init(debugDescription: "Temporary"))
        }
        #expect(await attempts.value == 2)
        #expect(result.name == "Accueil")
        #expect(result.usedVision)
        #expect(result.error == nil)
        let refusal = AttemptCount()
        let refused = try await ScreenSemanticNamer.nameWithFallback(home, recognizedTitle: .known("Accueil")) {
            await refusal.record()
            throw LanguageModelError.guardrailViolation(.init(debugDescription: "Blocked"))
        }
        #expect(await refusal.value == 1)
        #expect(refused.name == "Accueil")
        #expect(refused.usedVision)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["STILLSET_TEST_FRONTMOST_DIRECTORY"] != nil))
    func visionFallbackNamesForemostPicker() async throws {
        let directory = try #require(ProcessInfo.processInfo.environment["STILLSET_TEST_FRONTMOST_DIRECTORY"])
        for filename in ["001_picker.png", "003_picker.png"] {
            let recognition = try await ScreenVisionFallback.recognize(URL(fileURLWithPath: directory).appendingPathComponent(filename))
            #expect(recognition.pickerName != nil)
            let title = try #require(recognition.title)
            #expect(title.folding(options: .diacriticInsensitive, locale: nil).lowercased().contains("kilometr"))
        }
        let form = try await ScreenVisionFallback.recognize(URL(fileURLWithPath: directory).appendingPathComponent("006_form.png"))
        #expect(form.title == "Simulation de revenus")
        #expect(form.pickerName == nil)
    }

    @Test func visionEvidenceSkipsNamingButNeverMergesMatchingText() async throws {
        let box = CGRect(x: 0.1, y: 0.5, width: 0.4, height: 0.03)
        let first = ScreenVisionFallback.Recognition(title: "Profil", pickerName: nil,
            lines: [.init(text: "Vide", box: box, confidence: 1)])
        let changed = ScreenVisionFallback.Recognition(title: "Profil", pickerName: nil,
            lines: [.init(text: "Rempli", box: box, confidence: 1)])
        #expect(first.clearlyDiffers(from: changed))
        #expect(!first.clearlyDiffers(from: first))
        let scrolled = ScreenVisionFallback.Recognition(title: "Profil", pickerName: nil,
            lines: [.init(text: "Vide", box: box.offsetBy(dx: 0, dy: -0.1), confidence: 1)])
        #expect(!first.clearlyDiffers(from: scrolled))
        let uncertain = ScreenVisionFallback.Recognition(title: "Profil", pickerName: nil,
            lines: [.init(text: "Rempli", box: box, confidence: 0.5)])
        #expect(!first.clearlyDiffers(from: uncertain))
        let values = ["2018", "85000", "1000"].map {
            ScreenVisionFallback.TextLine(text: $0, box: box, confidence: 1)
        }
        #expect(ScreenVisionFallback.numericPickerName(title: "Année", confidence: 1, body: values) != nil)
        let formBody = values + [.init(text: "Année", box: box, confidence: 1)]
        #expect(ScreenVisionFallback.numericPickerName(title: "Modifier véhicule", confidence: 1, body: formBody) == nil)
        let missing = URL(fileURLWithPath: "/stillset-missing-picker.png")
        let picker = ScreenVisionFallback.Recognition(title: "Kilométrage", pickerName: "Choix de kilométrage", lines: [])
        let names = try await ScreenSemanticNamer.classify(fileURLs: [missing], sources: [0],
            recognition: [0: picker], onProgress: { _, _ in })
        #expect(names.first?.name == "Choix de kilométrage")
        #expect(names.first?.usedVision == true)
        #expect(names.first?.error == nil)
    }

    @Test func cachedNamesAvoidModelCallsAndImageReads() async throws {
        let missing = URL(fileURLWithPath: "/stillset-missing-image.png")
        let results = try await ScreenSemanticNamer.classify(
            fileURLs: [missing, missing], sources: [0, 0], cachedNames: [0: ScreenNameResult(name: "Profil rempli", error: nil, usedVision: true)], onProgress: { _, _ in })
        #expect(results.count == 2)
        #expect(results.allSatisfy { $0.name == "Profil rempli" && $0.error == nil && $0.usedVision })
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["STILLSET_PROFILE_PIPELINE"] == "1"
        && ProcessInfo.processInfo.environment["STILLSET_PROFILE_VIDEO"] != nil))
    func profileLocalRecordingAndCachedCatalog() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["STILLSET_PROFILE_VIDEO"])
        let video = URL(fileURLWithPath: path)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let start = ContinuousClock.now
        let result = try await AnalysisPipeline.run(url: video, onProgress: { _ in })
        let decoded = ContinuousClock.now
        let files = try await ScreenshotExporter.export(states: result.states, from: video, to: folder)
        let exported = ContinuousClock.now
        let analyzer = ScreenCatalogAnalyzer()
        let localOnly = ProcessInfo.processInfo.environment["STILLSET_PROFILE_LOCAL_ONLY"] == "1"
        let catalog = try await analyzer.analyze(fileURLs: files, useFoundationModels: !localOnly)
        let named = ContinuousClock.now
        #expect(catalog.recognitionFailures == 0)
        #expect(catalog.errorDescription == nil)
        #expect(files.count == result.states.count)
        print("Stillset timing: decode=\(start.duration(to: decoded)), export=\(decoded.duration(to: exported)), catalog=\(exported.duration(to: named)), captures=\(files.count), uniqueStates=\(Set(catalog.classifications.map(\.stateID)).count), failures=\(catalog.recognitionFailures)")
        // Failed requests are deliberately uncached; do not benchmark a full second analysis as a cache lookup.
        if catalog.recognitionFailures == 0, catalog.errorDescription == nil {
            let cached = try await analyzer.analyze(fileURLs: files, useFoundationModels: !localOnly)
            #expect(cached.classifications == catalog.classifications)
            print("Stillset cached catalog: \(named.duration(to: .now))")
        }

    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["STILLSET_TEST_FAST_CATALOG_LIST"] != nil))
    func localCatalogIsReadyWithinTenSeconds() async throws {
        let list = try #require(ProcessInfo.processInfo.environment["STILLSET_TEST_FAST_CATALOG_LIST"])
        let files = try String(contentsOfFile: list, encoding: .utf8).split(separator: "\n")
            .map { URL(fileURLWithPath: String($0)) }
        let first = try #require(files.first)
        let firstBytes = try Data(contentsOf: first)
        let observations = Mutex<(started: ContinuousClock.Instant?, calls: Int)>((nil, 0))
        let recognize: @Sendable (Data) async throws -> ScreenVisionFallback.Recognition = { data in
            if data == firstBytes {
                observations.withLock { value in
                    value.started = value.started ?? .now
                    value.calls += 1
                }
            }
            return try await ScreenVisionFallback.recognize(data)
        }
        let prepared = ScreenCatalogAnalyzer.PreparedRecognition(recognize: recognize)
        defer { prepared.cancel() }
        let start = ContinuousClock.now
        prepared.start(fileURL: first)
        let analysisStart = ContinuousClock.now
        let catalog = try await ScreenCatalogAnalyzer(recognize: recognize).analyze(
            fileURLs: files, useFoundationModels: false, preparedRecognition: prepared)
        let elapsed = start.duration(to: .now)
        let (ocrStart, calls) = observations.withLock { $0 }
        let firstStarted = try #require(ocrStart)
        #expect(calls == 1)
        print("Stillset first PNG OCR: startRelativeToAnalysis=\(analysisStart.duration(to: firstStarted)), calls=\(calls)")
        #expect(elapsed < .seconds(10))
        #expect(catalog.classifications.count == files.count && catalog.recognitionFailures == 0)
        #expect(catalog.errorDescription == nil)
        print("Stillset local catalog: \(elapsed), captures=\(files.count), states=\(Set(catalog.classifications.map(\.stateID)).count)")
    }

    @Test func localMatchingRequiresVisualEvidenceAndPreservesChangedValuesBadgesAndSelection() {
        let box = CGRect(x: 0.08, y: 0.5, width: 0.2, height: 0.02)
        let row = [UInt8](repeating: 50, count: 128 * 24 * 4)
        let pixels = [UInt8](repeating: 50, count: 128 * 256 * 4)
        func recognize(_ texts: [String]) -> ScreenVisionFallback.Recognition {
            ScreenVisionFallback.Recognition(title: "Profil", pickerName: nil,
                lines: texts.enumerated().map { offset, text in
                    ScreenVisionFallback.TextLine(text: text, box: box.offsetBy(dx: 0, dy: -Double(offset) * 0.07),
                        confidence: 1, rowPixels: row)
                }, titleConfidence: 1, pixels: pixels)
        }
        let original = recognize(["Profil", "Nom", "Alice"])
        #expect(original.sameState(as: original) == true)
        #expect(original.sameState(as: recognize(["Profil", "Nom", "Bob"])) == false)
        #expect(original.sameState(as: recognize(["Profil", "Nom", "alice"])) != true)
        #expect(original.sameState(as: recognize(["Profil", "Nom", "Alice", "Vérifié"])) == false)
        let list = recognize(["Profil", "Alfa", "Audi", "BMW"])
        let otherList = recognize(["Profil", "Ford", "Fiat", "Honda"])
        let moved = ScreenVisionFallback.Recognition(title: otherList.title, pickerName: nil,
            lines: otherList.lines.map { ScreenVisionFallback.TextLine(text: $0.text,
                box: $0.box.offsetBy(dx: 0, dy: 0.19), confidence: 1, rowPixels: row) }, titleConfidence: 1, pixels: pixels)
        #expect(list.sameState(as: moved) == false)
        var unknown = original
        unknown.pixels = []
        #expect(original.sameState(as: unknown) == nil)
        var selected = original
        for y in 64..<72 {
            for x in 112..<120 {
                for channel in 0..<3 { selected.pixels[(y * 128 + x) * 4 + channel] = 240 }
            }
        }
        #expect(original.sameState(as: selected) == nil)
        var picker = recognize(["Kilométrage", "15 000 km", "50 000 km", "100 000 km"])
        picker = ScreenVisionFallback.Recognition(title: "Kilométrage", pickerName: nil,
            lines: picker.lines, titleConfidence: 1, pixels: pixels)
        var shiftedLines = picker.lines.map {
            ScreenVisionFallback.TextLine(text: $0.text, box: $0.box.offsetBy(dx: 0, dy: 0.02), confidence: 1, rowPixels: row)
        }
        let scrolled = ScreenVisionFallback.Recognition(title: "Kilométrage", pickerName: nil,
            lines: shiftedLines, titleConfidence: 1, pixels: selected.pixels)
        #expect(picker.sameState(as: scrolled) == true)
        for y in 8..<16 {
            for x in 112..<120 {
                for channel in 0..<3 { shiftedLines[1].rowPixels[(y * 128 + x) * 4 + channel] = 240 }
            }
        }
        let changedSelection = ScreenVisionFallback.Recognition(title: "Kilométrage", pickerName: nil,
            lines: shiftedLines, titleConfidence: 1, pixels: selected.pixels)
        #expect(picker.sameState(as: changedSelection) == nil)
        var leftControlLines = scrolled.lines
        for y in 8..<16 {
            for x in 0..<4 {
                for channel in 0..<3 { leftControlLines[1].rowPixels[(y * 128 + x) * 4 + channel] = 240 }
            }
        }
        let leftSelection = ScreenVisionFallback.Recognition(title: "Kilométrage", pickerName: nil,
            lines: leftControlLines, titleConfidence: 1, pixels: selected.pixels)
        #expect(picker.sameState(as: leftSelection) == nil)
        var changedValueLines = scrolled.lines
        changedValueLines[1] = ScreenVisionFallback.TextLine(text: "20 000 km", box: changedValueLines[1].box,
            confidence: 1, rowPixels: row)
        let changedValue = ScreenVisionFallback.Recognition(title: "Kilométrage", pickerName: nil,
            lines: changedValueLines, titleConfidence: 1, pixels: selected.pixels)
        #expect(picker.sameState(as: changedValue) != true)
    }

    @Test func reliableLocalTitlesAvoidModelCallsAndImageReads() async throws {
        let recognition = ScreenVisionFallback.Recognition(title: "Compte", pickerName: nil, lines: [], titleConfidence: 1)
        let names = try await ScreenSemanticNamer.classify(fileURLs: [URL(fileURLWithPath: "/missing.png")], sources: [0],
            recognition: [0: recognition], onProgress: { _, _ in })
        #expect(names.count == 1 && names[0].name == "Compte" && names[0].usedVision && names[0].error == nil)
    }

    @Test func localNamingHandlesAmbiguousFormsWithoutReadingImagesOrStartingTheModel() async throws {
        let fields = ["Marque", "Modèle", "Kilométrage"].enumerated().map { index, text in
            ScreenVisionFallback.TextLine(text: text,
                box: CGRect(x: 0.08, y: 0.6 - Double(index) * 0.08, width: 0.3, height: 0.02), confidence: 1)
        }
        let recognition = ScreenVisionFallback.Recognition(title: "Simulation de revenus", pickerName: nil,
            lines: fields, titleConfidence: 1)
        #expect(recognition.fastName == nil)
        let result = try await ScreenSemanticNamer.classify(fileURLs: [URL(fileURLWithPath: "/missing.png")], sources: [0],
            recognition: [0: recognition], useFoundationModels: false, onProgress: { _, _ in })
        #expect(result[0].name == "Simulation de revenus" && result[0].usedVision && result[0].error == nil)
    }

    @Test func comparisonCacheReusesNegativeEvidenceButRetriesFailures() async throws {
        let analyzer = ScreenCatalogAnalyzer()
        let first = SHA256.hash(data: Data("first".utf8))
        let second = SHA256.hash(data: Data("second".utf8))
        let changed = SHA256.hash(data: Data("changed".utf8))
        let attempts = AttemptCount()
        let distinct = try await analyzer.cachedComparison([first, second]) {
            await attempts.record()
            return false
        }
        let reversed = try await analyzer.cachedComparison([second, first]) {
            await attempts.record()
            return true
        }
        #expect(!distinct && !reversed)
        #expect(await attempts.value == 1)
        await #expect(throws: CocoaError.self) {
            try await analyzer.cachedComparison([first, changed]) {
                throw CocoaError(.coderInvalidValue)
            }
        }
        let retried = try await analyzer.cachedComparison([first, changed]) {
            await attempts.record()
            return true
        }
        #expect(retried)
        #expect(await attempts.value == 2)
    }

    @Test(.timeLimit(.minutes(1))) func orderedWorkKeepsOneSlotBusyAndRestoresInputOrder() async throws {
        let work = CatalogWork()
        let values = try await ScreenCatalogAnalyzer.orderedMap([0, 1, 2, 3]) { index in
            await work.begin(String(index))
            try Task.checkCancellation()
            await work.end(String(index))
            return index
        }
        #expect(values == [0, 1, 2, 3])
        #expect(await work.peak == 1)
        #expect(await work.completed == ["0", "1", "2", "3"])
        let task = Task {
            try await ScreenCatalogAnalyzer.orderedMap([0, 1, 2]) { index in
                try await Task.sleep(for: .seconds(60))
                return index
            }
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test func candidateSelectionKeepsSmallVisualChangesWithoutVisionEvidence() {
        #expect(ScreenCatalogAnalyzer.candidateDistance(pixels: [20, 22], otherPixels: [22, 24]) == 2)
        #expect(ScreenCatalogAnalyzer.candidateDistance(pixels: [20, 22], otherPixels: [220, 224]) == nil)
        #expect(ScreenCatalogAnalyzer.candidateDistance(pixels: nil, otherPixels: [20, 22]) == nil)
        #expect(ScreenCatalogAnalyzer.candidateDistance(pixels: [], otherPixels: []) == nil)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["STILLSET_TEST_SCROLL_DIRECTORY"] != nil))
    func smallYearPickerScrollRemainsCandidate() throws {
        let directory = try #require(ProcessInfo.processInfo.environment["STILLSET_TEST_SCROLL_DIRECTORY"])
        let files = try FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: directory), includingPropertiesForKeys: nil)
        let first = try #require(files.first { $0.lastPathComponent.hasPrefix("014_00-") })
        let second = try #require(files.first { $0.lastPathComponent.hasPrefix("015_00-") })
        let distance = ScreenCatalogAnalyzer.candidateDistance(
            pixels: try ScreenCatalogAnalyzer.comparisonPixels(first),
            otherPixels: try ScreenCatalogAnalyzer.comparisonPixels(second))
        #expect(distance != nil)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["STILLSET_TEST_SCROLL_DIRECTORY"] != nil))
    func yearPickerSmallScrollSharesOneUniqueState() async throws {
        let directory = try #require(ProcessInfo.processInfo.environment["STILLSET_TEST_SCROLL_DIRECTORY"])
        let files = try FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: directory), includingPropertiesForKeys: nil)
        let inputs = try ["014_00-", "015_00-", "016_00-"].map { prefix in
            try #require(files.first { $0.lastPathComponent.hasPrefix(prefix) })
        }
        let catalog = try await ScreenCatalogAnalyzer().analyze(fileURLs: inputs)
        #expect(catalog.errorDescription == nil)
        #expect(catalog.classifications[0].stateID == catalog.classifications[2].stateID)
    }

    @Test func semanticFilenamesStaySafeOrderedAndDoNotOverwrite() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("source.png")
        try Data([1, 2, 3]).write(to: file)
        #expect(ScreenClassification(screenID: 1, name: "Simulation de revenus — Choix du kilométrage").name == "Simulation de revenus Choix du kilométrage")
        let files = try await ScreenshotExporter.prepareNamedFiles(files: [file, file], screenNames: ["../Réglages / Profil", "💥"])
        #expect(files.map(\.lastPathComponent) == ["001_reglages-profil.png", "002_ecran.png"])
        #expect(try await ScreenshotExporter.prepareNamedFiles(files: files, screenNames: ["../Réglages / Profil", "💥"]) == files)
        let collision = try await ScreenshotExporter.prepareNamedFiles(files: [file], screenNames: ["Réglages / Profil"])
        #expect(collision[0].lastPathComponent == "001_reglages-profil-2.png")
        #expect(try Data(contentsOf: files[0]) == Data([1, 2, 3]))
        await #expect(throws: ScreenshotExportError.self) {
            try await ScreenshotExporter.prepareNamedFiles(files: [file], screenNames: [])
        }
    }

    @Test(.disabled(if: isVirtualMachine, "Requires a physical Mac")) func preparedRealVisionMatchesUnpreparedCatalog() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let home = try screenshot(title: "Accueil", offset: 0, folder: folder)
        let details = try screenshot(title: "Details", offset: 0, folder: folder)
        let counts = Mutex<[Data: Int]>([:])
        let recognize: ScreenCatalogAnalyzer.Recognition = { data, image in
            counts.withLock { $0[data, default: 0] += 1 }
            return try await ScreenVisionFallback.recognize(image)
        }
        let prepared = ScreenCatalogAnalyzer.PreparedRecognition(recognizeImage: recognize)
        defer { prepared.cancel() }
        prepared.start(fileURL: home)
        let files = [home, details, home]
        let catalog = try await ScreenCatalogAnalyzer(recognizeImage: recognize).analyze(
            fileURLs: files, useFoundationModels: false, preparedRecognition: prepared)
        let baseline = try await ScreenCatalogAnalyzer().analyze(fileURLs: files, useFoundationModels: false)
        #expect(catalog.classifications == baseline.classifications)
        #expect(catalog.classifications.map(\.name) == ["Accueil", "Details", "Accueil"])
        #expect(catalog.classifications[0].stateID == catalog.classifications[2].stateID)
        #expect(catalog.recognitionFailures == 0 && catalog.errorDescription == nil)
        let homeBytes = try Data(contentsOf: home)
        #expect(counts.withLock { $0[homeBytes] } == 1)
        #expect(counts.withLock { $0.values.reduce(0, +) } == 2)
    }

    private func screenshot(title: String?, offset: CGFloat, folder: URL) throws -> URL {
        let context = try #require(CGContext(
            data: nil, width: 400, height: 800, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 400, height: 800))
        if let title {
            let attributes: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica-Bold" as CFString, 34, nil),
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1)
            ]
            context.textPosition = CGPoint(x: 70, y: 680)
            CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: title, attributes: attributes)), context)
            for row in 0..<4 {
                context.setFillColor(CGColor(gray: 0.3 + CGFloat(row) * 0.12, alpha: 1))
                context.fill(CGRect(x: 40, y: 100 + CGFloat(row) * 100 + offset, width: 320, height: 60))
            }
        }
        let url = folder.appendingPathComponent("\(UUID().uuidString).png")
        let image = try #require(context.makeImage())
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        try #require(CGImageDestinationFinalize(destination))
        return url
    }
}

private actor RecognitionCounter {
    private(set) var value = 0
    func increment() { value += 1 }
}

private actor CatalogProgress {
    private(set) var values: [Double] = []
    func record(_ value: Double) { values.append(value) }
}

private actor AttemptCount {
    private(set) var value = 0
    func record() { value += 1 }
}

private actor CatalogWork {
    private(set) var peak = 0
    private(set) var completed: [String] = []
    private var active = 0
    private let firstStarted = AsyncStream<Void>.makeStream()
    private let otherCallsFinished = AsyncStream<Void>.makeStream()

    func begin(_ call: String) async {
        if call == "1" {
            for await _ in firstStarted.stream {}
        }
        active += 1
        peak = max(peak, active)
        if call == "0" { firstStarted.continuation.finish() }
    }

    func waitForOtherCalls() async {
        // Keep the first slot occupied while the second processes every remaining input.
        for await _ in otherCallsFinished.stream {}
    }

    func end(_ call: String) {
        completed.append(call)
        active -= 1
        if completed.count == 3 { otherCallsFinished.continuation.finish() }
    }
}
