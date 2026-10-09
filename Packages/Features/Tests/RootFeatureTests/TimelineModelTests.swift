import AppKit
import Observation
import StillsetCore
import Testing
@testable import StillsetFeatures

@MainActor
struct TimelineModelTests {
    @Test func endpointsShiftAndSubsetNavigationProduceExactlyOneFreshRequest() {
        let model = RenderFixture.session()
        let ids = model.screenshots.map(\.id)
        let revision = model.timelineRenderPlan.revision
        model.selectScreenshot(ids[0], modifiers: [])
        #expect(model.timelineRevealRequest == nil)
        let count = model.timelineRevealCount
        model.moveFocus(by: -1)
        let first = model.timelineRevealRequest
        #expect(first?.target == ids[0] && first?.cause == .navigation)
        #expect(model.timelineRevealCount == count + 1)
        model.moveFocus(by: -1)
        #expect(model.timelineRevealRequest?.id != first?.id)
        #expect(model.timelineRevealCount == count + 2)
        model.moveFocus(by: 1, modifiers: [.shift, .command])
        #expect(model.timelineRevealCount == count + 3)
        #expect(model.timelineRevealRequest?.target == ids[4])
        #expect(model.focusedScreenshotID == ids[4])
        #expect(model.selectedScreenshotOrder == ids)
        #expect(model.dragURLs(startingAt: ids[4]).map(\.path) == ["/literal-0.png", "/literal-1.png", "/literal-2.png", "/literal-3.png", "/literal-4.png"])
        let farRequest = model.timelineRevealRequest
        model.moveFocus(by: 1, modifiers: [.shift, .command])
        #expect(model.timelineRevealCount == count + 4)
        #expect(model.timelineRevealRequest?.id != farRequest?.id)
        #expect(model.timelineRevealRequest?.target == ids[4])
        model.moveFocus(by: -1)
        #expect(model.timelineRevealCount == count + 5)
        #expect(model.focusedScreenshotID == ids[3])
        #expect(model.selectedScreenshotOrder == ids)
        #expect(model.timelineRenderPlan.revision == revision)
    }

    @Test func groupSelectionHasFreshIntentAndOrdinarySelectionHasNone() {
        let model = RenderFixture.session()
        model.setTimelineGrouping(true)
        let ids = model.screenshots.map(\.id)
        let count = model.timelineRevealCount
        model.selectTimelineScreenGroup(ids[0])
        #expect(model.timelineRevealRequest?.cause == .groupSelection)
        #expect(model.timelineRevealCount == count + 1)
        let request = model.timelineRevealRequest
        model.selectTimelineScreenGroup(ids[0])
        #expect(model.timelineRevealRequest?.id != request?.id)
        #expect(model.timelineRevealCount == count + 2)
        let next = model.timelineRevealRequest
        model.selectScreenshot(ids[2], modifiers: .shift)
        #expect(model.timelineRevealRequest == next)
        #expect(model.timelineRevealCount == count + 2)
    }

    @Test func newReadyFollowOnlyAndFiltersCancelBeforeReconciliation() {
        let model = RenderFixture.session(count: 1)
        let job = model.imports.models[0]
        model.followsLatest = true
        let next = RenderFixture.occurrences(2)[1]
        job.screenshots.append(CapturedScreenshot(state: next.state, fileURL: URL(fileURLWithPath: "/new.png")))
        #expect(model.timelineRevealRequest?.cause == .followLatest)
        let count = model.timelineRevealCount
        let request = model.timelineRevealRequest
        job.videoURL = URL(fileURLWithPath: "/renamed.mov")
        #expect(model.timelineRevealRequest == request && model.timelineRevealCount == count)
        model.setUniqueScreens(true)
        #expect(!model.followsLatest && model.timelineRevealRequest == nil)
        #expect(model.timelineRevealCount == count)
        model.followsLatest = true
        job.screenshots.append(CapturedScreenshot(state: RenderFixture.occurrences(3)[2].state, fileURL: URL(fileURLWithPath: "/later.png")))
        #expect(model.timelineRevealRequest?.cause == .followLatest)
        model.selectScreenshot(model.screenshots[0].id, modifiers: [])
        #expect(model.timelineRevealRequest == nil && !model.followsLatest)
        model.followsLatest = true
        job.screenshots.append(CapturedScreenshot(state: RenderFixture.occurrences(4)[3].state, fileURL: URL(fileURLWithPath: "/last.png")))
        model.setTimelineGrouping(true)
        #expect(model.timelineRevealRequest == nil && !model.followsLatest)
    }

    @Test func pixelsAndProgressDoNotRebuildPlanButMetadataAndGeometryDo() {
        let model = RenderFixture.session()
        let job = model.imports.models[0]
        job.setAnalysisPreviewFrames([Frame(timestamp: 0, width: 100, height: 100, luma: Data([0]))])
        let revision = model.timelineRenderPlan.revision
        job.progress = AnalysisProgress(stage: .decoding, fraction: 0.9, detail: "Progress")
        job.setAnalysisPreviewFrames([Frame(timestamp: 1, width: 100, height: 100, luma: Data([1]))])
        model.selectAll()
        #expect(model.timelineRenderPlan.revision == revision)
        let count = model.timelineRevealCount
        job.videoURL = URL(fileURLWithPath: "/renamed.mov")
        #expect(model.timelineRenderPlan.revision != revision)
        let renamed = model.timelineRenderPlan.revision
        job.setAnalysisPreviewFrames([Frame(timestamp: 2, width: 200, height: 100, luma: Data([2]))])
        #expect(model.timelineRenderPlan.revision != renamed)
        #expect(model.timelineRenderPlan.cards[0].frame.width == 178)
        #expect(model.timelineRevealCount == count)
    }

    @Test func retryPublishesNewEmptySlotWithoutChangingOldJobIdentity() async {
        let runner = ControlledAnalysisRunner()
        let queue = VideoImportQueue(runner: runner.run)
        let model = SessionModel(preferences: AppPreferences(defaults: UserDefaults(suiteName: "StillsetRetry-\(UUID())")!),
            imports: queue, catalogRunner: { _, _, _ in SessionCatalogResult(classifications: []) })
        model.setTimelineGrouping(false)
        queue.enqueue([URL(fileURLWithPath: "/failed.mov")])
        let failed = queue.models[0]
        await runner.waitForStart(failed)
        runner.finish(failed, with: .failed("Literal failure"))
        await queue.waitUntilDrained()
        let before = model.timelineRenderPlan.revision
        queue.retry(failed)
        let replacement = queue.models[1]
        await runner.waitForStart(replacement)
        #expect(model.timelineRenderPlan.revision != before)
        #expect(model.timelineRenderPlan.cards.map(\.id) == [.emptyJob(failed.id), .emptyJob(replacement.id)])
        #expect(model.timelineRenderPlan.headers.map(\.id) == [.video(failed.id), .video(replacement.id)])
        #expect(replacement.id != failed.id && replacement.attempt == 2)
        #expect(model.timelineRevealRequest == nil)
        runner.finish(replacement, with: .failed("Retained failure"))
        await queue.waitUntilDrained()
        #expect(model.timelineRenderPlan.cards.map(\.id) == [.emptyJob(failed.id), .emptyJob(replacement.id)])
    }

    @Test func readyPayloadAndJobMembershipUsePublishedPlan() {
        let model = RenderFixture.session(count: 0)
        let job = model.imports.models[0]
        job.setPreviewAnalysisRunning(true)
        let a = RenderFixture.occurrences(1)[0]
        job.detectedScreens = [a.state]
        let pending = model.timelineRenderPlan
        #expect(pending.cards.count == 1)
        if case .occurrence(let item) = pending.cards[0].content { #expect(item.capture == nil) }
        else { Issue.record("Pending occurrence expected") }
        job.screenshots = [CapturedScreenshot(state: a.state, fileURL: URL(fileURLWithPath: "/ready.png"))]
        let ready = model.timelineRenderPlan
        #expect(ready.revision != pending.revision)
        #expect(ready.cards.map(\.id) == pending.cards.map(\.id))
        #expect(ready.cards.map(\.frame) == pending.cards.map(\.frame))
        job.admit(URL(fileURLWithPath: "/queued.mov"))
        model.imports.remove(job)
        #expect(model.timelineRenderPlan.cards.isEmpty && model.timelineRenderPlan.headers.isEmpty)
    }
}
