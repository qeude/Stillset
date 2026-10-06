import Foundation

public struct StableStateDetector: Sendable {
    public let minimumStableDuration: TimeInterval
    public let minimumCandidateDuration: TimeInterval
    private var motionAnalyzer = MotionAnalyzer()
    private let frameSelector = RepresentativeFrameSelector()
    private var previousFrame: Frame?
    private var stableStart: TimeInterval?
    private var bestFrame: Frame?
    private var bestScore: Float = -.infinity
    private var bestStability: Float = 0
    private var candidateConfirmed = false

    public init(minimumStableDuration: TimeInterval = 0.12, minimumCandidateDuration: TimeInterval = 0.04) {
        self.minimumStableDuration = minimumStableDuration
        self.minimumCandidateDuration = minimumCandidateDuration
    }

    public mutating func consume(_ frame: Frame) -> StateCandidate? {
        let sample = motionAnalyzer.sample(current: frame, previous: previousFrame)
        var completed: StateCandidate?

        if StabilityAnalyzer.isMoving(sample) {
            completed = finish(until: previousFrame?.timestamp ?? frame.timestamp)
            stableStart = nil
            bestFrame = nil
            bestScore = -.infinity
            bestStability = 0
            candidateConfirmed = false
        } else {
            if stableStart == nil {
                stableStart = frame.timestamp
                bestFrame = frame
                bestScore = -.infinity
                bestStability = 0
                candidateConfirmed = false
            }
            let start = stableStart ?? frame.timestamp
            let score = frameSelector.score(frame: frame, motion: sample, secondsFromTransition: frame.timestamp - start)
            if score > bestScore {
                bestScore = score
                bestFrame = frame
                bestStability = max(0, 1 - sample.globalEnergy)
            }
            if frame.timestamp - start + 0.000_001 >= minimumStableDuration { candidateConfirmed = true }
        }

        previousFrame = frame
        return completed
    }

    public mutating func finish() -> StateCandidate? {
        finish(until: previousFrame?.timestamp ?? 0)
    }

    private mutating func finish(until end: TimeInterval) -> StateCandidate? {
        defer {
            stableStart = nil
            bestFrame = nil
            bestScore = -.infinity
            bestStability = 0
            candidateConfirmed = false
        }
        guard let start = stableStart, let frame = bestFrame, end - start >= minimumCandidateDuration else { return nil }
        return StateCandidate(interval: start..<max(start, end), frame: frame, stabilityScore: bestStability, isConfirmed: candidateConfirmed)
    }
}
