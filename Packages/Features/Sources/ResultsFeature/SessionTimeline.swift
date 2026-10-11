import Observation
import SwiftUI

struct SessionTimeline: View {
    let model: SessionModel
    let reduceMotion: Bool
    let keyboardTarget: TimelineKeyboardTarget
    @State private var viewport = Viewport()
    @State private var position = ScrollPosition(x: 0)

    private struct Update: Equatable {
        let revision: UUID
        let request: UUID?
    }

    var body: some View {
        let plan = viewport.plan
        ScrollView(.horizontal) {
            Color.clear
                .frame(width: plan.size.width, height: max(208, plan.size.height))
                .accessibilityHidden(true)
                .transaction { $0.animation = nil }
                .overlay(alignment: .topLeading) {
                    ZStack(alignment: .topLeading) {
                        ForEach(plan.headers[viewport.window.headers]) { header in
                            timelineHeader(header)
                                .frame(width: header.frame.width, height: header.frame.height, alignment: .topLeading)
                                .offset(x: header.frame.minX, y: header.frame.minY)
                                .transition(reduceMotion ? .identity : .opacity)
                                .accessibilitySortPriority(-Double(header.frame.minX) + 0.5)
                        }
                        ForEach(plan.cards[viewport.window.cards]) { card in
                            timelineCard(card)
                                .frame(width: card.frame.width, height: card.frame.height, alignment: .topLeading)
                                .offset(x: card.frame.minX, y: card.frame.minY)
                                .transition(reduceMotion ? .identity : .opacity.combined(with: .scale(scale: 0.97)).combined(with: .offset(y: 6)))
                                .accessibilitySortPriority(-Double(card.frame.minX))
                        }
                    }
                }
        }
        .scrollPosition($position)
        .scrollIndicators(.never)
        .frame(height: 208)
        .layoutPriority(1)
        .onChange(of: Update(revision: model.timelineRenderPlan.revision, request: model.timelineRevealRequest?.id), initial: true) {
            let changesContent = viewport.plan.revision != model.timelineRenderPlan.revision
            transact(allowsContentAnimation: changesContent && viewport.allowsContentAnimation,
                animatesLayout: viewport.changesVisibleLayout(to: model.timelineRenderPlan)) {
                viewport.accept(model.timelineRenderPlan, request: model.timelineRevealRequest)
            }
        }
        .onScrollGeometryChange(for: Viewport.Geometry.self) { geometry in
            .init(rect: geometry.visibleRect, contentWidth: geometry.contentSize.width)
        } action: { _, geometry in
            let mountsInitialContent = viewport.geometry.rect.width == 0 && geometry.rect.width > 0 && !viewport.plan.cards.isEmpty
            transact(allowsContentAnimation: mountsInitialContent, animatesLayout: mountsInitialContent) {
                viewport.observe(geometry)
            }
        }
        .onScrollPhaseChange { _, phase in
            let manual = phase == .tracking || phase == .interacting || phase == .decelerating
            if manual { model.beginTimelineReview() }
            transact { viewport.phaseChanged(to: phase) }
        }
        .accessibilityScrollAction { direction in
            let forward: Bool
            switch direction {
            case .leading: forward = false
            case .trailing: forward = true
            default: return
            }
            model.beginTimelineReview()
            transact { viewport.page(forward: forward) }
        }
    }

    private func transact(allowsContentAnimation: Bool = false, animatesLayout: Bool = false, _ action: () -> CGFloat?) {
        let animation: Animation? = allowsContentAnimation && animatesLayout && !reduceMotion ? .smooth(duration: 0.32) : nil
        var contentTransaction = Transaction(animation: animation)
        contentTransaction.disablesAnimations = reduceMotion || !allowsContentAnimation
        let offset = withTransaction(contentTransaction, action)
        guard let offset else { return }
        var transaction = Transaction()
        transaction.animation = nil
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            position.scrollTo(x: offset)
        }
    }

    @ViewBuilder
    private func timelineHeader(_ header: TimelineRenderPlan.Header) -> some View {
        let label = Text(verbatim: header.name)
            .font(.caption.weight(.semibold))
            .lineLimit(2)
            .help(header.name)
        if let groupID = header.screenGroupID {
            label.accessibilityHidden(true)
                .overlay {
                    TimelineDragView(urlsForDrag: { [] }, accessibilityText: header.name,
                        accessibilityHint: String(localized: "Selects the visible screenshots for this screen", bundle: .module),
                        onClick: { _ in model.selectTimelineScreenGroup(groupID) }, keyboardTarget: keyboardTarget)
                }
        } else {
            label.accessibilityLabel(header.name)
        }
    }

    @ViewBuilder
    private func timelineCard(_ card: TimelineRenderPlan.Card) -> some View {
        switch card.content {
        case .emptyJob(let job) where job.importState.isPending:
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.quaternary)
                .overlay { ProgressView().controlSize(.small) }
                .frame(width: TimelineRenderPlan.imageWidth(for: 9 / 19), height: 112)
                .frame(width: 190, height: 136, alignment: .topLeading)
                .accessibilityElement()
                .accessibilityLabel(job.importState.label)
        case .emptyJob(let job):
            VStack(alignment: .leading, spacing: 6) {
                Text(job.importState.label)
                if let failure = job.importState.failure { Text(failure).lineLimit(3).help(failure) }
                Text("No screenshots available", bundle: .module)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(width: 190, height: 136, alignment: .leading)
        case .occurrence(let occurrence):
            let selected = model.selectedScreenshotIDs.contains(occurrence.id)
            TimelineOccurrenceCell(occurrence: occurrence,
                width: TimelineRenderPlan.imageWidth(for: occurrence.aspectRatio),
                showsVideoLabel: model.imports.models.count > 1,
                animatesCaptureArrival: model.isAnalyzing && model.followsLatest,
                isSelected: selected, previewReduceMotion: reduceMotion)
                .accessibilityHidden(occurrence.capture != nil)
                .overlay {
                    if occurrence.capture != nil {
                        TimelineDragView(urlsForDrag: { model.dragURLs(startingAt: occurrence.id) },
                            accessibilityText: occurrence.provenance + (selected ? String(localized: ", selected", bundle: .module) : "")
                                + (occurrence.classification.map { ", \($0.name)" } ?? ""),
                            onClick: { model.selectScreenshot(occurrence.id, modifiers: $0) }, keyboardTarget: keyboardTarget)
                    }
                }
                .help(occurrence.provenance)
        }
    }

    @MainActor
    @Observable
    final class Viewport {
        struct Geometry: Equatable {
            let rect: CGRect
            let contentWidth: CGFloat
        }
        struct Inspection {
            let anchor: TimelineRenderPlan.AnchorID
            let displacement: CGFloat
        }
        private enum Intent {
            case reveal(OccurrenceID)
            case preserve(Inspection?, TimelineRenderPlan, CGFloat)
            case page(CGFloat)
        }

        private(set) var plan = TimelineRenderPlan(sections: [], visibleIDs: [])
        private(set) var window = TimelineRenderPlan.Window(cards: 0..<0, headers: 0..<0)
        @ObservationIgnored private(set) var geometry = Geometry(rect: .zero, contentWidth: 0)
        @ObservationIgnored private(set) var inspected: Inspection?
        @ObservationIgnored private var inspectionPlan: TimelineRenderPlan?
        @ObservationIgnored private(set) var consumedRequestID: UUID?
        @ObservationIgnored private var phase: ScrollPhase = .idle
        private var manual: Bool { phase == .tracking || phase == .interacting || phase == .decelerating }
        var allowsContentAnimation: Bool { !manual }
        @ObservationIgnored private var pending: Intent?
        @ObservationIgnored private var issuedOffset: CGFloat?
        @ObservationIgnored private var issuedRevealTarget: OccurrenceID?

        func changesVisibleLayout(to next: TimelineRenderPlan) -> Bool {
            if plan.cards.isEmpty, !next.cards.isEmpty { return true }
            let nextWindow = next.window(in: geometry.rect, overscan: geometry.rect.width / 2)
            return !plan.cards[window.cards].elementsEqual(next.cards[nextWindow.cards], by: {
                $0.id == $1.id && $0.frame == $1.frame
            }) || !plan.headers[window.headers].elementsEqual(next.headers[nextWindow.headers], by: {
                $0.id == $1.id && $0.name == $1.name && $0.frame == $1.frame
            })
        }

        func accept(_ next: TimelineRenderPlan, request: TimelineRevealRequest?) -> CGFloat? {
            let replacing = next.revision != plan.revision
            let fresh = request.map { $0.id != consumedRequestID } ?? false
            let basis = inspectionPlan ?? plan
            if case .reveal(let target) = pending,
               fresh || request == nil || next.frame(for: .occurrence(target)) == nil {
                pending = basis.revision != next.revision && basis.size != .zero
                    ? .preserve(inspected, basis, geometry.rect.minX) : nil
            }
            if replacing {
                let old = basis
                let oldInspection = inspected
                plan = next
                if pending == nil, old.size != .zero { pending = .preserve(oldInspection, old, geometry.rect.minX) }
                if let target = issuedRevealTarget, request?.id == consumedRequestID,
                   next.frame(for: .occurrence(target)) != nil {
                    pending = .reveal(target)
                    issuedOffset = nil
                    issuedRevealTarget = nil
                }
            }
            if fresh, let request {
                consumedRequestID = request.id
                if next.frame(for: .occurrence(request.target)) != nil { pending = .reveal(request.target) }
                issuedOffset = nil
                issuedRevealTarget = nil
            }
            mount(at: geometry.rect.minX)
            return flush(allowManual: fresh)
        }

        func observe(_ next: Geometry) -> CGFloat? {
            let moved = next.rect.minX != geometry.rect.minX
            let acknowledgesPoint = issuedOffset.map { abs(next.rect.minX - $0) < 1 } ?? false
            geometry = next
            if moved, manual, !acknowledgesPoint {
                if issuedOffset == nil, case .reveal = pending { pending = nil }
                inspect()
                if case .preserve = pending { pending = .preserve(inspected, plan, next.rect.minX) }
            } else if issuedOffset == nil, pending == nil {
                inspect()
            }
            if let issuedOffset, moved || abs(next.rect.minX - issuedOffset) < 1 {
                self.issuedOffset = nil
                issuedRevealTarget = nil
                inspect()
            }
            mount(at: next.rect.minX)
            return flush()
        }

        func phaseChanged(to next: ScrollPhase) -> CGFloat? {
            let nextManual = next == .tracking || next == .interacting || next == .decelerating
            let resumed = phase == .decelerating && (next == .tracking || next == .interacting)
            if nextManual, !manual || resumed {
                switch pending {
                case .preserve: break
                default: pending = nil
                }
                issuedOffset = nil
                issuedRevealTarget = nil
                if pending == nil { inspect() }
            }
            phase = next
            return flush()
        }

        func page(forward: Bool) -> CGFloat? {
            pending = nil
            issuedOffset = nil
            issuedRevealTarget = nil
            inspect()
            pending = .page(geometry.rect.minX + (forward ? 1 : -1) * max(1, geometry.rect.width - 32))
            return flush(allowManual: true)
        }

        private func inspect() {
            inspectionPlan = plan
            let visible = plan.window(in: geometry.rect, overscan: 0)
            let anchor: TimelineRenderPlan.AnchorID?
            if let first = visible.cards.first { anchor = plan.cards[first].id }
            else if let first = visible.headers.first { anchor = .header(plan.headers[first].id) }
            else { anchor = nil }
            inspected = anchor.flatMap { id in
                plan.frame(for: id).map { Inspection(anchor: id, displacement: $0.minX - geometry.rect.minX) }
            }
        }

        private func mount(at x: CGFloat) {
            let offset = x > clamp(x) ? issuedOffset ?? x : x
            let rect = CGRect(x: offset, y: geometry.rect.minY, width: geometry.rect.width, height: geometry.rect.height)
            let next = plan.window(in: rect, overscan: rect.width / 2)
            if next != window { window = next }
        }

        private func clamp(_ offset: CGFloat) -> CGFloat {
            min(max(0, offset), max(0, plan.size.width - geometry.rect.width))
        }

        private func flush(allowManual: Bool = false) -> CGFloat? {
            guard let pending, geometry.rect.width > 0,
                  (abs(geometry.contentWidth - plan.size.width) < 1
                    || geometry.contentWidth >= max(plan.size.width, geometry.rect.width) - 1) else { return nil }
            if manual, !allowManual {
                let offset = clamp(geometry.rect.minX)
                guard offset < geometry.rect.minX, issuedOffset != offset else { return nil }
                mount(at: offset)
                issuedOffset = offset
                issuedRevealTarget = nil
                return offset
            }
            let x: CGFloat
            switch pending {
            case .reveal(let target):
                guard let frame = plan.frame(for: .occurrence(target)) else { self.pending = nil; return nil }
                if frame.width > geometry.rect.width || frame.minX < geometry.rect.minX { x = frame.minX }
                else if frame.maxX > geometry.rect.maxX { x = frame.maxX - geometry.rect.width }
                else { x = geometry.rect.minX }
            case .preserve(let inspection, let old, let raw):
                if let inspection, let anchor = plan.survivingAnchor(inspection.anchor, from: old),
                   let frame = plan.frame(for: anchor) { x = frame.minX - inspection.displacement }
                else { x = raw }
            case .page(let offset): x = offset
            }
            self.pending = nil
            let offset = clamp(x)
            mount(at: offset)
            guard abs(offset - geometry.rect.minX) > 0.01 else { inspect(); return nil }
            issuedOffset = offset
            if case .reveal(let target) = pending { issuedRevealTarget = target }
            else { issuedRevealTarget = nil }
            return offset
        }
    }
}

private struct TimelineOccurrenceCell: View {
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion

    let occurrence: SessionOccurrence
    let width: CGFloat
    let showsVideoLabel: Bool
    let animatesCaptureArrival: Bool
    var isSelected = false
    var previewReduceMotion = false

    private var reduceMotion: Bool {
        previewReduceMotion || systemReduceMotion
    }

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                StillsetStyle.surface
                Image(systemName: "photo")
                    .font(.system(size: 16, weight: .light))
                    .foregroundStyle(StillsetStyle.muted.opacity(0.65))
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(occurrence.provenance)
                    .accessibilityValue(Text("Queued", bundle: .module))
                    .accessibilityHidden(occurrence.capture != nil)

                if let screenshot = occurrence.capture {
                    ScreenshotPreview(
                        url: screenshot.fileURL,
                        maxPixelSize: 180,
                        occurrenceID: occurrence.id,
                        animatesCaptureArrival: animatesCaptureArrival,
                        showsLoadingIndicator: false,
                        previewReduceMotion: previewReduceMotion,
                        requiresScrollVisibility: true
                    )
                }
            }
            .frame(width: width, height: 112)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(
                        isSelected ? StillsetStyle.accent : StillsetStyle.border.opacity(0.55),
                        lineWidth: isSelected ? 2 : 0.5
                    )
            }
            .padding(3)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(StillsetStyle.accent.opacity(0.13))
                }
            }
            .animation(reduceMotion ? nil : .smooth(duration: 0.22), value: isSelected)

            VStack(alignment: .leading, spacing: 2) {
                if showsVideoLabel {
                    Text("V\(occurrence.videoOrdinal)")
                }
                Text(occurrence.state.representativeTimestamp.stillsetTimecode)
            }
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(StillsetStyle.muted)
                .lineLimit(2)
                .minimumScaleFactor(0.75)
                .padding(.horizontal, 3)
                .frame(height: showsVideoLabel ? 26 : 12, alignment: .top)
                .accessibilityHidden(true)
        }
        .frame(width: width + 6)
    }
}
