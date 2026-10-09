import AppKit
import Observation
import StillsetCore
import UniformTypeIdentifiers

struct CapturedScreenshot: Identifiable, Sendable {
    let state: UIState
    let fileURL: URL

    var id: UUID { state.id }
}

struct TimelineScreenGroup: Identifiable {
    let id: Int?
    let name: String
    let screenshots: [CapturedScreenshot]
}

@MainActor
@Observable
public final class AppModel {
    var videoURL: URL?
    var screenshots: [CapturedScreenshot] = []
    private var screenCatalogAnalyzer = ScreenCatalogAnalyzer()
    var screenClassifications: [UUID: ScreenClassification] = [:]
    private(set) var showsUniqueScreens = true
    private(set) var groupsTimelineByScreen = false
    private(set) var selectedScreenshotIDs: Set<UUID> = []
    private(set) var selectedScreenshotOrder: [UUID] = []
    var focusedScreenshotID: UUID?
    var focusNavigationID: UUID?
    var analysisPreviewFrames: [Frame] = []
    var detectedScreens: [UIState] = []
    var analysisStartedAt = Date()
    enum OperationOutcome: Equatable {
        case completed
        case cancelled
        case failed(String)
    }

    private(set) var analysisOutcome: OperationOutcome?
    private(set) var saveOutcome: OperationOutcome?
    private(set) var refinementOutcome: OperationOutcome?

    private struct AnalysisOperation {
        let id = UUID()
        var task: Task<Void, Never>?
        var progress = AnalysisProgress(stage: .decoding, fraction: 0, detail: "Lecture de la vidéo")
    }

    private struct SaveOperation {
        let id = UUID()
        let plan: ScreenshotExportPlan
        var task: Task<Void, Never>?
        var progress = AnalysisProgress(stage: .exporting, fraction: 0, detail: "Enregistrement des PNG")
    }

    private struct RefinementOperation {
        let id = UUID()
        var task: Task<Void, Never>?
        var detail = "Affinage des captures…"
    }

    private var analysisOperation: AnalysisOperation?
    private var saveOperation: SaveOperation?
    private var refinementOperation: RefinementOperation?
    private var lastAnalysisProgress = AnalysisProgress(stage: .decoding, fraction: 0, detail: "Déposez un enregistrement")
    var progress: AnalysisProgress {
        get { analysisOperation?.progress ?? lastAnalysisProgress }
        set {
            lastAnalysisProgress = newValue
            analysisOperation?.progress = newValue
        }
    }
    var saveProgress: AnalysisProgress? { saveOperation?.progress }
    public var isWorking: Bool { analysisOperation != nil || saveOperation != nil }
    var isAnalyzing: Bool { analysisOperation != nil }
    var errorMessage: String?
    var notice: String?
    var refinementDetail: String? { refinementOperation?.detail }
    var exportedFolderURL: URL?
    var followsLatest = true

    private let preferences: AppPreferences
    private let recentAnalysisCache: RecentAnalysisCache
    private let localCatalog: (@Sendable ([URL]) async throws -> ScreenCatalog)?
    private let refineCatalog: (@Sendable ([URL]) async throws -> ScreenCatalog)?
    private var sessionID = UUID()
    private var analysisAttemptID: UUID?
    private var cachedContext: (result: AnalysisResult, source: RecentAnalysisCache.Source)?
    private var terminationObserver: NSObjectProtocol?
    var chooseSaveFolder: (@MainActor (ScreenshotExportPlan) -> URL?)?
    var beforeOrganization: @Sendable () async throws -> Void = {}
    var copyFiles: @Sendable (ScreenshotExportPlan, URL, @Sendable (Double, String) -> Void) async throws -> [URL] = {
        try ScreenshotExporter.copy(plan: $0, to: $1, onProgress: $2)
    }
    private var stagingFolderURL: URL?
    private var selectionAnchorID: UUID?
    private var fanSlots: [UUID: Int] = [:]

    public convenience init(preferences: AppPreferences) {
        self.init(preferences: preferences, cache: .shared)
    }

    init(preferences: AppPreferences, cache: RecentAnalysisCache,
         localCatalog: (@Sendable ([URL]) async throws -> ScreenCatalog)? = nil,
         refineCatalog: (@Sendable ([URL]) async throws -> ScreenCatalog)? = nil) {
        self.preferences = preferences
        self.recentAnalysisCache = cache
        self.localCatalog = localCatalog
        self.refineCatalog = refineCatalog
        showsUniqueScreens = preferences.captureDefault == .uniques
        groupsTimelineByScreen = preferences.organisationDefault == .byScreen
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.cleanUpSession() }
        }
    }

    #if DEBUG
    func setPreviewAnalysisRunning(_ running: Bool) {
        analysisOperation = running ? AnalysisOperation() : nil
        progress = AnalysisProgress(
            stage: running ? .annotating : .complete,
            fraction: running ? 0.62 : 1,
            detail: running ? "Organisation des captures…" : "Captures prêtes"
        )
    }
    #endif

    isolated deinit {
        if let terminationObserver { NotificationCenter.default.removeObserver(terminationObserver) }
        if let stagingFolderURL { try? FileManager.default.removeItem(at: stagingFolderURL) }
        analysisOperation?.task?.cancel()
        saveOperation?.task?.cancel()
        refinementOperation?.task?.cancel()
    }

    func waitForAnalysis() async { await analysisOperation?.task?.value }
    func waitForSave() async { await saveOperation?.task?.value }
    func waitForRefinement() async { await refinementOperation?.task?.value }

    public var hasScreenshots: Bool { !screenshots.isEmpty }
    public var canCopySelection: Bool { !selectedScreenshotIDs.isEmpty }
    public var canSaveSelection: Bool { !selectedScreenshots.isEmpty && saveOperation == nil }

    var focusedScreenshot: CapturedScreenshot? {
        screenshots.first { $0.id == focusedScreenshotID }
    }

    private var filteredScreenshots: [CapturedScreenshot] {
        guard showsUniqueScreens else { return screenshots }
        var seen: Set<Int> = []
        return screenshots.filter { screenshot in
            guard let screen = screenClassifications[screenshot.id] else { return true }
            return seen.insert(screen.stateID).inserted
        }
    }

    var timelineScreenGroups: [TimelineScreenGroup] {
        let captures = filteredScreenshots
        let byScreen = Dictionary(grouping: captures) { screenClassifications[$0.id]?.screenID }
        var seen: Set<Int?> = []
        return captures.compactMap { capture in
            let screen = screenClassifications[capture.id]
            guard seen.insert(screen?.screenID).inserted else { return nil }
            return TimelineScreenGroup(id: screen?.screenID, name: screen?.name ?? "À identifier",
                                       screenshots: byScreen[screen?.screenID, default: []])
        }
    }

    var visibleScreenshots: [CapturedScreenshot] {
        groupsTimelineByScreen ? timelineScreenGroups.flatMap(\.screenshots) : filteredScreenshots
    }

    func setTimelineGrouping(_ enabled: Bool) {
        groupsTimelineByScreen = enabled
        selectionAnchorID = focusedScreenshotID
        focusNavigationID = focusedScreenshotID
        followsLatest = false
    }

    func setUniqueScreens(_ enabled: Bool) {
        showsUniqueScreens = enabled
        let visible = visibleScreenshots
        let ids = Set(visible.map(\.id))
        setSelection(selectedScreenshotOrder.filter { ids.contains($0) })
        if focusedScreenshotID.map({ ids.contains($0) }) != true {
            focusedScreenshotID = selectedScreenshotOrder.first ?? visible.first?.id
            if selectedScreenshotIDs.isEmpty, let focusedScreenshotID {
                setSelection([focusedScreenshotID], resetFan: true)
            }
        }
        selectionAnchorID = focusedScreenshotID
        focusNavigationID = focusedScreenshotID
        followsLatest = false
    }

    var selectedScreenshots: [CapturedScreenshot] {
        screenshots.filter { selectedScreenshotIDs.contains($0.id) }
    }

    var fanSelectedScreenshots: [CapturedScreenshot] {
        let byID = Dictionary(uniqueKeysWithValues: screenshots.map { ($0.id, $0) })
        return selectedScreenshotOrder.compactMap { byID[$0] }
    }

    func fanSlot(for id: UUID) -> Int {
        fanSlots[id] ?? 0
    }

    var previewDragURLs: [URL] {
        let selected = selectedScreenshots
        if !selected.isEmpty { return selected.map(\.fileURL) }
        return focusedScreenshot.map { [$0.fileURL] } ?? []
    }

    public func chooseVideo() {
        guard !isWorking else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .mpeg4Movie]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.prompt = "Ouvrir"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        importVideo(url)
    }

    func importVideo(_ url: URL) {
        beginAnalysis(url, reuseCache: true)
    }

    func reanalyze() {
        guard let videoURL else { return }
        beginAnalysis(videoURL, reuseCache: false)
    }

    private func beginAnalysis(_ url: URL, reuseCache: Bool) {
        guard !isWorking else { return }
        guard ["mov", "mp4"].contains(url.pathExtension.lowercased()) else {
            errorMessage = "Choisissez un enregistrement MOV ou MP4."
            return
        }
        cancelRefinement()
        screenCatalogAnalyzer = ScreenCatalogAnalyzer()
        sessionID = UUID()
        cachedContext = nil
        let oldRefinement = refinementOperation?.task
        let oldStaging = stagingFolderURL
        stagingFolderURL = nil
        clearAnalysisCaptures()
        showsUniqueScreens = preferences.captureDefault == .uniques
        groupsTimelineByScreen = preferences.organisationDefault == .byScreen
        analysisStartedAt = Date()
        videoURL = url
        exportedFolderURL = nil
        errorMessage = nil
        analyze(url, reuseCache: reuseCache, oldRefinement: oldRefinement, oldStaging: oldStaging)
    }

    private func clearAnalysisCaptures() {
        if let stagingFolderURL { try? FileManager.default.removeItem(at: stagingFolderURL) }
        stagingFolderURL = nil
        screenshots = []
        screenClassifications = [:]
        setSelection([])
        focusedScreenshotID = nil
        focusNavigationID = nil
        selectionAnchorID = nil
        analysisPreviewFrames = []
        detectedScreens = []
        followsLatest = true
        notice = nil
    }

    private func acceptsAnalysis(session: UUID, attempt: UUID) -> Bool {
        sessionID == session && analysisAttemptID == attempt
    }

    private enum ReconstructionError: Error {
        case sourceChanged
    }

    private func analyze(_ videoURL: URL, reuseCache: Bool, oldRefinement: Task<Void, Never>?, oldStaging: URL?) {
        let catalogAnalyzer = screenCatalogAnalyzer
        let localCatalog = localCatalog
        let cache = recentAnalysisCache
        let session = sessionID
        let firstAttempt = UUID()
        analysisAttemptID = firstAttempt
        analysisOperation = AnalysisOperation()
        analysisOutcome = nil
        let beforeOrganization = beforeOrganization
        progress = AnalysisProgress(stage: .decoding, fraction: 0, detail: "Lecture de la vidéo")
        let model = self
        analysisOperation?.task = Task.detached(priority: .userInitiated) {
            await oldRefinement?.value
            if let oldStaging { try? FileManager.default.removeItem(at: oldStaging) }
            await MainActor.run { model.refinementOperation = nil }
            let preparedRecognition = ScreenCatalogAnalyzer.PreparedRecognition()
            await withTaskCancellationHandler {
                var collector: IncrementalCaptures?
                var attempt = firstAttempt
                do {
                    var source = try await cache.fingerprint(for: videoURL)
                    var cached: CachedAnalysis?
                    if reuseCache, let source { cached = try await cache.load(for: source) }
                    while true {
                        try Task.checkCancellation()
                        let currentAttempt = attempt
                        let folder = FileManager.default.temporaryDirectory
                            .appendingPathComponent("Stillset-\(UUID().uuidString)", isDirectory: true)
                        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                        let registered = await MainActor.run {
                            guard model.acceptsAnalysis(session: session, attempt: currentAttempt) else { return false }
                            model.stagingFolderURL = folder
                            return true
                        }
                        guard registered else {
                            try? FileManager.default.removeItem(at: folder)
                            return
                        }
                        let captures = IncrementalCaptures(videoURL: videoURL, folderURL: folder,
                                                           preparedRecognition: cached == nil ? preparedRecognition : nil) { capture in
                            await MainActor.run {
                                guard model.acceptsAnalysis(session: session, attempt: currentAttempt) else { return }
                                model.screenshots.append(capture)
                                if model.followsLatest {
                                    model.focusedScreenshotID = capture.id
                                    model.setSelection([capture.id], resetFan: true)
                                }
                            }
                        }
                        collector = captures
                        do {
                            let result: AnalysisResult
                            if let cached {
                                result = cached.result(for: videoURL)
                                await MainActor.run {
                                    guard model.acceptsAnalysis(session: session, attempt: currentAttempt) else { return }
                                    model.detectedScreens = result.states
                                }
                                try await captures.append(result.states)
                            } else {
                                result = try await AnalysisPipeline.run(
                                    url: videoURL,
                                    onProgress: { update in
                                        Task { @MainActor in
                                            guard model.acceptsAnalysis(session: session, attempt: currentAttempt),
                                                  model.progress.stage == .decoding, update.stage == .decoding else { return }
                                            model.progress = update
                                        }
                                    },
                                    onAnalyzedFrames: { frames in
                                        await MainActor.run {
                                            guard model.acceptsAnalysis(session: session, attempt: currentAttempt),
                                                  model.progress.stage == .decoding else { return }
                                            let colorPreviews = frames.filter { $0.previewRGBA != nil }
                                            model.analysisPreviewFrames = Array((model.analysisPreviewFrames + colorPreviews).suffix(2))
                                        }
                                    },
                                    onDetectedScreens: { screens in
                                        await MainActor.run {
                                            guard model.acceptsAnalysis(session: session, attempt: currentAttempt) else { return }
                                            model.detectedScreens.append(contentsOf: screens)
                                        }
                                        try await captures.append(screens)
                                    }
                                )
                            }
                            try Task.checkCancellation()
                            let completed = try await captures.finish()
                            guard completed.map(\.id) == result.states.map(\.id) else {
                                throw ScreenshotExportError.invalidImageSequence
                            }
                            let files = completed.map(\.fileURL)
                            try Task.checkCancellation()
                            let catalog: ScreenCatalog
                            if let cached {
                                catalog = cached.catalog
                            } else {
                                await MainActor.run {
                                    guard model.acceptsAnalysis(session: session, attempt: currentAttempt) else { return }
                                    model.progress = AnalysisProgress(stage: .annotating, fraction: 0, detail: "Organisation des captures…")
                                }
                                try await beforeOrganization()
                                if let localCatalog {
                                    catalog = try await localCatalog(files)
                                } else {
                                    catalog = try await catalogAnalyzer.analyze(fileURLs: files, useFoundationModels: false, preparedRecognition: preparedRecognition) { fraction, _ in
                                        await MainActor.run {
                                            guard model.acceptsAnalysis(session: session, attempt: currentAttempt) else { return }
                                            model.progress = AnalysisProgress(stage: .annotating, fraction: fraction, detail: "Organisation des captures…")
                                        }
                                    }
                                }
                            }
                            if cached == nil { await preparedRecognition.cancelAndDrain() }
                            let namedFiles = try ScreenshotExporter.prepareNamedFiles(files: files, screenNames: catalog.classifications.map(\.name))
                            if let originalSource = source {
                                let matches = try await cache.matches(originalSource)
                                if matches == false { throw ReconstructionError.sourceChanged }
                                if matches == nil { source = nil }
                            }
                            try Task.checkCancellation()
                            let completedSource = source
                            let wasCached = cached != nil
                            let accepted = await MainActor.run {
                                guard model.acceptsAnalysis(session: session, attempt: currentAttempt), !Task.isCancelled else { return false }
                                model.screenClassifications = Dictionary(uniqueKeysWithValues: zip(result.states, catalog.classifications).map { ($0.0.id, $0.1) })
                                model.screenshots = zip(result.states, namedFiles).map { CapturedScreenshot(state: $0.0, fileURL: $0.1) }
                                model.setUniqueScreens(model.showsUniqueScreens)
                                model.cachedContext = completedSource.map { (result, $0) }
                                let warning = Self.catalogWarning(catalog)
                                model.notice = wasCached
                                    ? (["Analyse récente retrouvée", warning].compactMap { $0 }.joined(separator: ". "))
                                    : warning
                                model.progress = AnalysisProgress(stage: .complete, fraction: 1, detail: "\(files.count) captures prêtes")
                                return true
                            }
                            guard accepted else { return }
                            if let completedSource {
                                if wasCached {
                                    try await cache.markUsed(completedSource)
                                } else if let snapshot = CachedAnalysis(result: result, catalog: catalog) {
                                    try await cache.store(snapshot, for: completedSource)
                                }
                            }
                            try Task.checkCancellation()
                            await MainActor.run {
                                guard model.acceptsAnalysis(session: session, attempt: currentAttempt) else { return }
                                model.analysisAttemptID = nil
                                model.analysisOutcome = .completed
                                model.analysisOperation = nil
                            }
                            return
                        } catch {
                            await captures.cancelAndDrain()
                            if Task.isCancelled || error is CancellationError { throw CancellationError() }
                            guard cached != nil else { throw error }
                            let nextAttempt = UUID()
                            let retry = await MainActor.run {
                                guard model.acceptsAnalysis(session: session, attempt: currentAttempt) else { return false }
                                model.analysisAttemptID = nextAttempt
                                model.clearAnalysisCaptures()
                                model.progress = AnalysisProgress(stage: .decoding, fraction: 0, detail: "Lecture de la vidéo")
                                return true
                            }
                            guard retry else { return }
                            attempt = nextAttempt
                            cached = nil
                            source = try await cache.fingerprint(for: videoURL)
                        }
                    }
                } catch {
                    await collector?.cancelAndDrain()
                    await preparedRecognition.cancelAndDrain()
                    let cancelled = Task.isCancelled || error is CancellationError
                    let failedAttempt = attempt
                    let message = error is ReconstructionError
                        ? "La vidéo a changé pendant l’analyse. Relancez l’analyse."
                        : error.localizedDescription
                    await MainActor.run {
                        guard model.acceptsAnalysis(session: session, attempt: failedAttempt) else { return }
                        model.analysisAttemptID = nil
                        model.cachedContext = nil
                        model.analysisOutcome = cancelled ? .cancelled : .failed(message)
                        model.analysisOperation = nil
                        if cancelled {
                            model.progress = AnalysisProgress(stage: .cancelled, fraction: 0, detail: "Analyse annulée")
                        } else {
                            model.errorMessage = message
                        }
                    }
                }
            } onCancel: { preparedRecognition.cancel() }
        }
    }

    private nonisolated static func catalogWarning(_ catalog: ScreenCatalog) -> String? {
        if catalog.recognitionFailures > 0 {
            return "Analyse incomplète pour \(catalog.recognitionFailures) capture(s). Toutes les captures sont conservées."
        }
        if catalog.errorDescription != nil {
            return catalog.visionNames > 0
                ? "Organisation partielle : \(catalog.visionNames) capture(s) nommée(s). Toutes les captures restent disponibles."
                : "L’organisation des captures n’a pas pu être terminée. Toutes les captures restent disponibles."
        }
        return nil
    }

    private func acceptsRefinement(session: UUID, request: UUID, ids: [UUID]) -> Bool {
        sessionID == session && refinementOperation?.id == request && screenshots.map(\.id) == ids
    }

    func refineScreens() {
        guard !isWorking, !screenshots.isEmpty, refinementDetail == nil else { return }
        let files = screenshots.map(\.fileURL)
        cancelRefinement()
        let ids = screenshots.map(\.id)
        let session = sessionID
        let operation = RefinementOperation()
        refinementOperation = operation
        refinementOutcome = nil
        let request = operation.id
        let beforeOrganization = beforeOrganization
        let context = cachedContext
        let analyzer = screenCatalogAnalyzer
        let cache = recentAnalysisCache
        let refinement = refineCatalog
        refinementOperation?.task = Task { [weak self] in
            do {
                try await beforeOrganization()
                let catalog: ScreenCatalog
                if let refinement {
                    catalog = try await refinement(files)
                } else {
                    catalog = try await analyzer.analyze(fileURLs: files) { fraction, _ in
                        await MainActor.run {
                            guard let self, self.acceptsRefinement(session: session, request: request, ids: ids) else { return }
                            self.refinementOperation?.detail = "Affinage des captures… \(fraction.formatted(.percent.precision(.fractionLength(0))))"
                        }
                    }
                }
                try Task.checkCancellation()
                if let context, try await cache.matches(context.source) == false {
                    throw ReconstructionError.sourceChanged
                }
                try Task.checkCancellation()
                guard let self, self.acceptsRefinement(session: session, request: request, ids: ids) else { return }
                let namedFiles = try ScreenshotExporter.prepareNamedFiles(files: files, screenNames: catalog.classifications.map(\.name))
                self.applyRefinement(classifications: catalog.classifications, files: namedFiles, expectedIDs: ids)
                if catalog.recognitionFailures > 0 {
                    self.notice = "Affinage incomplet pour \(catalog.recognitionFailures) capture(s). Toutes les captures restent disponibles."
                } else if catalog.errorDescription != nil {
                    self.notice = "L’affinage des captures n’a pas pu être terminé. Les résultats locaux restent disponibles."
                }
                if catalog.recognitionFailures == 0, catalog.errorDescription == nil, let context,
                   let snapshot = CachedAnalysis(result: context.result, catalog: catalog) {
                    try await cache.store(snapshot, for: context.source)
                }
                guard self.acceptsRefinement(session: session, request: request, ids: ids) else { return }
                self.refinementOutcome = .completed
                self.refinementOperation = nil
            } catch {
                guard let self, self.acceptsRefinement(session: session, request: request, ids: ids) else { return }
                if !(error is CancellationError) && !Task.isCancelled {
                    self.notice = "Affinage interrompu : \(error.localizedDescription). Les résultats locaux restent disponibles."
                }
                self.refinementOutcome = error is CancellationError || Task.isCancelled ? .cancelled : .failed(error.localizedDescription)
                self.refinementOperation = nil
            }
        }
    }

    func cancelRefinement() {
        refinementOperation?.task?.cancel()
    }

    func applyRefinement(classifications: [ScreenClassification], files: [URL], expectedIDs: [UUID]) {
        guard screenshots.map(\.id) == expectedIDs, classifications.count == screenshots.count,
              files.count == screenshots.count else { return }
        screenClassifications = Dictionary(uniqueKeysWithValues: zip(expectedIDs, classifications))
        screenshots = zip(screenshots, files).map { CapturedScreenshot(state: $0.0.state, fileURL: $0.1) }
        setUniqueScreens(showsUniqueScreens)
    }

    func selectScreenshot(_ id: UUID, modifiers: NSEvent.ModifierFlags) {
        let visible = visibleScreenshots
        guard visible.contains(where: { $0.id == id }) else { return }
        followsLatest = false
        notice = nil
        if modifiers.contains(.shift),
           let anchor = selectionAnchorID ?? focusedScreenshotID,
           let start = visible.firstIndex(where: { $0.id == anchor }),
           let end = visible.firstIndex(where: { $0.id == id }) {
            let range = (start <= end ? Array(start...end) : Array((end...start).reversed()))
                .map { visible[$0].id }
            if modifiers.contains(.command) {
                setSelection(selectedScreenshotOrder + range.filter { !selectedScreenshotIDs.contains($0) })
            } else {
                setSelection(range)
            }
            if focusedScreenshotID.map({ selectedScreenshotIDs.contains($0) }) != true {
                focusedScreenshotID = range.first
            }
            return
        }

        selectionAnchorID = id
        if modifiers.contains(.command) {
            if selectedScreenshotIDs.contains(id) {
                setSelection(selectedScreenshotOrder.filter { $0 != id })
                if focusedScreenshotID == id {
                    focusedScreenshotID = selectedScreenshotOrder.first ?? id
                }
            } else {
                setSelection(selectedScreenshotOrder + [id])
                if focusedScreenshotID.map({ selectedScreenshotIDs.contains($0) }) != true {
                    focusedScreenshotID = id
                }
            }
        } else {
            setSelection([id], resetFan: true)
            focusedScreenshotID = id
        }
    }

    func selectTimelineScreenGroup(_ screenID: Int?) {
        guard !isAnalyzing, groupsTimelineByScreen,
              let group = timelineScreenGroups.first(where: { $0.id == screenID }),
              let first = group.screenshots.first else { return }
        setSelection(group.screenshots.map(\.id), resetFan: true)
        focusedScreenshotID = first.id
        selectionAnchorID = first.id
        focusNavigationID = first.id
        followsLatest = false
        notice = nil
    }

    public func selectAll() {
        let visible = visibleScreenshots
        guard !visible.isEmpty else { return }
        followsLatest = false
        notice = nil
        setSelection(selectedScreenshotOrder + visible.map(\.id).filter { !selectedScreenshotIDs.contains($0) })
        if focusedScreenshotID == nil { focusedScreenshotID = selectedScreenshotOrder.first }
        selectionAnchorID = focusedScreenshotID
    }

    func moveFocus(by offset: Int) {
        let visible = visibleScreenshots
        guard !visible.isEmpty, offset != 0 else { return }
        let candidates = selectedScreenshotIDs.count > 1
            ? visible.filter { selectedScreenshotIDs.contains($0.id) }
            : visible
        guard !candidates.isEmpty else { return }
        let currentIndex = candidates.firstIndex { $0.id == focusedScreenshotID } ?? 0
        let nextIndex = min(candidates.count - 1, max(0, currentIndex + offset))
        let next = candidates[nextIndex]
        focusedScreenshotID = next.id
        focusNavigationID = next.id
        selectionAnchorID = next.id
        if selectedScreenshotIDs.count <= 1 {
            setSelection([next.id], resetFan: true)
        }
        followsLatest = false
        notice = nil
    }

    func dragURLs(startingAt id: UUID) -> [URL] {
        if selectedScreenshotIDs.contains(id) {
            return selectedScreenshots.map(\.fileURL)
        }
        return screenshots.first { $0.id == id }.map { [$0.fileURL] } ?? []
    }

    private func setSelection(_ ids: [UUID], resetFan: Bool = false) {
        if resetFan || ids.isEmpty { fanSlots = [:] }
        var nextFanSlot = (fanSlots.values.max() ?? -1) + 1
        for id in ids where fanSlots[id] == nil {
            fanSlots[id] = nextFanSlot
            nextFanSlot += 1
        }
        selectedScreenshotOrder = ids.sorted { fanSlot(for: $0) < fanSlot(for: $1) }
        selectedScreenshotIDs = Set(ids)
    }

    public func copySelection() {
        let files = selectedScreenshots.map(\.fileURL)
        guard !files.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if pasteboard.writeObjects(files.map { $0 as NSURL }) {
            notice = "\(files.count) capture\(files.count == 1 ? "" : "s") copiée\(files.count == 1 ? "" : "s")."
        } else {
            errorMessage = "Impossible de copier les captures sélectionnées."
        }
    }

    func makeSelectionExportPlan() -> ScreenshotExportPlan {
        if groupsTimelineByScreen {
            let groups = timelineScreenGroups.compactMap { group -> ScreenshotExportPlan.ScreenGroup? in
                let files = group.screenshots.filter { selectedScreenshotIDs.contains($0.id) }.map(\.fileURL)
                return files.isEmpty ? nil : .init(screenName: group.name, sourceURLs: files)
            }
            if preferences.screenExportLayout == .folders { return .screenFolders(groups) }
            return .singleFolder(groups.flatMap { group in
                group.sourceURLs.map { .init(sourceURL: $0, screenName: group.screenName) }
            })
        }
        return .singleFolder(visibleScreenshots.filter { selectedScreenshotIDs.contains($0.id) }.map {
            .init(sourceURL: $0.fileURL, screenName: screenClassifications[$0.id]?.name ?? "À identifier")
        })
    }

    public func saveSelection() {
        guard canSaveSelection else { return }
        let plan = makeSelectionExportPlan()
        guard plan.fileCount > 0 else { return }
        let operation = SaveOperation(plan: plan)
        saveOperation = operation
        saveOutcome = nil
        let token = operation.id
        let folderURL: URL?
        if let chooseSaveFolder { folderURL = chooseSaveFolder(plan) }
        else { folderURL = presentSavePanel(plan: plan) }
        guard saveOperation?.id == token else { return }
        guard let folderURL else {
            saveOutcome = .cancelled
            saveOperation = nil
            return
        }
        let model = self
        let copy = copyFiles
        notice = nil
        errorMessage = nil
        saveOperation?.task = Task.detached(priority: .userInitiated) {
            do {
                let copied = try await copy(operation.plan, folderURL) { fraction, detail in
                    Task { @MainActor in
                        guard model.saveOperation?.id == token else { return }
                        model.saveOperation?.progress = AnalysisProgress(stage: .exporting, fraction: fraction, detail: detail)
                    }
                }
                try Task.checkCancellation()
                await MainActor.run {
                    guard model.saveOperation?.id == token else { return }
                    model.saveOutcome = .completed
                    model.saveOperation = nil
                    model.exportedFolderURL = folderURL
                    model.notice = "\(copied.count) capture\(copied.count == 1 ? "" : "s") enregistrée\(copied.count == 1 ? "" : "s")."
                }
            } catch is CancellationError {
                await MainActor.run {
                    guard model.saveOperation?.id == token else { return }
                    model.saveOutcome = .cancelled
                    model.saveOperation = nil
                    model.notice = "Enregistrement annulé"
                }
            } catch {
                let message = error.localizedDescription
                await MainActor.run {
                    guard model.saveOperation?.id == token else { return }
                    model.saveOutcome = .failed(message)
                    model.saveOperation = nil
                    model.errorMessage = message
                }
            }
        }
    }

    private func presentSavePanel(plan: ScreenshotExportPlan) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Enregistrer ici"
        let layout: String
        switch plan {
        case .singleFolder: layout = "dans un seul dossier, numérotés dans l’ordre de la timeline"
        case .screenFolders: layout = "dans un dossier par écran, numérotés dans l’ordre de la timeline"
        }
        panel.message = "Choisissez un dossier pour \(plan.fileCount) PNG en pleine résolution, \(layout)."
        return panel.runModal() == .OK ? panel.url : nil
    }

    func cancel() { analysisOperation?.task?.cancel() }
    func cancelSave() { saveOperation?.task?.cancel() }

    func cleanUpSession() {
        sessionID = UUID()
        analysisAttemptID = nil
        cachedContext = nil
        analysisOperation?.task?.cancel()
        saveOperation?.task?.cancel()
        cancelRefinement()
        if let stagingFolderURL { try? FileManager.default.removeItem(at: stagingFolderURL) }
        stagingFolderURL = nil
    }

    func showExportedFolder() {
        guard let exportedFolderURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([exportedFolderURL])
    }
}
