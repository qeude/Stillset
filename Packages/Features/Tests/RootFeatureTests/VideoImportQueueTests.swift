import Foundation
import StillsetCore
import Testing
@testable import StillsetFeatures

@MainActor
struct VideoImportQueueTests {
    private func preferences() -> AppPreferences {
        let suite = "StillsetQueueTests-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return AppPreferences(defaults: defaults)
    }

    private func url(_ name: String) -> URL { URL(fileURLWithPath: "/tmp/\(name).mov") }

    @Test func droppedScreenshotsDoNotBecomeVideoJobs() async {
        let runner = ControlledAnalysisRunner()
        let queue = VideoImportQueue(runner: runner.run)
        let screenshots = (1...12).map { URL(fileURLWithPath: "/tmp/capture-\($0).png") }
        #expect(!queue.enqueueDroppedVideos(screenshots))
        #expect(queue.models.isEmpty)
        let video = URL(fileURLWithPath: "/tmp/workflow.MP4")
        #expect(queue.enqueueDroppedVideos(screenshots + [video, URL(string: "https://example.com/remote.mov")!]))
        let job = queue.models[0]
        await runner.waitForStart(job)
        #expect(queue.models.count == 1)
        #expect(job.videoURL == video)
        #expect(!queue.enqueueDroppedVideos(screenshots))
        #expect(queue.models.count == 1)
        runner.finish(job, with: .completed)
        await queue.waitUntilDrained()
    }

    @Test func closingSessionCancelsWorkWithoutStartingQueuedVideos() async {
        let runner = ControlledAnalysisRunner()
        let queue = VideoImportQueue(runner: runner.run)
        queue.enqueue([url("A"), url("B"), url("C")])
        let a = queue.models[0], b = queue.models[1], c = queue.models[2]
        _ = await runner.waitForStart(a)
        _ = await runner.waitForStart(b)
        queue.close()
        #expect(a.importState == .cancelling)
        #expect(b.importState == .cancelling)
        #expect(c.importState == .cancelled)
        #expect(!queue.enqueue([url("D")]))
        runner.finish(a, with: .cancelled)
        runner.finish(b, with: .cancelled)
        await queue.waitUntilDrained()
        #expect(queue.activeModelIDs.isEmpty)
        #expect(c.importState == .cancelled)
        #expect(!queue.canRetry(a))
    }

    @Test func classificationAndURLReplacementPublishOneCompleteGeneration() async {
        let runner = ControlledAnalysisRunner()
        let queue = VideoImportQueue(runner: runner.run)
        let session = SessionModel(preferences: preferences(), imports: queue,
            catalogRunner: { _, _, _ in SessionCatalogResult(classifications: []) })
        queue.enqueue([url("A")])
        let a = queue.models[0]
        let run = await runner.waitForStart(a)
        let state = UIState(interval: 0..<1, representativeTimestamp: 0, stabilityScore: 1)
        let original = CapturedScreenshot(state: state, fileURL: URL(fileURLWithPath: "/tmp/original.png"))
        let renamed = CapturedScreenshot(state: state, fileURL: URL(fileURLWithPath: "/tmp/renamed.png"))
        run.publish { $0.screenshots = [original] }
        let builds = session.projectionBuildCount
        var publishedURLs: [[URL]] = []
        var publishedNames: [[String]] = []
        let publication = a.onPublication
        a.onPublication = {
            publication?()
            publishedURLs.append(session.occurrences.map(\.fileURL))
            publishedNames.append(session.occurrences.compactMap { $0.classification?.name })
        }
        run.publish {
            $0.screenClassifications = [state.id: ScreenClassification(screenID: 1, name: "Named", stateID: 1)]
            $0.screenshots = [renamed]
        }
        #expect(publishedURLs == [[renamed.fileURL]])
        #expect(publishedNames == [["Named"]])
        #expect(session.projectionBuildCount == builds + 1)
        #expect(session.selectedScreenshots.map(\.fileURL) == [renamed.fileURL])
        #expect(session.makeSelectionExportPlan() == .singleFolder([.init(sourceURL: renamed.fileURL, screenName: "Named")]))
        runner.finish(a, with: .completed)
        await queue.waitUntilDrained()
        #expect(session.projectionBuildCount == builds + 2)
        #expect(publishedURLs == [[renamed.fileURL], [renamed.fileURL]])
        a.onPublication = publication
    }

    @Test func cancellingRecoveryAppendsAndSortsAtomicallyWithTokenOnlyGuard() async {
        let runner = ControlledAnalysisRunner()
        let queue = VideoImportQueue(runner: runner.run)
        let session = SessionModel(preferences: preferences(), imports: queue,
            catalogRunner: { _, _, _ in SessionCatalogResult(classifications: []) })
        queue.enqueue([url("A")])
        let a = queue.models[0]
        let run = await runner.waitForStart(a)
        let early = CapturedScreenshot(state: UIState(interval: 0..<1, representativeTimestamp: 0, stabilityScore: 1),
            fileURL: URL(fileURLWithPath: "/tmp/recovered-early.png"))
        let late = CapturedScreenshot(state: UIState(interval: 2..<3, representativeTimestamp: 2, stabilityScore: 1),
            fileURL: URL(fileURLWithPath: "/tmp/recovered-late.png"))
        run.publish { $0.screenshots = [late] }
        a.cancel()
        let builds = session.projectionBuildCount
        var generations: [[UUID]] = []
        let publication = a.onPublication
        a.onPublication = { publication?(); generations.append(a.screenshots.map(\.id)) }
        a.retainPartialCaptures([early], folder: nil, token: UUID())
        run.publish { $0.screenshots = [] }
        #expect(generations.isEmpty)
        #expect(session.projectionBuildCount == builds)
        a.retainPartialCaptures([early, late], folder: nil, token: run.token)
        #expect(generations == [[early.id, late.id]])
        #expect(session.projectionBuildCount == builds + 1)
        #expect(session.screenshots.map(\.id) == [OccurrenceID(videoID: a.id, stateID: early.id), OccurrenceID(videoID: a.id, stateID: late.id)])
        #expect(session.focusedScreenshotID == OccurrenceID(videoID: a.id, stateID: late.id))
        runner.finish(a, with: .cancelled)
        await queue.waitUntilDrained()
        #expect(session.projectionBuildCount == builds + 2)
        #expect(session.catalogSnapshot.inputs.map(\.fileURL) == [early.fileURL, late.fileURL])
        a.retainPartialCaptures([], folder: nil, token: run.token)
        #expect(session.projectionBuildCount == builds + 2)
        a.onPublication = publication
    }

    @Test func batchAdmissionPublishesMembershipOnceAndEmptyAdmissionDoesNotPublish() async {
        let runner = ControlledAnalysisRunner()
        let queue = VideoImportQueue(runner: runner.run)
        var membership: [[Int]] = []
        queue.onPublication = { membership.append(queue.models.map(\.importOrdinal)) }
        #expect(!queue.enqueue([]))
        #expect(membership.isEmpty)
        queue.enqueue([url("A"), url("B"), url("C")])
        #expect(membership == [[1, 2, 3], [1, 2, 3], [1, 2, 3]])
        let a = queue.models[0], b = queue.models[1], c = queue.models[2]
        _ = await runner.waitForStart(a)
        _ = await runner.waitForStart(b)
        runner.finish(b, with: .completed)
        _ = await runner.waitForStart(c)
        #expect(queue.activeModelIDs == [a.id, c.id])
        #expect(membership.count == 5)
        runner.finish(a, with: .completed)
        runner.finish(c, with: .completed)
        await queue.waitUntilDrained()
        #expect(membership.count == 7)
    }

    @Test func reanalysisKeepsPriorAttemptAndBypassesCacheOnlyOnceWhilePending() async {
        let runner = ControlledAnalysisRunner()
        let queue = VideoImportQueue(runner: runner.run)
        queue.enqueue([url("A")])
        let original = queue.models[0]
        await runner.waitForStart(original)
        runner.finish(original, with: .completed)
        await queue.waitUntilDrained()
        #expect(queue.canReanalyze(original))
        queue.reanalyze(original)
        queue.reanalyze(original)
        #expect(queue.models.count == 2)
        #expect(queue.models[0].id == original.id && original.importState == .completed)
        let fresh = queue.models[1]
        #expect(!fresh.reuseCachedAnalysis && fresh.attempt == 2)
        #expect(!queue.canReanalyze(original))
        await runner.waitForStart(fresh)
        runner.finish(fresh, with: .completed)
        await queue.waitUntilDrained()
    }

    @Test(.timeLimit(.minutes(1))) func secondCompletionStartsThirdWhileFirstStillRuns() async {
        let runner = ControlledAnalysisRunner()
        let queue = VideoImportQueue(runner: runner.run)
        queue.enqueue([url("A"), url("B"), url("C")])
        let (a, b, c) = (queue.models[0], queue.models[1], queue.models[2])
        #expect(queue.models.map(\.importState) == [.running, .running, .queued])
        #expect(queue.activeModelIDs == [a.id, b.id])
        await runner.waitForStart(a)
        await runner.waitForStart(b)
        #expect(a.isAnalyzing)
        #expect(c.importState == .queued)
        runner.finish(b, with: .completed)
        await runner.waitForStart(c)
        #expect(queue.models.map(\.importState) == [.running, .completed, .running])
        #expect(queue.activeModelIDs == [a.id, c.id])
        runner.finish(c, with: .completed)
        runner.finish(a, with: .completed)
        await queue.waitUntilDrained()
        #expect(queue.models.map(\.importState) == [.completed, .completed, .completed])
        #expect(queue.models.map(\.importOrdinal) == [1, 2, 3])
        #expect(queue.activeModelIDs.isEmpty)
    }

    @Test(.timeLimit(.minutes(1))) func immediateCancellationReachesUnderlyingAnalysisTask() async {
        let gate = AnalysisBarrier()
        let queue = VideoImportQueue { _, _, _ in
            await gate.wait()
            #expect(Task.isCancelled)
            return .cancelled
        }
        queue.enqueue([url("A")])
        let model = queue.models[0]
        model.cancel()
        gate.open()
        await queue.waitUntilDrained()
        #expect(model.importState == .cancelled)
        #expect(queue.activeModelIDs.isEmpty)
    }

    @Test(.timeLimit(.minutes(1))) func appendedVideoUsesVacantSlotImmediately() async {
        let runner = ControlledAnalysisRunner()
        let queue = VideoImportQueue(runner: runner.run)
        queue.enqueue([url("A")])
        let a = queue.models[0]
        await runner.waitForStart(a)
        queue.enqueue([url("B")])
        let b = queue.models[1]
        #expect(queue.models.map(\.importState) == [.running, .running])
        await runner.waitForStart(b)
        #expect(queue.activeModelIDs == [a.id, b.id])
        runner.finish(b, with: .completed)
        runner.finish(a, with: .completed)
        await queue.waitUntilDrained()
        #expect(queue.models.map(\.importState) == [.completed, .completed])
    }

    @Test(.timeLimit(.minutes(1))) func batchesAndRetriesAreAdmittedInFIFOOrder() async throws {
        let runner = ControlledAnalysisRunner()
        let queue = VideoImportQueue(runner: runner.run)
        queue.enqueue([url("A"), url("B"), url("C"), url("D")])
        let (a, b, c, d) = (queue.models[0], queue.models[1], queue.models[2], queue.models[3])
        await runner.waitForStart(a)
        await runner.waitForStart(b)
        queue.enqueue([url("E"), url("F")])
        let (e, f) = (queue.models[4], queue.models[5])
        #expect(queue.models.map(\.importState) == [.running, .running, .queued, .queued, .queued, .queued])
        runner.finish(b, with: .failed("Unreadable B"))
        await runner.waitForStart(c)
        #expect(b.importState == .failed("Unreadable B"))
        queue.retry(b)
        let retry = try #require(queue.models.last)
        #expect(retry.displayName == String(localized: "\("B.mov") · attempt \(2)", bundle: .module))
        #expect(retry.importState == .queued)
        for (finished, next) in [(c, d), (d, e), (e, f), (f, retry)] {
            runner.finish(finished, with: .completed)
            await runner.waitForStart(next)
            #expect(queue.activeModelIDs == [a.id, next.id])
            #expect(a.importState == .running)
        }
        runner.finish(retry, with: .completed)
        runner.finish(a, with: .completed)
        await queue.waitUntilDrained()
        #expect(queue.models.map(\.importState) == [.completed, .failed("Unreadable B"), .completed, .completed,
                                                    .completed, .completed, .completed])
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func failureAndCancellationRetainPartialResultsAndOtherCompletionRefills(cancel: Bool) async {
        let runner = ControlledAnalysisRunner()
        let queue = VideoImportQueue(runner: runner.run)
        queue.enqueue([url("A"), url("B"), url("C"), url("D")])
        let (a, b, c, d) = (queue.models[0], queue.models[1], queue.models[2], queue.models[3])
        let runA = await runner.waitForStart(a)
        await runner.waitForStart(b)
        let capture = CapturedScreenshot(state: UIState(interval: 0..<1, representativeTimestamp: 0, stabilityScore: 1),
                                         fileURL: URL(fileURLWithPath: "/tmp/partial.png"))
        runA.publish { $0.screenshots = [capture] }
        if cancel {
            a.cancel()
            #expect(a.importState == .cancelling)
            runA.publish { $0.screenshots = []; $0.notice = "late" }
            #expect(a.screenshots.map(\.id) == [capture.id])
            #expect(a.notice == nil)
        }
        #expect(queue.activeModelIDs == [a.id, b.id])
        #expect(c.importState == .queued && d.importState == .queued)
        runner.finish(b, with: .completed)
        await runner.waitForStart(c)
        #expect(queue.activeModelIDs == [a.id, c.id])
        #expect(a.importState == (cancel ? .cancelling : .running))
        #expect(d.importState == .queued)
        runner.finish(a, with: cancel ? .completed : .failed("Unreadable A"))
        await runner.waitForStart(d)
        #expect(a.importState == (cancel ? .cancelled : .failed("Unreadable A")))
        #expect(a.screenshots.map(\.id) == [capture.id])
        a.errorMessage = nil
        if !cancel { #expect(a.importState.failure == "Unreadable A") }
        runA.publish { $0.notice = "stale terminal callback" }
        #expect(a.notice == nil)
        runner.finish(c, with: .completed)
        runner.finish(d, with: .completed)
        await queue.waitUntilDrained()
        #expect(queue.models.dropFirst().map(\.importState) == [.completed, .completed, .completed])
    }

    @Test(.timeLimit(.minutes(1))) func cancelledTerminalRetainsUnpublishedCapturesAndRejectsOldTokens() async {
        let runner = ControlledAnalysisRunner()
        let queue = VideoImportQueue(runner: runner.run)
        queue.enqueue([url("A")])
        let model = queue.models[0]
        let run = await runner.waitForStart(model)
        let capture = CapturedScreenshot(state: UIState(interval: 0..<1, representativeTimestamp: 0, stabilityScore: 1),
                                         fileURL: URL(fileURLWithPath: "/tmp/unpublished.png"))
        model.cancel()
        model.retainPartialCaptures([capture], folder: nil, token: UUID())
        #expect(model.screenshots.isEmpty)
        model.retainPartialCaptures([capture], folder: nil, token: run.token)
        runner.finish(model, with: .cancelled)
        await queue.waitUntilDrained()
        #expect(model.screenshots.map(\.id) == [capture.id])
        model.retainPartialCaptures([], folder: nil, token: run.token)
        run.publish { $0.errorMessage = "late failure" }
        #expect(model.errorMessage == nil)
        #expect(model.importState == .cancelled)
    }

    @Test(.timeLimit(.minutes(1))) func retryAppendsFreshLabelledSessionAndDeduplicatesPendingAttempts() async throws {
        let runner = ControlledAnalysisRunner()
        let queue = VideoImportQueue(runner: runner.run)
        queue.enqueue([url("A"), url("B"), url("C"), url("D")])
        let (a, b, c, d) = (queue.models[0], queue.models[1], queue.models[2], queue.models[3])
        let runA = await runner.waitForStart(a)
        await runner.waitForStart(b)
        let capture = CapturedScreenshot(state: UIState(interval: 0..<1, representativeTimestamp: 0, stabilityScore: 1),
                                         fileURL: URL(fileURLWithPath: "/tmp/retry-partial.png"))
        runA.publish { $0.screenshots = [capture] }
        runner.finish(a, with: .failed("Unreadable"))
        await runner.waitForStart(c)
        queue.retry(a)
        queue.retry(a)
        let retry = try #require(queue.models.last)
        #expect(queue.models.count == 5)
        #expect(retry.id != a.id)
        #expect(retry.displayName == String(localized: "\("A.mov") · attempt \(2)", bundle: .module))
        #expect(retry.importState == .queued)
        #expect(queue.canRetry(a) == false)
        #expect(a.importState == .failed("Unreadable"))
        #expect(a.screenshots.map(\.id) == [capture.id])
        #expect(retry.screenshots.isEmpty)
        runner.finish(b, with: .completed)
        await runner.waitForStart(d)
        #expect(retry.importState == .queued)
        runner.finish(c, with: .completed)
        await runner.waitForStart(retry)
        queue.retry(a)
        #expect(queue.models.count == 5)
        runA.publish { $0.notice = "old attempt" }
        #expect(a.notice == nil && retry.notice == nil)
        runner.finish(retry, with: .cancelled)
        runner.finish(d, with: .completed)
        await queue.waitUntilDrained()
        queue.retry(retry)
        let third = try #require(queue.models.last)
        await runner.waitForStart(third)
        #expect(third.displayName == String(localized: "\("A.mov") · attempt \(3)", bundle: .module))
        #expect(queue.canRetry(a) == false)
        runner.finish(third, with: .completed)
        await queue.waitUntilDrained()
        #expect(third.importState == .completed)
    }

    @Test(.timeLimit(.minutes(1))) func onlyQueuedRowsCanBeRemoved() async {
        let runner = ControlledAnalysisRunner()
        let queue = VideoImportQueue(runner: runner.run)
        queue.enqueue([url("A"), url("B"), url("C")])
        let (a, b, removed) = (queue.models[0], queue.models[1], queue.models[2])
        await runner.waitForStart(a)
        await runner.waitForStart(b)
        queue.remove(a)
        queue.remove(b)
        #expect(queue.models.count == 3)
        queue.remove(removed)
        #expect(queue.models.map(\.videoURL?.lastPathComponent) == ["A.mov", "B.mov"])
        runner.finish(b, with: .completed)
        runner.finish(a, with: .completed)
        await queue.waitUntilDrained()
        queue.remove(a)
        #expect(queue.models.count == 2)
        #expect(Set(runner.runs.keys) == [a.id, b.id])
        #expect(queue.models.map(\.importState) == [.completed, .completed])
    }

    @Test(.timeLimit(.minutes(1))) func mixedInvalidFilesRetainErrorsAndDoNotBlockValidVideos() async {
        let runner = ControlledAnalysisRunner()
        let queue = VideoImportQueue(runner: runner.run)
        #expect(queue.enqueue([]) == false)
        #expect(queue.enqueue([url("A"), URL(fileURLWithPath: "/tmp/invalid.txt"), url("B")]))
        let (a, invalid, b) = (queue.models[0], queue.models[1], queue.models[2])
        await runner.waitForStart(a)
        await runner.waitForStart(b)
        #expect(invalid.importState.failure == String(localized: "Choose a local MOV or MP4 recording.", bundle: .module))
        #expect(queue.activeModelIDs == [a.id, b.id])
        invalid.errorMessage = nil
        runner.finish(b, with: .completed)
        runner.finish(a, with: .completed)
        await queue.waitUntilDrained()
        #expect(queue.models.map(\.importState) == [.completed, .failed(String(localized: "Choose a local MOV or MP4 recording.", bundle: .module)), .completed])
    }

    @Test(.timeLimit(.minutes(1))) func drainIncludesAppendedWorkAndQueueCanBeReused() async {
        let runner = ControlledAnalysisRunner()
        let queue = VideoImportQueue(runner: runner.run)
        queue.enqueue([url("A")])
        let a = queue.models[0]
        await runner.waitForStart(a)
        let enteredDrain = AnalysisBarrier()
        let drain = Task {
            enteredDrain.open()
            await queue.waitUntilDrained()
            #expect(queue.models.map(\.importState) == [.completed, .completed, .completed])
            #expect(queue.activeModelIDs.isEmpty)
        }
        await enteredDrain.wait()
        queue.enqueue([url("B"), url("C")])
        let (b, c) = (queue.models[1], queue.models[2])
        await runner.waitForStart(b)
        #expect(c.importState == .queued)
        runner.finish(a, with: .completed)
        await runner.waitForStart(c)
        runner.finish(b, with: .completed)
        runner.finish(c, with: .completed)
        await drain.value
        queue.enqueue([url("D"), url("E"), url("F")])
        let (d, e, f) = (queue.models[3], queue.models[4], queue.models[5])
        #expect(queue.models.suffix(3).map(\.importState) == [.running, .running, .queued])
        await runner.waitForStart(d)
        await runner.waitForStart(e)
        runner.finish(e, with: .completed)
        await runner.waitForStart(f)
        runner.finish(d, with: .completed)
        runner.finish(f, with: .completed)
        await queue.waitUntilDrained()
        #expect(queue.models.map(\.importState) == Array(repeating: .completed, count: 6))
        #expect(queue.activeModelIDs.isEmpty)
    }

    @Test(.timeLimit(.minutes(1))) func drainIncludesRetryAdmittedBeforeQuiescence() async throws {
        let runner = ControlledAnalysisRunner()
        let queue = VideoImportQueue(runner: runner.run)
        queue.enqueue([url("A"), url("B"), url("C")])
        let (a, b, c) = (queue.models[0], queue.models[1], queue.models[2])
        await runner.waitForStart(a)
        await runner.waitForStart(b)
        let enteredDrain = AnalysisBarrier()
        let drain = Task {
            enteredDrain.open()
            await queue.waitUntilDrained()
            #expect(queue.models.map(\.importState) == [.completed, .failed("Unreadable B"), .completed, .completed])
            #expect(queue.activeModelIDs.isEmpty)
        }
        await enteredDrain.wait()
        runner.finish(b, with: .failed("Unreadable B"))
        await runner.waitForStart(c)
        queue.retry(b)
        let retry = try #require(queue.models.last)
        #expect(retry.importState == .queued)
        runner.finish(a, with: .completed)
        await runner.waitForStart(retry)
        runner.finish(c, with: .completed)
        runner.finish(retry, with: .completed)
        await drain.value
        #expect(retry.displayName == String(localized: "\("B.mov") · attempt \(2)", bundle: .module))
    }

    @Test func partialRecoveryFindsValidOriginalPNGsInOccurrenceOrder() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let png = try #require(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Wl6cX0AAAAASUVORK5CYII="))
        let first = folder.appendingPathComponent("001_00-00-000.png")
        let third = folder.appendingPathComponent("003_00-02-000.png")
        try png.write(to: third)
        try png.write(to: first)
        try png.write(to: folder.appendingPathComponent("001_named-copy.png"))
        try Data("unfinished".utf8).write(to: folder.appendingPathComponent("002_00-01-000.png"))
        let states = (0..<4).map {
            UIState(interval: Double($0)..<Double($0 + 1), representativeTimestamp: Double($0), stabilityScore: 1)
        }
        let captures = try await AppModel.recoverWrittenCaptures(states: states, folder: folder)
        #expect(captures.map(\.id) == [states[0].id, states[2].id])
        #expect(captures.map { $0.fileURL.resolvingSymlinksInPath() } == [first, third].map { $0.resolvingSymlinksInPath() })
        #expect(try Data(contentsOf: first) == png)
    }

    @Test(.timeLimit(.minutes(1))) func realRunnerRetainsEachMissingVideoFailureAndContinues() async {
        let queue = VideoImportQueue()
        queue.enqueue([url("Stillset-missing-\(UUID())"), url("Stillset-missing-\(UUID())"), url("Stillset-missing-\(UUID())")])
        await queue.waitUntilDrained()
        #expect(queue.models.count == 3)
        #expect(queue.models.allSatisfy { $0.importState.failure != nil && !$0.isWorking })
        #expect(queue.activeModelIDs.isEmpty)
    }
}

@MainActor
final class ControlledAnalysisRunner {
    struct Run {
        let model: AppModel
        let token: UUID
        let url: URL
        let completion: CheckedContinuation<VideoImportState, Never>

        @MainActor func publish(_ update: (AppModel) -> Void) { model.updateAnalysis(token: token, update) }
    }

    private(set) var runs: [UUID: Run] = [:]
    private var startWaiters: [UUID: [CheckedContinuation<Void, Never>]] = [:]

    func run(model: AppModel, token: UUID, url: URL) async -> VideoImportState {
        await withCheckedContinuation { completion in
            runs[model.id] = Run(model: model, token: token, url: url, completion: completion)
            for waiter in startWaiters.removeValue(forKey: model.id) ?? [] { waiter.resume() }
        }
    }

    @discardableResult
    func waitForStart(_ model: AppModel) async -> Run {
        if let run = runs[model.id] { return run }
        await withCheckedContinuation { startWaiters[model.id, default: []].append($0) }
        return runs[model.id]!
    }

    func finish(_ model: AppModel, with outcome: VideoImportState) {
        runs[model.id]!.completion.resume(returning: outcome)
    }
}

@MainActor
private final class AnalysisBarrier {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func open() {
        isOpen = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}
