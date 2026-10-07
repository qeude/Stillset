import AppKit
import Observation
import StillsetCore
import UniformTypeIdentifiers

struct CapturedScreenshot: Identifiable {
    let state: UIState
    let fileURL: URL

    var id: UUID { state.id }
}

@MainActor
@Observable
public final class AppModel {
    var videoURL: URL?
    var screenshots: [CapturedScreenshot] = []
    private let screenCatalogAnalyzer = ScreenCatalogAnalyzer()
    var screenClassifications: [UUID: ScreenClassification] = [:]
    private(set) var showsUniqueScreens = true
    private(set) var selectedScreenshotIDs: Set<UUID> = []
    private(set) var selectedScreenshotOrder: [UUID] = []
    var focusedScreenshotID: UUID?
    var focusNavigationID: UUID?
    var analysisPreviewFrames: [Frame] = []
    var detectedScreens: [UIState] = []
    var analysisStartedAt = Date()
    var progress = AnalysisProgress(stage: .decoding, fraction: 0, detail: "Déposez un enregistrement")
    public private(set) var isWorking = false
    var isAnalyzing = false
    var errorMessage: String?
    var notice: String?
    var refinementDetail: String?
    var exportedFolderURL: URL?
    var followsLatest = true

    private var workTask: Task<Void, Never>?
    private var refinementTask: Task<Void, Never>?
    private var stagingFolderURL: URL?
    private var selectionAnchorID: UUID?
    private var fanSlots: [UUID: Int] = [:]

    public init() {}

    isolated deinit { refinementTask?.cancel() }

    public var hasScreenshots: Bool { !screenshots.isEmpty }
    public var canCopySelection: Bool { !selectedScreenshotIDs.isEmpty }
    public var canSaveSelection: Bool { canCopySelection && !isWorking }

    var focusedScreenshot: CapturedScreenshot? {
        screenshots.first { $0.id == focusedScreenshotID }
    }

    var visibleScreenshots: [CapturedScreenshot] {
        guard showsUniqueScreens else { return screenshots }
        var seen: Set<Int> = []
        return screenshots.filter { screenshot in
            guard let screen = screenClassifications[screenshot.id] else { return true }
            return seen.insert(screen.stateID).inserted
        }
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
        guard !isWorking else { return }
        guard ["mov", "mp4"].contains(url.pathExtension.lowercased()) else {
            errorMessage = "Choisissez un enregistrement MOV ou MP4."
            return
        }
        cancelRefinement()
        if let stagingFolderURL { try? FileManager.default.removeItem(at: stagingFolderURL) }
        stagingFolderURL = nil
        screenshots = []
        screenClassifications = [:]
        showsUniqueScreens = true
        setSelection([])
        focusedScreenshotID = nil
        focusNavigationID = nil
        selectionAnchorID = nil
        analysisPreviewFrames = []
        detectedScreens = []
        analysisStartedAt = Date()
        followsLatest = true
        videoURL = url
        notice = nil
        exportedFolderURL = nil
        errorMessage = nil
        analyze(url)
    }

    private func analyze(_ videoURL: URL) {
        let catalogAnalyzer = screenCatalogAnalyzer
        isWorking = true
        isAnalyzing = true
        progress = AnalysisProgress(stage: .decoding, fraction: 0, detail: "Lecture de la vidéo")
        let model = self
        workTask = Task.detached(priority: .userInitiated) {
            var stagingURL: URL?
            do {
                let result = try await AnalysisPipeline.run(
                    url: videoURL,
                    onProgress: { update in
                        Task { @MainActor in
                            guard model.isAnalyzing,
                                  model.progress.stage == .decoding,
                                  update.stage == .decoding else { return }
                            model.progress = update
                        }
                    },
                    onAnalyzedFrames: { frames in
                        await MainActor.run {
                            guard model.isAnalyzing, model.progress.stage == .decoding else { return }
                            let colorPreviews = frames.filter { $0.previewRGBA != nil }
                            model.analysisPreviewFrames = Array((model.analysisPreviewFrames + colorPreviews).suffix(2)) // ponytail: keep two full-resolution previews in memory; use disk-backed history if longer playback is needed.
                        }
                    },
                    onDetectedScreens: { screens in
                        await MainActor.run {
                            guard model.isAnalyzing, !Task.isCancelled else { return }
                            model.detectedScreens.append(contentsOf: screens)
                        }
                    }
                )
                try Task.checkCancellation()
                let folder = FileManager.default.temporaryDirectory
                    .appendingPathComponent("Stillset-\(UUID().uuidString)", isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                stagingURL = folder
                await MainActor.run {
                    model.progress = AnalysisProgress(stage: .exporting, fraction: 0, detail: "Préparation des captures")
                }
                let files = try await ScreenshotExporter.export(
                    states: result.states,
                    from: videoURL,
                    to: folder,
                    onScreenshot: { index, fileURL in
                        await MainActor.run {
                            guard model.isAnalyzing else { return }
                            model.screenshots.append(
                                CapturedScreenshot(state: result.states[index], fileURL: fileURL)
                            )
                            if model.followsLatest {
                                model.focusedScreenshotID = result.states[index].id
                                model.setSelection([result.states[index].id], resetFan: true)
                            }
                            model.progress = AnalysisProgress(
                                stage: .exporting,
                                fraction: Double(index + 1) / Double(result.states.count),
                                detail: "Capture \(index + 1) sur \(result.states.count)"
                            )
                        }
                    }
                )
                try Task.checkCancellation()
                await MainActor.run {
                    model.progress = AnalysisProgress(stage: .annotating, fraction: 0, detail: "Repérage des écrans…")
                }
                let catalog = try await catalogAnalyzer.analyze(fileURLs: files, useFoundationModels: false) { fraction, detail in
                    await MainActor.run {
                        model.progress = AnalysisProgress(stage: .annotating, fraction: fraction, detail: detail)
                    }
                }
                let namedFiles = try ScreenshotExporter.prepareNamedFiles(files: files, screenNames: catalog.classifications.map(\.name))
                try Task.checkCancellation()
                await MainActor.run {
                    model.screenClassifications = Dictionary(uniqueKeysWithValues: zip(result.states, catalog.classifications).map { ($0.0.id, $0.1) })
                    model.screenshots = zip(result.states, namedFiles).map {
                        CapturedScreenshot(state: $0.0, fileURL: $0.1)
                    }
                    model.setUniqueScreens(model.showsUniqueScreens)
                    model.stagingFolderURL = folder
                    model.isAnalyzing = false
                    model.isWorking = false
                    model.workTask = nil
                    model.notice = nil
                    if catalog.recognitionFailures > 0 {
                        model.notice = "Analyse incomplète pour \(catalog.recognitionFailures) capture(s). Toutes les captures sont conservées."
                    }
                    if let error = catalog.errorDescription {
                        model.notice = catalog.visionNames > 0
                            ? "Vision a nommé \(catalog.visionNames) capture(s). \(error)"
                            : error
                    }
                    model.progress = AnalysisProgress(
                        stage: .complete,
                        fraction: 1,
                        detail: "\(files.count) captures prêtes"
                    )
                }
            } catch is CancellationError {
                await MainActor.run {
                    model.stagingFolderURL = stagingURL
                    model.isAnalyzing = false
                    model.isWorking = false
                    model.workTask = nil
                    model.progress = AnalysisProgress(stage: .cancelled, fraction: 0, detail: "Analyse annulée")
                }
            } catch {
                let message = error.localizedDescription
                await MainActor.run {
                    model.stagingFolderURL = stagingURL
                    model.isAnalyzing = false
                    model.isWorking = false
                    model.workTask = nil
                    model.errorMessage = message
                }
            }
        }
    }

    func refineScreens() {
        guard !isWorking, !screenshots.isEmpty, refinementDetail == nil else { return }
        let files = screenshots.map(\.fileURL)
        cancelRefinement()
        let ids = screenshots.map(\.id)
        let analyzer = screenCatalogAnalyzer
        refinementDetail = "Affinage des cas ambigus avec l’IA…"
        refinementTask = Task { [weak self] in
            do {
                let catalog = try await analyzer.analyze(fileURLs: files) { _, detail in
                    await MainActor.run {
                        guard let self, self.screenshots.map(\.id) == ids, !Task.isCancelled else { return }
                        self.refinementDetail = "Affinage IA : \(detail)"
                    }
                }
                try Task.checkCancellation()
                guard let self, self.screenshots.map(\.id) == ids else { return }
                let namedFiles = try ScreenshotExporter.prepareNamedFiles(files: files, screenNames: catalog.classifications.map(\.name))
                self.applyRefinement(classifications: catalog.classifications, files: namedFiles, expectedIDs: ids)
                if let error = catalog.errorDescription { self.notice = "Les résultats locaux restent disponibles. \(error)" }
                self.refinementDetail = nil
                self.refinementTask = nil
            } catch is CancellationError {
                // The cancelling action already clears the status; never overwrite a newer import.
            } catch {
                guard let self, self.screenshots.map(\.id) == ids, !Task.isCancelled else { return }
                self.notice = "Affinage interrompu : \(error.localizedDescription). Les résultats locaux restent disponibles."
                self.refinementDetail = nil
                self.refinementTask = nil
            }
        }
    }

    func cancelRefinement() {
        refinementTask?.cancel()
        refinementTask = nil
        refinementDetail = nil
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

    public func saveSelection() {
        let files = selectedScreenshots.map(\.fileURL)
        guard !files.isEmpty, !isWorking else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Enregistrer ici"
        panel.message = "Choisissez un dossier pour \(files.count) PNG en pleine résolution."
        guard panel.runModal() == .OK, let folderURL = panel.url else { return }

        let model = self
        isWorking = true
        notice = nil
        errorMessage = nil
        progress = AnalysisProgress(stage: .exporting, fraction: 0, detail: "Enregistrement des PNG")
        workTask = Task.detached(priority: .userInitiated) {
            do {
                let copied = try ScreenshotExporter.copy(files: files, to: folderURL) { fraction, detail in
                    Task { @MainActor in
                        guard model.isWorking, !model.isAnalyzing else { return }
                        model.progress = AnalysisProgress(stage: .exporting, fraction: fraction, detail: detail)
                    }
                }
                await MainActor.run {
                    model.isWorking = false
                    model.workTask = nil
                    model.exportedFolderURL = folderURL
                    model.notice = "\(copied.count) capture\(copied.count == 1 ? "" : "s") enregistrée\(copied.count == 1 ? "" : "s")."
                    model.progress = AnalysisProgress(stage: .complete, fraction: 1, detail: model.notice ?? "")
                }
            } catch is CancellationError {
                await MainActor.run {
                    model.isWorking = false
                    model.workTask = nil
                    model.progress = AnalysisProgress(stage: .cancelled, fraction: 0, detail: "Enregistrement annulé")
                }
            } catch {
                let message = error.localizedDescription
                await MainActor.run {
                    model.isWorking = false
                    model.workTask = nil
                    model.errorMessage = message
                }
            }
        }
    }

    func cancel() {
        workTask?.cancel()
    }

    func showExportedFolder() {
        guard let exportedFolderURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([exportedFolderURL])
    }
}
