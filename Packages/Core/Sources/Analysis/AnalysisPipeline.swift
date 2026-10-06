import Foundation

public enum AnalysisPipeline {
    public static func run(
        url: URL,
        onProgress: @Sendable (AnalysisProgress) -> Void,
        onAnalyzedFrames: @Sendable ([Frame]) async -> Void = { _ in },
        onPrepared: @Sendable (TimeInterval) async -> Void = { _ in },
        onDetectedScreens: @Sendable ([UIState]) async -> Void = { _ in }
    ) async throws -> AnalysisResult {
        let accumulator = CandidateAccumulator()
        let duration = try await VideoDecoder.decode(url: url, onFrames: { frames in
            let detected = await accumulator.consume(frames)
            if !detected.isEmpty { await onDetectedScreens(detected) }
            await onAnalyzedFrames(frames)
        }, onProgress: onProgress, onPrepared: onPrepared)
        let (states, finalState) = await accumulator.finish()
        if let finalState { await onDetectedScreens([finalState]) }
        guard !states.isEmpty else { throw VideoAnalysisError.noStableStates }
        onProgress(AnalysisProgress(stage: .complete, fraction: 1, detail: "\(states.count.formatted()) screenshots ready"))
        return AnalysisResult(sourceURL: url, duration: duration, states: states)
    }
}

private actor CandidateAccumulator {
    private var detector = StableStateDetector()
    private var states: [UIState] = []

    func consume(_ frames: [Frame]) -> [UIState] {
        let previousCount = states.count
        for frame in frames {
            if let candidate = detector.consume(frame) { append(candidate) }
        }
        return Array(states.dropFirst(previousCount))
    }

    func finish() -> ([UIState], UIState?) {
        let finalState = detector.finish().map { append($0) }
        return (states, finalState)
    }

    @discardableResult
    private func append(_ candidate: StateCandidate) -> UIState {
        let state = UIState(
            interval: candidate.interval,
            representativeTimestamp: candidate.frame.timestamp,
            stabilityScore: candidate.stabilityScore
        )
        states.append(state)
        return state
    }
}
