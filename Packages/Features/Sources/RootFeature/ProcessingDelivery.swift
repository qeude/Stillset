import Foundation
import OSLog
import StillsetCore
import Synchronization

final class PreviewDemand: Sendable {
    private let visible = Mutex(false)
    func setVisible(_ value: Bool) { visible.withLock { $0 = value } }
    func read() -> PreviewRequest? { visible.withLock { $0 } ? PreviewRequest() : nil }
}

private final class DeliveryCancellation: Sendable {
    let value = Mutex(false)
}

actor SessionCadence {
    private struct Waiter {
        let id: UUID
        let cancelled: DeliveryCancellation
        let continuation: CheckedContinuation<Void, Error>
    }
    private let now: @Sendable () -> ContinuousClock.Instant
    private let sleep: @Sendable (ContinuousClock.Instant) async throws -> Void
    private var next: ContinuousClock.Instant?
    private var busy = false
    private var waiters: [Waiter] = []

    init(now: @escaping @Sendable () -> ContinuousClock.Instant = { .now },
         sleep: @escaping @Sendable (ContinuousClock.Instant) async throws -> Void = {
             try await ContinuousClock().sleep(until: $0)
         }) {
        self.now = now
        self.sleep = sleep
    }

    func isDue() -> Bool { !busy && (next.map { $0 <= now() } ?? true) }

    func commit(_ body: @MainActor @Sendable () -> Bool) async throws -> Bool {
        let id = UUID()
        let cancelled = DeliveryCancellation()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await acquire(id, cancelled: cancelled)
        } onCancel: {
            cancelled.value.withLock { $0 = true }
            Task(priority: .utility) { await self.cancel(id) }
        }
        do {
            if let next { try await sleep(next) }
            try Task.checkCancellation()
            let now = now
            let (accepted, completion) = await MainActor.run {
                let accepted = body()
                return (accepted, now())
            }
            release(completed: completion)
            return accepted
        } catch {
            release(completed: nil)
            throw error
        }
    }

    private func acquire(_ id: UUID, cancelled: DeliveryCancellation) async throws {
        guard !cancelled.value.withLock({ $0 }) else { throw CancellationError() }
        if !busy { busy = true; return }
        try await withCheckedThrowingContinuation { continuation in
            waiters.append(Waiter(id: id, cancelled: cancelled, continuation: continuation))
        }
    }

    private func cancel(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }

    private func release(completed: ContinuousClock.Instant?) {
        if let completed { next = completed.advanced(by: .milliseconds(50)) }
        while !waiters.isEmpty {
            let waiter = waiters.removeFirst()
            if waiter.cancelled.value.withLock({ $0 }) {
                waiter.continuation.resume(throwing: CancellationError())
            } else { waiter.continuation.resume(); return }
        }
        busy = false
    }
}

enum StructuralRecord: Sendable {
    case detection(UIState)
    case capture(CapturedScreenshot)
}

struct PreparedFinalValues: Sendable {
    let captures: [CapturedScreenshot]
    let classifications: [UUID: ScreenClassification]
    let notice: String?
}

enum DeliveryBarrier: Sendable {
    case stage(AnalysisProgress, folder: URL? = nil)
    case finished(PreparedFinalValues)
}

struct DeliveryBatch: Sendable {
    let records: [StructuralRecord]
    let throughSequence: Int
    let progress: AnalysisProgress?
    let previews: [Frame]
    let sourceAspectRatio: Double?
    let barrier: DeliveryBarrier?
}

actor RunDelivery {
    private let cadence: SessionCadence
    private let commit: @MainActor @Sendable (DeliveryBatch) -> Bool
    private var records: [StructuralRecord] = []
    private var latestProgress: AnalysisProgress?
    private var latestPreviews: [Frame] = []
    private var ratio: Double?
    private var stage = AnalysisStage.decoding
    private(set) var sequence = 0
    private(set) var acknowledged = 0
    private(set) var peakBuffered = 0
    private var closed = false

    init(cadence: SessionCadence, commit: @escaping @MainActor @Sendable (DeliveryBatch) -> Bool) {
        self.cadence = cadence
        self.commit = commit
    }

    func detections(_ states: [UIState]) async throws {
        for state in states { try await append(.detection(state)) }
        try await drainIfDue()
    }

    func capture(_ capture: CapturedScreenshot) async throws {
        try await append(.capture(capture))
        try await drainIfDue()
    }

    func progress(_ progress: AnalysisProgress) async throws {
        try checkOpen()
        guard progress.stage == stage else { return }
        latestProgress = progress
        try await drainIfDue()
    }

    func previews(_ frames: [Frame]) async throws {
        try checkOpen()
        guard stage == .decoding else { return }
        ratio = frames.first?.sourceAspectRatio ?? ratio
        latestPreviews = Array((latestPreviews + frames.filter { $0.previewRGBA != nil }).suffix(2))
        try await drainIfDue()
    }

    func flush(_ barrier: DeliveryBarrier) async throws {
        try checkOpen()
        let acceptedThrough = sequence
        while !records.isEmpty { try await publish() }
        guard acknowledged == acceptedThrough else { throw CancellationError() }
        try await publish(barrier: barrier)
        if case .stage(let progress, _) = barrier { stage = progress.stage }
    }

    func closeForRecovery() {
        closed = true
        records.removeAll()
        latestProgress = nil
        latestPreviews.removeAll()
    }

    private func checkOpen() throws {
        try Task.checkCancellation()
        guard !closed else { throw CancellationError() }
    }

    private func append(_ record: StructuralRecord) async throws {
        try checkOpen()
        if records.count == 16 { try await publish() }
        records.append(record)
        sequence += 1
        peakBuffered = max(peakBuffered, records.count)
    }

    private func drainIfDue() async throws {
        if await cadence.isDue() { try await publish() }
    }

    private func publish(barrier: DeliveryBarrier? = nil) async throws {
        try checkOpen()
        let count = min(8, records.count)
        let through = acknowledged + count
        let batch = DeliveryBatch(records: Array(records.prefix(count)), throughSequence: through,
            progress: latestProgress, previews: latestPreviews, sourceAspectRatio: ratio, barrier: barrier)
        guard !batch.records.isEmpty || batch.progress != nil || !batch.previews.isEmpty || ratio != nil || barrier != nil else { return }
        let commit = commit
        guard try await cadence.commit({ commit(batch) }) else {
            closeForRecovery()
            throw CancellationError()
        }
        guard !closed else { throw CancellationError() }
        records.removeFirst(count)
        acknowledged = through
        latestProgress = nil
        latestPreviews.removeAll()
        ratio = nil
    }
}

let processingSignposter = OSSignposter(subsystem: "com.qeude.stillset", category: "ProcessingPublication")

final class SessionProcessing: Sendable {
    let budget = ProcessingBudget()
    let importLanes: [ProcessingLane]
    let catalogLane: ProcessingLane
    let thumbnailLane: ProcessingLane
    let copyLane: ProcessingLane
    let cadence = SessionCadence()

    init() {
        let lanes = try! budget.makeLanes(count: 5)
        importLanes = Array(lanes.prefix(2))
        catalogLane = lanes[2]
        thumbnailLane = lanes[3]
        copyLane = lanes[4]
    }
}

actor ProgressDelivery {
    private let cadence: SessionCadence
    private let commit: @MainActor @Sendable (Double, String) -> Bool
    private var latest: (Double, String)?

    init(cadence: SessionCadence, commit: @escaping @MainActor @Sendable (Double, String) -> Bool) {
        self.cadence = cadence
        self.commit = commit
    }

    func update(_ fraction: Double, _ detail: String) async throws {
        try Task.checkCancellation()
        latest = (fraction, detail)
        if await cadence.isDue() { try await flush() }
    }

    func flush() async throws {
        guard let value = latest else { return }
        let commit = commit
        guard try await cadence.commit({ commit(value.0, value.1) }) else { throw CancellationError() }
        latest = nil
    }
}
