import AppKit
import Observation
import UniformTypeIdentifiers

enum VideoImportState: Equatable, Sendable {
    case review
    case queued
    case running
    case cancelling
    case completed
    case failed(String)
    case cancelled

    var isPending: Bool { self == .queued || self == .running || self == .cancelling }
    var canRetry: Bool {
        switch self {
        case .failed, .cancelled: true
        default: false
        }
    }
    var label: String {
        switch self {
        case .review, .completed: "Terminée"
        case .queued: "En attente"
        case .running: "Analyse en cours"
        case .cancelling: "Annulation en cours…"
        case .failed: "Échec de l’analyse"
        case .cancelled: "Analyse annulée"
        }
    }
    var failure: String? {
        if case .failed(let message) = self { return message }
        return nil
    }
}

typealias AnalysisRunner = @Sendable (AppModel, UUID, URL) async -> VideoImportState

@MainActor
@Observable
public final class VideoImportQueue {
    nonisolated let processing = SessionProcessing()
    private(set) var models: [AppModel] = []
    var activeModelIDs: Set<UUID> { Set(activeTasks.keys) }
    @ObservationIgnored var onPublication: (@MainActor () -> Void)?
    @ObservationIgnored var onDrain: (@MainActor () -> Void)?
    var isBusy: Bool { !activeTasks.isEmpty || models.contains { $0.importState.isPending } }
    private var isClosed = false
    private var isPaused = false
    private var laneSlots: [UUID: Int] = [:]
    private var nextImportOrdinal = 1
    private let runner: AnalysisRunner?
    private var activeTasks: [UUID: Task<Void, Never>] = [:]

    public init() { runner = nil }

    init(paused: Bool) {
        runner = nil
        isPaused = paused
    }

    init(runner: @escaping AnalysisRunner) { self.runner = runner }

    init(models: [AppModel]) {
        runner = nil
        for model in models { append(model) }
    }

    private func append(_ model: AppModel) {
        model.assignImportOrdinal(nextImportOrdinal)
        nextImportOrdinal += 1
        model.onPublication = { [weak self] in self?.onPublication?() }
        models.append(model)
    }

    public func chooseVideos() {
        guard !isClosed, let urls = Self.chooseVideoURLs() else { return }
        enqueue(urls)
    }

    public static func chooseVideoURLs() -> [URL]? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .mpeg4Movie]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.prompt = "Ouvrir"
        guard panel.runModal() == .OK else { return nil }
        return panel.urls
    }

    @discardableResult
    func enqueueDroppedVideos(_ urls: [URL]) -> Bool {
        enqueue(urls.filter(Self.supportsVideo))
    }

    private static func supportsVideo(_ url: URL) -> Bool {
        url.isFileURL && ["mov", "mp4"].contains(url.pathExtension.lowercased())
    }

    @discardableResult
    func enqueue(_ urls: [URL]) -> Bool {
        guard !isClosed else { return false }
        for url in urls {
            let model = AppModel()
            let supported = Self.supportsVideo(url)
            model.admit(url, failure: supported ? nil : "Choisissez un enregistrement MOV ou MP4 local.")
            append(model)
        }
        if !urls.isEmpty { onPublication?() }
        fillAvailableSlots()
        return !urls.isEmpty
    }

    func remove(_ model: AppModel) {
        guard model.importState == .queued else { return }
        models.removeAll { $0.id == model.id }
        model.onPublication = nil
        onPublication?()
    }

    func canRetry(_ model: AppModel) -> Bool {
        let sourceID = model.retrySourceID ?? model.id
        return !isClosed && models.contains(where: { $0.id == model.id }) && model.importState.canRetry && !models.contains {
            ($0.retrySourceID ?? $0.id) == sourceID && $0.importState.isPending
        }
    }

    func retry(_ model: AppModel) { appendAttempt(model, reuseCache: true) }

    func canReanalyze(_ model: AppModel) -> Bool {
        let sourceID = model.retrySourceID ?? model.id
        return !isClosed && models.contains(where: { $0.id == model.id }) && !model.importState.isPending
            && !models.contains { ($0.retrySourceID ?? $0.id) == sourceID && $0.importState.isPending }
    }

    func reanalyze(_ model: AppModel) {
        guard canReanalyze(model) else { return }
        appendAttempt(model, reuseCache: false)
    }

    private func appendAttempt(_ model: AppModel, reuseCache: Bool) {
        guard !isClosed, models.contains(where: { $0.id == model.id }), !model.importState.isPending,
              let url = model.videoURL else { return }
        if reuseCache, !canRetry(model) { return }
        let sourceID = model.retrySourceID ?? model.id
        let retry = AppModel()
        retry.reuseCachedAnalysis = reuseCache
        retry.retrySourceID = sourceID
        retry.attempt = models.filter { ($0.retrySourceID ?? $0.id) == sourceID }.map(\.attempt).max().map { $0 + 1 } ?? 2
        let supported = url.isFileURL && ["mov", "mp4"].contains(url.pathExtension.lowercased())
        retry.admit(url, failure: supported ? nil : "Choisissez un enregistrement MOV ou MP4 local.")
        append(retry)
        onPublication?()
        fillAvailableSlots()
    }

    private func fillAvailableSlots() {
        guard !isClosed, !isPaused else { return }
        while activeTasks.count < 2, let model = models.first(where: { $0.importState == .queued }) {
            let slot = (0..<2).first { !laneSlots.values.contains($0) }!
            laneSlots[model.id] = slot
            let completion = model.startAnalysis(runner: runner, work: processing.importLanes[slot], cadence: processing.cadence)
            activeTasks[model.id] = Task(priority: .utility) { [self] in
                await completion.value
                activeTasks[model.id] = nil
                laneSlots[model.id] = nil
                fillAvailableSlots()
                onDrain?()
            }
        }
    }

    func resume() {
        guard !isClosed else { return }
        isPaused = false
        fillAvailableSlots()
    }

    func close() {
        isClosed = true
        onPublication = nil
        onDrain = nil
        for model in models {
            model.onPublication = nil
            model.cancel()
        }
    }

    func waitUntilDrained() async {
        while let task = activeTasks.values.first {
            await task.value
        }
    }
}
