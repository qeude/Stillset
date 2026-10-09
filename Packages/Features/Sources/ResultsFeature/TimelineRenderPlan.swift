import Foundation

struct TimelineRevealRequest: Equatable {
    enum Cause: Equatable { case navigation, groupSelection, followLatest }
    let id: UUID
    let target: OccurrenceID
    let cause: Cause
}

@MainActor
struct TimelineRenderPlan {
    struct Section: Identifiable {
        enum ID: Hashable { case video(UUID), screen(OccurrenceID) }
        let id: ID
        let name: String
        let screenGroupID: OccurrenceID?
        let occurrences: [SessionOccurrence]
        let job: AppModel?
    }
    enum AnchorID: Hashable {
        case occurrence(OccurrenceID), emptyJob(UUID), header(Section.ID)
    }
    struct Card: Identifiable {
        enum Content { case occurrence(SessionOccurrence), emptyJob(AppModel) }
        let id: AnchorID
        let content: Content
        let frame: CGRect
    }
    struct Header: Identifiable {
        let id: Section.ID
        let name: String
        let screenGroupID: OccurrenceID?
        let frame: CGRect
    }
    struct Window: Equatable {
        let cards: Range<Int>
        let headers: Range<Int>
    }

    let revision = UUID()
    let size: CGSize
    let cards: [Card]
    let headers: [Header]
    private let frames: [AnchorID: CGRect]
    private let cardRanks: [AnchorID: Int]
    private let headerBodyRanks: [Section.ID: Int]
    private let chapters: [AnchorID: Section.ID]

    init(sections: [Section], visibleIDs: Set<OccurrenceID>) {
        let interval = processingSignposter.beginInterval("TimelinePlan")
        defer { processingSignposter.endInterval("TimelinePlan", interval) }
        var cards: [Card] = []
        var headers: [Header] = []
        var frames: [AnchorID: CGRect] = [:]
        var ranks: [AnchorID: Int] = [:]
        var chapters: [AnchorID: Section.ID] = [:]
        var headerBodyRanks: [Section.ID: Int] = [:]
        var x: CGFloat = 24
        for section in sections {
            headerBodyRanks[section.id] = cards.count
            var bodyX = x
            func append(_ card: Card) {
                ranks[card.id] = cards.count
                chapters[card.id] = section.id
                frames[card.id] = card.frame
                cards.append(card)
            }
            for occurrence in section.occurrences where visibleIDs.contains(occurrence.id) {
                let width = Self.imageWidth(for: occurrence.aspectRatio) + 18
                append(Card(id: .occurrence(occurrence.id), content: .occurrence(occurrence),
                    frame: CGRect(x: bodyX, y: 48, width: width, height: 150)))
                bodyX += width
            }
            if section.occurrences.isEmpty, let job = section.job {
                append(Card(id: .emptyJob(job.id), content: .emptyJob(job),
                    frame: CGRect(x: x, y: 48, width: 190, height: 136)))
                bodyX += 190
            }
            let minimumWidth: CGFloat
            let headerWidth: CGFloat
            switch section.id {
            case .video:
                minimumWidth = 240
                headerWidth = 240
            case .screen:
                minimumWidth = 0
                headerWidth = bodyX - x
            }
            let width = max(minimumWidth, bodyX - x)
            if !section.name.isEmpty {
                let header = Header(id: section.id, name: section.name, screenGroupID: section.screenGroupID,
                    frame: CGRect(x: x, y: 10, width: headerWidth, height: 32))
                headers.append(header)
                frames[.header(section.id)] = header.frame
            }
            x += width + 20
        }
        self.cards = cards
        self.headers = headers
        self.frames = frames
        cardRanks = ranks
        self.chapters = chapters
        self.headerBodyRanks = headerBodyRanks
        size = sections.isEmpty ? .zero : CGSize(width: x - 20 + 24, height: 208)
    }

    static func imageWidth(for ratio: CGFloat) -> CGFloat {
        min(160, max(48, 112 * (ratio.isFinite && ratio > 0 ? ratio : 9 / 19)))
    }

    func window(in visibleRect: CGRect, overscan: CGFloat) -> Window {
        let interval = processingSignposter.beginInterval("TimelineWindowQuery")
        defer { processingSignposter.endInterval("TimelineWindowQuery", interval) }
        let leading = visibleRect.minX - max(0, overscan)
        let trailing = visibleRect.maxX + max(0, overscan)
        func range(count: Int, frame: (Int) -> CGRect) -> Range<Int> {
            var low = 0, high = count
            while low < high {
                let mid = (low + high) / 2
                if frame(mid).maxX <= leading { low = mid + 1 } else { high = mid }
            }
            let start = low
            high = count
            while low < high {
                let mid = (low + high) / 2
                if frame(mid).minX < trailing { low = mid + 1 } else { high = mid }
            }
            return start..<low
        }
        return Window(cards: range(count: cards.count) { cards[$0].frame },
            headers: range(count: headers.count) { headers[$0].frame })
    }

    func frame(for anchor: AnchorID) -> CGRect? { frames[anchor] }

    func survivingAnchor(_ anchor: AnchorID, from old: Self) -> AnchorID? {
        if frames[anchor] != nil { return anchor }
        let successorStart: Int?
        let predecessorEnd: Int?
        if case .header(let section) = anchor {
            successorStart = old.headerBodyRanks[section]
            predecessorEnd = successorStart
        } else {
            successorStart = old.cardRanks[anchor].map { $0 + 1 }
            predecessorEnd = old.cardRanks[anchor]
        }
        if let successorStart {
            for card in old.cards.dropFirst(successorStart) where frames[card.id] != nil { return card.id }
        }
        if let predecessorEnd {
            for card in old.cards.prefix(predecessorEnd).reversed() where frames[card.id] != nil { return card.id }
        }
        if let chapter = old.chapters[anchor], frames[.header(chapter)] != nil { return .header(chapter) }
        return nil
    }
}
