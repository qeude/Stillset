import Foundation
import Synchronization

public enum ProcessingBudgetError: Error {
    case laneLimit
    case nestedOperation
}

/// One owner supplies finite lanes to all producers in a processing session.
public final class ProcessingBudget: Sendable {
    private let issued = Mutex(0)
    fileprivate let scheduler: ProcessingScheduler
    fileprivate let identity = UUID()
    fileprivate let now: @Sendable () -> ContinuousClock.Instant

    public init() {
        now = { .now }
        scheduler = ProcessingScheduler()
    }

    init(now: @escaping @Sendable () -> ContinuousClock.Instant,
         sleep: @escaping @Sendable (ContinuousClock.Instant) async throws -> Void) {
        self.now = now
        scheduler = ProcessingScheduler(now: now, sleep: sleep)
    }

    public func makeLanes(count: Int) throws -> [ProcessingLane] {
        try issued.withLock { issued in
            guard count > 0, count <= 5 - issued else { throw ProcessingBudgetError.laneLimit }
            let lanes = (issued..<(issued + count)).map { ProcessingLane(owner: self, index: $0) }
            issued += count
            return lanes
        }
    }
}

public struct ProcessingLane: Sendable {
    fileprivate let owner: ProcessingBudget
    fileprivate let index: Int
    @TaskLocal private static var operationOwner: UUID?

    /// Standalone entry points create one owner and pass this lane through their entire call graph.
    public static func standalone() -> ProcessingLane {
        try! ProcessingBudget().makeLanes(count: 1)[0]
    }

    public func perform<Value: Sendable>(
        _ operation: @Sendable () async throws -> Value
    ) async throws -> Value {
        guard Self.operationOwner != owner.identity else { throw ProcessingBudgetError.nestedOperation }
        let request = UUID()
        let cancelled = BudgetCancellation()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await owner.scheduler.acquire(request: request, lane: index, cancelled: cancelled)
        } onCancel: {
            cancelled.value.withLock { $0 = true }
            Task(priority: .utility) { await owner.scheduler.cancel(request) }
        }
        let start = owner.now()
        let result: Result<Value, Error>
        do {
            try Task.checkCancellation()
            result = .success(try await Self.$operationOwner.withValue(owner.identity) { try await operation() })
        } catch { result = .failure(error) }
        let completion = owner.now()
        await owner.scheduler.finish(lane: index, start: start, completion: completion)
        try Task.checkCancellation()
        return try result.get()
    }
}

private final class BudgetCancellation: Sendable {
    let value = Mutex(false)
}

private actor ProcessingScheduler {
    struct Request {
        let id: UUID
        let lane: Int
        let cancelled: BudgetCancellation
        let continuation: CheckedContinuation<Void, Error>
    }
    private let now: @Sendable () -> ContinuousClock.Instant
    private let sleep: @Sendable (ContinuousClock.Instant) async throws -> Void
    private var pending: [Request] = []
    private var executing: Set<Int> = []
    private var eligible: [Int: ContinuousClock.Instant] = [:]
    private var wake: Task<Void, Never>?
    private var wakeID: UUID?

    init(now: @escaping @Sendable () -> ContinuousClock.Instant = { .now },
         sleep: @escaping @Sendable (ContinuousClock.Instant) async throws -> Void = {
             try await ContinuousClock().sleep(until: $0)
         }) {
        self.now = now
        self.sleep = sleep
    }

    func acquire(request: UUID, lane: Int, cancelled: BudgetCancellation) async throws {
        guard !cancelled.value.withLock({ $0 }) else { throw CancellationError() }
        try await withCheckedThrowingContinuation { continuation in
            pending.append(Request(id: request, lane: lane, cancelled: cancelled, continuation: continuation))
            refill()
        }
    }

    func cancel(_ id: UUID) {
        guard let index = pending.firstIndex(where: { $0.id == id }) else { return }
        let request = pending.remove(at: index)
        request.continuation.resume(throwing: CancellationError())
        refill()
    }

    func finish(lane: Int, start: ContinuousClock.Instant, completion: ContinuousClock.Instant) {
        guard executing.remove(lane) != nil else { return }
        eligible[lane] = completion.advanced(by: max(.milliseconds(1), start.duration(to: completion) / 4))
        refill()
    }

    private func refill() {
        wake?.cancel()
        wake = nil
        wakeID = nil
        let instant = now()
        var index = 0
        while index < pending.count {
            let request = pending[index]
            if request.cancelled.value.withLock({ $0 }) {
                pending.remove(at: index)
                request.continuation.resume(throwing: CancellationError())
            } else if executing.count < 2, !executing.contains(request.lane), eligible[request.lane].map({ $0 <= instant }) ?? true {
                pending.remove(at: index)
                executing.insert(request.lane)
                request.continuation.resume()
            } else { index += 1 }
        }
        guard executing.count < 2,
              let deadline = pending.filter({ !executing.contains($0.lane) }).compactMap({ eligible[$0.lane] }).min() else { return }
        let id = UUID()
        wakeID = id
        let sleep = sleep
        wake = Task.detached(priority: .utility) { [weak self] in
            do {
                try await sleep(deadline)
                try Task.checkCancellation()
                await self?.deadlineReached(id)
            } catch {}
        }
    }

    private func deadlineReached(_ id: UUID) {
        guard wakeID == id else { return }
        refill()
    }
}

public struct PreviewRequest: Sendable {
    public let maximumPixelSize: Int
    public init(maximumPixelSize: Int = 1400) { self.maximumPixelSize = max(1, min(1400, maximumPixelSize)) }
}
