import AppKit
import Foundation
import ImageIO
import Testing
import StillsetCore
@testable import StillsetFeatures

@Suite(.serialized)
@MainActor
struct RecentAnalysisIntegrationTests {
    @Test func cachedReimportRebuildsOriginalPNGsAndPreservesEveryOccurrence() async throws {
        let fixture = try fixtureURL()
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let video = root.appendingPathComponent("first.mov")
        try FileManager.default.copyItem(at: fixture, to: video)
        let cache = RecentAnalysisCache(directory: root.appendingPathComponent("cache"))
        let original = snapshot(video)
        let source = try #require(try await cache.fingerprint(for: video))
        try await cache.store(original, for: source)
        let model = makeModel(cache)
        model.importVideo(video)
        try await waitForAnalysis(model)
        #expect(model.errorMessage == nil)
        #expect(model.notice?.contains("Analyse récente retrouvée") == true)
        #expect(model.notice?.contains("Analyse incomplète pour 1") == true)
        #expect(model.analysisPreviewFrames.isEmpty)
        #expect(model.screenshots.map(\.id) == original.occurrences.map(\.state.id))
        #expect(model.screenshots.map(\.state.representativeTimestamp) == [0.2, 1, 2.8])
        #expect(model.screenshots.map(\.fileURL.lastPathComponent) == ["001_accueil.png", "002_accueil.png", "003_accueil.png"])
        #expect(model.screenClassifications.values.allSatisfy { $0.screenID == 1 })
        #expect(model.visibleScreenshots.map(\.id) == Array(original.occurrences.prefix(2)).map(\.state.id))
        model.setUniqueScreens(false)
        #expect(model.visibleScreenshots.count == 3)
        model.setTimelineGrouping(true)
        #expect(model.timelineScreenGroups.count == 1)
        #expect(model.timelineScreenGroups[0].screenshots.count == 3)
        model.selectAll()
        #expect(model.selectedScreenshots.count == 3)
        #expect(model.dragURLs(startingAt: model.screenshots[0].id) == model.screenshots.map(\.fileURL))
        let oldURLs = model.screenshots.map(\.fileURL)
        let oldBytes = try oldURLs.map { try Data(contentsOf: $0) }
        for url in oldURLs {
            let image = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
            let properties = try #require(CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [CFString: Any])
            #expect(properties[kCGImagePropertyPixelWidth] as? Int == 128)
            #expect(properties[kCGImagePropertyPixelHeight] as? Int == 192)
        }
        try FileManager.default.removeItem(at: oldURLs[0].deletingLastPathComponent())
        let renamed = root.appendingPathComponent("renamed.mov")
        try FileManager.default.moveItem(at: video, to: renamed)
        model.importVideo(renamed)
        try await waitForAnalysis(model)
        #expect(model.notice?.contains("Analyse récente retrouvée") == true)
        #expect(model.videoURL == renamed)
        #expect(model.screenshots.map(\.id) == original.occurrences.map(\.state.id))
        #expect(model.screenshots.map(\.state.interval) == original.occurrences.map(\.state.interval))
        #expect(model.screenshots.map(\.state.representativeTimestamp) == [0.2, 1, 2.8])
        #expect(model.screenshots.map(\.fileURL) != oldURLs)
        #expect(try model.screenshots.map { try Data(contentsOf: $0.fileURL) } == oldBytes)
        #expect(model.visibleScreenshots.count == 2)
        #expect(model.screenshots.map { model.screenClassifications[$0.id]?.stateID } == [1, 2, 1])
    }

    @Test func reanalysisBypassesCacheAndReplacesOnlyOnSuccess() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let video = root.appendingPathComponent("video.mov")
        try FileManager.default.copyItem(at: fixtureURL(), to: video)
        let cache = RecentAnalysisCache(directory: root.appendingPathComponent("cache"))
        let seeded = snapshot(video)
        let source = try #require(try await cache.fingerprint(for: video))
        try await cache.store(seeded, for: source)
        let model = makeModel(cache)
        model.importVideo(video)
        try await waitForAnalysis(model)
        model.reanalyze()
        let prior = try #require(try await cache.load(for: source))
        #expect(prior.occurrences.map(\.state.id) == seeded.occurrences.map(\.state.id))
        try await waitForAnalysis(model)
        #expect(model.errorMessage == nil)
        #expect(model.notice?.contains("Analyse récente retrouvée") != true)
        #expect(model.screenshots.map(\.id) != seeded.occurrences.map(\.state.id))
        let fresh = try #require(try await cache.load(for: source))
        #expect(fresh.occurrences.map(\.state.id) == model.screenshots.map(\.id))
        #expect(!fresh.occurrences.isEmpty)
        model.reanalyze()
        model.cancel()
        await model.waitForAnalysis()
        #expect(!model.isWorking && !model.isAnalyzing)
        let retained = try #require(try await cache.load(for: source))
        #expect(retained.occurrences.map(\.state.id) == fresh.occurrences.map(\.state.id))
        model.importVideo(video)
        try await waitForAnalysis(model)
        #expect(model.notice?.contains("Analyse récente retrouvée") == true)
        #expect(model.screenshots.map(\.id) == fresh.occurrences.map(\.state.id))
    }

    @Test func badCachedExtractionRetriesFreshOnceWithCleanUI() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let video = root.appendingPathComponent("video.mov")
        try FileManager.default.copyItem(at: fixtureURL(), to: video)
        let cache = RecentAnalysisCache(directory: root.appendingPathComponent("cache"))
        let source = try #require(try await cache.fingerprint(for: video))
        let states = [UIState(interval: 0..<1, representativeTimestamp: 0.2, stabilityScore: 1),
                      UIState(interval: 9..<10, representativeTimestamp: 9.5, stabilityScore: 1)]
        let bad = try #require(CachedAnalysis(result: AnalysisResult(sourceURL: video, duration: 10, states: states),
            catalog: catalog(names: ["Seeded", "Seeded"], failures: 0)))
        try await cache.store(bad, for: source)
        let model = makeModel(cache)
        model.importVideo(video)
        try await waitForAnalysis(model)
        #expect(model.errorMessage == nil)
        #expect(model.notice?.contains("Analyse récente retrouvée") != true)
        #expect(!model.screenshots.isEmpty)
        #expect(Set(model.screenshots.map(\.id)).isDisjoint(with: states.map(\.id)))
        #expect(model.detectedScreens.map(\.id) == model.screenshots.map(\.id))
        #expect(model.screenshots.allSatisfy { FileManager.default.fileExists(atPath: $0.fileURL.path) })
        #expect(model.selectedScreenshotIDs.isSubset(of: Set(model.screenshots.map(\.id))))
        let restored = try #require(try await cache.load(for: source))
        #expect(restored.occurrences.map(\.state.id) == model.screenshots.map(\.id))
    }

    @Test func unavailableCacheStillProducesUsableResults() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let unavailable = root.appendingPathComponent("unavailable")
        try Data([0]).write(to: unavailable)
        let model = makeModel(RecentAnalysisCache(directory: unavailable))
        model.importVideo(try fixtureURL())
        try await waitForAnalysis(model)
        #expect(model.errorMessage == nil)
        #expect(!model.screenshots.isEmpty)
        #expect(model.screenshots.allSatisfy { FileManager.default.fileExists(atPath: $0.fileURL.path) })
        #expect(model.notice?.contains("Analyse récente retrouvée") != true)
    }

    @Test func successfulRefinementPersistsAndPartialRefinementKeepsPriorMetadata() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let video = root.appendingPathComponent("video.mov")
        try FileManager.default.copyItem(at: fixtureURL(), to: video)
        let cache = RecentAnalysisCache(directory: root.appendingPathComponent("cache"))
        let source = try #require(try await cache.fingerprint(for: video))
        let seeded = snapshot(video)
        try await cache.store(seeded, for: source)
        let refined = catalog(names: ["Compte", "Compte", "Compte"], failures: 0)
        let model = makeModel(cache, refine: { _ in refined })
        model.importVideo(video)
        try await waitForAnalysis(model)
        model.refineScreens()
        try await waitForRefinement(model)
        #expect(model.screenshots.map { model.screenClassifications[$0.id]?.name } == ["Compte", "Compte", "Compte"])
        let persisted = try #require(try await cache.load(for: source))
        #expect(persisted.catalog.classifications == refined.classifications)
        #expect(persisted.occurrences.map(\.state.id) == seeded.occurrences.map(\.state.id))
        #expect(persisted.catalog.recognitionFailures == 0 && persisted.catalog.errorDescription == nil)
        let partial = makeModel(cache, refine: { _ in catalog(names: ["Partiel", "Partiel", "Partiel"], failures: 1) })
        partial.importVideo(video)
        try await waitForAnalysis(partial)
        partial.refineScreens()
        try await waitForRefinement(partial)
        #expect(partial.notice?.contains("Affinage incomplet") == true)
        #expect(partial.screenClassifications.values.allSatisfy { $0.name == "Partiel" })
        let unchanged = try #require(try await cache.load(for: source))
        #expect(unchanged.catalog.classifications == refined.classifications)
    }

    @Test func cancelledRefinementCannotPublishAcrossSameUUIDReimport() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let video = root.appendingPathComponent("video.mov")
        try FileManager.default.copyItem(at: fixtureURL(), to: video)
        let cache = RecentAnalysisCache(directory: root.appendingPathComponent("cache"))
        let source = try #require(try await cache.fingerprint(for: video))
        let seeded = snapshot(video)
        try await cache.store(seeded, for: source)
        let gate = RefinementGate()
        let stale = catalog(names: ["Stale", "Stale", "Stale"], failures: 0)
        let model = makeModel(cache, refine: { _ in await gate.wait(); return stale })
        model.importVideo(video)
        try await waitForAnalysis(model)
        model.refineScreens()
        try await waitUntil { await gate.isWaiting }
        model.cancelRefinement()
        model.importVideo(video)
        #expect(model.isWorking)
        await gate.release()
        try await waitForAnalysis(model)
        #expect(model.screenshots.map(\.id) == seeded.occurrences.map(\.state.id))
        try await waitUntil { await gate.finished }
        for _ in 0..<5 { await Task.yield() }
        #expect(model.refinementDetail == nil)
        #expect(model.screenClassifications.values.allSatisfy { $0.name == "Accueil" })
        let unchanged = try #require(try await cache.load(for: source))
        #expect(unchanged.catalog.classifications == seeded.catalog.classifications)
    }

    @Test func partialScreenshotsWithoutCacheContextCanStillRefine() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let video = try fixtureURL()
        let states = snapshot(video).result(for: video).states
        let files = try await ScreenshotExporter.export(states: states, from: video, to: root)
        let refined = catalog(names: ["Compte", "Compte", "Compte"], failures: 0)
        let cache = RecentAnalysisCache(directory: root.appendingPathComponent("cache"))
        let model = makeModel(cache, refine: { _ in refined })
        model.screenshots = zip(states, files).map { CapturedScreenshot(state: $0.0, fileURL: $0.1) }
        model.refineScreens()
        try await waitForRefinement(model)
        #expect(model.screenClassifications.values.allSatisfy { $0.name == "Compte" })
        #expect(model.screenshots.count == 3)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("cache").path))
    }

    @Test func cancelDuringFreshCatalogCannotOverwritePriorCacheOrNewSession() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let video = root.appendingPathComponent("video.mov")
        try FileManager.default.copyItem(at: fixtureURL(), to: video)
        let cache = RecentAnalysisCache(directory: root.appendingPathComponent("cache"))
        let source = try #require(try await cache.fingerprint(for: video))
        let seeded = snapshot(video)
        try await cache.store(seeded, for: source)
        let gate = RefinementGate()
        let model = makeModel(cache, local: { files in
            await gate.wait()
            return catalog(names: Array(repeating: "Stale", count: files.count), failures: 0)
        })
        model.importVideo(video)
        try await waitForAnalysis(model)
        model.reanalyze()
        try await waitUntil { await gate.isWaiting }
        #expect(model.screenshots.count == 5)
        let abandonedFiles = model.screenshots.map(\.fileURL)
        model.cancel()
        #expect(model.isWorking)
        await gate.release()
        try await waitForAnalysis(model)
        model.importVideo(video)
        try await waitForAnalysis(model)
        try await waitUntil { await gate.finished }
        for _ in 0..<5 { await Task.yield() }
        #expect(!model.isWorking && model.errorMessage == nil)
        #expect(model.screenshots.map(\.id) == seeded.occurrences.map(\.state.id))
        #expect(model.screenClassifications.values.allSatisfy { $0.name == "Accueil" })
        #expect(abandonedFiles.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
        let retained = try #require(try await cache.load(for: source))
        #expect(retained.occurrences.map(\.state.id) == seeded.occurrences.map(\.state.id))
    }

    @Test func changedSourceDuringRefinementKeepsPublishedAndCachedMetadata() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let video = root.appendingPathComponent("video.mov")
        try FileManager.default.copyItem(at: fixtureURL(), to: video)
        let cache = RecentAnalysisCache(directory: root.appendingPathComponent("cache"))
        let source = try #require(try await cache.fingerprint(for: video))
        let seeded = snapshot(video)
        try await cache.store(seeded, for: source)
        let gate = RefinementGate()
        let refined = catalog(names: ["Stale", "Stale", "Stale"], failures: 0)
        let model = makeModel(cache, refine: { _ in await gate.wait(); return refined })
        model.importVideo(video)
        try await waitForAnalysis(model)
        model.refineScreens()
        try await waitUntil { await gate.isWaiting }
        var bytes = try Data(contentsOf: video)
        bytes[bytes.count - 1] ^= 1
        try bytes.write(to: video)
        await gate.release()
        try await waitForRefinement(model)
        #expect(model.screenClassifications.values.allSatisfy { $0.name == "Accueil" })
        let retained = try #require(try await cache.load(for: source))
        #expect(retained.catalog.classifications == seeded.catalog.classifications)
    }

    @Test func normalQuitCleanupIsIdempotentAndKeepsMetadata() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let video = try fixtureURL()
        let cache = RecentAnalysisCache(directory: root.appendingPathComponent("cache"))
        let source = try #require(try await cache.fingerprint(for: video))
        try await cache.store(snapshot(video), for: source)
        let model = makeModel(cache)
        model.importVideo(video)
        try await waitForAnalysis(model)
        let folder = try #require(model.screenshots.first?.fileURL.deletingLastPathComponent())
        #expect(FileManager.default.fileExists(atPath: folder.path))
        NotificationCenter.default.post(name: NSApplication.willTerminateNotification, object: nil)
        NotificationCenter.default.post(name: NSApplication.willTerminateNotification, object: nil)
        #expect(!FileManager.default.fileExists(atPath: folder.path))
        let retained = try #require(try await cache.load(for: source))
        #expect(retained.occurrences.map(\.state.representativeTimestamp) == [0.2, 1, 2.8])
    }

    private func snapshot(_ url: URL) -> CachedAnalysis {
        let states = [UIState(interval: 0..<0.4, representativeTimestamp: 0.2, stabilityScore: 1),
                      UIState(interval: 0.8..<1.2, representativeTimestamp: 1, stabilityScore: 0.75),
                      UIState(interval: 2.6..<3, representativeTimestamp: 2.8, stabilityScore: 1)]
        return CachedAnalysis(result: AnalysisResult(sourceURL: url, duration: 3.1, states: states),
            catalog: catalog(names: ["Accueil", "Accueil", "Accueil"], failures: 1))!
    }

    private nonisolated func catalog(names: [String], failures: Int) -> ScreenCatalog {
        let classifications = names.enumerated().map {
            ScreenClassification(screenID: 1, name: $0.element, stateID: $0.offset == 1 ? 2 : 1)
        }
        return ScreenCatalog(classifications: classifications, usedContextualNaming: failures == 0,
            visionNames: failures == 0 ? 0 : names.count - 1, recognitionFailures: failures,
            errorDescription: failures == 0 ? nil : "Reconnaissance partielle")
    }

    private func makeModel(_ cache: RecentAnalysisCache,
                           local: (@Sendable ([URL]) async throws -> ScreenCatalog)? = nil,
                           refine: (@Sendable ([URL]) async throws -> ScreenCatalog)? = nil) -> AppModel {
        let suite = "Stillset-integration-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let localAnalysis: @Sendable ([URL]) async throws -> ScreenCatalog = local ?? { files in
            catalog(names: Array(repeating: "Local", count: files.count), failures: 1)
        }
        return AppModel(preferences: AppPreferences(defaults: defaults), cache: cache,
                        localCatalog: localAnalysis, refineCatalog: refine)
    }

    private func fixtureURL() throws -> URL {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Core/Tests/Fixtures/scroll-stops-navigation-return.mov")
        #expect(FileManager.default.fileExists(atPath: url.path))
        return url
    }

    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Stillset-integration-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func waitForAnalysis(_ model: AppModel) async throws {
        do { try await waitUntil { !model.isWorking } }
        catch {
            let detail = "\(model.progress.stage) \(model.progress.fraction) \(model.progress.detail), captures=\(model.screenshots.count)"
            model.cancel()
            throw WaitError.analysisTimeout(detail)
        }
    }

    private func waitForRefinement(_ model: AppModel) async throws {
        try await waitUntil { model.refinementDetail == nil }
    }

    private func waitUntil(_ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(30)
        while !(await condition()) {
            guard ContinuousClock.now < deadline else { throw WaitError.timeout }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private enum WaitError: Error { case timeout, analysisTimeout(String) }
}

private actor RefinementGate {
    var isWaiting = false
    var finished = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            isWaiting = true
        }
        finished = true
    }

    func release() { continuation?.resume(); continuation = nil }
}
