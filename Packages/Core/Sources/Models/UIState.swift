import Foundation

public struct UIState: Identifiable, Sendable {
    public let id: UUID
    public let interval: Range<TimeInterval>
    public let representativeTimestamp: TimeInterval
    public let stabilityScore: Float

    public init(
        id: UUID = UUID(),
        interval: Range<TimeInterval>,
        representativeTimestamp: TimeInterval,
        stabilityScore: Float
    ) {
        self.id = id
        self.interval = interval
        self.representativeTimestamp = representativeTimestamp
        self.stabilityScore = stabilityScore
    }
}

public struct AnalysisResult: Sendable {
    public let sourceURL: URL
    public let duration: TimeInterval
    public let states: [UIState]

    public init(sourceURL: URL, duration: TimeInterval, states: [UIState]) {
        self.sourceURL = sourceURL
        self.duration = duration
        self.states = states
    }
}
