import Foundation
import ImageIO
import StillsetCore
import SwiftUI

struct ThumbnailKey: Hashable, Sendable {
    let url: URL
    let maximumPixels: Int
    let captureStateID: UUID?
}

@MainActor
final class ThumbnailLoader {
    private struct Consumer {
        let key: ThumbnailKey
        let priority: Int
        let ordinal: Int
        let receive: @MainActor (CGImage?) -> Void
        var served = false
    }
    private struct Request: Sendable {
        let key: ThumbnailKey
        let cached: CGImage?
    }
    private let lane: ProcessingLane
    private let cadence: SessionCadence
    private let decode: @Sendable (ThumbnailKey) async throws -> CGImage?
    private var consumers: [UUID: Consumer] = [:]
    private var window: [ThumbnailKey] = []
    private var refill: [ThumbnailKey] = []
    private var inFlight: Set<ThumbnailKey> = []
    private var currentKey: ThumbnailKey?
    private var ordinal = 0
    private var cache: [ThumbnailKey: CGImage] = [:]
    private var cacheKeysByURL: [URL: Set<ThumbnailKey>] = [:]
    private var cacheOrder: [ThumbnailKey] = []
    private var cacheBytes = 0
    private var worker: Task<Void, Never>?
    private(set) var peakWindow = 0
    private(set) var peakRefill = 0

    init(lane: ProcessingLane, cadence: SessionCadence,
         decode: @escaping @Sendable (ThumbnailKey) async throws -> CGImage? = { key in
             guard let source = CGImageSourceCreateWithURL(key.url as CFURL, [
                 kCGImageSourceShouldCache: false
             ] as CFDictionary) else { return nil }
             return CGImageSourceCreateThumbnailAtIndex(source, 0, [
                 kCGImageSourceCreateThumbnailFromImageAlways: true,
                 kCGImageSourceCreateThumbnailWithTransform: true,
                 kCGImageSourceThumbnailMaxPixelSize: key.maximumPixels
             ] as CFDictionary)
         }) {
        self.lane = lane
        self.cadence = cadence
        self.decode = decode
    }

    func demand(_ key: ThumbnailKey, consumer id: UUID, priority: Int,
                receive: @escaping @MainActor (CGImage?) -> Void) {
        if consumers[id]?.key == key { return }
        if consumers[id] != nil { cancel(id) }
        ordinal += 1
        consumers[id] = Consumer(key: key, priority: priority, ordinal: ordinal, receive: receive)
        startWorker()
    }

    func cancel(_ consumer: UUID) {
        consumers[consumer] = nil
        let keys = Set(consumers.values.filter { !$0.served }.map(\.key))
        window.removeAll { !keys.contains($0) }
        refill.removeAll { !keys.contains($0) }
        if let currentKey, !keys.contains(currentKey) { worker?.cancel() }
    }

    private func startWorker() {
        guard worker == nil else { return }
        let lane = lane
        let cadence = cadence
        let decode = decode
        worker = Task.detached(priority: .utility) { [weak self] in
            while !Task.isCancelled, let first = await self?.next() {
                var images: [(ThumbnailKey, CGImage?)] = []
                var request: Request? = first
                while let current = request {
                    let image: CGImage?
                    do {
                        image = try await lane.perform {
                            if let cached = current.cached { return cached }
                            return try await decode(current.key)
                        }
                    } catch { image = nil }
                    if Task.isCancelled { break }
                    images.append((current.key, image))
                    if images.count == 8 { break }
                    request = await self?.next()
                }
                let completed = images
                _ = try? await cadence.commit {
                    for (key, image) in completed { self?.complete(key, image: image) }
                    return true
                }
            }
            await self?.workerEnded()
        }
    }

    private func next() -> Request? {
        let current = consumers.values.filter { !$0.served && !inFlight.contains($0.key) }.sorted {
            $0.priority == $1.priority ? $0.ordinal < $1.ordinal : $0.priority > $1.priority
        }
        window.removeAll(keepingCapacity: true)
        var admitted: Set<ThumbnailKey> = []
        for consumer in current where window.count < 128 {
            if admitted.insert(consumer.key).inserted { window.append(consumer.key) }
        }
        refill = Array(window.prefix(32))
        peakWindow = max(peakWindow, window.count)
        peakRefill = max(peakRefill, refill.count)
        guard let key = refill.first else { return nil }
        inFlight.insert(key)
        currentKey = key
        return Request(key: key, cached: cache[key])
    }

    private func complete(_ key: ThumbnailKey, image: CGImage?) {
        inFlight.remove(key)
        if currentKey == key { currentKey = nil }
        window.removeAll { $0 == key }
        refill.removeAll { $0 == key }
        let ids = consumers.keys.filter { consumers[$0]?.key == key && consumers[$0]?.served == false }
        guard !ids.isEmpty else { return }
        if let image, cache[key] == nil {
            let cost = image.bytesPerRow * image.height
            while cacheBytes + cost > 64 * 1024 * 1024, !cacheOrder.isEmpty {
                let oldest = cacheOrder.removeFirst()
                if let evicted = cache.removeValue(forKey: oldest) {
                    cacheBytes -= evicted.bytesPerRow * evicted.height
                    cacheKeysByURL[oldest.url]?.remove(oldest)
                    if cacheKeysByURL[oldest.url]?.isEmpty == true { cacheKeysByURL[oldest.url] = nil }
                }
            }
            if cost <= 64 * 1024 * 1024 {
                cache[key] = image
                cacheKeysByURL[key.url, default: []].insert(key)
                cacheOrder.append(key)
                cacheBytes += cost
            }
        }
        for id in ids {
            guard var consumer = consumers[id] else { continue }
            consumer.served = true
            consumers[id] = consumer
            consumer.receive(image)
        }
    }

    private func workerEnded() {
        worker = nil
        currentKey = nil
        inFlight.removeAll()
        if consumers.values.contains(where: { !$0.served }) { startWorker() }
    }

    isolated deinit { worker?.cancel() }

    func cachedImage(for url: URL) -> CGImage? {
        guard let key = cacheKeysByURL[url]?.max(by: { $0.maximumPixels < $1.maximumPixels }) else { return nil }
        return cache[key]
    }

    func waitUntilDrained() async {
        while let worker { await worker.value }
    }
}

private struct ThumbnailLoaderKey: EnvironmentKey {
    static let defaultValue: ThumbnailLoader? = nil
}
extension EnvironmentValues {
    var thumbnailLoader: ThumbnailLoader? {
        get { self[ThumbnailLoaderKey.self] }
        set { self[ThumbnailLoaderKey.self] = newValue }
    }
}
