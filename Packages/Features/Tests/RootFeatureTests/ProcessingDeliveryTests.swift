import Foundation
import Synchronization
import StillsetCore
import Testing
@testable import StillsetFeatures

@MainActor
struct ProcessingDeliveryTests {
    @Test func boundedLosslessRecordsAndStageTailAcknowledgement() async throws {
        let clock = DeliveryTestTime()
        let cadence = SessionCadence(now: { clock.now }, sleep: { clock.advance(to: $0) })
        var batches: [DeliveryBatch] = []
        var starts: [ContinuousClock.Instant] = []
        let delivery = RunDelivery(cadence: cadence) { batch in
            batches.append(batch)
            starts.append(clock.now)
            clock.advance(by: .milliseconds(7))
            return true
        }
        try await delivery.progress(AnalysisProgress(stage: .decoding, fraction: 0, detail: "initial"))
        let states = (0..<41).map { UIState(interval: Double($0)..<Double($0 + 1), representativeTimestamp: Double($0), stabilityScore: 1) }
        try await delivery.detections(states)
        try await delivery.progress(AnalysisProgress(stage: .decoding, fraction: 0.5, detail: "old"))
        try await delivery.progress(AnalysisProgress(stage: .decoding, fraction: 0.75, detail: "latest"))
        try await delivery.flush(.stage(AnalysisProgress(stage: .exporting, fraction: 0, detail: "export")))
        let captures = states.map { CapturedScreenshot(state: $0, fileURL: URL(fileURLWithPath: "/missing/\($0.id).png")) }
        for capture in captures { try await delivery.capture(capture) }
        try await delivery.progress(AnalysisProgress(stage: .decoding, fraction: 1, detail: "stale stage"))
        try await delivery.flush(.stage(AnalysisProgress(stage: .annotating, fraction: 0, detail: "annotate")))
        try await delivery.flush(.finished(PreparedFinalValues(captures: captures, classifications: [:], notice: "done")))
        #expect(await delivery.peakBuffered == 16)
        #expect(await delivery.acknowledged == 82)
        #expect(batches.allSatisfy { $0.records.count <= 8 })
        let detections = batches.flatMap(\.records).compactMap { record -> UUID? in
            if case .detection(let state) = record { return state.id }; return nil
        }
        let written = batches.flatMap(\.records).compactMap { record -> UUID? in
            if case .capture(let capture) = record { return capture.id }; return nil
        }
        #expect(detections == states.map(\.id))
        #expect(written == captures.map(\.id))
        let barriers = batches.filter { $0.barrier != nil }
        #expect(barriers.map(\.throughSequence) == [41, 82, 82])
        #expect(!batches.contains { $0.progress?.detail == "old" || $0.progress?.detail == "stale stage" })
        #expect(batches.contains { $0.progress?.detail == "latest" })
        #expect(zip(starts, starts.dropFirst()).allSatisfy { $0.duration(to: $1) == .milliseconds(57) })
    }

    @Test func sharedCadenceUsesActualCompletionAndHasNoCatchup() async throws {
        let clock = DeliveryTestTime()
        let cadence = SessionCadence(now: { clock.now }, sleep: { clock.advance(to: $0) })
        var starts: [ContinuousClock.Instant] = []
        let body: @MainActor @Sendable () -> Bool = {
            starts.append(clock.now)
            clock.advance(by: .milliseconds(80))
            return true
        }
        let first = RunDelivery(cadence: cadence) { _ in body() }
        let second = RunDelivery(cadence: cadence) { _ in body() }
        let stage = AnalysisProgress(stage: .exporting, fraction: 0, detail: "stage")
        async let a: Void = first.flush(.stage(stage))
        async let b: Void = second.flush(.stage(stage))
        async let catalog = cadence.commit(body)
        async let copy = cadence.commit(body)
        _ = try await (a, b, catalog, copy)
        #expect(starts.count == 4)
        #expect(zip(starts, starts.dropFirst()).allSatisfy { $0.duration(to: $1) == .milliseconds(130) })
        clock.advance(by: .seconds(2))
        _ = try await cadence.commit(body)
        _ = try await cadence.commit(body)
        #expect(starts[4].duration(to: starts[5]) == .milliseconds(130))
    }

    @Test func replaceableCatalogAndCopyProgressDoNotPaceEveryFileButFlushTheExactTail() async throws {
        let clock = DeliveryTestTime()
        let cadence = SessionCadence(now: { clock.now }, sleep: { clock.advance(to: $0) })
        var values: [Double] = []
        let delivery = ProgressDelivery(cadence: cadence) { fraction, _ in values.append(fraction); return true }
        for index in 1...642 { try await delivery.update(Double(index) / 642, "copy") }
        #expect(values == [Double(1) / 642])
        try await delivery.flush()
        #expect(values == [Double(1) / 642, 1])
    }

    @Test func rejectedAttemptNeverAcknowledgesItsBarrier() async throws {
        let delivery = RunDelivery(cadence: SessionCadence()) { _ in false }
        let state = UIState(interval: 0..<1, representativeTimestamp: 0, stabilityScore: 1)
        await #expect(throws: CancellationError.self) { try await delivery.detections([state]) }
        #expect(await delivery.sequence == 1)
        #expect(await delivery.acknowledged == 0)
        await #expect(throws: CancellationError.self) {
            try await delivery.flush(.stage(AnalysisProgress(stage: .exporting, fraction: 0, detail: "never")))
        }
    }

    @Test func cancellationDuringCadenceDropsNormalDeliveryAndReleasesAdmission() async throws {
        let clock = FeatureControlledClock()
        let cadence = SessionCadence(now: { clock.now }, sleep: { try await clock.sleep(until: $0) })
        _ = try await cadence.commit { true }
        var installed = 0
        let delivery = RunDelivery(cadence: cadence) { _ in installed += 1; return true }
        let stage = AnalysisProgress(stage: .exporting, fraction: 0, detail: "stage")
        let task = Task { try await delivery.flush(.stage(stage)) }
        await clock.waitForSleep()
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        await delivery.closeForRecovery()
        #expect(installed == 0)
        clock.advance(by: .seconds(1))
        #expect(try await cadence.commit { true })
    }
}

final class DeliveryTestTime: Sendable {
    private let instant = Mutex(ContinuousClock.now)
    var now: ContinuousClock.Instant { instant.withLock { $0 } }
    func advance(to deadline: ContinuousClock.Instant) { instant.withLock { $0 = max($0, deadline) } }
    func advance(by duration: Duration) { instant.withLock { $0 = $0.advanced(by: duration) } }
}

final class FeatureControlledClock: Sendable {
    let origin = ContinuousClock.now
    private struct Sleeper {
        let deadline: ContinuousClock.Instant
        let continuation: CheckedContinuation<Void, Error>
    }
    private struct State {
        var instant: ContinuousClock.Instant
        var sleepers: [UUID: Sleeper] = [:]
        var observers: [CheckedContinuation<Void, Never>] = []
    }
    private let state: Mutex<State>
    init() { state = Mutex(State(instant: origin)) }
    var now: ContinuousClock.Instant { state.withLock { $0.instant } }
    func advance(by duration: Duration) {
        let ready = state.withLock { state in
            state.instant = state.instant.advanced(by: duration)
            let ready = state.sleepers.filter { $0.value.deadline <= state.instant }
            for id in ready.keys { state.sleepers[id] = nil }
            return ready.values.map(\.continuation)
        }
        for continuation in ready { continuation.resume() }
    }
    func sleep(until deadline: ContinuousClock.Instant) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let (resolution, observers) = state.withLock { state -> (Int, [CheckedContinuation<Void, Never>]) in
                    if Task.isCancelled { return (2, []) }
                    if state.instant >= deadline { return (1, []) }
                    state.sleepers[id] = Sleeper(deadline: deadline, continuation: continuation)
                    let observers = state.observers
                    state.observers.removeAll()
                    return (0, observers)
                }
                for observer in observers { observer.resume() }
                if resolution == 2 { continuation.resume(throwing: CancellationError()) }
                else if resolution == 1 { continuation.resume() }
            }
        } onCancel: {
            let continuation = self.state.withLock { $0.sleepers.removeValue(forKey: id)?.continuation }
            continuation?.resume(throwing: CancellationError())
        }
    }
    func waitForSleep() async {
        await withCheckedContinuation { continuation in
            let ready = state.withLock { state in
                if !state.sleepers.isEmpty { return true }
                state.observers.append(continuation)
                return false
            }
            if ready { continuation.resume() }
        }
    }
}
