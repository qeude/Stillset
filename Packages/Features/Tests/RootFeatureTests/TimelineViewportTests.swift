import Foundation
import SwiftUI
import Testing
@testable import StillsetFeatures

@MainActor
struct TimelineViewportTests {
    @Test func arrivalsAndRegroupingChangeVisibleLayoutButLoadedImagesDoNot() {
        let state = SessionTimeline.Viewport()
        let items = RenderFixture.occurrences(4)
        let pending = RenderFixture.plan([items])
        #expect(state.changesVisibleLayout(to: pending))
        _ = state.accept(pending, request: nil)
        _ = state.observe(.init(rect: CGRect(x: 0, y: 0, width: 800, height: 208), contentWidth: pending.size.width))
        let loaded = RenderFixture.plan([items.enumerated().map { RenderFixture.ready($0.element, path: "/capture-\($0.offset).png") }])
        #expect(!state.changesVisibleLayout(to: loaded))
        let grouped = TimelineRenderPlan(sections: [
            .init(id: .screen(items[0].id), name: "Compte", screenGroupID: items[0].id,
                occurrences: [items[0], items[2]], job: nil),
            .init(id: .screen(items[1].id), name: "Recherche", screenGroupID: items[1].id,
                occurrences: [items[1], items[3]], job: nil)
        ], visibleIDs: Set(items.map(\.id)))
        #expect(state.changesVisibleLayout(to: grouped))
        _ = state.accept(grouped, request: nil)
        _ = state.observe(.init(rect: CGRect(x: 0, y: 0, width: 800, height: 208), contentWidth: grouped.size.width))
        #expect(!state.changesVisibleLayout(to: grouped))
    }

    @Test func arrivalsOutsideViewportDoNotRestartVisibleLayoutAnimations() {
        let state = SessionTimeline.Viewport()
        let before = RenderFixture.plan([RenderFixture.occurrences(4096)])
        _ = state.accept(before, request: nil)
        _ = state.observe(.init(rect: CGRect(x: 0, y: 0, width: 320, height: 208), contentWidth: before.size.width))
        let after = RenderFixture.plan([RenderFixture.occurrences(4097)])
        #expect(!state.changesVisibleLayout(to: after))
    }

    @Test func arrivalPreservesLiteralInspectionAndRegroupingPreservesIdentity() {
        let a = RenderFixture.occurrences(20)
        let old = RenderFixture.plan([a])
        let state = SessionTimeline.Viewport()
        #expect(state.accept(old, request: nil) == nil)
        #expect(state.observe(.init(rect: CGRect(x: 980, y: 0, width: 260, height: 208), contentWidth: old.size.width)) == nil)
        #expect(state.inspected?.anchor == .occurrence(a[7].id))
        #expect(state.inspected?.displacement == -46)
        let inserted = RenderFixture.occurrences(1, video: RenderFixture.otherVideo, ratio: 2)
        let next = RenderFixture.plan([inserted, a])
        #expect(state.accept(next, request: nil) == nil)
        #expect(state.observe(.init(rect: CGRect(x: 980, y: 0, width: 260, height: 208), contentWidth: next.size.width)) == 1240)
        #expect(state.observe(.init(rect: CGRect(x: 1240, y: 0, width: 260, height: 208), contentWidth: next.size.width)) == nil)
        #expect(state.inspected?.anchor == .occurrence(a[7].id))
        #expect(state.inspected?.displacement == -46)
        let grouped = TimelineRenderPlan(sections: [.init(id: .screen(a[0].id), name: "Grouped", screenGroupID: a[0].id,
            occurrences: a + inserted, job: nil)], visibleIDs: Set((a + inserted).map(\.id)))
        #expect(state.accept(grouped, request: nil) == 980)
        #expect(state.observe(.init(rect: CGRect(x: 980, y: 0, width: 260, height: 208), contentWidth: grouped.size.width)) == nil)
    }

    @Test func removedAnchorUsesSuccessorThenPredecessorThenHeaderThenRawClamp() {
        let a = RenderFixture.occurrences(12)
        let old = RenderFixture.plan([a])
        let successor = RenderFixture.plan([Array(a.dropFirst(8))])
        #expect(successor.survivingAnchor(.occurrence(a[7].id), from: old) == .occurrence(a[8].id))
        let predecessor = RenderFixture.plan([Array(a.prefix(7))])
        #expect(predecessor.survivingAnchor(.occurrence(a[7].id), from: old) == .occurrence(a[6].id))
        let header = TimelineRenderPlan(sections: [.init(id: .video(RenderFixture.video), name: "Filtered", screenGroupID: nil,
            occurrences: a, job: nil)], visibleIDs: [])
        #expect(header.survivingAnchor(.occurrence(a[7].id), from: old) == .header(.video(RenderFixture.video)))
        let gone = RenderFixture.plan([RenderFixture.occurrences(2, video: RenderFixture.otherVideo)])
        #expect(gone.survivingAnchor(.occurrence(a[7].id), from: old) == nil)
        let state = SessionTimeline.Viewport()
        _ = state.accept(old, request: nil)
        _ = state.observe(.init(rect: CGRect(x: 980, y: 0, width: 130, height: 208), contentWidth: old.size.width))
        #expect(state.accept(gone, request: nil) == 178)
        #expect(state.observe(.init(rect: CGRect(x: 178, y: 0, width: 130, height: 208), contentWidth: gone.size.width)) == nil)
    }

    @Test func removalCorrectionsUseLiteralViewportOffsets() {
        let a = RenderFixture.occurrences(12)
        let old = RenderFixture.plan([a])
        let header = TimelineRenderPlan(sections: [.init(id: .video(RenderFixture.video), name: "Filtered", screenGroupID: nil,
            occurrences: a, job: nil)], visibleIDs: [])
        let replacements = [RenderFixture.plan([Array(a.dropFirst(8))]), RenderFixture.plan([Array(a.prefix(7))]), header]
        let offsets: [CGFloat] = [70, 828, 70]
        for (index, replacement) in replacements.enumerated() {
            let state = SessionTimeline.Viewport()
            _ = state.accept(old, request: nil)
            _ = state.observe(.init(rect: CGRect(x: 980, y: 0, width: 130, height: 208), contentWidth: old.size.width))
            #expect(state.accept(replacement, request: nil) == offsets[index])
            #expect(state.observe(.init(rect: CGRect(x: offsets[index], y: 0, width: 130, height: 208), contentWidth: replacement.size.width)) == nil)
        }
    }

    @Test func realRatioChangePreservesAnchorAndHeaderOnlyInspectionNeverRevealsFocus() {
        var a = RenderFixture.occurrences(20)
        let old = RenderFixture.plan([a])
        let state = SessionTimeline.Viewport()
        _ = state.accept(old, request: nil)
        _ = state.observe(.init(rect: CGRect(x: 980, y: 0, width: 260, height: 208), contentWidth: old.size.width))
        a[0].sourceAspectRatio = 2
        let next = RenderFixture.plan([a])
        _ = state.accept(next, request: nil)
        #expect(state.observe(.init(rect: CGRect(x: 980, y: 0, width: 260, height: 208), contentWidth: next.size.width)) == 1028)
        let header = TimelineRenderPlan(sections: [.init(id: .video(RenderFixture.video), name: "Only header", screenGroupID: nil,
            occurrences: a, job: nil)], visibleIDs: [])
        let headerState = SessionTimeline.Viewport()
        _ = headerState.accept(header, request: nil)
        _ = headerState.observe(.init(rect: CGRect(x: 100, y: 0, width: 100, height: 208), contentWidth: 288))
        #expect(headerState.inspected?.anchor == .header(.video(RenderFixture.video)))
        #expect(headerState.inspected?.displacement == -76)
        #expect(headerState.phaseChanged(to: .idle) == nil)
    }

    @Test func combinedFarRequestWaitsForExtentThenMountsAndScrollsOnce() {
        let a = RenderFixture.occurrences(30)
        let old = RenderFixture.plan([Array(a.prefix(3))])
        let next = RenderFixture.plan([a])
        let state = SessionTimeline.Viewport()
        _ = state.accept(old, request: nil)
        _ = state.observe(.init(rect: CGRect(x: 0, y: 0, width: 260, height: 208), contentWidth: old.size.width))
        let request = TimelineRevealRequest(id: UUID(), target: a[29].id, cause: .navigation)
        #expect(state.accept(next, request: request) == nil)
        #expect(state.window.cards == 0..<3)
        #expect(state.observe(.init(rect: CGRect(x: 0, y: 0, width: 260, height: 208), contentWidth: next.size.width)) == 3664)
        #expect(state.window.cards == 27..<30)
        #expect(state.accept(next, request: request) == nil)
        #expect(state.observe(.init(rect: CGRect(x: 3664, y: 0, width: 260, height: 208), contentWidth: next.size.width)) == nil)
        #expect(state.consumedRequestID == request.id)
        #expect(state.accept(next, request: request) == nil)
    }

    @Test func canceledFollowAndInvalidRevealStillPreserveStructuralInspection() {
        let a = RenderFixture.occurrences(30)
        let old = RenderFixture.plan([a])
        let expanded = RenderFixture.plan([RenderFixture.occurrences(1, video: RenderFixture.otherVideo), a])
        let state = SessionTimeline.Viewport()
        _ = state.accept(old, request: nil)
        _ = state.observe(.init(rect: CGRect(x: 980, y: 0, width: 260, height: 208), contentWidth: old.size.width))
        let follow = TimelineRevealRequest(id: UUID(), target: a[29].id, cause: .followLatest)
        _ = state.accept(expanded, request: follow)
        #expect(state.accept(expanded, request: nil) == nil)
        #expect(state.observe(.init(rect: CGRect(x: 980, y: 0, width: 260, height: 208), contentWidth: expanded.size.width)) == 1240)
        _ = state.observe(.init(rect: CGRect(x: 1240, y: 0, width: 260, height: 208), contentWidth: expanded.size.width))
        let next = RenderFixture.plan([a])
        let invalid = TimelineRevealRequest(id: UUID(), target: RenderFixture.occurrences(1, video: UUID())[0].id, cause: .navigation)
        #expect(state.accept(next, request: invalid) == 980)
        #expect(state.consumedRequestID == invalid.id)
        #expect(state.observe(.init(rect: CGRect(x: 980, y: 0, width: 260, height: 208), contentWidth: next.size.width)) == nil)
        _ = state.observe(.init(rect: CGRect(x: 980, y: 0, width: 260, height: 208), contentWidth: next.size.width))
        #expect(state.inspected?.anchor == .occurrence(a[7].id))
    }

    @Test func removedHeaderFindsSuccessorBodyInOldDocumentOrder() {
        let a = RenderFixture.occurrences(1)
        let b = RenderFixture.occurrences(3, video: RenderFixture.otherVideo)
        let old = TimelineRenderPlan(sections: [.init(id: .video(RenderFixture.video), name: "Filtered", screenGroupID: nil,
            occurrences: a, job: nil), .init(id: .video(RenderFixture.otherVideo), name: "Visible", screenGroupID: nil,
            occurrences: b, job: nil)], visibleIDs: Set(b.map(\.id)))
        let next = RenderFixture.plan([b])
        #expect(next.survivingAnchor(.header(.video(RenderFixture.video)), from: old) == .occurrence(b[0].id))
        let state = SessionTimeline.Viewport()
        _ = state.accept(old, request: nil)
        _ = state.observe(.init(rect: CGRect(x: 200, y: 0, width: 20, height: 208), contentWidth: old.size.width))
        #expect(state.inspected?.anchor == .header(.video(RenderFixture.video)))
        _ = state.accept(next, request: nil)
        #expect(state.observe(.init(rect: CGRect(x: 200, y: 0, width: 20, height: 208), contentWidth: next.size.width)) == nil)
    }

    @Test func structuralArrivalBeforePointAcknowledgmentContinuesOnlyTheIssuedCommand() {
        let a = RenderFixture.occurrences(30)
        let old = RenderFixture.plan([a])
        let next = RenderFixture.plan([RenderFixture.occurrences(1, video: RenderFixture.otherVideo), a])
        let state = SessionTimeline.Viewport()
        _ = state.accept(old, request: nil)
        _ = state.observe(.init(rect: CGRect(x: 0, y: 0, width: 260, height: 208), contentWidth: old.size.width))
        let request = TimelineRevealRequest(id: UUID(), target: a[29].id, cause: .navigation)
        #expect(state.accept(old, request: request) == 3664)
        #expect(state.accept(next, request: request) == nil)
        #expect(state.observe(.init(rect: CGRect(x: 0, y: 0, width: 260, height: 208), contentWidth: next.size.width)) == 3924)
        _ = state.observe(.init(rect: CGRect(x: 3924, y: 0, width: 260, height: 208), contentWidth: next.size.width))
        _ = state.phaseChanged(to: .interacting)
        _ = state.observe(.init(rect: CGRect(x: 980, y: 0, width: 260, height: 208), contentWidth: next.size.width))
        _ = state.phaseChanged(to: .idle)
        #expect(state.accept(next, request: request) == nil)
    }

    @Test func momentumWithoutLaterMovementAppliesOnlyOneStructuralCorrectionAtIdle() {
        let a = RenderFixture.occurrences(30)
        let old = RenderFixture.plan([a])
        let next = RenderFixture.plan([RenderFixture.occurrences(1, video: RenderFixture.otherVideo), a])
        let state = SessionTimeline.Viewport()
        _ = state.accept(old, request: nil)
        _ = state.observe(.init(rect: CGRect(x: 980, y: 0, width: 260, height: 208), contentWidth: old.size.width))
        _ = state.phaseChanged(to: .interacting)
        _ = state.accept(next, request: nil)
        #expect(state.observe(.init(rect: CGRect(x: 980, y: 0, width: 260, height: 208), contentWidth: next.size.width)) == nil)
        #expect(state.phaseChanged(to: .idle) == 1240)
        #expect(state.phaseChanged(to: .idle) == nil)
        #expect(state.observe(.init(rect: CGRect(x: 1240, y: 0, width: 260, height: 208), contentWidth: next.size.width)) == nil)
    }

    @Test func manualGestureCancelsPendingExplicitAndNewCommandWins() {
        let a = RenderFixture.occurrences(30)
        let old = RenderFixture.plan([Array(a.prefix(3))])
        let next = RenderFixture.plan([a])
        let state = SessionTimeline.Viewport()
        _ = state.accept(old, request: nil)
        _ = state.observe(.init(rect: CGRect(x: 0, y: 0, width: 260, height: 208), contentWidth: old.size.width))
        let request = TimelineRevealRequest(id: UUID(), target: a[29].id, cause: .navigation)
        _ = state.accept(next, request: request)
        #expect(state.phaseChanged(to: .interacting) == nil)
        #expect(state.observe(.init(rect: CGRect(x: 130, y: 0, width: 260, height: 208), contentWidth: next.size.width)) == nil)
        #expect(state.phaseChanged(to: .idle) == nil)
        #expect(state.accept(next, request: request) == nil)
        let renewed = TimelineRevealRequest(id: UUID(), target: a[29].id, cause: .navigation)
        #expect(state.accept(next, request: renewed) == 3664)
    }

    @Test func movementDuringExistingGestureCancelsAnExtentWaitingCommand() {
        let a = RenderFixture.occurrences(30)
        let old = RenderFixture.plan([Array(a.prefix(3))])
        let next = RenderFixture.plan([a])
        let state = SessionTimeline.Viewport()
        _ = state.accept(old, request: nil)
        _ = state.observe(.init(rect: CGRect(x: 0, y: 0, width: 260, height: 208), contentWidth: old.size.width))
        _ = state.phaseChanged(to: .interacting)
        let request = TimelineRevealRequest(id: UUID(), target: a[29].id, cause: .navigation)
        #expect(state.accept(next, request: request) == nil)
        #expect(state.observe(.init(rect: CGRect(x: 130, y: 0, width: 260, height: 208), contentWidth: old.size.width)) == nil)
        #expect(state.observe(.init(rect: CGRect(x: 130, y: 0, width: 260, height: 208), contentWidth: next.size.width)) == nil)
        #expect(state.phaseChanged(to: .idle) == nil)
        #expect(state.accept(next, request: request) == nil)
        #expect(state.accept(next, request: .init(id: UUID(), target: a[29].id, cause: .navigation)) == 3664)
    }

    @Test func momentumKeepsLatestInspectionAndHasOneIdleCorrection() {
        let a = RenderFixture.occurrences(30)
        let old = RenderFixture.plan([a])
        let next = RenderFixture.plan([RenderFixture.occurrences(1, video: RenderFixture.otherVideo), a])
        let state = SessionTimeline.Viewport()
        _ = state.accept(old, request: nil)
        _ = state.observe(.init(rect: CGRect(x: 980, y: 0, width: 260, height: 208), contentWidth: old.size.width))
        _ = state.phaseChanged(to: .interacting)
        _ = state.accept(next, request: nil)
        #expect(state.observe(.init(rect: CGRect(x: 1110, y: 0, width: 260, height: 208), contentWidth: next.size.width)) == nil)
        #expect(state.inspected?.anchor == .occurrence(a[6].id))
        #expect(state.phaseChanged(to: .idle) == nil)
        #expect(state.observe(.init(rect: CGRect(x: 1110, y: 0, width: 260, height: 208), contentWidth: next.size.width)) == nil)
    }

    @Test func resumedGestureDuringDecelerationCancelsExtentWaitingCommandBeforeMovement() {
        for resumedPhase in [ScrollPhase.tracking, .interacting] {
            let a = RenderFixture.occurrences(30)
            let old = RenderFixture.plan([Array(a.prefix(3))])
            let next = RenderFixture.plan([a])
            let state = SessionTimeline.Viewport()
            _ = state.accept(old, request: nil)
            _ = state.observe(.init(rect: CGRect(x: 0, y: 0, width: 260, height: 208), contentWidth: 438))
            _ = state.phaseChanged(to: .tracking)
            _ = state.phaseChanged(to: .interacting)
            _ = state.phaseChanged(to: .decelerating)
            let request = TimelineRevealRequest(id: UUID(), target: a[29].id, cause: .navigation)
            #expect(state.accept(next, request: request) == nil)
            #expect(state.phaseChanged(to: resumedPhase) == nil)
            #expect(state.phaseChanged(to: .interacting) == nil)
            #expect(state.observe(.init(rect: CGRect(x: 0, y: 0, width: 260, height: 208), contentWidth: 3948)) == nil)
            #expect(state.phaseChanged(to: .idle) == nil)
            #expect(state.accept(next, request: request) == nil)
            #expect(state.accept(next, request: .init(id: UUID(), target: a[29].id, cause: .navigation)) == 3664)
        }
    }

    @Test func commandAfterResumedInputWinsEvenBeforeExpandedExtentAcknowledgment() {
        let a = RenderFixture.occurrences(30)
        let old = RenderFixture.plan([Array(a.prefix(3))])
        let next = RenderFixture.plan([a])
        let state = SessionTimeline.Viewport()
        _ = state.accept(old, request: nil)
        _ = state.observe(.init(rect: CGRect(x: 0, y: 0, width: 260, height: 208), contentWidth: 438))
        _ = state.phaseChanged(to: .decelerating)
        let stale = TimelineRevealRequest(id: UUID(), target: a[29].id, cause: .navigation)
        #expect(state.accept(next, request: stale) == nil)
        #expect(state.phaseChanged(to: .tracking) == nil)
        let renewed = TimelineRevealRequest(id: UUID(), target: a[28].id, cause: .navigation)
        #expect(state.accept(next, request: renewed) == nil)
        #expect(state.phaseChanged(to: .interacting) == nil)
        #expect(state.observe(.init(rect: CGRect(x: 0, y: 0, width: 260, height: 208), contentWidth: 3948)) == nil)
        #expect(state.phaseChanged(to: .idle) == 3534)
        #expect(state.consumedRequestID == renewed.id)
        #expect(state.observe(.init(rect: CGRect(x: 3534, y: 0, width: 260, height: 208), contentWidth: 3948)) == nil)
        #expect(state.accept(next, request: renewed) == nil)
    }

    @Test func farShrinkPublishesRenderableDestinationBeforeExtentAcknowledgment() {
        let a = RenderFixture.occurrences(30)
        let old = RenderFixture.plan([a])
        let next = RenderFixture.plan([Array(a.prefix(3))])
        let state = SessionTimeline.Viewport()
        _ = state.accept(old, request: nil)
        _ = state.observe(.init(rect: CGRect(x: 3000, y: 0, width: 260, height: 208), contentWidth: 3948))
        #expect(state.accept(next, request: nil) == 178)
        #expect(state.window.cards == 0..<3)
        #expect(state.window.headers == 0..<1)
        #expect(state.plan.cards[state.window.cards].map(\.id) == a.prefix(3).map { .occurrence($0.id) })
        #expect(state.observe(.init(rect: CGRect(x: 3000, y: 0, width: 260, height: 208), contentWidth: 438)) == nil)
        #expect(state.window.cards == 0..<3)
        #expect(state.observe(.init(rect: CGRect(x: 178, y: 0, width: 260, height: 208), contentWidth: 3948)) == nil)
        #expect(state.window.cards == 0..<3)
        #expect(state.observe(.init(rect: CGRect(x: 178, y: 0, width: 260, height: 208), contentWidth: 438)) == nil)
        #expect(state.window.cards == 0..<3)
        #expect(state.inspected?.anchor == .occurrence(a[1].id))
        #expect(state.inspected?.displacement == -24)
    }

    @Test func phaseContinuationAndResumptionRetainStructuralMomentumCorrection() {
        for resumes in [false, true] {
            let a = RenderFixture.occurrences(30)
            let old = RenderFixture.plan([a])
            let next = RenderFixture.plan([RenderFixture.occurrences(1, video: RenderFixture.otherVideo), a])
            let state = SessionTimeline.Viewport()
            _ = state.accept(old, request: nil)
            _ = state.observe(.init(rect: CGRect(x: 980, y: 0, width: 260, height: 208), contentWidth: 3948))
            _ = state.phaseChanged(to: .tracking)
            #expect(state.accept(next, request: nil) == nil)
            #expect(state.phaseChanged(to: .interacting) == nil)
            #expect(state.phaseChanged(to: .decelerating) == nil)
            if resumes {
                #expect(state.phaseChanged(to: .tracking) == nil)
                #expect(state.phaseChanged(to: .interacting) == nil)
            }
            #expect(state.observe(.init(rect: CGRect(x: 980, y: 0, width: 260, height: 208), contentWidth: 4208)) == nil)
            #expect(state.phaseChanged(to: .idle) == 1240)
            #expect(state.phaseChanged(to: .idle) == nil)
            #expect(state.observe(.init(rect: CGRect(x: 1240, y: 0, width: 260, height: 208), contentWidth: 4208)) == nil)
            #expect(state.inspected?.anchor == .occurrence(a[7].id))
            #expect(state.inspected?.displacement == -46)
        }
    }

    @Test func shrinkDuringMomentumClampsBoundsButDefersRemovedAnchorCorrectionUntilIdle() {
        let a = RenderFixture.occurrences(30)
        let old = RenderFixture.plan([a])
        let next = RenderFixture.plan([Array(a.suffix(3))])
        let state = SessionTimeline.Viewport()
        _ = state.accept(old, request: nil)
        _ = state.observe(.init(rect: CGRect(x: 3000, y: 0, width: 260, height: 208), contentWidth: 3948))
        #expect(state.inspected?.anchor == .occurrence(a[22].id))
        #expect(state.inspected?.displacement == -116)
        _ = state.phaseChanged(to: .decelerating)
        #expect(state.accept(next, request: nil) == 178)
        #expect(state.window.cards == 0..<3)
        #expect(state.plan.cards[state.window.cards].map(\.id) == a.suffix(3).map { .occurrence($0.id) })
        #expect(state.observe(.init(rect: CGRect(x: 3000, y: 0, width: 260, height: 208), contentWidth: 438)) == nil)
        #expect(state.window.cards == 0..<3)
        #expect(state.observe(.init(rect: CGRect(x: 178, y: 0, width: 260, height: 208), contentWidth: 438)) == nil)
        #expect(state.phaseChanged(to: .idle) == 140)
        #expect(state.window.cards == 0..<3)
        #expect(state.observe(.init(rect: CGRect(x: 140, y: 0, width: 260, height: 208), contentWidth: 438)) == nil)
        #expect(state.inspected?.anchor == .occurrence(a[27].id))
        #expect(state.inspected?.displacement == -116)
        #expect(state.phaseChanged(to: .idle) == nil)
    }

    @Test func shrinkDuringMomentumKeepsLaterManualInspectionWithoutAnIdleJump() {
        let a = RenderFixture.occurrences(30)
        let old = RenderFixture.plan([a])
        let next = RenderFixture.plan([Array(a.suffix(3))])
        let state = SessionTimeline.Viewport()
        _ = state.accept(old, request: nil)
        _ = state.observe(.init(rect: CGRect(x: 3000, y: 0, width: 260, height: 208), contentWidth: 3948))
        _ = state.phaseChanged(to: .decelerating)
        #expect(state.accept(next, request: nil) == 178)
        #expect(state.observe(.init(rect: CGRect(x: 178, y: 0, width: 260, height: 208), contentWidth: 438)) == nil)
        #expect(state.observe(.init(rect: CGRect(x: 130, y: 0, width: 260, height: 208), contentWidth: 438)) == nil)
        #expect(state.window.cards == 0..<3)
        #expect(state.inspected?.anchor == .occurrence(a[27].id))
        #expect(state.inspected?.displacement == -106)
        #expect(state.phaseChanged(to: .idle) == nil)
        #expect(state.phaseChanged(to: .idle) == nil)
    }

    @Test func shrinkCombinedCommandAndWideContainerStayWithinBothExtents() {
        let a = RenderFixture.occurrences(30)
        let old = RenderFixture.plan([a])
        let next = RenderFixture.plan([Array(a.prefix(3))])
        for width: CGFloat in [260, 500] {
            let state = SessionTimeline.Viewport()
            _ = state.accept(old, request: nil)
            _ = state.observe(.init(rect: CGRect(x: 3000, y: 0, width: width, height: 208), contentWidth: 3948))
            let request = TimelineRevealRequest(id: UUID(), target: a[0].id, cause: .navigation)
            let offset: CGFloat = width == 260 ? 24 : 0
            #expect(state.accept(next, request: request) == offset)
            #expect(state.window.cards == 0..<3)
            #expect(state.window.headers == 0..<1)
            #expect(state.accept(next, request: request) == nil)
            #expect(state.window.cards == 0..<3)
            #expect(state.observe(.init(rect: CGRect(x: offset, y: 0, width: width, height: 208), contentWidth: max(438, width))) == nil)
            #expect(state.window.cards == 0..<3)
            #expect(state.consumedRequestID == request.id)
        }
    }

    @Test func revealUsesMinimalMovementAndPageActionsReachBothEnds() {
        let a = RenderFixture.occurrences(5)
        let plan = RenderFixture.plan([a])
        let state = SessionTimeline.Viewport()
        _ = state.accept(plan, request: nil)
        _ = state.observe(.init(rect: CGRect(x: 0, y: 0, width: 260, height: 208), contentWidth: plan.size.width))
        #expect(state.accept(plan, request: .init(id: UUID(), target: a[0].id, cause: .navigation)) == nil)
        #expect(state.accept(plan, request: .init(id: UUID(), target: a[1].id, cause: .navigation)) == 24)
        _ = state.observe(.init(rect: CGRect(x: 24, y: 0, width: 260, height: 208), contentWidth: plan.size.width))
        #expect(state.page(forward: true) == 252)
        _ = state.observe(.init(rect: CGRect(x: 252, y: 0, width: 260, height: 208), contentWidth: plan.size.width))
        #expect(state.page(forward: true) == 438)
        _ = state.observe(.init(rect: CGRect(x: 438, y: 0, width: 260, height: 208), contentWidth: plan.size.width))
        #expect(state.page(forward: true) == nil)
        #expect(state.page(forward: false) == 210)
        _ = state.observe(.init(rect: CGRect(x: 210, y: 0, width: 40, height: 208), contentWidth: plan.size.width))
        #expect(state.accept(plan, request: .init(id: UUID(), target: a[1].id, cause: .navigation)) == 154)
    }
}
