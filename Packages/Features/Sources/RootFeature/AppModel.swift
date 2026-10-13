import AppKit
import ImageIO
import Observation
import StillsetCore
import UniformTypeIdentifiers

struct CapturedScreenshot: Identifiable, Sendable {
    let state: UIState
    let fileURL: URL
    let cachedAspectRatio: CGFloat?

    init(state: UIState, fileURL: URL) {
        self.state = state
        self.fileURL = fileURL
        guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber, height.doubleValue > 0 else {
            cachedAspectRatio = nil
            return
        }
        cachedAspectRatio = CGFloat(width.doubleValue / height.doubleValue)
    }

    init(replacingURL url: URL, of capture: CapturedScreenshot) {
        state = capture.state
        fileURL = url
        cachedAspectRatio = capture.cachedAspectRatio
    }

    var id: UUID { state.id }
}

struct TimelineScreenGroup: Identifiable {
    let id: Int?
    let name: String
    let screenshots: [CapturedScreenshot]
}

@MainActor
@Observable
public final class AppModel: Identifiable {
    public let id = UUID()
    private(set) var importOrdinal = 0

    func assignImportOrdinal(_ ordinal: Int) {
        precondition(importOrdinal == 0)
        importOrdinal = ordinal
    }
    private(set) var importState: VideoImportState = .review { didSet { structuralChanged() } }
    var retrySourceID: UUID?
    var attempt = 1 { didSet { structuralChanged() } }
    var displayName: String {
        let name = videoURL?.lastPathComponent ?? "Stillset"
        return attempt == 1 ? name : String(localized: "\(name) · attempt \(attempt)", bundle: .module)
    }

    var videoURL: URL? { didSet { structuralChanged() } }
    var screenshots: [CapturedScreenshot] = [] { didSet { structuralChanged() } }
    private var screenCatalogAnalyzer = ScreenCatalogAnalyzer()
    var screenClassifications: [UUID: ScreenClassification] = [:] { didSet { structuralChanged() } }
    private(set) var showsUniqueScreens = true
    private(set) var groupsTimelineByScreen = false
    private(set) var selectedScreenshotIDs: Set<UUID> = []
    private(set) var selectedScreenshotOrder: [UUID] = []
    var focusedScreenshotID: UUID?
    var focusNavigationID: UUID?
    var analysisPreviewFrames: [Frame] = []
    var detectedScreens: [UIState] = [] { didSet { structuralChanged() } }
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
        var progress = AnalysisProgress(stage: .decoding, fraction: 0, detail: String(localized: "Reading video", bundle: .module))
    }

    private struct SaveOperation {
        let id = UUID()
        let plan: ScreenshotExportPlan
        var task: Task<Void, Never>?
        var progress = AnalysisProgress(stage: .exporting, fraction: 0, detail: String(localized: "Saving PNGs", bundle: .module))
    }

    private struct RefinementOperation {
        let id = UUID()
        var task: Task<Void, Never>?
        var detail = String(localized: "Refining screenshots…", bundle: .module)
    }

    private var analysisOperation: AnalysisOperation?
    private var saveOperation: SaveOperation?
    private var refinementOperation: RefinementOperation?
    private var lastAnalysisProgress = AnalysisProgress(stage: .decoding, fraction: 0, detail: String(localized: "Drop a recording", bundle: .module))
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

    @ObservationIgnored var onPublication: (@MainActor () -> Void)?
    @ObservationIgnored private var structuralDepth = 0
    @ObservationIgnored private var structuralDirty = false
    nonisolated let previewDemand = PreviewDemand()
    private var deliveryAcknowledged = 0
    private var analysisToken: UUID?
    private var analysisTask: Task<VideoImportState, Never>?

    private(set) var sourceAspectRatio: CGFloat = 9 / 19
    var reuseCachedAnalysis = true
    private var processingLane = ProcessingLane.standalone()
    private var processingCadence = SessionCadence()

    private let diagnostics: DiagnosticJournal?
    private(set) var needsImportDiagnostic = false
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
        try await ScreenshotExporter.copy(plan: $0, to: $1, onProgress: $2)
    }
    private var stagingFolderURL: URL?
    private var selectionAnchorID: UUID?
    private var fanSlots: [UUID: Int] = [:]

    public convenience init(diagnostics: DiagnosticJournal? = nil) { self.init(preferences: AppPreferences(defaults: .standard), diagnostics: diagnostics) }

    public convenience init(preferences: AppPreferences, diagnostics: DiagnosticJournal? = nil) {
        self.init(preferences: preferences, cache: .shared, diagnostics: diagnostics)
    }

    init(preferences: AppPreferences, cache: RecentAnalysisCache, diagnostics: DiagnosticJournal? = nil,
         localCatalog: (@Sendable ([URL]) async throws -> ScreenCatalog)? = nil,
         refineCatalog: (@Sendable ([URL]) async throws -> ScreenCatalog)? = nil) {
        self.diagnostics = diagnostics
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
        importState = running ? .running : .review
        analysisOperation = running ? AnalysisOperation() : nil
        progress = AnalysisProgress(
            stage: running ? .annotating : .complete,
            fraction: running ? 0.62 : 1,
            detail: running ? String(localized: "Organizing screenshots…", bundle: .module) : String(localized: "Screenshots ready", bundle: .module)
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

    func admit(_ url: URL, failure: String? = nil) {
        videoURL = url
        importState = failure.map(VideoImportState.failed) ?? .queued
        errorMessage = failure
        needsImportDiagnostic = failure != nil && diagnostics != nil
    }

    func updateAnalysis(token: UUID, _ update: (AppModel) -> Void) {
        guard analysisToken == token, importState == .running else { return }
        withStructuralPublication { update(self) }
    }

    private func structuralChanged() {
        if structuralDepth > 0 { structuralDirty = true }
        else { onPublication?() }
    }

    private func withStructuralPublication(_ body: () -> Void) {
        structuralDepth += 1
        defer {
            structuralDepth -= 1
            if structuralDepth == 0, structuralDirty {
                structuralDirty = false
                onPublication?()
            }
        }
        body()
    }

    func setAnalysisPreviewFrames(_ frames: [Frame]) {
        let ratio = frames.first(where: { $0.width > 0 && $0.height > 0 })
            .map { CGFloat($0.sourceAspectRatio) } ?? 9 / 19
        analysisPreviewFrames = frames
        if sourceAspectRatio != ratio {
            sourceAspectRatio = ratio
            structuralChanged()
        }
    }

    func startAnalysis(runner: AnalysisRunner? = nil, work: ProcessingLane = .standalone(), cadence: SessionCadence = SessionCadence()) -> Task<Void, Never> {
        if needsImportDiagnostic {
            needsImportDiagnostic = false
            let diagnostics = diagnostics
            return Task {
                let diagnostic = await diagnostics?.begin(.videoImport)
                await diagnostic?.stage(.validating)
                await diagnostic?.finish(.failed(.unsupportedImport))
            }
        }
        precondition(importState == .queued)
        // Without an activity, App Nap throttles the analysis while Stillset is in the background.
        let activity = ProcessInfo.processInfo.beginActivity(options: .userInitiated, reason: "Analyzing a screen recording")
        let token = UUID()
        analysisToken = token
        deliveryAcknowledged = 0
        processingLane = work
        processingCadence = cadence
        importState = .running
        if let runner {
            analysisOperation = AnalysisOperation()
            let worker = Task.detached(priority: .utility) { [self] in
                let diagnostic = await diagnostics?.begin(reuseCachedAnalysis ? .analysis : .reanalysis)
                await diagnostic?.stage(.decoding)
                let outcome = await runner(self, token, videoURL!)
                if Task.isCancelled {
                    await diagnostic?.finish(.cancelled)
                } else {
                    switch outcome {
                    case .completed: await diagnostic?.finish(.success)
                    case .cancelled, .cancelling: await diagnostic?.finish(.cancelled)
                    default: await diagnostic?.finish(.failed(.unknown))
                    }
                }
                return outcome
            }
            analysisTask = worker
            return Task { [self] in
                defer { ProcessInfo.processInfo.endActivity(activity) }
                let outcome = await worker.value
                completeQueuedAnalysis(outcome, token: token)
            }
        }
        beginAnalysis(videoURL!, reuseCache: reuseCachedAnalysis)
        let worker = analysisOperation?.task
        return Task { [self] in
            defer { ProcessInfo.processInfo.endActivity(activity) }
            await worker?.value
            let outcome: VideoImportState
            switch analysisOutcome {
            case .completed: outcome = .completed
            case .failed(let message): outcome = .failed(message)
            default: outcome = .cancelled
            }
            completeQueuedAnalysis(outcome, token: token)
        }
    }

    private func completeQueuedAnalysis(_ outcome: VideoImportState, token: UUID) {
        guard analysisToken == token else { return }
        withStructuralPublication {
            let terminal = importState == .cancelling ? VideoImportState.cancelled : outcome
            analysisToken = nil
            analysisTask = nil
            analysisOperation = nil
            importState = terminal
            switch terminal {
            case .completed: progress = AnalysisProgress(stage: .complete, fraction: 1, detail: String(localized: "\(screenshots.count) screenshots ready", bundle: .module))
            case .cancelled: progress = AnalysisProgress(stage: .cancelled, fraction: 0, detail: String(localized: "Analysis cancelled", bundle: .module))
            case .failed(let message): errorMessage = message
            default: preconditionFailure("Analysis runner must return a terminal state")
            }
        }
    }

    func acceptDelivery(_ batch: DeliveryBatch, token: UUID) -> Bool {
        guard analysisToken == token, importState == .running,
              batch.throughSequence == deliveryAcknowledged + batch.records.count else { return false }
        let interval = processingSignposter.beginInterval("MainPublication")
        defer { processingSignposter.endInterval("MainPublication", interval) }
        withStructuralPublication {
            for record in batch.records {
                switch record {
                case .detection(let state): detectedScreens.append(state)
                case .capture(let capture): screenshots.append(capture)
                }
            }
            if let ratio = batch.sourceAspectRatio, sourceAspectRatio != CGFloat(ratio) {
                sourceAspectRatio = CGFloat(ratio)
                structuralChanged()
            }
            if !batch.previews.isEmpty {
                analysisPreviewFrames = Array((analysisPreviewFrames + batch.previews).suffix(2))
            }
            if let update = batch.progress, update.stage == progress.stage { progress = update }
            if let barrier = batch.barrier {
                switch barrier {
                case .stage(let update, let folder):
                    if let folder { stagingFolderURL = folder }
                    progress = update
                case .finished(let values):
                    screenClassifications = values.classifications
                    screenshots = values.captures
                    notice = values.notice
                }
            }
            deliveryAcknowledged = batch.throughSequence
        }
        return true
    }

    nonisolated static func recoverWrittenCaptures(
        states: [UIState], folder: URL?, work: ProcessingLane = .standalone()
    ) async throws -> [CapturedScreenshot] {
        guard let folder else { return [] }
        let byNumber = try await work.perform {
            let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            return Dictionary(grouping: files.filter { $0.pathExtension == "png" }) {
                $0.lastPathComponent.split(separator: "_").first.map(String.init) ?? ""
            }
        }
        var captures: [CapturedScreenshot] = []
        for (index, state) in states.enumerated() {
            let candidates = byNumber[String(format: "%03d", index + 1), default: []].sorted { $0.lastPathComponent < $1.lastPathComponent }
            let capture = try await work.perform {
                guard let file = candidates.first(where: {
                    guard let source = CGImageSourceCreateWithURL($0 as CFURL, nil) else { return false }
                    return CGImageSourceGetStatus(source) == .statusComplete
                }) else { return Optional<CapturedScreenshot>.none }
                return CapturedScreenshot(state: state, fileURL: file)
            }
            if let capture { captures.append(capture) }
        }
        return captures
    }

    func retainPartialCaptures(_ captures: [CapturedScreenshot], folder: URL?, token: UUID) {
        guard analysisToken == token else { return }
        withStructuralPublication {
            stagingFolderURL = folder
            let existing = Set(screenshots.map(\.id))
            screenshots.append(contentsOf: captures.filter { !existing.contains($0.id) })
            screenshots.sort { $0.state.representativeTimestamp < $1.state.representativeTimestamp }
        }
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
            return TimelineScreenGroup(id: screen?.screenID, name: screen?.name ?? String(localized: "Unidentified", bundle: .module),
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
        panel.prompt = String(localized: "Open", bundle: .module)
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
        guard url.isFileURL, ["mov", "mp4"].contains(url.pathExtension.lowercased()) else {
            errorMessage = String(localized: "Choose a MOV or MP4 recording.", bundle: .module)
            if let diagnostics {
                let operation = AnalysisOperation()
                analysisOperation = operation
                analysisOperation?.task = Task { [weak self] in
                    let diagnostic = await diagnostics.begin(.videoImport)
                    await diagnostic.stage(.validating)
                    await diagnostic.finish(.failed(.unsupportedImport))
                    guard let self, self.analysisOperation?.id == operation.id else { return }
                    self.analysisOperation = nil
                }
            }
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
        let work = processingLane
        let demand = previewDemand
        let cadence = processingCadence
        let session = sessionID
        let firstAttempt = UUID()
        analysisAttemptID = firstAttempt
        analysisOperation = AnalysisOperation()
        analysisOutcome = nil
        let beforeOrganization = beforeOrganization
        progress = AnalysisProgress(stage: .decoding, fraction: 0, detail: String(localized: "Reading video", bundle: .module))
        let model = self
        let diagnostics = diagnostics
        analysisOperation?.task = Task.detached(priority: .userInitiated) {
            let diagnostic = await diagnostics?.begin(reuseCache ? .analysis : .reanalysis)
            await diagnostic?.stage(.validating)
            await oldRefinement?.value
            if let oldStaging { try? FileManager.default.removeItem(at: oldStaging) }
            await MainActor.run { model.refinementOperation = nil }
            let preparedRecognition = ScreenCatalogAnalyzer.PreparedRecognition()
            await withTaskCancellationHandler {
                var collector: IncrementalCaptures?
                var attempt = firstAttempt
                do {
                    await diagnostic?.stage(.decoding)
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
                            await diagnostic?.finish(.cancelled)
                            return
                        }
                        let delivery = RunDelivery(cadence: cadence) { batch in
                            guard model.acceptsAnalysis(session: session, attempt: currentAttempt) else { return false }
                            model.withStructuralPublication {
                                for record in batch.records {
                                    switch record {
                                    case .detection(let state): model.detectedScreens.append(state)
                                    case .capture(let capture):
                                        model.screenshots.append(capture)
                                        if model.followsLatest {
                                            model.focusedScreenshotID = capture.id
                                            model.setSelection([capture.id], resetFan: true)
                                        }
                                    }
                                }
                                if let ratio = batch.sourceAspectRatio, model.sourceAspectRatio != CGFloat(ratio) {
                                    model.sourceAspectRatio = CGFloat(ratio)
                                    model.structuralChanged()
                                }
                                if !batch.previews.isEmpty { model.analysisPreviewFrames = batch.previews }
                                if let update = batch.progress { model.progress = update }
                                if case .stage(let update, _) = batch.barrier { model.progress = update }
                            }
                            return true
                        }
                        let captures = IncrementalCaptures(videoURL: videoURL, folderURL: folder,
                            preparedRecognition: cached == nil ? preparedRecognition : nil, work: work) { capture in
                            try? await delivery.capture(capture)
                        }
                        collector = captures
                        do {
                            let result: AnalysisResult
                            if let cached {
                                result = cached.result(for: videoURL)
                                try await delivery.detections(result.states)
                                try await captures.append(result.states)
                            } else {
                                result = try await AnalysisPipeline.run(
                                    url: videoURL, work: work, previewRequest: { demand.read() },
                                    onProgress: { try await delivery.progress($0) },
                                    onAnalyzedFrames: { try await delivery.previews($0) },
                                    onDetectedScreens: { screens in
                                        await diagnostic?.stage(.detecting)
                                        await diagnostic?.stage(.capturing)
                                        try await delivery.detections(screens)
                                        try await captures.append(screens)
                                    }
                                )
                            }
                            try Task.checkCancellation()
                            await diagnostic?.stage(.capturing)
                            let completed = try await captures.finish()
                            guard completed.map(\.id) == result.states.map(\.id) else {
                                throw ScreenshotExportError.invalidImageSequence
                            }
                            let files = completed.map(\.fileURL)
                            try await delivery.flush(.stage(AnalysisProgress(stage: .annotating, fraction: 0, detail: String(localized: "Organizing screenshots…", bundle: .module))))
                            try Task.checkCancellation()
                            await diagnostic?.stage(.cataloging)
                            let catalog: ScreenCatalog
                            if let cached {
                                catalog = cached.catalog
                            } else {
                                await MainActor.run {
                                    guard model.acceptsAnalysis(session: session, attempt: currentAttempt) else { return }
                                    model.progress = AnalysisProgress(stage: .annotating, fraction: 0, detail: String(localized: "Organizing screenshots…", bundle: .module))
                                }
                                try await beforeOrganization()
                                if let localCatalog {
                                    catalog = try await localCatalog(files)
                                } else {
                                    catalog = try await catalogAnalyzer.analyze(fileURLs: files, work: work, useFoundationModels: false, preparedRecognition: preparedRecognition, diagnostics: diagnostic) { fraction, _ in
                                        try await delivery.progress(AnalysisProgress(stage: .annotating, fraction: fraction, detail: String(localized: "Organizing screenshots…", bundle: .module)))
                                    }
                                }
                            }
                            if catalog.recognitionFailures > 0 || catalog.errorDescription != nil {
                                await diagnostic?.issue(.unknown, at: .cataloging)
                            }
                            if cached == nil { await preparedRecognition.cancelAndDrain() }
                            let namedFiles = try await ScreenshotExporter.prepareNamedFiles(files: files, screenNames: catalog.classifications.map(\.name), work: work)
                            if let originalSource = source {
                                let matches = try await cache.matches(originalSource)
                                if matches == false { throw ReconstructionError.sourceChanged }
                                if matches == nil { source = nil }
                            }
                            try Task.checkCancellation()
                            try await delivery.flush(.stage(AnalysisProgress(stage: .complete, fraction: 1, detail: String(localized: "\(files.count) screenshots ready", bundle: .module))))
                            let completedSource = source
                            let wasCached = cached != nil
                            let accepted = await MainActor.run {
                                guard model.acceptsAnalysis(session: session, attempt: currentAttempt), !Task.isCancelled else { return false }
                                model.screenClassifications = Dictionary(uniqueKeysWithValues: zip(result.states, catalog.classifications).map { ($0.0.id, $0.1) })
                                model.screenshots = zip(completed, namedFiles).map { CapturedScreenshot(replacingURL: $0.1, of: $0.0) }
                                model.setUniqueScreens(model.showsUniqueScreens)
                                model.cachedContext = completedSource.map { (result, $0) }
                                let warning = Self.catalogWarning(catalog)
                                model.notice = wasCached
                                    ? ([String(localized: "Recent analysis restored", bundle: .module), warning].compactMap { $0 }.joined(separator: ". "))
                                    : warning
                                model.progress = AnalysisProgress(stage: .complete, fraction: 1, detail: String(localized: "\(files.count) screenshots ready", bundle: .module))
                                return true
                            }
                            guard accepted else {
                                await diagnostic?.finish(Task.isCancelled ? .cancelled : .success)
                                return
                            }
                            if let completedSource {
                                if wasCached {
                                    try await cache.markUsed(completedSource)
                                } else if let snapshot = CachedAnalysis(result: result, catalog: catalog) {
                                    try await cache.store(snapshot, for: completedSource)
                                }
                            }
                            try Task.checkCancellation()
                            await diagnostic?.finish(.success)
                            await MainActor.run {
                                guard model.acceptsAnalysis(session: session, attempt: currentAttempt) else { return }
                                model.analysisAttemptID = nil
                                model.analysisOutcome = .completed
                                model.analysisOperation = nil
                            }
                            return
                        } catch {
                            await delivery.closeForRecovery()
                            await captures.cancelAndDrain()
                            let written = await captures.completed
                            await MainActor.run {
                                guard model.acceptsAnalysis(session: session, attempt: currentAttempt) else { return }
                                let existing = Set(model.screenshots.map(\.id))
                                model.screenshots.append(contentsOf: written.filter { !existing.contains($0.id) })
                            }
                            if Task.isCancelled || error is CancellationError { throw CancellationError() }
                            guard cached != nil else { throw error }
                            let nextAttempt = UUID()
                            let retry = await MainActor.run {
                                guard model.acceptsAnalysis(session: session, attempt: currentAttempt) else { return false }
                                model.analysisAttemptID = nextAttempt
                                model.clearAnalysisCaptures()
                                model.progress = AnalysisProgress(stage: .decoding, fraction: 0, detail: String(localized: "Reading video", bundle: .module))
                                return true
                            }
                            guard retry else {
                                await diagnostic?.finish(.cancelled)
                                return
                            }
                            await diagnostic?.issue(error is ReconstructionError ? .sourceChanged : .classify(error), at: .validating)
                            attempt = nextAttempt
                            cached = nil
                            source = try await cache.fingerprint(for: videoURL)
                        }
                    }
                } catch {
                    await collector?.cancelAndDrain()
                    await preparedRecognition.cancelAndDrain()
                    let cancelled = Task.isCancelled || error is CancellationError
                    await diagnostic?.finish(cancelled ? .cancelled : .failed(error is ReconstructionError ? .sourceChanged : .classify(error)))
                    let failedAttempt = attempt
                    let message = error is ReconstructionError
                        ? String(localized: "The video changed during analysis. Run the analysis again.", bundle: .module)
                        : error.localizedDescription
                    await MainActor.run {
                        guard model.acceptsAnalysis(session: session, attempt: failedAttempt) else { return }
                        model.analysisAttemptID = nil
                        model.cachedContext = nil
                        model.analysisOutcome = cancelled ? .cancelled : .failed(message)
                        model.analysisOperation = nil
                        if cancelled {
                            model.progress = AnalysisProgress(stage: .cancelled, fraction: 0, detail: String(localized: "Analysis cancelled", bundle: .module))
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
            return String(localized: "Analysis incomplete for \(catalog.recognitionFailures) screenshots. All screenshots are retained.", bundle: .module)
        }
        if catalog.errorDescription != nil {
            return catalog.visionNames > 0
                ? String(localized: "Partial organization: \(catalog.visionNames) screenshots named. All screenshots remain available.", bundle: .module)
                : String(localized: "Screenshot organization could not be completed. All screenshots remain available.", bundle: .module)
        }
        return nil
    }

    func cachedSourceIsCurrent() async throws -> Bool {
        guard let cachedContext else { return true }
        return try await recentAnalysisCache.matches(cachedContext.source) != false
    }

    func persistSessionRefinement(_ classifications: [ScreenClassification], expectedIDs: [UUID]) async throws {
        guard let context = cachedContext, screenshots.map(\.id) == expectedIDs,
              classifications.count == expectedIDs.count, try await cachedSourceIsCurrent() else { return }
        var representatives: [Int: Int] = [:]
        var screens: [Int: Int] = [:]
        let local = classifications.enumerated().map { index, value in
            let representative = representatives[value.stateID] ?? index + 1
            representatives[value.stateID] = representative
            let screen = screens[value.screenID] ?? screens.count + 1
            screens[value.screenID] = screen
            return ScreenClassification(screenID: screen, name: value.name, stateID: representative)
        }
        let catalog = ScreenCatalog(classifications: local, usedContextualNaming: true,
            visionNames: 0, recognitionFailures: 0, errorDescription: nil)
        if let snapshot = CachedAnalysis(result: context.result, catalog: catalog) {
            try await recentAnalysisCache.store(snapshot, for: context.source)
        }
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
        let diagnostics = diagnostics
        refinementOperation?.task = Task { [weak self] in
            let diagnostic = await diagnostics?.begin(.refinement)
            await diagnostic?.stage(.cataloging)
            do {
                try await beforeOrganization()
                let catalog: ScreenCatalog
                if let refinement {
                    catalog = try await refinement(files)
                } else {
                    catalog = try await analyzer.analyze(fileURLs: files, diagnostics: diagnostic) { fraction, _ in
                        await MainActor.run {
                            guard let self, self.acceptsRefinement(session: session, request: request, ids: ids) else { return }
                            self.refinementOperation?.detail = String(localized: "Refining screenshots… \(fraction.formatted(.percent.precision(.fractionLength(0))))", bundle: .module)
                        }
                    }
                }
                if catalog.recognitionFailures > 0 || catalog.errorDescription != nil {
                    await diagnostic?.issue(.unknown, at: .cataloging)
                }
                try Task.checkCancellation()
                if let context, try await cache.matches(context.source) == false {
                    throw ReconstructionError.sourceChanged
                }
                try Task.checkCancellation()
                guard let self, self.acceptsRefinement(session: session, request: request, ids: ids) else {
                    await diagnostic?.finish(Task.isCancelled ? .cancelled : .success)
                    return
                }
                let namedFiles = try await ScreenshotExporter.prepareNamedFiles(files: files, screenNames: catalog.classifications.map(\.name))
                self.applyRefinement(classifications: catalog.classifications, files: namedFiles, expectedIDs: ids)
                if catalog.recognitionFailures > 0 {
                    self.notice = String(localized: "Refinement incomplete for \(catalog.recognitionFailures) screenshots. All screenshots remain available.", bundle: .module)
                } else if catalog.errorDescription != nil {
                    self.notice = String(localized: "Screenshot refinement could not be completed. Local results remain available.", bundle: .module)
                }
                if catalog.recognitionFailures == 0, catalog.errorDescription == nil, let context,
                   let snapshot = CachedAnalysis(result: context.result, catalog: catalog) {
                    try await cache.store(snapshot, for: context.source)
                }
                await diagnostic?.finish(Task.isCancelled ? .cancelled : .success)
                guard self.acceptsRefinement(session: session, request: request, ids: ids) else { return }
                self.refinementOutcome = .completed
                self.refinementOperation = nil
            } catch {
                await diagnostic?.finish(Task.isCancelled || error is CancellationError ? .cancelled : .failed(error is ReconstructionError ? .sourceChanged : .classify(error)))
                guard let self, self.acceptsRefinement(session: session, request: request, ids: ids) else { return }
                if !(error is CancellationError) && !Task.isCancelled {
                    self.notice = String(localized: "Refinement interrupted: \(error.localizedDescription). Local results remain available.", bundle: .module)
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
        screenshots = zip(screenshots, files).map { CapturedScreenshot(replacingURL: $0.1, of: $0.0) }
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
            notice = String(localized: "\(files.count) screenshots copied.", bundle: .module)
        } else {
            errorMessage = String(localized: "Could not copy the selected screenshots.", bundle: .module)
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
            .init(sourceURL: $0.fileURL, screenName: screenClassifications[$0.id]?.name ?? String(localized: "Unidentified", bundle: .module))
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
        let diagnostics = diagnostics
        saveOperation?.task = Task.detached(priority: .userInitiated) {
            let diagnostic = await diagnostics?.begin(.screenshotExport)
            await diagnostic?.stage(.saving)
            do {
                let copied = try await copy(operation.plan, folderURL) { fraction, detail in
                    Task { @MainActor in
                        guard model.saveOperation?.id == token else { return }
                        model.saveOperation?.progress = AnalysisProgress(stage: .exporting, fraction: fraction, detail: detail)
                    }
                }
                try Task.checkCancellation()
                await diagnostic?.finish(.success)
                await MainActor.run {
                    guard model.saveOperation?.id == token else { return }
                    model.saveOutcome = .completed
                    model.saveOperation = nil
                    model.exportedFolderURL = folderURL
                    model.notice = String(localized: "\(copied.count) screenshots saved.", bundle: .module)
                }
            } catch is CancellationError {
                await diagnostic?.finish(.cancelled)
                await MainActor.run {
                    guard model.saveOperation?.id == token else { return }
                    model.saveOutcome = .cancelled
                    model.saveOperation = nil
                    model.notice = String(localized: "Save cancelled", bundle: .module)
                }
            } catch {
                await diagnostic?.finish(.failure(error, cancelled: Task.isCancelled))
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
        panel.prompt = String(localized: "Save Here", bundle: .module)
        let layout: String
        switch plan {
        case .singleFolder: layout = String(localized: "Choose a folder for \(plan.fileCount) full-resolution PNGs, numbered in timeline order.", bundle: .module)
        case .screenFolders: layout = String(localized: "Choose a folder for \(plan.fileCount) full-resolution PNGs, organized by screen and numbered in timeline order.", bundle: .module)
        }
        panel.message = layout
        return panel.runModal() == .OK ? panel.url : nil
    }

    func cancel() {
        if importState == .queued { importState = .cancelled }
        if importState == .running { importState = .cancelling }
        analysisTask?.cancel()
        analysisOperation?.task?.cancel()
    }
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
