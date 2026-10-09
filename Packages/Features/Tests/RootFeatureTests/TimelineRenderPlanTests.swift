import Foundation
import StillsetCore
import Testing
@testable import StillsetFeatures

@MainActor
struct TimelineRenderPlanTests {
    @Test func screenGroupsKeepCompactSpacingWithoutOverlappingTitles() {
        let a = RenderFixture.occurrences(1, ratio: 0.1)
        let b = RenderFixture.occurrences(1, video: RenderFixture.otherVideo, ratio: 0.1)
        let plan = TimelineRenderPlan(sections: [
            .init(id: .screen(a[0].id), name: "Kilométrage", screenGroupID: a[0].id, occurrences: a, job: nil),
            .init(id: .screen(b[0].id), name: "Simulation de revenus", screenGroupID: b[0].id, occurrences: b, job: nil)
        ], visibleIDs: Set((a + b).map(\.id)))
        #expect(plan.cards.count == 2)
        #expect(plan.cards[1].frame.minX - plan.cards[0].frame.maxX == 20)
        #expect(plan.headers[0].frame.maxX <= plan.headers[1].frame.minX)
        #expect(plan.window(in: plan.cards[1].frame, overscan: 0).cards == 1..<2)
    }

    @Test func literalGeometryAndCompositeIdentity() {
        let a = RenderFixture.occurrences(2)
        let b = RenderFixture.occurrences(1, video: RenderFixture.otherVideo)
        let plan = RenderFixture.plan([a, b])
        #expect(plan.cards.map(\.frame) == [CGRect(x: 24, y: 48, width: 130, height: 150),
            CGRect(x: 154, y: 48, width: 130, height: 150), CGRect(x: 304, y: 48, width: 130, height: 150)])
        #expect(plan.headers.map(\.frame) == [CGRect(x: 24, y: 10, width: 240, height: 32),
            CGRect(x: 304, y: 10, width: 240, height: 32)])
        #expect(plan.size == CGSize(width: 568, height: 208))
        #expect(a[0].id.stateID == b[0].id.stateID)
        #expect(plan.cards[0].id != plan.cards[2].id)
        #expect(TimelineRenderPlan.imageWidth(for: 0.1) == 48)
        #expect(TimelineRenderPlan.imageWidth(for: 2) == 160)
        #expect(TimelineRenderPlan.imageWidth(for: .nan) == 53.05263157894736)
    }

    @Test func emptyJobsFilteredChaptersAndRenames() {
        let job = AppModel()
        let empty = TimelineRenderPlan.Section(id: .video(job.id), name: "Failed", screenGroupID: nil, occurrences: [], job: job)
        let a = RenderFixture.occurrences(2)
        let filtered = TimelineRenderPlan.Section(id: .video(RenderFixture.video), name: "Filtered", screenGroupID: nil, occurrences: a, job: nil)
        let plan = TimelineRenderPlan(sections: [empty, filtered], visibleIDs: [])
        #expect(plan.cards.map(\.id) == [.emptyJob(job.id)])
        #expect(plan.cards[0].frame == CGRect(x: 24, y: 48, width: 190, height: 136))
        #expect(plan.headers.map(\.frame.minX) == [24, 284])
        #expect(plan.size == CGSize(width: 548, height: 208))
        let renamed = TimelineRenderPlan(sections: [.init(id: empty.id, name: String(repeating: "Long ", count: 80),
            screenGroupID: nil, occurrences: [], job: job), filtered], visibleIDs: [])
        #expect(renamed.size == plan.size)
        #expect(renamed.cards.map(\.frame) == plan.cards.map(\.frame))
        #expect(renamed.headers.map(\.frame) == plan.headers.map(\.frame))
        let noSession = TimelineRenderPlan(sections: [], visibleIDs: [])
        #expect(noSession.cards.isEmpty && noSession.headers.isEmpty && noSession.size == .zero)
    }

    @Test func pendingReadyAndRatioChange() {
        var pending = RenderFixture.occurrences(2)
        let before = RenderFixture.plan([pending])
        pending[0] = RenderFixture.ready(pending[0], path: "/current.png")
        let ready = RenderFixture.plan([pending])
        #expect(before.cards.map(\.id) == ready.cards.map(\.id))
        #expect(before.cards.map(\.frame) == ready.cards.map(\.frame))
        if case .occurrence(let item) = ready.cards[0].content { #expect(item.capture?.fileURL.path == "/current.png") }
        else { Issue.record("Expected occurrence") }
        pending[0].sourceAspectRatio = 2
        let changed = RenderFixture.plan([pending])
        #expect(changed.cards[0].frame.width == 178)
        #expect(changed.cards[1].frame.minX == 202)
    }

    @Test func indexed4096WindowsHaveExactIDsAndAnalyticalBounds() {
        let all = RenderFixture.occurrences(4096)
        let plan = RenderFixture.plan([all])
        let far = plan.window(in: CGRect(x: 390024, y: 0, width: 260, height: 208), overscan: 130)
        #expect(far.cards == 2999..<3003)
        #expect(plan.cards[far.cards].map(\.id) == all[2999..<3003].map { .occurrence($0.id) })
        #expect(far.headers.isEmpty)
        for width: CGFloat in [66, 320, 1024, 1800] {
            for x: CGFloat in [0, 100000, plan.size.width - width] {
                let result = plan.window(in: CGRect(x: x, y: 0, width: width, height: 208), overscan: width / 2)
                #expect(result.cards.count <= Int(ceil(2 * width / 66)) + 2)
                #expect(result.headers.count <= Int(ceil(2 * width / 260)) + 2)
            }
        }
        let hidden = TimelineRenderPlan(sections: [.init(id: .video(RenderFixture.video), name: "Hidden", screenGroupID: nil,
            occurrences: all, job: nil)], visibleIDs: [all[3000].id])
        #expect(hidden.cards.map(\.id) == [.occurrence(all[3000].id)])
    }

    @Test func thousandsOfChapterHeadersHaveIndependentExactWindowBounds() {
        let groups = (0..<4096).map { index in
            RenderFixture.occurrences(1, video: UUID(uuidString: "00000000-0000-0000-0003-\(String(format: "%012d", index + 1))")!)
        }
        let plan = RenderFixture.plan(groups)
        let result = plan.window(in: CGRect(x: 780024, y: 0, width: 260, height: 208), overscan: 130)
        #expect(result.headers == 2999..<3002)
        #expect(result.cards == 3000..<3002)
        #expect(plan.headers[result.headers].map(\.id) == groups[2999..<3002].map { .video($0[0].id.videoID) })
        for x: CGFloat in [0, 780024, plan.size.width - 1024] {
            let result = plan.window(in: CGRect(x: x, y: 0, width: 1024, height: 208), overscan: 512)
            #expect(result.headers.count <= 10)
            #expect(result.cards.count <= 34)
        }
    }

    @Test func bodyAndHeaderIndexesStayIndependent() {
        let a = RenderFixture.occurrences(1, ratio: 0.1)
        let b = RenderFixture.occurrences(1, video: RenderFixture.otherVideo, ratio: 0.1)
        let plan = RenderFixture.plan([a, b])
        let result = plan.window(in: CGRect(x: 200, y: 0, width: 20, height: 208), overscan: 0)
        #expect(result.cards.isEmpty)
        #expect(result.headers == 0..<1)
    }
}

@MainActor
enum RenderFixture {
    static let video = UUID(uuidString: "00000000-0000-0000-0001-000000000000")!
    static let otherVideo = UUID(uuidString: "00000000-0000-0000-0002-000000000000")!

    static func occurrences(_ count: Int, video: UUID = video, ratio: CGFloat = 1) -> [SessionOccurrence] {
        (0..<count).map { index in
            let state = UIState(id: UUID(uuidString: "00000000-0000-0000-0000-\(String(format: "%012d", index + 1))")!,
                interval: Double(index / 2)..<Double(index / 2 + 1), representativeTimestamp: Double(index / 2), stabilityScore: 1)
            return SessionOccurrence(id: OccurrenceID(videoID: video, stateID: state.id), videoOrdinal: video == self.video ? 1 : 2,
                sourceURL: nil, attempt: 1, state: state, capture: nil, classification: nil, sourceAspectRatio: ratio)
        }
    }

    static func ready(_ item: SessionOccurrence, path: String) -> SessionOccurrence {
        SessionOccurrence(id: item.id, videoOrdinal: item.videoOrdinal, sourceURL: item.sourceURL, attempt: item.attempt,
            state: item.state, capture: CapturedScreenshot(state: item.state, fileURL: URL(fileURLWithPath: path)),
            classification: item.classification, sourceAspectRatio: item.sourceAspectRatio)
    }

    static func plan(_ groups: [[SessionOccurrence]]) -> TimelineRenderPlan {
        TimelineRenderPlan(sections: groups.enumerated().map { index, group in
            .init(id: .video(group.first?.id.videoID ?? video), name: "Chapter \(index)", screenGroupID: nil, occurrences: group, job: nil)
        }, visibleIDs: Set(groups.flatMap { $0.map(\.id) }))
    }

    static func session(count: Int = 5) -> SessionModel {
        let job = AppModel()
        job.screenshots = occurrences(count).enumerated().map { index, item in
            CapturedScreenshot(state: item.state, fileURL: URL(fileURLWithPath: "/literal-\(index).png"))
        }
        let defaults = UserDefaults(suiteName: "StillsetRender-\(UUID())")!
        let session = SessionModel(preferences: AppPreferences(defaults: defaults), imports: VideoImportQueue(models: [job]),
            catalogRunner: { _, _, _ in SessionCatalogResult(classifications: []) })
        session.setUniqueScreens(false)
        session.setTimelineGrouping(false)
        return session
    }
}
