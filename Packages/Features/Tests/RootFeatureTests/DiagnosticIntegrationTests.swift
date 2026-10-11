import Foundation
import StillsetCore
import Testing
@testable import StillsetFeatures

@MainActor
struct DiagnosticIntegrationTests {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func preferences() -> AppPreferences {
        AppPreferences(defaults: UserDefaults(suiteName: "DiagnosticIntegrationTests-\(UUID())")!)
    }

    private func journal(_ folder: URL) -> DiagnosticJournal {
        DiagnosticJournal(storeURL: folder.appendingPathComponent("store"), appVersion: "0.1.0", appBuild: "1")
    }

    private func events(_ journal: DiagnosticJournal, folder: URL) async throws -> [[String: Any]] {
        let url = folder.appendingPathComponent("export")
        try await journal.export(to: url)
        let report = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        return try #require(report["events"] as? [[String: Any]])
    }

    private func screenshot(_ root: URL, model: AppModel) throws {
        let url = root.appendingPathComponent("PRIVATE-FILENAME-OCR.png")
        try Data([1, 2, 3]).write(to: url)
        let state = UIState(interval: 0..<1, representativeTimestamp: 0, stabilityScore: 1)
        model.screenshots = [CapturedScreenshot(state: state, fileURL: url)]
        model.screenClassifications = [state.id: ScreenClassification(screenID: 1, name: "PRIVATE-SCREEN-NAME")]
    }

    @Test func queueRecordsRejectionRetryAndReanalysisWithoutPrivateRunnerStrings() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let diagnostics = journal(root)
        let queue = VideoImportQueue(runner: { model, _, _ in
            switch await model.attempt {
            case 1: .failed("PRIVATE-RUNNER-ERROR")
            case 2: .completed
            default: .cancelled
            }
        }, diagnostics: diagnostics)
        queue.enqueue([root.appendingPathComponent("PRIVATE-REJECTED.txt"), root.appendingPathComponent("PRIVATE-VIDEO.mov")])
        await queue.waitUntilDrained()
        let original = queue.models[1]
        queue.retry(original)
        await queue.waitUntilDrained()
        queue.reanalyze(queue.models[2])
        await queue.waitUntilDrained()
        let records = try await events(diagnostics, folder: root)
        let terminal = records.filter { $0["kind"] as? String == "finished" }
        #expect(terminal.count == 4)
        #expect(terminal.filter { $0["operation"] as? String == "videoImport" }.first?["failure"] as? String == "unsupportedImport")
        #expect(terminal.filter { $0["operation"] as? String == "analysis" }.compactMap { $0["outcome"] as? String } == ["failed", "success"])
        #expect(terminal.filter { $0["operation"] as? String == "reanalysis" }.first?["outcome"] as? String == "cancelled")
        for name in ["store", "export"] { #expect(try !String(contentsOf: root.appendingPathComponent(name), encoding: .utf8).contains("PRIVATE-")) }
    }

    @Test func synchronousRejectionAdmissionKeepsOnlyTwoWorkers() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let diagnostics = journal(root)
        let queue = VideoImportQueue(diagnostics: diagnostics)
        queue.enqueue((0..<12).map { root.appendingPathComponent("PRIVATE-\($0).txt") })
        #expect(queue.activeModelIDs.count == 2)
        await queue.waitUntilDrained()
        let terminal = try await events(diagnostics, folder: root).filter { $0["kind"] as? String == "finished" }
        #expect(terminal.count == 12)
        #expect(terminal.allSatisfy { $0["failure"] as? String == "unsupportedImport" })
        #expect(queue.activeModelIDs.isEmpty)
    }

    @Test func replacementSessionKeepsJournalAndCapturesAnalysisFailure() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let diagnostics = journal(root)
        let old = SessionModel(preferences: preferences(), diagnostics: diagnostics)
        let next = old.replacingVideos([root.appendingPathComponent("PRIVATE-MISSING.mov")])
        let model = next.imports.models[0]
        while model.importState == .queued { await Task.yield() }
        await next.imports.waitUntilDrained()
        let records = try await events(diagnostics, folder: root)
        #expect(records.filter { $0["kind"] as? String == "started" }.count == 1)
        #expect(records.last?["operation"] as? String == "analysis")
        #expect(records.last?["outcome"] as? String == "failed")
        #expect(try !String(contentsOf: root.appendingPathComponent("export"), encoding: .utf8).contains("PRIVATE-"))
        await next.finishSession()
    }

    @Test func appSaveAndRefinementFailuresAreRecordedOnce() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let diagnostics = journal(root)
        let hostile = NSError(domain: "PRIVATE-DOMAIN", code: 42, userInfo: [NSLocalizedDescriptionKey: "PRIVATE-ERROR"])
        let cache = RecentAnalysisCache(directory: root.appendingPathComponent("cache"))
        let model = AppModel(preferences: preferences(), cache: cache, diagnostics: diagnostics,
            refineCatalog: { _ in throw hostile })
        try screenshot(root, model: model)
        model.selectAll()
        model.chooseSaveFolder = { _ in root }
        model.copyFiles = { _, _, _ in throw hostile }
        model.saveSelection()
        await model.waitForSave()
        model.refineScreens()
        await model.waitForRefinement()
        let records = try await events(diagnostics, folder: root)
        let terminal = records.filter { $0["kind"] as? String == "finished" }
        #expect(terminal.compactMap { $0["operation"] as? String } == ["screenshotExport", "refinement"])
        #expect(terminal.compactMap { $0["failure"] as? String } == ["unknown", "unknown"])
        #expect(try !String(contentsOf: root.appendingPathComponent("export"), encoding: .utf8).contains("PRIVATE-"))
    }

    @Test func cancellationOutcomeSurvivesReplacedUIOwnership() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let diagnostics = journal(root)
        let gate = DiagnosticGate()
        let model = AppModel(preferences: preferences(), diagnostics: diagnostics)
        try screenshot(root, model: model)
        model.selectAll()
        model.chooseSaveFolder = { _ in root }
        model.copyFiles = { _, _, _ in
            await gate.block()
            throw CancellationError()
        }
        model.saveSelection()
        await gate.waitForStart()
        model.cleanUpSession()
        await gate.release()
        await model.waitForSave()
        let records = try await events(diagnostics, folder: root)
        #expect(records.last?["kind"] as? String == "finished")
        #expect(records.last?["outcome"] as? String == "cancelled")
        #expect(records.filter { $0["kind"] as? String == "finished" }.count == 1)
    }

    @Test func refinementTerminalSurvivesStaleSessionGuard() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let diagnostics = journal(root)
        let gate = DiagnosticGate()
        let hostile = NSError(domain: "PRIVATE-DOMAIN", code: 42, userInfo: [NSLocalizedDescriptionKey: "PRIVATE-ERROR"])
        let model = AppModel(preferences: preferences(), cache: RecentAnalysisCache(directory: root.appendingPathComponent("cache")),
            diagnostics: diagnostics, refineCatalog: { _ in await gate.block(); throw hostile })
        try screenshot(root, model: model)
        model.refineScreens()
        await gate.waitForStart()
        model.cleanUpSession()
        await gate.release()
        await model.waitForRefinement()
        let terminal = try await events(diagnostics, folder: root).filter { $0["kind"] as? String == "finished" }
        #expect(terminal.count == 1)
        #expect(terminal[0]["operation"] as? String == "refinement")
        #expect(terminal[0]["outcome"] as? String == "cancelled")
        #expect(model.refinementOutcome == nil)
    }

    @Test func sessionCatalogAndSaveAreRecordedWithoutNamesOrPaths() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let diagnostics = journal(root)
        let model = AppModel()
        try screenshot(root, model: model)
        let session = SessionModel(preferences: preferences(), imports: VideoImportQueue(models: [model]), catalogRunner: { _, _, _ in
            SessionCatalogResult(classifications: [ScreenClassification(screenID: 1, name: "PRIVATE-OCR")])
        }, diagnostics: diagnostics)
        await session.waitForCatalog()
        session.selectAll()
        session.chooseSaveFolder = { _ in root.appendingPathComponent("saved") }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("saved"), withIntermediateDirectories: true)
        session.saveSelection()
        await session.waitForExport()
        #expect(session.exportedFolderURL == root.appendingPathComponent("saved"))
        let terminal = try await events(diagnostics, folder: root).filter { $0["kind"] as? String == "finished" }
        #expect(terminal.compactMap { $0["operation"] as? String } == ["sessionCatalog", "sessionExport"])
        #expect(terminal.compactMap { $0["outcome"] as? String } == ["success", "success"])
        #expect(try !String(contentsOf: root.appendingPathComponent("export"), encoding: .utf8).contains("PRIVATE-"))
        await session.finishSession()
    }

    @Test func presenterCancellationCreatesNothingAndFailureIsFixed() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let diagnostics = journal(root)
        var failures = 0
        let cancelled = DiagnosticPresenter(journal: diagnostics, chooseDestination: { nil }, showFailure: { failures += 1 })
        cancelled.export()
        #expect(!cancelled.isExporting)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
        let export = root.appendingPathComponent("report.json")
        let presenter = DiagnosticPresenter(journal: diagnostics, chooseDestination: { export }, showFailure: { failures += 1 })
        presenter.export()
        #expect(presenter.isExporting)
        presenter.export()
        await presenter.waitForExport()
        #expect(!presenter.isExporting && failures == 0)
        #expect(FileManager.default.fileExists(atPath: export.path))
        let failed = DiagnosticPresenter(journal: diagnostics, chooseDestination: { export.appendingPathComponent("PRIVATE") }, showFailure: { failures += 1 })
        failed.export()
        await failed.waitForExport()
        #expect(failures == 1 && !failed.isExporting)
    }

    @Test(arguments: ["en", "fr"])
    func exportStringsAreLocalized(language: String) throws {
        let path = try #require(Bundle.module.path(forResource: language, ofType: "lproj"))
        let bundle = try #require(Bundle(path: path))
        #expect(String(localized: "Export Diagnostic…", bundle: bundle) == (language == "fr" ? "Exporter un diagnostic…" : "Export Diagnostic…"))
        #expect(String(localized: "Could not export the diagnostic.", bundle: bundle) == (language == "fr" ? "Impossible d’exporter le diagnostic." : "Could not export the diagnostic."))
        #expect(String(localized: "Choose another location and try again.", bundle: bundle) == (language == "fr" ? "Choisissez un autre emplacement et réessayez." : "Choose another location and try again."))
    }
}

private actor DiagnosticGate {
    private var started = false
    private var startWaiter: CheckedContinuation<Void, Never>?
    private var waiter: CheckedContinuation<Void, Never>?

    func block() async {
        started = true
        startWaiter?.resume()
        startWaiter = nil
        await withCheckedContinuation { waiter = $0 }
    }

    func waitForStart() async {
        if started { return }
        await withCheckedContinuation { startWaiter = $0 }
    }

    func release() { waiter?.resume(); waiter = nil }
}
