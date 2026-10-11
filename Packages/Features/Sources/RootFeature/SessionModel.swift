import AppKit
import Observation
import StillsetCore

struct OccurrenceID: Hashable, Sendable {
    let videoID: UUID
    let stateID: UUID
}

struct SessionOccurrence: Identifiable, Sendable {
    let id: OccurrenceID
    let videoOrdinal: Int
    let sourceURL: URL?
    let attempt: Int
    let state: UIState
    let capture: CapturedScreenshot?
    let classification: ScreenClassification?
    var sourceAspectRatio: CGFloat = 9 / 19

    var fileURL: URL { capture!.fileURL }
    var provenance: String {
        String(localized: "V\(videoOrdinal) · \(sourceURL?.lastPathComponent ?? String(localized: "Video", bundle: .module)) · attempt \(attempt) · \(state.representativeTimestamp.stillsetTimecode)", bundle: .module)
    }
    var aspectRatio: CGFloat {
        capture?.cachedAspectRatio ?? sourceAspectRatio
    }
}

struct SessionScreenGroup: Identifiable {
    let id: OccurrenceID
    let name: String
    let occurrences: [SessionOccurrence]
    var screenshots: [SessionOccurrence] { occurrences.filter { $0.capture != nil } }
    var sourceVideoCount: Int? = nil
    var videoCount: Int { sourceVideoCount ?? Set(occurrences.map { $0.id.videoID }).count }
}

struct SessionCatalogInput: Equatable, Sendable {
    let id: OccurrenceID
    let fileURL: URL
    let classification: ScreenClassification?
}

struct SessionCatalogSnapshot: Equatable, Sendable {
    let videoIDs: [UUID]
    let inputs: [SessionCatalogInput]
}

struct SessionCatalogResult: Sendable {
    let classifications: [ScreenClassification]
    var recognitionFailures = 0
    var errorDescription: String?
}

struct SessionProjection {
    let occurrences: [SessionOccurrence]
    let occurrencesByVideo: [UUID: [SessionOccurrence]]
    let readyInChronology: [SessionOccurrence]
    let readyByID: [OccurrenceID: SessionOccurrence]
    let readyRank: [OccurrenceID: Int]
    let allIDs: Set<OccurrenceID>
    let readyIDs: Set<OccurrenceID>
    let uniqueIDs: Set<OccurrenceID>
    let screenGroups: [SessionScreenGroup]
    let catalogSnapshot: SessionCatalogSnapshot

    static let empty = SessionProjection(occurrences: [], occurrencesByVideo: [:], readyInChronology: [],
        readyByID: [:], readyRank: [:], allIDs: [], readyIDs: [], uniqueIDs: [], screenGroups: [],
        catalogSnapshot: SessionCatalogSnapshot(videoIDs: [], inputs: []))
}

struct SessionVisibility {
    let ids: Set<OccurrenceID>
    let screenGroups: [SessionScreenGroup]
    let occurrencesInTimelineOrder: [SessionOccurrence]
    let readyInTimelineOrder: [SessionOccurrence]

    static let empty = SessionVisibility(ids: [], screenGroups: [], occurrencesInTimelineOrder: [], readyInTimelineOrder: [])
}

private struct SessionComponents {
    private var parents: [Int]
    private var sizes: [Int]
    private var earliest: [Int]

    init(count: Int) {
        parents = Array(0..<count)
        sizes = Array(repeating: 1, count: count)
        earliest = parents
    }

    mutating func root(_ index: Int) -> Int {
        var current = index
        while parents[current] != current {
            parents[current] = parents[parents[current]]
            current = parents[current]
        }
        return current
    }

    mutating func join(_ lhs: Int, _ rhs: Int) {
        var a = root(lhs), b = root(rhs)
        guard a != b else { return }
        if sizes[a] < sizes[b] { swap(&a, &b) }
        parents[b] = a
        sizes[a] += sizes[b]
        earliest[a] = min(earliest[a], earliest[b])
    }

    mutating func representative(_ index: Int) -> Int { earliest[root(index)] }
}

typealias SessionCatalogRunner = @Sendable ([URL], Bool, @escaping @Sendable (Double, String) async throws -> Void) async throws -> SessionCatalogResult

@MainActor
@Observable
public final class SessionModel {
    public let imports: VideoImportQueue
    let thumbnailLoader: ThumbnailLoader
    private let diagnostics: DiagnosticJournal?
    private let preferences: AppPreferences
    private(set) var showsUniqueScreens: Bool
    private(set) var groupsTimelineByScreen: Bool
    private(set) var selectedScreenshotIDs: Set<OccurrenceID> = []
    private(set) var selectedScreenshotOrder: [OccurrenceID] = []
    var focusedScreenshotID: OccurrenceID?
    private(set) var timelineRenderPlan = TimelineRenderPlan(sections: [], visibleIDs: [])
    private(set) var timelineRevealRequest: TimelineRevealRequest?
    @ObservationIgnored private(set) var timelineRevealCount = 0
    @ObservationIgnored private(set) var timelinePlanInstallCount = 0
    var followsLatest = true
    var notice: String?
    var errorMessage: String?
    private(set) var catalogDetail: String?
    private(set) var refinementDetail: String?
    private(set) var isExporting = false
    var exportedFolderURL: URL?
    var progress = AnalysisProgress(stage: .exporting, fraction: 0, detail: String(localized: "Saving PNGs", bundle: .module))
    private(set) var projection = SessionProjection.empty
    private(set) var visibility = SessionVisibility.empty
    private(set) var visibleCaptureCount = 0
    @ObservationIgnored private(set) var projectionBuildCount = 0
    private var selectionAnchorID: OccurrenceID?
    private var fanSlots: [OccurrenceID: Int] = [:]
    private var retainedVisibleIDs: Set<OccurrenceID> = []
    private var knownReadyIDs: Set<OccurrenceID> = []
    private let catalogAnalyzer = ScreenCatalogAnalyzer()
    private let catalogRunner: SessionCatalogRunner?
    private var catalogTask: Task<Void, Never>?
    private var catalogToken: UUID?
    private var pendingCatalog: (snapshot: SessionCatalogSnapshot, refined: Bool)?
    private var activeCatalogRequest: (snapshot: SessionCatalogSnapshot, refined: Bool)?
    private var requestedSnapshot: SessionCatalogSnapshot?
    private var automaticMetadata: [OccurrenceID: CatalogMetadata] = [:]
    private var refinedMetadata: [OccurrenceID: CatalogMetadata] = [:]
    private var startupTask: Task<Void, Never>?
    var chooseSaveFolder: (@MainActor (ScreenshotExportPlan) -> URL?)?
    private var exportTask: Task<Void, Never>?
    private var exportToken: UUID?
    private var exportCancellationRequested = false

    private struct CatalogMetadata {
        let input: SessionCatalogInput
        let representative: OccurrenceID
        let classification: ScreenClassification
    }
    private struct ScreenNode: Hashable {
        let videoID: UUID
        let screenID: Int?
    }
    private enum StateKey: Hashable {
        case occurrence(OccurrenceID)
        case local(UUID, Int)
    }

    public convenience init(preferences: AppPreferences, diagnostics: DiagnosticJournal? = nil) {
        self.init(preferences: preferences, imports: VideoImportQueue(diagnostics: diagnostics), diagnostics: diagnostics)
    }

    init(preferences: AppPreferences, imports: VideoImportQueue, catalogRunner: SessionCatalogRunner? = nil, diagnostics: DiagnosticJournal? = nil) {
        self.diagnostics = diagnostics
        self.preferences = preferences
        self.imports = imports
        thumbnailLoader = ThumbnailLoader(lane: imports.processing.thumbnailLane, cadence: imports.processing.cadence)
        showsUniqueScreens = preferences.captureDefault == .uniques
        groupsTimelineByScreen = preferences.organisationDefault == .byScreen
        self.catalogRunner = catalogRunner
        imports.onPublication = { [weak self] in self?.processingPublished() }
        imports.onDrain = { [weak self] in self?.requestCatalog() }
        processingPublished()
    }

    public func replacingVideos(_ urls: [URL]) -> SessionModel {
        let pendingStartup = startupTask
        cancelSessionWork()
        let next = SessionModel(preferences: preferences, imports: VideoImportQueue(paused: true, diagnostics: diagnostics), diagnostics: diagnostics)
        next.imports.enqueue(urls)
        next.startupTask = Task { [weak next] in
            await pendingStartup?.value
            await finishSession()
            guard let next, !Task.isCancelled else { return }
            next.imports.resume()
            next.startupTask = nil
        }
        return next
    }

    private func cancelSessionWork() {
        startupTask?.cancel()
        imports.close()
        pendingCatalog = nil
        activeCatalogRequest = nil
        catalogToken = nil
        catalogTask?.cancel()
        cancelExport()
    }

    func finishSession() async {
        cancelSessionWork()
        await imports.waitUntilDrained()
        await catalogTask?.value
        await exportTask?.value
        for model in imports.models { model.cleanUpSession() }
        catalogTask = nil
        exportTask = nil
    }

    isolated deinit {
        startupTask?.cancel()
        catalogTask?.cancel()
        exportTask?.cancel()
    }

    var isAnalyzing: Bool { imports.models.contains { $0.isAnalyzing } }
    public var hasScreenshots: Bool { !projection.readyInChronology.isEmpty }
    public var canCopySelection: Bool { !selectedScreenshots.isEmpty }
    public var canSaveSelection: Bool { canCopySelection && !isExporting }
    var focusedScreenshot: SessionOccurrence? { focusedScreenshotID.flatMap { projection.readyByID[$0] } }
    var screenshots: [SessionOccurrence] { projection.readyInChronology }
    var analysisModel: AppModel? { imports.models.first { $0.isAnalyzing } }
    var occurrences: [SessionOccurrence] { projection.occurrences }
    var catalogSnapshot: SessionCatalogSnapshot { projection.catalogSnapshot }
    var timelineScreenGroups: [SessionScreenGroup] { visibility.screenGroups }
    var visibleOccurrences: [SessionOccurrence] { visibility.occurrencesInTimelineOrder }
    var visibleScreenshots: [SessionOccurrence] { visibility.readyInTimelineOrder }
    var selectedScreenshots: [SessionOccurrence] {
        selectedScreenshotIDs.compactMap { projection.readyByID[$0] }
            .sorted { projection.readyRank[$0.id]! < projection.readyRank[$1.id]! }
    }
    var fanSelectedScreenshots: [SessionOccurrence] {
        selectedScreenshotOrder.compactMap { projection.readyByID[$0] }
    }

    private struct VideoInput {
        let id: UUID
        let ordinal: Int
        let sourceURL: URL?
        let attempt: Int
        let isPending: Bool
        let sourceAspectRatio: CGFloat
        let detected: [UIState]
        let captures: [CapturedScreenshot]
        let classifications: [UUID: ScreenClassification]
    }

    private func rebuildProjection() {
        let interval = processingSignposter.beginInterval("Projection")
        defer { processingSignposter.endInterval("Projection", interval) }
        let inputs = imports.models.map {
            VideoInput(id: $0.id, ordinal: $0.importOrdinal, sourceURL: $0.videoURL, attempt: $0.attempt,
                isPending: $0.importState.isPending, sourceAspectRatio: $0.sourceAspectRatio,
                detected: $0.detectedScreens, captures: $0.screenshots, classifications: $0.screenClassifications)
        }
        projectionBuildCount += 1
        projection = Self.makeProjection(inputs: inputs, automatic: automaticMetadata, refined: refinedMetadata)
    }

    private static func makeProjection(inputs: [VideoInput], automatic: [OccurrenceID: CatalogMetadata],
                                       refined: [OccurrenceID: CatalogMetadata]) -> SessionProjection {
        var entries: [SessionOccurrence] = []
        var byVideo: [UUID: [SessionOccurrence]] = [:]
        var ready: [SessionOccurrence] = []
        var readyByID: [OccurrenceID: SessionOccurrence] = [:]
        var readyRank: [OccurrenceID: Int] = [:]
        var catalogInputs: [SessionCatalogInput] = []
        for video in inputs.sorted(by: { $0.ordinal < $1.ordinal }) {
            let captures = Dictionary(uniqueKeysWithValues: video.captures.map { ($0.id, $0) })
            let detectedIDs = Set(video.detected.map(\.id))
            let states = video.isPending
                ? video.detected + video.captures.filter { !detectedIDs.contains($0.id) }.map(\.state)
                : video.captures.map(\.state)
            let occurrences = states.enumerated().sorted {
                $0.element.representativeTimestamp == $1.element.representativeTimestamp
                    ? $0.offset < $1.offset : $0.element.representativeTimestamp < $1.element.representativeTimestamp
            }.map { _, state in
                let id = OccurrenceID(videoID: video.id, stateID: state.id)
                let local = video.classifications[state.id]
                let capture = captures[state.id]
                let input = capture.map { SessionCatalogInput(id: id, fileURL: $0.fileURL, classification: local) }
                let display = refined[id].flatMap { $0.input == input ? $0.classification : nil }
                let entry = SessionOccurrence(id: id, videoOrdinal: video.ordinal, sourceURL: video.sourceURL,
                    attempt: video.attempt, state: state, capture: capture, classification: display ?? local,
                    sourceAspectRatio: video.sourceAspectRatio)
                if capture != nil {
                    readyRank[id] = ready.count
                    readyByID[id] = entry
                    ready.append(entry)
                }
                if !video.isPending, let input { catalogInputs.append(input) }
                return entry
            }
            byVideo[video.id] = occurrences
            entries.append(contentsOf: occurrences)
        }
        let eligible = Dictionary(uniqueKeysWithValues: catalogInputs.map { ($0.id, $0) })
        func valid(_ metadata: [OccurrenceID: CatalogMetadata]) -> [OccurrenceID: CatalogMetadata] {
            metadata.filter { id, value in
                eligible[id] == value.input && eligible[value.representative] != nil
                    && metadata[value.representative].map { eligible[value.representative] == $0.input } == true
            }
        }
        let automatic = valid(automatic), refined = valid(refined)
        let ranks = Dictionary(uniqueKeysWithValues: entries.enumerated().map { ($0.element.id, $0.offset) })
        var states = SessionComponents(count: entries.count)
        for metadata in [automatic, refined] {
            for (id, value) in metadata {
                states.join(ranks[id]!, ranks[value.representative]!)
            }
        }
        var keys: [OccurrenceID: StateKey] = [:]
        var uniqueIDs: Set<OccurrenceID> = []
        var seen: Set<StateKey> = []
        for (index, entry) in entries.enumerated() {
            let key: StateKey
            if automatic[entry.id] != nil || refined[entry.id] != nil {
                key = .occurrence(entries[states.representative(index)].id)
            } else {
                key = entry.classification.map { .local(entry.id.videoID, $0.stateID) } ?? .occurrence(entry.id)
            }
            keys[entry.id] = key
            if seen.insert(key).inserted { uniqueIDs.insert(entry.id) }
        }
        var nodes: [ScreenNode: Int] = [:]
        let entryNodes = entries.map { entry in
            let node = ScreenNode(videoID: entry.id.videoID, screenID: entry.classification?.screenID)
            if let index = nodes[node] { return index }
            let index = nodes.count
            nodes[node] = index
            return index
        }
        var families = SessionComponents(count: nodes.count)
        let byState = Dictionary(grouping: entries.indices) { keys[entries[$0].id]! }
        for members in byState.values where Set(members.map { entries[$0].id.videoID }).count > 1 {
            guard let first = members.first else { continue }
            for member in members.dropFirst() { families.join(entryNodes[member], entryNodes[first]) }
        }
        var order: [Int] = []
        var buckets: [Int: [SessionOccurrence]] = [:]
        for (index, entry) in entries.enumerated() {
            let family = families.root(entryNodes[index])
            if buckets[family] == nil { order.append(family) }
            buckets[family, default: []].append(entry)
        }
        let groups = order.map { key in
            let members = buckets[key]!
            let first = members[0]
            return SessionScreenGroup(id: first.id, name: first.classification?.name ?? String(localized: "Unidentified", bundle: .module), occurrences: members)
        }
        return SessionProjection(occurrences: entries, occurrencesByVideo: byVideo, readyInChronology: ready,
            readyByID: readyByID, readyRank: readyRank, allIDs: Set(entries.map(\.id)), readyIDs: Set(readyByID.keys),
            uniqueIDs: uniqueIDs, screenGroups: groups,
            catalogSnapshot: SessionCatalogSnapshot(videoIDs: inputs.map(\.id), inputs: catalogInputs))
    }

    private func publishVisibility() {
        let interval = processingSignposter.beginInterval("TimelineVisibility")
        defer { processingSignposter.endInterval("TimelineVisibility", interval) }
        let ids = (showsUniqueScreens ? projection.uniqueIDs : projection.allIDs).union(retainedVisibleIDs)
        let groups = projection.screenGroups.compactMap { group -> SessionScreenGroup? in
            let entries = group.occurrences.filter { ids.contains($0.id) }
            return entries.isEmpty ? nil : SessionScreenGroup(id: group.id, name: group.name,
                occurrences: entries, sourceVideoCount: group.videoCount)
        }
        let occurrences = groupsTimelineByScreen ? groups.flatMap(\.occurrences)
            : projection.occurrences.filter { ids.contains($0.id) }
        let ready = occurrences.filter { $0.capture != nil }
        visibility = SessionVisibility(ids: ids, screenGroups: groups,
            occurrencesInTimelineOrder: occurrences, readyInTimelineOrder: ready)
        if visibleCaptureCount != ready.count { visibleCaptureCount = ready.count }
        let sections: [TimelineRenderPlan.Section]
        if groupsTimelineByScreen {
            sections = groups.map { group in
                let screenName = group.occurrences.lazy.compactMap { $0.classification?.name }
                    .first { !$0.isEmpty && $0 != String(localized: "Unidentified screen", bundle: .module) }
                let name = screenName.map { group.videoCount > 1 ? String(localized: "\($0) · \(group.videoCount) videos", bundle: .module) : $0 } ?? ""
                return .init(id: .screen(group.id), name: name,
                    screenGroupID: group.id, occurrences: group.occurrences, job: nil)
            }
        } else {
            sections = imports.models.map { job in
                .init(id: .video(job.id), name: imports.models.count > 1 ? "V\(job.importOrdinal) · \(job.displayName)" : job.displayName,
                    screenGroupID: nil, occurrences: projection.occurrencesByVideo[job.id, default: []], job: job)
            }
        }
        timelineRenderPlan = TimelineRenderPlan(sections: sections, visibleIDs: ids)
        timelinePlanInstallCount += 1
        processingSignposter.emitEvent("TimelinePlanInstall")
    }
    var previewDragURLs: [URL] {
        selectedScreenshots.isEmpty ? focusedScreenshot.map { [$0.fileURL] } ?? [] : selectedScreenshots.map(\.fileURL)
    }
    func fanSlot(for id: OccurrenceID) -> Int { fanSlots[id] ?? 0 }

    private func processingPublished() {
        let interval = processingSignposter.beginInterval("TimelinePublication")
        defer { processingSignposter.endInterval("TimelinePublication", interval) }
        rebuildProjection()
        reconcileEntries()
        requestCatalog()
    }

    func reconcileEntries(preserveReview: Bool = true) {
        let interval = processingSignposter.beginInterval("ReviewReconciliation")
        defer { processingSignposter.endInterval("ReviewReconciliation", interval) }
        let readyIDs = projection.readyIDs
        if preserveReview {
            let naturalIDs = showsUniqueScreens ? projection.uniqueIDs : projection.allIDs
            retainedVisibleIDs.formUnion(selectedScreenshotIDs.intersection(readyIDs).subtracting(naturalIDs))
            if let focusedScreenshotID, readyIDs.contains(focusedScreenshotID), !naturalIDs.contains(focusedScreenshotID) {
                retainedVisibleIDs.insert(focusedScreenshotID)
            }
        } else { retainedVisibleIDs = [] }
        retainedVisibleIDs.formIntersection(readyIDs)
        publishVisibility()
        let visible = visibleScreenshots
        let ids = Set(visible.map(\.id))
        setSelection(selectedScreenshotOrder.filter { ids.contains($0) })
        if focusedScreenshotID.map({ ids.contains($0) }) != true {
            focusedScreenshotID = selectedScreenshotOrder.first ?? visible.first?.id
            if selectedScreenshotIDs.isEmpty, let focusedScreenshotID { setSelection([focusedScreenshotID], resetFan: true) }
            if followsLatest, let focusedScreenshotID, !knownReadyIDs.contains(focusedScreenshotID) {
                requestTimelineReveal(focusedScreenshotID, cause: .followLatest)
            }
        } else if followsLatest, let focused = focusedScreenshotID,
                  let currentRank = projection.readyRank[focused],
                  let newest = visible.last(where: { !knownReadyIDs.contains($0.id) }),
                  let rank = projection.readyRank[newest.id], rank > currentRank {
            focusedScreenshotID = newest.id
            setSelection([newest.id], resetFan: true)
            requestTimelineReveal(newest.id, cause: .followLatest)
        }
        knownReadyIDs = readyIDs
        if selectionAnchorID.map({ ids.contains($0) }) != true { selectionAnchorID = focusedScreenshotID }
    }

    func setTimelineGrouping(_ enabled: Bool) {
        beginTimelineReview()
        groupsTimelineByScreen = enabled
        publishVisibility()
        selectionAnchorID = focusedScreenshotID
    }

    func setUniqueScreens(_ enabled: Bool) {
        beginTimelineReview()
        showsUniqueScreens = enabled
        reconcileEntries(preserveReview: false)
        selectionAnchorID = focusedScreenshotID
    }

    private func requestCatalog(refined: Bool = false) {
        let snapshot = catalogSnapshot
        if imports.isBusy {
            if !snapshot.inputs.isEmpty {
                if refined || requestedSnapshot != snapshot {
                    pendingCatalog = (snapshot, refined || pendingCatalog?.refined == true || activeCatalogRequest?.refined == true)
                } else if pendingCatalog == nil, let activeCatalogRequest {
                    pendingCatalog = activeCatalogRequest
                }
            } else { pendingCatalog = nil }
            requestedSnapshot = snapshot
            catalogTask?.cancel()
            return
        }
        if let pendingCatalog, pendingCatalog.snapshot == snapshot, !refined {
            startPendingCatalog()
            return
        }
        guard refined || requestedSnapshot != snapshot else { return }
        requestedSnapshot = snapshot
        if snapshot.inputs.isEmpty {
            pendingCatalog = nil
            catalogTask?.cancel()
            return
        }
        pendingCatalog = (snapshot, refined)
        if catalogTask != nil { catalogTask?.cancel() } else { startPendingCatalog() }
    }

    private func startPendingCatalog() {
        guard !imports.isBusy, catalogTask == nil, let request = pendingCatalog else { return }
        pendingCatalog = nil
        activeCatalogRequest = request
        let token = UUID()
        catalogToken = token
        if request.refined { refinementDetail = String(localized: "Refining screenshots…", bundle: .module) }
        else { catalogDetail = String(localized: "Organizing session…", bundle: .module) }
        let runner = catalogRunner
        let analyzer = catalogAnalyzer
        let work = imports.processing.catalogLane
        let diagnostics = diagnostics
        let cadence = imports.processing.cadence
        let delivery = ProgressDelivery(cadence: cadence) { [weak self] fraction, _ in
            guard let self, self.catalogToken == token, self.activeCatalogRequest?.snapshot == request.snapshot,
                  self.activeCatalogRequest?.refined == request.refined, !self.imports.isBusy,
                  self.catalogSnapshot == request.snapshot else { return false }
            let detail = "\(fraction.formatted(.percent.precision(.fractionLength(0))))"
            if request.refined { self.refinementDetail = String(localized: "Refining screenshots… \(detail)", bundle: .module) }
            else { self.catalogDetail = String(localized: "Organizing session… \(detail)", bundle: .module) }
            return true
        }
        catalogTask = Task.detached(priority: .utility) { [weak self] in
            let diagnostic = await diagnostics?.begin(request.refined ? .refinement : .sessionCatalog)
            await diagnostic?.stage(.cataloging)
            do {
                let progress: @Sendable (Double, String) async throws -> Void = { fraction, detail in
                    try await delivery.update(fraction, detail)
                }
                let result: SessionCatalogResult
                if let runner {
                    result = try await runner(request.snapshot.inputs.map(\.fileURL), request.refined, progress)
                } else {
                    let catalog = try await analyzer.analyze(fileURLs: request.snapshot.inputs.map(\.fileURL), work: work,
                        useContextualNaming: true, useFoundationModels: request.refined, diagnostics: diagnostic, onProgress: progress)
                    result = SessionCatalogResult(classifications: catalog.classifications,
                        recognitionFailures: catalog.recognitionFailures, errorDescription: catalog.errorDescription)
                }
                if result.recognitionFailures > 0 || result.errorDescription != nil {
                    await diagnostic?.issue(.unknown, at: .cataloging)
                }
                try await delivery.flush()
                try Task.checkCancellation()
                if request.refined, let self {
                    for model in await self.imports.models {
                        guard try await model.cachedSourceIsCurrent() else {
                            throw CocoaError(.fileReadUnknown)
                        }
                    }
                }
                let accepted = try await cadence.commit {
                    guard let self, self.catalogToken == token,
                          self.activeCatalogRequest?.snapshot == request.snapshot,
                          self.activeCatalogRequest?.refined == request.refined,
                          !self.imports.isBusy else { return false }
                    let applied = self.applyCatalog(result.classifications, snapshot: request.snapshot, refined: request.refined)
                    if applied {
                        if result.recognitionFailures == 0, let error = result.errorDescription {
                            self.notice = String(localized: "Partial organization: \(error). All screenshots remain available.", bundle: .module)
                        }
                    } else if self.catalogSnapshot == request.snapshot {
                        self.notice = String(localized: "Session organization could not be completed. All screenshots remain available.", bundle: .module)
                    }
                    return applied
                }
                if accepted, request.refined, result.recognitionFailures == 0, result.errorDescription == nil, let self {
                    for model in await self.imports.models {
                        let inputs = request.snapshot.inputs.enumerated().filter { $0.element.id.videoID == model.id }
                        try await model.persistSessionRefinement(inputs.map { result.classifications[$0.offset] },
                            expectedIDs: inputs.map { $0.element.id.stateID })
                    }
                }
                await diagnostic?.finish(Task.isCancelled ? .cancelled : .success)
            } catch is CancellationError {
                await diagnostic?.finish(.cancelled)
            } catch {
                await diagnostic?.finish(.failure(error, cancelled: Task.isCancelled))
                let message = error.localizedDescription
                _ = try? await cadence.commit {
                    guard let self, self.catalogToken == token,
                          self.activeCatalogRequest?.snapshot == request.snapshot,
                          self.activeCatalogRequest?.refined == request.refined,
                          self.catalogSnapshot == request.snapshot,
                          !self.imports.isBusy else { return false }
                    self.notice = String(localized: "Organization interrupted: \(message). All screenshots remain available.", bundle: .module)
                    return true
                }
            }
            await MainActor.run {
                guard let self, self.catalogToken == token else { return }
                self.catalogToken = nil
                self.catalogTask = nil
                self.activeCatalogRequest = nil
                if request.refined { self.refinementDetail = nil } else { self.catalogDetail = nil }
                self.startPendingCatalog()
            }
        }
    }

    @discardableResult
    func applyCatalog(_ classifications: [ScreenClassification], snapshot: SessionCatalogSnapshot, refined: Bool) -> Bool {
        let interval = processingSignposter.beginInterval("TimelineMetadataPublication")
        defer { processingSignposter.endInterval("TimelineMetadataPublication", interval) }
        guard snapshot == catalogSnapshot, classifications.count == snapshot.inputs.count,
              classifications.enumerated().allSatisfy({ index, value in
                  let representative = value.stateID - 1
                  return representative >= 0 && representative <= index
                      && classifications[representative].stateID == value.stateID
              }) else { return false }
        var metadata: [OccurrenceID: CatalogMetadata] = [:]
        for (index, input) in snapshot.inputs.enumerated() {
            let classification = classifications[index]
            metadata[input.id] = CatalogMetadata(input: input,
                representative: snapshot.inputs[classification.stateID - 1].id, classification: classification)
        }
        if refined { refinedMetadata = metadata } else { automaticMetadata = metadata }
        rebuildProjection()
        reconcileEntries()
        return true
    }

    func refineScreens() {
        guard !catalogSnapshot.inputs.isEmpty, refinementDetail == nil, pendingCatalog?.refined != true else { return }
        requestCatalog(refined: true)
    }

    func cancelRefinement() {
        if pendingCatalog?.refined == true { pendingCatalog = nil }
        if activeCatalogRequest?.refined == true { activeCatalogRequest = nil }
        if refinementDetail != nil { catalogTask?.cancel() }
        if catalogSnapshot.inputs.contains(where: { automaticMetadata[$0.id]?.input != $0 }) {
            requestedSnapshot = nil
            requestCatalog()
        }
    }

    func waitForCatalog() async {
        while let task = catalogTask { await task.value }
    }
    func selectScreenshot(_ id: OccurrenceID, modifiers: NSEvent.ModifierFlags) {
        let visible = visibleScreenshots
        guard visible.contains(where: { $0.id == id }) else { return }
        beginTimelineReview()
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

    func selectTimelineScreenGroup(_ screenID: OccurrenceID) {
        guard groupsTimelineByScreen,
              let group = timelineScreenGroups.first(where: { $0.id == screenID }),
              let first = group.screenshots.first else { return }
        setSelection(group.screenshots.map(\.id), resetFan: true)
        focusedScreenshotID = first.id
        selectionAnchorID = first.id
        beginTimelineReview()
        requestTimelineReveal(first.id, cause: .groupSelection)
        notice = nil
    }

    public func selectAll() {
        let visible = visibleScreenshots
        guard !visible.isEmpty else { return }
        beginTimelineReview()
        notice = nil
        setSelection(selectedScreenshotOrder + visible.map(\.id).filter { !selectedScreenshotIDs.contains($0) })
        if focusedScreenshotID == nil { focusedScreenshotID = selectedScreenshotOrder.first }
        selectionAnchorID = focusedScreenshotID
    }

    func moveFocus(by offset: Int, modifiers: NSEvent.ModifierFlags = []) {
        let visible = visibleScreenshots
        guard !visible.isEmpty, offset != 0 else { return }
        beginTimelineReview()
        if modifiers.contains(.shift), let focusedScreenshotID,
           let index = visible.firstIndex(where: { $0.id == focusedScreenshotID }) {
            let target = modifiers.contains(.command) ? (offset < 0 ? 0 : visible.count - 1) : min(visible.count - 1, max(0, index + offset))
            let next = visible[target]
            selectScreenshot(next.id, modifiers: modifiers)
            self.focusedScreenshotID = next.id
            requestTimelineReveal(next.id, cause: .navigation)
            return
        }
        let candidates = selectedScreenshotIDs.count > 1
            ? visible.filter { selectedScreenshotIDs.contains($0.id) }
            : visible
        guard !candidates.isEmpty else { return }
        let currentIndex = candidates.firstIndex { $0.id == focusedScreenshotID } ?? 0
        let nextIndex = modifiers.contains(.command) ? (offset < 0 ? 0 : candidates.count - 1)
            : min(candidates.count - 1, max(0, currentIndex + offset))
        let next = candidates[nextIndex]
        focusedScreenshotID = next.id
        requestTimelineReveal(next.id, cause: .navigation)
        selectionAnchorID = next.id
        if selectedScreenshotIDs.count <= 1 {
            setSelection([next.id], resetFan: true)
        }
        notice = nil
    }

    func beginTimelineReview() {
        followsLatest = false
        if timelineRevealRequest?.cause == .followLatest { timelineRevealRequest = nil }
    }

    private func requestTimelineReveal(_ id: OccurrenceID, cause: TimelineRevealRequest.Cause) {
        timelineRevealCount += 1
        timelineRevealRequest = TimelineRevealRequest(id: UUID(), target: id, cause: cause)
    }

    func dragURLs(startingAt id: OccurrenceID) -> [URL] {
        if selectedScreenshotIDs.contains(id) {
            return selectedScreenshots.map(\.fileURL)
        }
        return projection.readyByID[id].map { [$0.fileURL] } ?? []
    }

    private func setSelection(_ ids: [OccurrenceID], resetFan: Bool = false) {
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
            .init(sourceURL: $0.fileURL, screenName: $0.classification?.name ?? String(localized: "Unidentified", bundle: .module))
        })
    }

    public func saveSelection() {
        guard !isExporting else { return }
        let plan = makeSelectionExportPlan()
        guard plan.fileCount > 0 else { return }
        isExporting = true
        let token = UUID()
        exportToken = token
        exportCancellationRequested = false
        var transferredWork = false
        defer {
            if !transferredWork, exportToken == token {
                exportToken = nil
                isExporting = false
            }
        }
        let folderURL: URL?
        if let chooseSaveFolder { folderURL = chooseSaveFolder(plan) }
        else { folderURL = presentSavePanel(plan: plan) }
        guard let folderURL else { return }

        let model = self
        notice = nil
        errorMessage = nil
        progress = AnalysisProgress(stage: .exporting, fraction: 0, detail: String(localized: "Saving PNGs", bundle: .module))
        let work = imports.processing.copyLane
        let cadence = imports.processing.cadence
        let delivery = ProgressDelivery(cadence: cadence) { fraction, detail in
            guard model.exportToken == token, !model.exportCancellationRequested else { return false }
            model.progress = AnalysisProgress(stage: .exporting, fraction: fraction, detail: detail)
            return true
        }
        let diagnostics = diagnostics
        exportTask = Task.detached(priority: .utility) {
            let diagnostic = await diagnostics?.begin(.sessionExport)
            await diagnostic?.stage(.saving)
            let result: Result<[URL], Error>
            do {
                let copied = try await ScreenshotExporter.copy(plan: plan, to: folderURL, work: work) { fraction, detail in
                    try await delivery.update(fraction, detail)
                }
                try await delivery.flush()
                result = .success(copied)
            } catch { result = .failure(error) }
            switch result {
            case .success: await diagnostic?.finish(Task.isCancelled ? .cancelled : .success)
            case .failure(let error): await diagnostic?.finish(.failure(error, cancelled: Task.isCancelled))
            }
            let completion = Task.detached(priority: .utility) {
                _ = try? await cadence.commit {
                    guard model.exportToken == token else { return false }
                    model.exportToken = nil
                    model.isExporting = false
                    model.exportTask = nil
                    if model.exportCancellationRequested {
                        model.progress = AnalysisProgress(stage: .cancelled, fraction: 0, detail: String(localized: "Save cancelled", bundle: .module))
                    } else {
                        switch result {
                        case .success(let copied):
                            model.exportedFolderURL = folderURL
                            model.notice = String(localized: "\(copied.count) screenshots saved.", bundle: .module)
                            model.progress = AnalysisProgress(stage: .complete, fraction: 1, detail: model.notice ?? "")
                        case .failure(let error) where error is CancellationError:
                            model.progress = AnalysisProgress(stage: .cancelled, fraction: 0, detail: String(localized: "Save cancelled", bundle: .module))
                        case .failure(let error): model.errorMessage = error.localizedDescription
                        }
                    }
                    return true
                }
            }
            await completion.value
        }
        transferredWork = true
    }

    func waitForExport() async { await exportTask?.value }

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
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    func cancelExport() {
        exportCancellationRequested = true
        exportTask?.cancel()
    }

    func showExportedFolder() {
        guard let exportedFolderURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([exportedFolderURL])
    }
}
