import CoreGraphics
import Foundation
@testable import StillsetCore
import Testing
@testable import StillsetFeatures

@MainActor
struct ThumbnailLoaderTests {
    @Test func overflowRefillsWithoutAVisibilityChangeAndCoalescesKeys() async throws {
        let clock = DeliveryTestTime()
        let cadence = SessionCadence(now: { clock.now }, sleep: { clock.advance(to: $0) })
        let image = try thumbnailTestImage()
        let recorder = ThumbnailRecorder(image: image)
        let loader = ThumbnailLoader(lane: .standalone(), cadence: cadence, decode: { await recorder.decode($0) })
        var received: [Int] = []
        var duplicates = 0
        let revision = UUID()
        for index in 0..<170 {
            let key = ThumbnailKey(url: URL(fileURLWithPath: "/fixture/\(index).png"), maximumPixels: 180, captureStateID: revision)
            loader.demand(key, consumer: UUID(), priority: 0) { result in
                if result != nil { received.append(index) }
            }
            if index == 0 { loader.demand(key, consumer: UUID(), priority: 0) { if $0 != nil { duplicates += 1 } } }
        }
        await loader.waitUntilDrained()
        #expect(received == Array(0..<170))
        #expect(duplicates == 1)
        #expect(await recorder.keys.count == 170)
        #expect(loader.peakWindow == 128)
        #expect(loader.peakRefill == 32)
    }

    @Test func cancellationRemovesConsumersAndQueuedDemandButDrainsActiveImage() async throws {
        let image = try thumbnailTestImage()
        let gate = ThumbnailGate(image: image)
        let clock = DeliveryTestTime()
        let loader = ThumbnailLoader(lane: .standalone(),
            cadence: SessionCadence(now: { clock.now }, sleep: { clock.advance(to: $0) }),
            decode: { await gate.decode($0) })
        let active = ThumbnailKey(url: URL(fileURLWithPath: "/active.png"), maximumPixels: 180, captureStateID: UUID())
        let waiting = ThumbnailKey(url: URL(fileURLWithPath: "/waiting.png"), maximumPixels: 180, captureStateID: UUID())
        let first = UUID(), second = UUID(), duplicate = UUID()
        var delivered: [String] = []
        loader.demand(active, consumer: first, priority: 2) { _ in delivered.append("cancelled") }
        loader.demand(active, consumer: duplicate, priority: 2) { _ in delivered.append("survivor") }
        loader.demand(waiting, consumer: second, priority: 0) { _ in delivered.append("queued") }
        await gate.waitForStart()
        loader.cancel(first)
        loader.cancel(second)
        #expect(await gate.keys == [active])
        await gate.release()
        await loader.waitUntilDrained()
        #expect(delivered == ["survivor"])
        #expect(await gate.keys == [active])
    }

    @Test func replacingConsumerDrainsExecutingImageBeforeNewImageStarts() async throws {
        let gate = ThumbnailGate(image: try thumbnailTestImage())
        let time = DeliveryTestTime()
        let loader = ThumbnailLoader(lane: .standalone(),
            cadence: SessionCadence(now: { time.now }, sleep: { time.advance(to: $0) }),
            decode: { await gate.decode($0) })
        let old = ThumbnailKey(url: URL(fileURLWithPath: "/executing.png"), maximumPixels: 180, captureStateID: UUID())
        let replacement = ThumbnailKey(url: URL(fileURLWithPath: "/replacement.png"), maximumPixels: 180, captureStateID: UUID())
        let id = UUID()
        var delivered: [String] = []
        loader.demand(old, consumer: id, priority: 0) { _ in delivered.append("obsolete") }
        await gate.waitForStart()
        loader.demand(replacement, consumer: id, priority: 2) { _ in delivered.append("replacement") }
        #expect(await gate.keys == [old])
        await gate.release()
        await gate.waitForStart(2)
        #expect(await gate.keys == [old, replacement])
        #expect(delivered.isEmpty)
        await gate.release()
        await loader.waitUntilDrained()
        #expect(delivered == ["replacement"])
    }

    @Test func replacingConsumerCancelsObsoleteCooldownAdmission() async throws {
        let clock = FeatureControlledClock()
        let lane = try ProcessingBudget(now: { clock.now }, sleep: { try await clock.sleep(until: $0) }).makeLanes(count: 1)[0]
        _ = try await lane.perform { clock.advance(by: .milliseconds(40)) }
        let image = try thumbnailTestImage()
        let recorder = ThumbnailRecorder(image: image)
        let publicationTime = DeliveryTestTime()
        let loader = ThumbnailLoader(lane: lane,
            cadence: SessionCadence(now: { publicationTime.now }, sleep: { publicationTime.advance(to: $0) }),
            decode: { await recorder.decode($0) })
        let old = ThumbnailKey(url: URL(fileURLWithPath: "/old.png"), maximumPixels: 180, captureStateID: UUID())
        let replacement = ThumbnailKey(url: URL(fileURLWithPath: "/replacement.png"), maximumPixels: 180, captureStateID: UUID())
        let consumer = UUID()
        var delivered: [String] = []
        loader.demand(old, consumer: consumer, priority: 0) { _ in delivered.append("old") }
        await clock.waitForSleep()
        loader.demand(replacement, consumer: consumer, priority: 2) { _ in delivered.append("replacement") }
        clock.advance(by: .seconds(1))
        await loader.waitUntilDrained()
        #expect(await recorder.keys == [replacement])
        #expect(delivered == ["replacement"])
    }

    @Test func indexedVisibleDemandCancelsOnEvictionAndReentrySurvives() async throws {
        let items = RenderFixture.occurrences(20)
        let plan = RenderFixture.plan([items])
        let initial = plan.window(in: CGRect(x: 0, y: 0, width: 260, height: 208), overscan: 0)
        let mounted = plan.window(in: CGRect(x: 0, y: 0, width: 260, height: 208), overscan: 130)
        #expect(initial.cards == 0..<2 && mounted.cards == 0..<3)
        let gate = ThumbnailGate(image: try thumbnailTestImage())
        let time = DeliveryTestTime()
        let loader = ThumbnailLoader(lane: .standalone(),
            cadence: SessionCadence(now: { time.now }, sleep: { time.advance(to: $0) }),
            decode: { await gate.decode($0) })
        let consumers = [UUID(), UUID()]
        let keys = [0, 1].map { ThumbnailKey(url: URL(fileURLWithPath: "/visible-\($0).png"),
            maximumPixels: 180, captureStateID: items[$0].id.stateID) }
        var delivered: [String] = []
        for index in initial.cards {
            loader.demand(keys[index], consumer: consumers[index], priority: 0) { _ in delivered.append("old-\(index)") }
        }
        await gate.waitForStart()
        let evicted = plan.window(in: CGRect(x: 540, y: 0, width: 260, height: 208), overscan: 0)
        #expect(evicted.cards == 3..<6)
        for consumer in consumers { loader.cancel(consumer) }
        loader.demand(keys[0], consumer: consumers[0], priority: 0) { _ in delivered.append("current") }
        await gate.release()
        await gate.waitForStart(2)
        #expect(await gate.keys == [keys[0], keys[0]])
        #expect(delivered.isEmpty)
        await gate.release()
        await loader.waitUntilDrained()
        #expect(delivered == ["current"])
        #expect(await gate.keys == [keys[0], keys[0]])
    }

    @Test func URLSizeAndImmutableFileRevisionSeparateCacheEntries() async throws {
        let image = try thumbnailTestImage()
        let recorder = ThumbnailRecorder(image: image)
        let clock = DeliveryTestTime()
        let loader = ThumbnailLoader(lane: .standalone(),
            cadence: SessionCadence(now: { clock.now }, sleep: { clock.advance(to: $0) }),
            decode: { await recorder.decode($0) })
        let url = URL(fileURLWithPath: "/image.png"), revision = UUID()
        let keys = [ThumbnailKey(url: url, maximumPixels: 180, captureStateID: revision),
                    ThumbnailKey(url: url, maximumPixels: 650, captureStateID: revision),
                    ThumbnailKey(url: url, maximumPixels: 180, captureStateID: UUID())]
        var received = 0
        for key in keys { loader.demand(key, consumer: UUID(), priority: 0) { if $0 != nil { received += 1 } } }
        await loader.waitUntilDrained()
        loader.demand(keys[0], consumer: UUID(), priority: 2) { if $0 != nil { received += 1 } }
        await loader.waitUntilDrained()
        #expect(received == 4)
        #expect(await recorder.keys == keys)
    }
}

private func thumbnailTestImage() throws -> CGImage {
    let context = try #require(CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8,
        bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    return try #require(context.makeImage())
}

private actor ThumbnailRecorder {
    let image: CGImage
    private(set) var keys: [ThumbnailKey] = []
    init(image: CGImage) { self.image = image }
    func decode(_ key: ThumbnailKey) -> CGImage { keys.append(key); return image }
}

private actor ThumbnailGate {
    let image: CGImage
    private(set) var keys: [ThumbnailKey] = []
    private var continuation: CheckedContinuation<Void, Never>?
    private var started: [(Int, CheckedContinuation<Void, Never>)] = []
    init(image: CGImage) { self.image = image }
    func decode(_ key: ThumbnailKey) async -> CGImage {
        keys.append(key)
        let ready = started.filter { keys.count >= $0.0 }
        started.removeAll { keys.count >= $0.0 }
        for (_, waiter) in ready { waiter.resume() }
        await withCheckedContinuation { continuation = $0 }
        return image
    }
    func waitForStart(_ count: Int = 1) async {
        if keys.count >= count { return }
        await withCheckedContinuation { started.append((count, $0)) }
    }
    func release() { continuation?.resume(); continuation = nil }
}
