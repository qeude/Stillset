import Foundation

public enum AnalysisPipeline {
    public static func run(
        url: URL,
        work: ProcessingLane = .standalone(),
        previewRequest: @escaping @Sendable () -> PreviewRequest? = { PreviewRequest() },
        onProgress: @Sendable (AnalysisProgress) async throws -> Void,
        onAnalyzedFrames: @Sendable ([Frame]) async throws -> Void = { _ in },
        onPrepared: @Sendable (TimeInterval) async throws -> Void = { _ in },
        onDetectedScreens: @Sendable ([UIState]) async throws -> Void = { _ in }
    ) async throws -> AnalysisResult {
        let accumulator = CandidateAccumulator()
        let duration = try await VideoDecoder.decode(url: url, work: work, previewRequest: previewRequest, onFrames: { frames in
            let detected = try await work.perform { await accumulator.consume(frames) }
            if !detected.isEmpty { try await onDetectedScreens(detected) }
            try await onAnalyzedFrames(frames)
        }, onProgress: onProgress, onPrepared: onPrepared)
        let (states, finalState) = try await work.perform { await accumulator.finish() }
        if let finalState { try await onDetectedScreens([finalState]) }
        guard !states.isEmpty else { throw VideoAnalysisError.noStableStates }
        try await onProgress(AnalysisProgress(stage: .complete, fraction: 1, detail: String(localized: "\(states.count.formatted()) screenshots ready", bundle: .module)))
        try Task.checkCancellation()
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
