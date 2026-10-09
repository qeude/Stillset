import Foundation
import Synchronization
import Testing
@testable import StillsetCore

struct ProcessingBudgetTests {
    @Test func finiteLanesGlobalPeakAndDrainBeforeRefill() async throws {
        let budget = ProcessingBudget()
        let lanes = try budget.makeLanes(count: 5)
        #expect(throws: ProcessingBudgetError.self) { try budget.makeLanes(count: 1) }
        #expect(throws: ProcessingBudgetError.self) { try budget.makeLanes(count: .max) }
        let gate = OperationGate()
        let first = Task { try await lanes[0].perform { await gate.run(0) } }
        let second = Task { try await lanes[1].perform { await gate.run(1) } }
        await gate.waitForStarts(2)
        let third = Task { try await lanes[2].perform { await gate.run(2) } }
        let fourth = Task { try await lanes[3].perform { await gate.run(3) } }
        let fifth = Task { try await lanes[4].perform { await gate.run(4) } }
        first.cancel()
        #expect(await gate.started.count == 2)
        await gate.release(0)
        await gate.waitForStarts(3)
        await gate.release(1)
        await gate.waitForStarts(4)
        for index in await gate.started where index >= 2 { await gate.release(index) }
        await gate.waitForStarts(5)
        for index in 2...4 { await gate.release(index) }
        await #expect(throws: CancellationError.self) { try await first.value }
        _ = try await second.value
        _ = try await third.value
        _ = try await fourth.value
        _ = try await fifth.value
        #expect(await gate.peak == 2)
        #expect(Set(await gate.started) == Set(0...4))
    }

    @Test func overlappingSameLaneWorkSerializesAndCancelledWaiterPreservesAdmission() async throws {
        let lanes = try ProcessingBudget().makeLanes(count: 2)
        let gate = OperationGate()
        let active = Task { try await lanes[0].perform { await gate.run(0) } }
        await gate.waitForStarts(1)
        let cancelledBodyRan = Mutex(false)
        let cancelled = Task {
            try await lanes[0].perform { cancelledBodyRan.withLock { $0 = true }; return 42 }
        }
        cancelled.cancel()
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        let queued = Task { try await lanes[0].perform { await gate.run(1) } }
        let otherLane = Task { try await lanes[1].perform { await gate.run(2) } }
        await gate.waitForStarts(2)
        #expect(await gate.started == [0, 2])
        #expect(!cancelledBodyRan.withLock { $0 })
        await gate.release(0)
        _ = try await active.value
        await gate.waitForStarts(3)
        #expect(await gate.started == [0, 2, 1])
        await gate.release(1)
        await gate.release(2)
        #expect(try await queued.value == 1)
        #expect(try await otherLane.value == 2)
        #expect(await gate.peak == 2)
        await #expect(throws: ProcessingBudgetError.self) {
            try await lanes[0].perform { try await lanes[1].perform { 42 } }
        }
        #expect(try await lanes[0].perform { 7 } == 7)
    }

    @Test func cancellationBeforeRegistrationAndDuringCooldownStopsReplacement() async throws {
        let clock = ControlledClock()
        let lane = try ProcessingBudget(now: { clock.now }, sleep: { try await clock.sleep(until: $0) }).makeLanes(count: 1)[0]
        let first = try await lane.perform { clock.advance(by: .milliseconds(40)); return 1 }
        #expect(first == 1)
        let next = Task { try await lane.perform { 2 } }
        await clock.waitForSleep()
        next.cancel()
        await #expect(throws: CancellationError.self) { try await next.value }
        let alreadyCancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await lane.perform { 3 }
        }
        await #expect(throws: CancellationError.self) { try await alreadyCancelled.value }
        clock.advance(by: .seconds(1))
        #expect(try await lane.perform { 4 } == 4)
    }

    @Test func executorHandoffDoesNotInflateTheOperationCooldown() async throws {
        let clock = ControlledClock()
        let reads = Mutex(0)
        let budget = ProcessingBudget(now: {
            let handoff = reads.withLock { reads in reads += 1; return reads == 2 }
            if handoff { clock.advance(by: .milliseconds(100)) }
            return clock.now
        }, sleep: { try await clock.sleep(until: $0) })
        let lane = try budget.makeLanes(count: 1)[0]
        _ = try await lane.perform { clock.advance(by: .milliseconds(40)) }
        let next = Task { try await lane.perform { 7 } }
        await clock.waitForSleep()
        #expect(clock.nextDeadline == clock.origin.advanced(by: .milliseconds(150)))
        clock.advance(by: .seconds(1))
        #expect(try await next.value == 7)
    }

    @Test func coolingLaneDoesNotBlockAnotherAndDeadlinesDoNotAccumulateCredit() async throws {
        let clock = ControlledClock()
        let lanes = try ProcessingBudget(now: { clock.now }, sleep: { try await clock.sleep(until: $0) }).makeLanes(count: 2)
        _ = try await lanes[0].perform { clock.advance(by: .milliseconds(40)) }
        let replacement = Task { try await lanes[0].perform { clock.now } }
        await clock.waitForSleep()
        #expect(try await lanes[1].perform { 9 } == 9)
        clock.advance(by: .milliseconds(9))
        #expect(clock.now == clock.origin.advanced(by: .milliseconds(49)))
        clock.advance(by: .seconds(1))
        #expect(try await replacement.value == clock.now)
        let noCatchup = Task { try await lanes[0].perform { 10 } }
        await clock.waitForSleep()
        clock.advance(by: .milliseconds(1))
        #expect(try await noCatchup.value == 10)
    }
}

private actor OperationGate {
    private(set) var started: [Int] = []
    private(set) var peak = 0
    private var active = 0
    private var operations: [Int: CheckedContinuation<Void, Never>] = [:]
    private var observers: [(Int, CheckedContinuation<Void, Never>)] = []
    func run(_ id: Int) async -> Int {
        active += 1
        peak = max(peak, active)
        started.append(id)
        let ready = observers.filter { started.count >= $0.0 }
        observers.removeAll { started.count >= $0.0 }
        for (_, observer) in ready { observer.resume() }
        await withCheckedContinuation { operations[id] = $0 }
        active -= 1
        return id
    }
    func waitForStarts(_ count: Int) async {
        if started.count >= count { return }
        await withCheckedContinuation { observers.append((count, $0)) }
    }
    func release(_ id: Int) { operations.removeValue(forKey: id)?.resume() }
}

final class ControlledClock: Sendable {
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
    var nextDeadline: ContinuousClock.Instant? { state.withLock { $0.sleepers.values.map(\.deadline).min() } }
    func advance(by duration: Duration) {
        state.withLock { state in
            state.instant = state.instant.advanced(by: duration)
            let ready = state.sleepers.filter { $0.value.deadline <= state.instant }
            for (id, sleeper) in ready {
                state.sleepers[id] = nil
                sleeper.continuation.resume()
            }
        }
    }
    func sleep(until deadline: ContinuousClock.Instant) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                state.withLock { state in
                    if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                    else if state.instant >= deadline { continuation.resume() }
                    else {
                        state.sleepers[id] = Sleeper(deadline: deadline, continuation: continuation)
                        for observer in state.observers { observer.resume() }
                        state.observers.removeAll()
                    }
                }
            }
        } onCancel: {
            self.state.withLock { $0.sleepers.removeValue(forKey: id)?.continuation.resume(throwing: CancellationError()) }
        }
    }
    func waitForSleep() async {
        await withCheckedContinuation { continuation in
            state.withLock { state in
                if !state.sleepers.isEmpty { continuation.resume() }
                else { state.observers.append(continuation) }
            }
        }
    }
}
