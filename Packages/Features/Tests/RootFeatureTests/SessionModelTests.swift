import AppKit
import ImageIO
import Observation
import Synchronization
import StillsetCore
import Testing
@testable import StillsetFeatures

@MainActor
struct SessionModelTests {
    @Test func cancellingSingleVideoReturnsAnEmptySessionBeforeWorkerFinishes() async {
        let runner = ControlledAnalysisRunner()
        let old = SessionModel(preferences: preferences(), imports: VideoImportQueue(runner: runner.run))
        old.imports.enqueue([URL(fileURLWithPath: "/tmp/original.mov")])
        let video = old.imports.models[0]
        let run = await runner.waitForStart(video)
        run.publish { $0.screenshots = [capture(0)] }
        let home = old.replacingVideos([])
        #expect(home !== old)
        #expect(home.imports.models.isEmpty)
        #expect(home.screenshots.isEmpty)
        #expect(home.selectedScreenshotIDs.isEmpty)
        #expect(home.focusedScreenshotID == nil)
        #expect(video.importState == .cancelling)
        home.imports.enqueue([URL(fileURLWithPath: "/tmp/new-missing.mov")])
        let replacement = home.imports.models[0]
        #expect(replacement.importState == .queued)
        #expect(home.imports.activeModelIDs.isEmpty)
        runner.finish(video, with: .cancelled)
        await old.finishSession()
        while replacement.importState == .queued { await Task.yield() }
        await home.imports.waitUntilDrained()
        #expect(replacement.importState.failure != nil)
        #expect(home.screenshots.isEmpty)
    }

    @Test func replacementResetsImmediatelyWhileOldCatalogDrains() async {
        let catalog = ControlledCatalogRunner()
        let old = SessionModel(preferences: preferences(), imports: VideoImportQueue(models: [job("old", captures: [capture(0)])]),
            catalogRunner: catalog.run)
        await catalog.waitForStart(0)
        let next = old.replacingVideos([URL(fileURLWithPath: "/tmp/replacement-missing.mov")])
        #expect(next !== old)
        #expect(next.imports.models.count == 1)
        #expect(next.imports.models[0].importOrdinal == 1)
        #expect(next.imports.models[0].importState == .queued)
        #expect(next.screenshots.isEmpty)
        #expect(next.selectedScreenshotIDs.isEmpty)
        #expect(next.focusedScreenshotID == nil)
        #expect(next.imports.activeModelIDs.isEmpty)
        let latest = next.replacingVideos([URL(fileURLWithPath: "/tmp/latest-missing.mov")])
        #expect(latest.imports.models[0].importState == .queued)
        #expect(latest.imports.activeModelIDs.isEmpty)
        catalog.finish(0, labels: [label(99, 1, "old")])
        await old.finishSession()
        while latest.imports.models[0].importState == .queued { await Task.yield() }
        await latest.imports.waitUntilDrained()
        #expect(next.imports.models[0].importState == .cancelled)
        #expect(latest.imports.models[0].videoURL?.lastPathComponent == "latest-missing.mov")
        #expect(latest.imports.models[0].importState.failure != nil)
        #expect(latest.screenshots.isEmpty)
    }

    @Test func importsInterruptCatalogAndUnchangedSnapshotResumesAfterTaskRemoval() async {
        let imports = ControlledAnalysisRunner()
        let queue = VideoImportQueue(runner: imports.run)
        let catalog = ControlledCatalogRunner()
        let session = SessionModel(preferences: preferences(), imports: queue, catalogRunner: catalog.run)
        queue.enqueue([URL(fileURLWithPath: "/tmp/A.mov")])
        let a = queue.models[0]
        let runA = await imports.waitForStart(a)
        let first = capture(0)
        runA.publish { $0.screenshots = [first] }
        imports.finish(a, with: .completed)
        await queue.waitUntilDrained()
        await catalog.waitForStart(0)
        queue.enqueue([URL(fileURLWithPath: "/tmp/B.mov")])
        let b = queue.models[1]
        await imports.waitForStart(b)
        let snapshotWhileBusy = session.catalogSnapshot
        catalog.finish(0, labels: [label(1, 1, "stale")])
        await session.waitForCatalog()
        #expect(catalog.runs.count == 1)
        #expect(queue.isBusy)
        imports.finish(b, with: .completed)
        await queue.waitUntilDrained()
        #expect(session.catalogSnapshot == snapshotWhileBusy)
        await catalog.waitForStart(1)
        #expect(catalog.runs[1].urls == [first.fileURL])
        catalog.finish(1, labels: [label(1, 1, "resumed")])
        await session.waitForCatalog()
        #expect(catalog.maxActive == 1)
        #expect(session.screenshots[0].capture?.fileURL == first.fileURL)
        #expect(!queue.isBusy)
    }

    @Test func quickPassIsFollowedByAutomaticRefinementOnlyWhenEnabled() async {
        for automatic in [true, false] {
            let imports = ControlledAnalysisRunner()
            let queue = VideoImportQueue(runner: imports.run)
            let catalog = ControlledCatalogRunner()
            let session = SessionModel(preferences: preferences(), imports: queue, catalogRunner: catalog.run,
                                       refinesAutomatically: automatic)
            queue.enqueue([URL(fileURLWithPath: "/tmp/A.mov")])
            let a = queue.models[0]
            let run = await imports.waitForStart(a)
            run.publish { $0.screenshots = [capture(0)] }
            imports.finish(a, with: .completed)
            await queue.waitUntilDrained()
            await catalog.waitForStart(0)
            #expect(!catalog.runs[0].refined)
            catalog.finish(0, labels: [label(1, 1)])
            if automatic {
                await catalog.waitForStart(1)
                #expect(catalog.runs[1].refined)
                catalog.finish(1, labels: [label(1, 1)])
            }
            await session.waitForCatalog()
            #expect(catalog.runs.count == (automatic ? 2 : 1))
        }
    }

    @Test func replacingVideosKeepsAutomaticRefinement() {
        for automatic in [true, false] {
            let session = SessionModel(preferences: preferences(), imports: VideoImportQueue(runner: ControlledAnalysisRunner().run),
                                       refinesAutomatically: automatic)
            #expect(session.replacingVideos([]).refinesAutomatically == automatic)
        }
    }

    @Test func importDrainDoesNotRestartAnExplicitlyStoppedRefinement() async {
        let imports = ControlledAnalysisRunner()
        let queue = VideoImportQueue(runner: imports.run)
        let catalog = ControlledCatalogRunner()
        let session = SessionModel(preferences: preferences(), imports: queue, catalogRunner: catalog.run)
        queue.enqueue([URL(fileURLWithPath: "/tmp/A.mov")])
        let a = queue.models[0]
        let runA = await imports.waitForStart(a)
        runA.publish { $0.screenshots = [capture(0)] }
        imports.finish(a, with: .completed)
        await queue.waitUntilDrained()
        await catalog.waitForStart(0)
        catalog.finish(0, labels: [label(1, 1)])
        await session.waitForCatalog()
        session.refineScreens()
        await catalog.waitForStart(1)
        queue.enqueue([URL(fileURLWithPath: "/tmp/B.mov")])
        let b = queue.models[1]
        await imports.waitForStart(b)
        session.cancelRefinement()
        catalog.finish(1, labels: [label(9, 1, "stale")])
        await session.waitForCatalog()
        imports.finish(b, with: .completed)
        await queue.waitUntilDrained()
        await session.waitForCatalog()
        #expect(catalog.runs.count == 2)
        #expect(session.refinementDetail == nil)
        #expect(session.canSaveSelection)
    }

    @Test func compositeIDsAndLocalCollisionsDoNotMergeAcrossVideos() {
        let shared = UUID()
        let a = job("A", captures: [capture(0, id: shared)], labels: [label(1, 1)])
        let b = job("B", captures: [capture(0, id: shared)], labels: [label(1, 1)])
        let session = makeSession([a, b])
        #expect(session.visibleScreenshots.map(\.id) == [id(a, shared), id(b, shared)])
        #expect(session.timelineScreenGroups.count == 2)
        session.selectAll()
        #expect(session.selectedScreenshotIDs == [id(a, shared), id(b, shared)])
        #expect(session.screenshots.map(\.videoOrdinal) == [1, 2])
    }

    @Test func crossVideoEvidenceJoinsFamiliesButRetainsDistinctStatesAndHiddenLinks() {
        let a = job("A", captures: [capture(0), capture(1)], labels: [label(1, 1), label(1, 2)])
        let b = job("B", captures: [capture(0), capture(1)], labels: [label(1, 1), label(1, 2)])
        let session = makeSession([a, b])
        let ids = session.screenshots.map(\.id)
        #expect(session.applyCatalog([label(1, 1), label(1, 2), label(1, 1), label(1, 4)],
            snapshot: session.catalogSnapshot, refined: false))
        session.setUniqueScreens(true)
        #expect(session.visibleScreenshots.map(\.id) == [ids[0], ids[1], ids[3]])
        #expect(session.timelineScreenGroups.count == 1)
        #expect(session.timelineScreenGroups[0].id == ids[0])
        #expect(session.timelineScreenGroups[0].videoCount == 2)
        session.setUniqueScreens(false)
        #expect(session.visibleScreenshots.map(\.id) == ids)
        session.setTimelineGrouping(true)
        session.selectTimelineScreenGroup(ids[0])
        #expect(session.selectedScreenshotIDs == Set(ids))
    }

    @Test func backgroundMatchingRetainsSelectedFocusedRepeatUntilExplicitFilter() {
        let a = job("A", captures: [capture(0)], labels: [label(1, 1)])
        let b = job("B", captures: [capture(0)], labels: [label(1, 1)])
        let session = makeSession([a, b])
        let ids = session.screenshots.map(\.id)
        session.selectScreenshot(ids[1], modifiers: [])
        #expect(session.applyCatalog([label(1, 1), label(1, 1)], snapshot: session.catalogSnapshot, refined: false))
        #expect(session.focusedScreenshotID == ids[1])
        #expect(session.selectedScreenshotIDs == [ids[1]])
        #expect(session.visibleScreenshots.map(\.id) == ids)
        session.setUniqueScreens(true)
        #expect(session.visibleScreenshots.map(\.id) == [ids[0]])
        #expect(session.focusedScreenshotID == ids[0])
        #expect(session.selectedScreenshotIDs == [ids[0]])
    }

    @Test func followLatestDoesNotPinHistoricalSelectionsBeforeTheyBecomeRepeats() {
        let a = job("A", captures: [])
        a.setPreviewAnalysisRunning(true)
        let session = makeSession([a])
        let captures = [capture(0), capture(1), capture(2)]
        for capture in captures { a.screenshots.append(capture) }
        let ids = captures.map { id(a, $0.id) }
        #expect(session.focusedScreenshotID == ids[2])
        a.screenClassifications = Dictionary(uniqueKeysWithValues: captures.map { ($0.id, label(1, 1)) })
        #expect(session.visibleScreenshots.map(\.id) == [ids[0], ids[2]])
        #expect(session.selectedScreenshotIDs == [ids[2]])
        session.setUniqueScreens(true)
        #expect(session.visibleScreenshots.map(\.id) == [ids[0]])
    }

    @Test func headlessPublicationReconcilesPlaceholdersAndReadyIDs() {
        let state = capture(3).state
        let a = job("A", captures: [])
        a.setPreviewAnalysisRunning(true)
        let session = makeSession([a])
        a.detectedScreens = [state]
        let occurrence = id(a, state.id)
        #expect(session.occurrences.map(\.id) == [occurrence])
        session.selectScreenshot(occurrence, modifiers: [])
        session.selectAll()
        #expect(!session.canCopySelection)
        a.screenshots = [CapturedScreenshot(state: state, fileURL: URL(fileURLWithPath: "/tmp/ready.png"))]
        #expect(session.visibleScreenshots.map(\.id) == [occurrence])
        #expect(session.focusedScreenshotID == occurrence)
        #expect(session.selectedScreenshotIDs == [occurrence])
        #expect(session.canSaveSelection)
    }

    @Test(arguments: [false, true])
    func terminalErrorOrCancellationDropsUnwrittenPlaceholdersAndRetainsPartialPNGs(cancel: Bool) async {
        let runner = ControlledAnalysisRunner()
        let queue = VideoImportQueue(runner: runner.run)
        let session = makeSession(queue: queue)
        queue.enqueue([URL(fileURLWithPath: "/tmp/A.mov")])
        let a = queue.models[0]
        let run = await runner.waitForStart(a)
        let captures = [capture(0), capture(1)]
        run.publish { $0.detectedScreens = captures.map(\.state); $0.screenshots = [captures[1]] }
        let readyID = id(a, captures[1].id)
        session.selectScreenshot(readyID, modifiers: [])
        if cancel { a.cancel() }
        runner.finish(a, with: cancel ? .cancelled : .failed("failure"))
        await queue.waitUntilDrained()
        #expect(session.occurrences.map(\.id) == [readyID])
        #expect(session.focusedScreenshotID == readyID)
        #expect(session.selectedScreenshotIDs == [readyID])
        #expect(session.makeSelectionExportPlan().fileCount == 1)
    }

    @Test func reverseCompletionKeepsChronologyAndLateEarlierVideoCannotStealReview() async {
        let runner = ControlledAnalysisRunner()
        let queue = VideoImportQueue(runner: runner.run)
        let session = makeSession(queue: queue)
        queue.enqueue([URL(fileURLWithPath: "/tmp/A.mov"), URL(fileURLWithPath: "/tmp/B.mov")])
        let a = queue.models[0], b = queue.models[1]
        let runA = await runner.waitForStart(a), runB = await runner.waitForStart(b)
        let ca = capture(50), cb = capture(0)
        runB.publish { $0.screenshots = [cb] }
        runner.finish(b, with: .completed)
        runA.publish { $0.screenshots = [ca] }
        runner.finish(a, with: .completed)
        await queue.waitUntilDrained()
        #expect(session.screenshots.map(\.id) == [id(a, ca.id), id(b, cb.id)])
        #expect(session.focusedScreenshotID == id(b, cb.id))
        #expect(session.selectedScreenshotIDs == [id(b, cb.id)])
        session.selectAll()
        #expect(session.makeSelectionExportPlan() == .singleFolder([
            .init(sourceURL: ca.fileURL, screenName: String(localized: "Unidentified", bundle: .module)), .init(sourceURL: cb.fileURL, screenName: String(localized: "Unidentified", bundle: .module))]))
    }

    @Test func backgroundArrivalsKeepManualSelectionAndReadyExportWhileAnalysisRuns() {
        let a = job("A", captures: [capture(0)])
        let b = job("B", captures: [])
        b.setPreviewAnalysisRunning(true)
        let session = makeSession([a, b])
        let selected = session.screenshots[0].id
        session.selectScreenshot(selected, modifiers: [])
        b.detectedScreens = [capture(1).state]
        b.screenshots = [capture(2)]
        #expect(session.focusedScreenshotID == selected && session.selectedScreenshotIDs == [selected])
        #expect(session.isAnalyzing && session.canSaveSelection)
        #expect(session.makeSelectionExportPlan().fileCount == 1)
    }

    @Test func globalRangesCommandAndArrowsUseVisibleTimelineButDragUsesChronology() {
        let a = job("A", captures: [capture(0), capture(1)], labels: [label(1, 1), label(2, 2)])
        let b = job("B", captures: [capture(0), capture(1)], labels: [label(1, 1), label(2, 2)])
        let session = makeSession([a, b])
        let ids = session.screenshots.map(\.id)
        session.setUniqueScreens(false)
        session.selectScreenshot(ids[1], modifiers: [])
        session.selectScreenshot(ids[3], modifiers: .shift)
        #expect(session.selectedScreenshotIDs == [ids[1], ids[2], ids[3]])
        session.selectScreenshot(ids[0], modifiers: .command)
        #expect(session.fanSelectedScreenshots.map(\.id) == [ids[1], ids[2], ids[3], ids[0]])
        #expect(session.dragURLs(startingAt: ids[3]) == session.screenshots.map(\.fileURL))
        session.moveFocus(by: 1)
        #expect(session.focusedScreenshotID == ids[2])
        session.selectScreenshot(ids[0], modifiers: [])
        session.moveFocus(by: 1, modifiers: .shift)
        session.moveFocus(by: 1, modifiers: .shift)
        #expect(session.selectedScreenshotIDs == [ids[0], ids[1], ids[2]])
        #expect(session.focusedScreenshotID == ids[2])
        session.selectAll()
        #expect(session.selectedScreenshotIDs == Set(ids))
        session.selectScreenshot(ids[0], modifiers: [])
        session.moveFocus(by: 1, modifiers: [.command, .shift])
        #expect(session.selectedScreenshotIDs == Set(ids) && session.focusedScreenshotID == ids[3])
        session.moveFocus(by: -1, modifiers: .command)
        #expect(session.focusedScreenshotID == ids[0])
    }

    @Test func staleCatalogAndRefinementSnapshotsCannotPublishOrMutateFiles() {
        let a = job("A", captures: [capture(0)], labels: [label(1, 1)])
        let session = makeSession([a])
        let old = session.catalogSnapshot
        let url = a.screenshots[0].fileURL
        a.screenshots = [CapturedScreenshot(state: a.screenshots[0].state, fileURL: url.appendingPathExtension("changed"))]
        #expect(!session.applyCatalog([label(9, 1, "Stale")], snapshot: old, refined: true))
        #expect(session.screenshots[0].classification?.name == "Compte")
        #expect(!session.applyCatalog([label(9, 99)], snapshot: session.catalogSnapshot, refined: false))
        #expect(session.applyCatalog([label(9, 1, "Profil")], snapshot: session.catalogSnapshot, refined: true))
        #expect(session.screenshots[0].classification?.name == "Profil")
        #expect(a.screenClassifications[a.screenshots[0].id]?.name == "Compte")
        #expect(a.screenshots[0].fileURL == url.appendingPathExtension("changed"))
    }

    @Test func refinementEvidenceSurvivesEarlierCompletionAndAutomaticAppendWithoutIntegerAliasing() {
        let a = job("A", captures: [])
        a.setPreviewAnalysisRunning(true)
        let b = job("B", captures: [capture(0), capture(1)], labels: [label(1, 1), label(1, 2)])
        let session = makeSession([a, b])
        let bIDs = session.screenshots.map(\.id)
        #expect(session.applyCatalog([label(7, 1, "Profil"), label(7, 1, "Profil")], snapshot: session.catalogSnapshot, refined: true))
        a.screenshots = [capture(0)]
        a.setPreviewAnalysisRunning(false)
        let aID = session.screenshots[0].id
        #expect(session.applyCatalog([label(1, 1), label(2, 2), label(3, 3)], snapshot: session.catalogSnapshot, refined: false))
        session.setUniqueScreens(true)
        #expect(session.visibleScreenshots.map(\.id) == [aID, bIDs[0]])
        #expect(session.timelineScreenGroups.map(\.name) == [String(localized: "Unidentified", bundle: .module), "Profil"])
        #expect(session.timelineScreenGroups.count == 2)
        #expect(b.screenClassifications.values.allSatisfy { $0.name == "Compte" })
    }

    @Test func frozenExportUsesOriginalBytesOrderingAndSeparateSameNameFolders() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let urls = try (0..<3).map { index in
            let url = directory.appendingPathComponent("source-\(index).png")
            try Data([UInt8(index), 255]).write(to: url)
            return url
        }
        let a = job("A", captures: [capture(8, url: urls[0]), capture(9, url: urls[1])], labels: [label(1, 1), label(2, 2)])
        let b = job("B", captures: [capture(0, url: urls[2])], labels: [label(1, 1)])
        let preferences = preferences()
        let session = makeSession([a, b], preferences: preferences)
        session.setUniqueScreens(false)
        session.setTimelineGrouping(true)
        preferences.screenExportLayout = .folders
        session.selectAll()
        let plan = session.makeSelectionExportPlan()
        #expect(plan == .screenFolders([
            .init(screenName: "Compte", sourceURLs: [urls[0]]), .init(screenName: "Compte", sourceURLs: [urls[1]]),
            .init(screenName: "Compte", sourceURLs: [urls[2]])]))
        session.imports.enqueue([URL(fileURLWithPath: "/tmp/unsupported.txt")])
        preferences.screenExportLayout = .singleFolder
        #expect(session.applyCatalog([label(9, 1, "Nouveau"), label(9, 2, "Nouveau"), label(9, 3, "Nouveau")],
            snapshot: session.catalogSnapshot, refined: true))
        let output = directory.appendingPathComponent("output")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let copied = try await ScreenshotExporter.copy(plan: plan, to: output)
        #expect(copied.map { $0.deletingLastPathComponent().lastPathComponent } == ["001_compte", "002_compte", "003_compte"])
        #expect(try copied.map { try Data(contentsOf: $0) } == [Data([0, 255]), Data([1, 255]), Data([2, 255])])
        #expect(a.screenshots.map(\.fileURL) == Array(urls.prefix(2)))
    }

    @Test func realSessionCatalogMatchesIdenticalPNGsAtDifferentPaths() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try renderPNG(directory, name: "first", variation: false)
        let second = directory.appendingPathComponent("second.png")
        try FileManager.default.copyItem(at: first, to: second)
        let a = job("A", captures: [capture(0, url: first)], labels: [label(1, 1)])
        let b = job("B", captures: [capture(0, url: second)], labels: [label(1, 1)])
        let session = SessionModel(preferences: preferences(), imports: VideoImportQueue(models: [a, b]))
        await session.waitForCatalog()
        session.setUniqueScreens(true)
        #expect(session.visibleScreenshots.map(\.id) == [id(a, a.screenshots[0].id)])
        #expect(session.timelineScreenGroups.count == 1)
        session.setUniqueScreens(false)
        #expect(session.screenshots.count == 2 && session.visibleScreenshots.count == 2)
        #expect(session.screenshots.map(\.fileURL) == [first, second])
    }

    @Test(.disabled(if: isVirtualMachine, "Requires a physical Mac")) func realLocalCatalogMatchesNonidenticalPNGsWithoutFoundationModels() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try renderPNG(directory, name: "first", variation: false)
        let second = try renderPNG(directory, name: "second", variation: true)
        #expect(try Data(contentsOf: first) != Data(contentsOf: second))
        let a = job("A", captures: [capture(0, url: first)], labels: [label(1, 1)])
        let b = job("B", captures: [capture(0, url: second)], labels: [label(1, 1)])
        let session = SessionModel(preferences: preferences(), imports: VideoImportQueue(models: [a, b]))
        await session.waitForCatalog()
        session.setUniqueScreens(true)
        #expect(session.visibleScreenshots.map(\.id) == [id(a, a.screenshots[0].id)])
        #expect(session.timelineScreenGroups.count == 1)
    }

    @Test func realCatalogKeepsChangedValuesAndUnknownImagesSeparateDespiteLocalNameAndIDCollisions() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try renderPNG(directory, name: "alice", variation: false)
        let second = try renderPNG(directory, name: "bob", variation: false, value: "Bob")
        let a = job("A", captures: [capture(0, url: first)], labels: [label(1, 1)])
        let b = job("B", captures: [capture(0, url: second)], labels: [label(1, 1)])
        let c = job("C", captures: [capture(0, url: directory.appendingPathComponent("missing.png"))])
        let session = SessionModel(preferences: preferences(), imports: VideoImportQueue(models: [a, b, c]))
        await session.waitForCatalog()
        session.setUniqueScreens(true)
        #expect(session.visibleScreenshots.map(\.id) == [id(a, a.screenshots[0].id), id(b, b.screenshots[0].id), id(c, c.screenshots[0].id)])
        #expect(session.timelineScreenGroups.count == 3)
        #expect(session.notice == nil)
        session.setUniqueScreens(false)
        #expect(session.visibleScreenshots.count == 3)
    }

    @Test func frozenPlanSurvivesQueuedRemovalAndImportOrdinalsNeverRenumber() async {
        let runner = ControlledAnalysisRunner()
        let queue = VideoImportQueue(runner: runner.run)
        let session = makeSession(queue: queue)
        queue.enqueue([URL(fileURLWithPath: "/tmp/A.mov"), URL(fileURLWithPath: "/tmp/B.mov"), URL(fileURLWithPath: "/tmp/C.mov")])
        let a = queue.models[0], b = queue.models[1], queued = queue.models[2]
        let runA = await runner.waitForStart(a), runB = await runner.waitForStart(b)
        let ca = capture(3), cb = capture(0)
        runA.publish { $0.screenshots = [ca] }
        runB.publish { $0.screenshots = [cb] }
        session.selectAll()
        let plan = session.makeSelectionExportPlan()
        queue.remove(queued)
        queue.enqueue([URL(fileURLWithPath: "/tmp/invalid.txt")])
        #expect(queue.models.map(\.importOrdinal) == [1, 2, 4])
        #expect(session.makeSelectionExportPlan() == plan)
        #expect(plan == .singleFolder([.init(sourceURL: ca.fileURL, screenName: String(localized: "Unidentified", bundle: .module)),
            .init(sourceURL: cb.fileURL, screenName: String(localized: "Unidentified", bundle: .module))]))
        runner.finish(a, with: .completed)
        runner.finish(b, with: .completed)
        await queue.waitUntilDrained()
        #expect(session.selectedScreenshotIDs == [id(a, ca.id), id(b, cb.id)])
    }

    @Test func catalogCancellationDrainsBeforeNewestSnapshotAndRefinementStarts() async {
        let runner = ControlledCatalogRunner()
        let a = job("A", captures: [capture(0)])
        let session = SessionModel(preferences: preferences(), imports: VideoImportQueue(models: [a]), catalogRunner: runner.run)
        await runner.waitForStart(0)
        a.screenshots.append(capture(1))
        a.screenshots.append(capture(2))
        session.refineScreens()
        #expect(runner.runs.count == 1)
        #expect(session.catalogDetail != nil && session.refinementDetail == nil)
        runner.finish(0, labels: [label(1, 1, "Stale")])
        await runner.waitForStart(1)
        #expect(runner.runs[1].urls == a.screenshots.map(\.fileURL))
        #expect(runner.runs[1].refined)
        #expect(session.catalogDetail == nil && session.refinementDetail != nil)
        runner.finish(1, labels: [label(1, 1, "Profil"), label(1, 2, "Profil"), label(1, 3, "Profil")])
        await session.waitForCatalog()
        #expect(runner.maxActive == 1)
        #expect(session.refinementDetail == nil && session.catalogDetail == nil)
        #expect(session.screenshots.allSatisfy { $0.classification?.name == "Profil" })
    }

    @Test func cancelledRefinementKeepsLastCompleteMetadataAndExportUsable() async {
        let runner = ControlledCatalogRunner()
        let a = job("A", captures: [capture(0)], labels: [label(1, 1)])
        let session = SessionModel(preferences: preferences(), imports: VideoImportQueue(models: [a]), catalogRunner: runner.run)
        await runner.waitForStart(0)
        runner.finish(0, labels: [label(1, 1)])
        await session.waitForCatalog()
        session.refineScreens()
        await runner.waitForStart(1)
        #expect(session.canSaveSelection && session.refinementDetail != nil)
        session.cancelRefinement()
        runner.finish(1, labels: [label(9, 1, "Stale")])
        await session.waitForCatalog()
        #expect(session.screenshots[0].classification?.name == "Compte")
        #expect(session.canSaveSelection && session.refinementDetail == nil)
    }

    @Test(arguments: [false, true]) func cancellingEarlyRefinementRestartsAutomaticGrouping(afterRefinementStarts: Bool) async {
        let runner = ControlledCatalogRunner()
        let a = job("A", captures: [capture(0)])
        let b = job("B", captures: [capture(0)])
        let session = SessionModel(preferences: preferences(), imports: VideoImportQueue(models: [a, b]), catalogRunner: runner.run)
        await runner.waitForStart(0)
        session.refineScreens()
        if afterRefinementStarts {
            runner.finish(0, labels: [label(1, 1), label(1, 1)])
            await runner.waitForStart(1)
            #expect(runner.runs[1].refined)
        }
        session.cancelRefinement()
        runner.finish(afterRefinementStarts ? 1 : 0, labels: [label(1, 1), label(1, 1)])
        let automaticIndex = afterRefinementStarts ? 2 : 1
        await runner.waitForStart(automaticIndex)
        #expect(!runner.runs[automaticIndex].refined)
        runner.finish(automaticIndex, labels: [label(1, 1), label(1, 1)])
        await session.waitForCatalog()
        #expect(session.timelineScreenGroups.count == 1)
        #expect(runner.maxActive == 1)
    }

    @Test func originalPNGAspectRatioSurvivesFileRemoval() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try renderPNG(directory, name: "original", variation: false)
        let a = job("Landscape", captures: [capture(0, url: url)])
        a.setAnalysisPreviewFrames([Frame(timestamp: 0, width: 1920, height: 1080, luma: Data())])
        try FileManager.default.removeItem(at: url)
        let session = makeSession([a])

        #expect(session.occurrences[0].aspectRatio == CGFloat(400) / CGFloat(600))
    }

    @Test func missingPNGsUseTheirOwnVideoAspectRatio() {
        let a = job("Landscape", captures: [capture(0)])
        let b = job("Portrait", captures: [capture(0)])
        a.setAnalysisPreviewFrames([Frame(timestamp: 0, width: 1920, height: 1080, luma: Data())])
        b.setAnalysisPreviewFrames([Frame(timestamp: 0, width: 1080, height: 1920, luma: Data())])
        let session = makeSession([a, b])
        #expect(session.occurrences[0].aspectRatio == CGFloat(1920) / CGFloat(1080))
        #expect(session.occurrences[1].aspectRatio == CGFloat(1080) / CGFloat(1920))
    }

    @Test func presentationUpdatesDoNotInvalidateStructureButCaptureArrivalDoes() {
        let first = capture(0), second = capture(1)
        let a = job("A", captures: [first])
        a.setPreviewAnalysisRunning(true)
        a.setAnalysisPreviewFrames([Frame(timestamp: 0, width: 1920, height: 1080, luma: Data())])
        let session = makeSession([a])
        let builds = session.projectionBuildCount
        let structureChanges = Mutex(0), countChanges = Mutex(0), previewChanges = Mutex(0), progressChanges = Mutex(0)
        withObservationTracking {
            _ = session.occurrences.map(\.id)
            _ = session.timelineScreenGroups.map(\.id)
            _ = session.catalogSnapshot
            _ = session.visibleOccurrences.map(\.id)
        } onChange: { structureChanges.withLock { $0 += 1 } }
        withObservationTracking { _ = session.visibleCaptureCount } onChange: { countChanges.withLock { $0 += 1 } }
        withObservationTracking { _ = a.analysisPreviewFrames } onChange: { previewChanges.withLock { $0 += 1 } }
        withObservationTracking { _ = a.progress } onChange: { progressChanges.withLock { $0 += 1 } }
        for index in 1...20 {
            a.progress = AnalysisProgress(stage: .decoding, fraction: Double(index) / 20, detail: "Progress \(index)")
            a.setAnalysisPreviewFrames([Frame(timestamp: Double(index), width: 1920, height: 1080, luma: Data([UInt8(index)]))])
        }
        #expect(structureChanges.withLock { $0 } == 0)
        #expect(countChanges.withLock { $0 } == 0)
        #expect(previewChanges.withLock { $0 } == 1)
        #expect(progressChanges.withLock { $0 } == 1)
        #expect(session.projectionBuildCount == builds)
        #expect(session.occurrences.map(\.id) == [id(a, first.id)])
        #expect(session.occurrences.map(\.aspectRatio) == [CGFloat(16) / 9])
        #expect(session.focusedScreenshotID == id(a, first.id))
        #expect(session.selectedScreenshots.map(\.fileURL) == [first.fileURL])
        a.screenshots.append(second)
        #expect(structureChanges.withLock { $0 } == 1)
        #expect(countChanges.withLock { $0 } == 1)
        #expect(session.projectionBuildCount == builds + 1)
        #expect(session.visibleScreenshots.map(\.id) == [id(a, first.id), id(a, second.id)])
        #expect(session.focusedScreenshotID == id(a, second.id))
        #expect(session.makeSelectionExportPlan() == .singleFolder([.init(sourceURL: second.fileURL, screenName: String(localized: "Unidentified", bundle: .module))]))
    }

    @Test func sourceGeometryChangesPublishOnceAndEmptyOrInvalidFramesRestoreFallback() {
        let ready = capture(0), pending = capture(1)
        let a = job("A", captures: [ready])
        a.setPreviewAnalysisRunning(true)
        a.detectedScreens = [ready.state, pending.state]
        let session = makeSession([a])
        let builds = session.projectionBuildCount
        let countChanges = Mutex(0), structureChanges = Mutex(0)
        withObservationTracking { _ = session.visibleCaptureCount } onChange: { countChanges.withLock { $0 += 1 } }
        withObservationTracking { _ = session.occurrences } onChange: { structureChanges.withLock { $0 += 1 } }
        a.setAnalysisPreviewFrames([Frame(timestamp: 0, width: 0, height: 100, luma: Data()),
            Frame(timestamp: 1, width: 1080, height: 1920, luma: Data())])
        #expect(session.projectionBuildCount == builds + 1)
        #expect(structureChanges.withLock { $0 } == 1)
        #expect(countChanges.withLock { $0 } == 0)
        #expect(session.occurrences.map(\.id) == [id(a, ready.id), id(a, pending.id)])
        #expect(session.occurrences.map(\.aspectRatio) == [CGFloat(9) / 16, CGFloat(9) / 16])
        a.setAnalysisPreviewFrames([])
        #expect(session.projectionBuildCount == builds + 2)
        #expect(session.occurrences.map(\.aspectRatio) == [CGFloat(9) / 19, CGFloat(9) / 19])
        a.setAnalysisPreviewFrames([Frame(timestamp: 2, width: 100, height: 0, luma: Data())])
        #expect(session.projectionBuildCount == builds + 2)
        #expect(session.occurrences.map(\.aspectRatio) == [CGFloat(9) / 19, CGFloat(9) / 19])
        #expect(session.visibleCaptureCount == 1)
        a.videoURL = URL(fileURLWithPath: "/tmp/new-source.mov")
        a.attempt = 2
        #expect(session.projectionBuildCount == builds + 4)
        #expect(session.occurrences.map(\.attempt) == [2, 2])
        #expect(session.occurrences.map(\.sourceURL) == [a.videoURL, a.videoURL])
    }

    @Test func reviewAndVisibilityCommandsReuseStructuralProjection() {
        let captures = [capture(0), capture(1), capture(2)]
        let a = job("A", captures: captures, labels: [label(1, 1), label(2, 2), label(1, 1)])
        let session = makeSession([a])
        session.setUniqueScreens(false)
        let builds = session.projectionBuildCount
        let changes = Mutex(0)
        withObservationTracking { _ = session.occurrences; _ = session.catalogSnapshot } onChange: { changes.withLock { $0 += 1 } }
        session.selectScreenshot(id(a, captures[1].id), modifiers: [])
        session.selectScreenshot(id(a, captures[2].id), modifiers: .shift)
        #expect(session.selectedScreenshots.map(\.fileURL) == [captures[1].fileURL, captures[2].fileURL])
        session.setTimelineGrouping(true)
        #expect(session.visibleScreenshots.map(\.id) == [id(a, captures[0].id), id(a, captures[2].id), id(a, captures[1].id)])
        session.setUniqueScreens(true)
        #expect(session.visibleScreenshots.map(\.id) == [id(a, captures[0].id), id(a, captures[1].id)])
        #expect(session.visibleCaptureCount == 2)
        #expect(session.selectedScreenshots.map(\.id) == [id(a, captures[1].id)])
        #expect(session.projectionBuildCount == builds)
        #expect(changes.withLock { $0 } == 0)
    }

    @Test(arguments: [false, true])
    func representativeInputInvalidationSplitsFamiliesWithoutErasingOwnRefinedLabel(remove: Bool) {
        let a = job("A", captures: [capture(0)], labels: [label(1, 1, "Local A")])
        let b = job("B", captures: [capture(0)], labels: [label(1, 1, "Local B")])
        let c = job("C", captures: [capture(0)], labels: [label(1, 1, "Local C")])
        let session = makeSession([a, b, c])
        let ids = session.screenshots.map(\.id)
        #expect(session.applyCatalog([label(1, 1), label(1, 1), label(3, 3)], snapshot: session.catalogSnapshot, refined: false))
        #expect(session.applyCatalog([label(1, 1, "Refined A"), label(2, 2, "Shared"), label(2, 2, "Shared")],
            snapshot: session.catalogSnapshot, refined: true))
        session.setUniqueScreens(false)
        #expect(session.timelineScreenGroups.map(\.id) == [ids[0]])
        #expect(session.timelineScreenGroups[0].occurrences.map(\.id) == ids)
        #expect(session.timelineScreenGroups[0].name == "Refined A")
        a.screenshots = [capture(0, id: ids[0].stateID, url: URL(fileURLWithPath: "/tmp/replaced-A.png"))]
        #expect(session.timelineScreenGroups.map(\.id) == [ids[0], ids[1]])
        #expect(session.timelineScreenGroups.map(\.name) == ["Local A", "Shared"])
        #expect(session.timelineScreenGroups.map { $0.occurrences.map(\.id) } == [[ids[0]], [ids[1], ids[2]]])
        if remove { b.screenshots = [] }
        else { b.screenshots = [capture(0, id: ids[1].stateID, url: URL(fileURLWithPath: "/tmp/replaced-B.png"))] }
        #expect(session.timelineScreenGroups.map(\.id) == (remove ? [ids[0], ids[2]] : ids))
        #expect(session.timelineScreenGroups.map(\.name) == (remove ? ["Local A", "Shared"] : ["Local A", "Local B", "Shared"]))
        #expect(session.occurrences.last?.classification?.name == "Shared")
        #expect(session.catalogSnapshot.inputs.last?.classification?.name == "Local C")
        session.setUniqueScreens(true)
        #expect(session.visibleScreenshots.map(\.id) == (remove ? [ids[0], ids[2]] : ids))
    }

    @Test func pendingAndTerminalTimestampTiesKeepTheirOwnSourceOrder() async {
        let runner = ControlledAnalysisRunner()
        let queue = VideoImportQueue(runner: runner.run)
        let session = makeSession(queue: queue)
        queue.enqueue([URL(fileURLWithPath: "/tmp/A.mov")])
        let a = queue.models[0]
        let run = await runner.waitForStart(a)
        let captures = [capture(0), capture(0), capture(0)]
        let ids = captures.map { id(a, $0.id) }
        run.publish {
            $0.detectedScreens = [captures[1].state, captures[0].state]
            $0.screenshots = [captures[0], captures[2], captures[1]]
        }
        #expect(session.occurrences.map(\.id) == [ids[1], ids[0], ids[2]])
        #expect(session.catalogSnapshot.inputs.isEmpty)
        runner.finish(a, with: .completed)
        await queue.waitUntilDrained()
        #expect(session.occurrences.map(\.id) == [ids[0], ids[2], ids[1]])
        #expect(session.catalogSnapshot.inputs.map(\.id) == [ids[0], ids[2], ids[1]])
    }

    private func makeSession(_ models: [AppModel], preferences: AppPreferences? = nil) -> SessionModel {
        SessionModel(preferences: preferences ?? self.preferences(), imports: VideoImportQueue(models: models), catalogRunner: { _, _, _ in SessionCatalogResult(classifications: []) })
    }
    private func makeSession(queue: VideoImportQueue) -> SessionModel {
        SessionModel(preferences: preferences(), imports: queue, catalogRunner: { _, _, _ in SessionCatalogResult(classifications: []) })
    }
    private func preferences() -> AppPreferences {
        AppPreferences(defaults: UserDefaults(suiteName: "StillsetSessionTests-\(UUID())")!)
    }
    private func label(_ screen: Int, _ state: Int, _ name: String = "Compte") -> ScreenClassification {
        ScreenClassification(screenID: screen, name: name, stateID: state)
    }
    private func id(_ job: AppModel, _ stateID: UUID) -> OccurrenceID { OccurrenceID(videoID: job.id, stateID: stateID) }
    private func capture(_ time: Double, id: UUID = UUID(), url: URL? = nil) -> CapturedScreenshot {
        CapturedScreenshot(state: UIState(id: id, interval: time..<(time + 1), representativeTimestamp: time, stabilityScore: 1),
            fileURL: url ?? URL(fileURLWithPath: "/tmp/\(id).png"))
    }
    private func job(_ name: String, captures: [CapturedScreenshot], labels: [ScreenClassification] = []) -> AppModel {
        let model = AppModel()
        model.videoURL = URL(fileURLWithPath: "/tmp/\(name).mov")
        model.screenshots = captures
        model.screenClassifications = Dictionary(uniqueKeysWithValues: zip(captures.map(\.id), labels))
        return model
    }
    private func renderPNG(_ directory: URL, name: String, variation: Bool, value: String = "Alice") throws -> URL {
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 400, pixelsHigh: 600,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let context = try #require(NSGraphicsContext(bitmapImageRep: bitmap))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: 400, height: 600).fill()
        for (index, text) in ["Compte", "Profil", "Nom", value, "Adresse", "Paris", "Enregistrer"].enumerated() {
            (text as NSString).draw(at: NSPoint(x: 40, y: 520 - index * 60), withAttributes: [
                .font: NSFont.systemFont(ofSize: index == 0 ? 30 : 24), .foregroundColor: NSColor.black])
        }
        if variation {
            NSColor(calibratedWhite: 0.98, alpha: 1).setFill()
            NSRect(x: 390, y: 590, width: 4, height: 4).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        let url = directory.appendingPathComponent("\(name).png")
        try data.write(to: url)
        return url
    }
}

@MainActor
private final class ControlledCatalogRunner {
    struct Run {
        let urls: [URL]
        let refined: Bool
        let continuation: CheckedContinuation<SessionCatalogResult, Error>
    }
    var runs: [Run] = []
    private var active = 0
    private(set) var maxActive = 0
    private var waiters: [Int: [CheckedContinuation<Void, Never>]] = [:]

    func run(_ urls: [URL], refined: Bool, progress: @escaping @Sendable (Double, String) async throws -> Void) async throws -> SessionCatalogResult {
        active += 1
        maxActive = max(maxActive, active)
        defer { active -= 1 }
        return try await withCheckedThrowingContinuation { continuation in
            let index = runs.count
            runs.append(Run(urls: urls, refined: refined, continuation: continuation))
            for waiter in waiters.removeValue(forKey: index) ?? [] { waiter.resume() }
        }
    }
    func waitForStart(_ index: Int) async {
        if runs.count > index { return }
        await withCheckedContinuation { waiters[index, default: []].append($0) }
    }
    func finish(_ index: Int, labels: [ScreenClassification]) {
        runs[index].continuation.resume(returning: SessionCatalogResult(classifications: labels))
    }
}
