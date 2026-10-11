import Foundation
import Testing
@testable import StillsetCore

struct RecentAnalysisCacheTests {
    private let date = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func exactOccurrencesGroupsAndPartialDiagnosticsRoundTrip() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = RecentAnalysisCache(directory: root.appendingPathComponent("cache"))
        let video = root.appendingPathComponent("video.mov")
        try Data([1, 2, 3]).write(to: video)
        let source = try #require(try await cache.fingerprint(for: video))
        let original = snapshot(video)
        try await cache.store(original, for: source)
        let restored = try #require(try await cache.load(for: source))
        #expect(restored.duration == 3)
        #expect(restored.occurrences.map(\.state.id) == original.occurrences.map(\.state.id))
        #expect(restored.occurrences.map(\.state.interval) == [0..<1, 1..<2, 2..<3])
        #expect(restored.occurrences.map(\.state.representativeTimestamp) == [1, 1.5, 2.5])
        #expect(restored.occurrences.map(\.state.stabilityScore) == [1, 0.75, 1])
        #expect(restored.catalog.classifications == original.catalog.classifications)
        #expect(restored.catalog.recognitionFailures == 1)
        #expect(restored.catalog.visionNames == 2)
        #expect(restored.catalog.errorDescription == "Reconnaissance partielle")
        #expect(!restored.catalog.usedContextualNaming)
        let json = try String(contentsOf: cacheFiles(root)[0], encoding: .utf8)
        #expect(!json.contains(video.path))
        #expect(!json.contains("fileURL") && !json.contains("sourceURL"))
    }

    @Test func removeAllForgetsStoredAnalyses() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = RecentAnalysisCache(directory: root.appendingPathComponent("cache"))
        try await cache.removeAll()
        let video = root.appendingPathComponent("video.mov")
        try Data([1, 2, 3]).write(to: video)
        let source = try #require(try await cache.fingerprint(for: video))
        try await cache.store(snapshot(video), for: source)
        try await cache.removeAll()
        #expect(try await cache.load(for: source) == nil)
        try await cache.store(snapshot(video), for: source)
        #expect(try await cache.load(for: source) != nil)
    }

    @Test func renameCopyAndSameLengthContentChanges() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = RecentAnalysisCache(directory: root.appendingPathComponent("cache"))
        let first = root.appendingPathComponent("first.mov")
        let renamed = root.appendingPathComponent("renamed.mov")
        let copied = root.appendingPathComponent("copied.mov")
        try Data([1, 2, 3]).write(to: first)
        let source = try #require(try await cache.fingerprint(for: first))
        try await cache.store(snapshot(first), for: source)
        try FileManager.default.moveItem(at: first, to: renamed)
        try FileManager.default.copyItem(at: renamed, to: copied)
        for url in [renamed, copied] {
            let identity = try #require(try await cache.fingerprint(for: url))
            let hit = try #require(try await cache.load(for: identity))
            #expect(hit.result(for: url).sourceURL == url)
        }
        let old = try #require(try await cache.fingerprint(for: copied))
        let modified = try FileManager.default.attributesOfItem(atPath: copied.path)[.modificationDate]
        try Data([3, 2, 1]).write(to: copied)
        try FileManager.default.setAttributes([.modificationDate: modified as Any], ofItemAtPath: copied.path)
        #expect(try await cache.matches(old) == false)
        try await cache.store(snapshot(copied), for: old)
        let changed = try #require(try await cache.fingerprint(for: copied))
        #expect(try await cache.load(for: changed) == nil)
    }

    @Test func invalidDiskEntriesSilentlyMiss() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = RecentAnalysisCache(directory: root.appendingPathComponent("cache"))
        let video = root.appendingPathComponent("video.mov")
        try Data([1, 2, 3]).write(to: video)
        let source = try #require(try await cache.fingerprint(for: video))
        try await cache.store(snapshot(video), for: source)
        let file = try #require(try cacheFiles(root).first)
        let valid = try Data(contentsOf: file)
        let mutations: [(inout [String: Any]) -> Void] = [
            { $0["language"] = "unsupported" },
            { $0["schemaVersion"] = 999 }, { $0["analysisVersion"] = 999 },
            { $0["duration"] = -1 }, { $0["recognitionFailures"] = 4 },
            { $0["lastUsedAt"] = 9_999_999_999.0 },
            { object in
                var occurrences = object["occurrences"] as! [[String: Any]]
                occurrences[1]["id"] = occurrences[0]["id"]
                object["occurrences"] = occurrences
            },
            { object in
                var occurrences = object["occurrences"] as! [[String: Any]]
                occurrences[0]["timestamp"] = 4
                object["occurrences"] = occurrences
            },
            { object in
                var occurrences = object["occurrences"] as! [[String: Any]]
                occurrences[0]["end"] = 0
                object["occurrences"] = occurrences
            },
            { object in
                var occurrences = object["occurrences"] as! [[String: Any]]
                occurrences[0]["id"] = "not-a-uuid"
                object["occurrences"] = occurrences
            },
            { object in
                var occurrences = object["occurrences"] as! [[String: Any]]
                occurrences[0]["score"] = 1.5
                object["occurrences"] = occurrences
            },
            { object in
                var occurrences = object["occurrences"] as! [[String: Any]]
                occurrences[0]["screenID"] = -1
                object["occurrences"] = occurrences
            },
            { object in
                var occurrences = object["occurrences"] as! [[String: Any]]
                occurrences[0]["name"] = "bad\u{0000}name"
                object["occurrences"] = occurrences
            }
        ]
        for mutate in mutations {
            var object = try JSONSerialization.jsonObject(with: valid) as! [String: Any]
            mutate(&object)
            try JSONSerialization.data(withJSONObject: object).write(to: file)
            #expect(try await cache.load(for: source) == nil)
        }
        try Data("corrupt".utf8).write(to: file)
        #expect(try await cache.load(for: source) == nil)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        #expect(try await cache.load(for: source) == nil)
    }

    @Test func retentionAgeLRUCountAndBytes() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sources = try (0..<3).map { index in
            let url = root.appendingPathComponent("\(index).mov")
            try Data([UInt8(index)]).write(to: url)
            return url
        }
        let folder = root.appendingPathComponent("cache")
        let cache = RecentAnalysisCache(directory: folder, limits: .init(entries: 2), now: { date })
        let first = try #require(try await cache.fingerprint(for: sources[0]))
        let second = try #require(try await cache.fingerprint(for: sources[1]))
        let third = try #require(try await cache.fingerprint(for: sources[2]))
        try await cache.store(snapshot(sources[0]), for: first)
        let later = RecentAnalysisCache(directory: folder, limits: .init(entries: 2), now: { date.addingTimeInterval(10) })
        try await later.store(snapshot(sources[1]), for: second)
        let touch = RecentAnalysisCache(directory: folder, limits: .init(entries: 2), now: { date.addingTimeInterval(20) })
        _ = try await touch.load(for: first)
        #expect(try cacheFiles(root).count == 2)
        let untouched = try JSONSerialization.jsonObject(with: Data(contentsOf: cacheFiles(root).first {
            (try? String(contentsOf: $0, encoding: .utf8).contains("\"lastUsedAt\":1800000000")) == true
        }!)) as! [String: Any]
        #expect(untouched["lastUsedAt"] as? Double == date.timeIntervalSince1970)
        try await touch.markUsed(first)
        try await touch.store(snapshot(sources[2]), for: third)
        #expect(try await touch.load(for: first) != nil)
        #expect(try await touch.load(for: second) == nil)
        #expect(try await touch.load(for: third) != nil)
        #expect(try cacheFiles(root).count == 2)
        let size = try cacheFiles(root).reduce(0) { try $0 + Data(contentsOf: $1).count }
        let bounded = RecentAnalysisCache(directory: folder, limits: .init(totalBytes: size / 2 + 50), now: { date.addingTimeInterval(30) })
        try await bounded.store(snapshot(sources[1]), for: second)
        #expect(try cacheFiles(root).reduce(0) { try $0 + Data(contentsOf: $1).count } <= size / 2 + 50)
        let expired = RecentAnalysisCache(directory: folder, limits: .init(), now: { date.addingTimeInterval(31 * 86400) })
        #expect(try await expired.load(for: second) == nil)
        #expect(try cacheFiles(root).isEmpty)
        try await expired.store(snapshot(sources[2]), for: third)
        #expect(try cacheFiles(root).count == 1)
    }

    @Test(arguments: [false, true])
    func rejectedSourceDoesNotEvictFullCache(removed: Bool) async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = RecentAnalysisCache(directory: root.appendingPathComponent("cache"), limits: .init(entries: 2))
        let videos = try (0..<3).map { index in
            let url = root.appendingPathComponent("\(index).mov")
            try Data([UInt8(index), 1, 2]).write(to: url)
            return url
        }
        let first = try #require(try await cache.fingerprint(for: videos[0]))
        let second = try #require(try await cache.fingerprint(for: videos[1]))
        let incoming = try #require(try await cache.fingerprint(for: videos[2]))
        try await cache.store(snapshot(videos[0]), for: first)
        try await cache.store(snapshot(videos[1]), for: second)
        let before = try cacheContents(root)
        #expect(before.count == 2)
        if removed {
            try FileManager.default.removeItem(at: videos[2])
        } else {
            let modified = try FileManager.default.attributesOfItem(atPath: videos[2].path)[.modificationDate]
            try Data([2, 2, 1]).write(to: videos[2])
            try FileManager.default.setAttributes([.modificationDate: modified as Any], ofItemAtPath: videos[2].path)
        }
        try await cache.store(snapshot(videos[2]), for: incoming)
        #expect(try cacheContents(root) == before)
        let retainedFirst = try #require(try await cache.load(for: first))
        let retainedSecond = try #require(try await cache.load(for: second))
        #expect(retainedFirst.occurrences.map(\.state.representativeTimestamp) == [1, 1.5, 2.5])
        #expect(retainedSecond.catalog.recognitionFailures == 1)
    }

    @Test func cancelledStoreBeforeSourceValidationDoesNotEvictFullCache() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = RecentAnalysisCache(directory: root.appendingPathComponent("cache"), limits: .init(entries: 1))
        let video = root.appendingPathComponent("retained.mov")
        try Data([1, 2, 3]).write(to: video)
        let retained = try #require(try await cache.fingerprint(for: video))
        try await cache.store(snapshot(video), for: retained)
        let incomingVideo = root.appendingPathComponent("incoming.mov")
        try Data([3, 2, 1]).write(to: incomingVideo)
        let incoming = try #require(try await cache.fingerprint(for: incomingVideo))
        let analysis = snapshot(incomingVideo)
        let before = try cacheContents(root)
        #expect(before.count == 1)
        try FileManager.default.removeItem(at: incomingVideo)
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await cache.store(analysis, for: incoming)
        }
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        #expect(try cacheContents(root) == before)
        let restored = try #require(try await cache.load(for: retained))
        #expect(restored.occurrences.map(\.state.representativeTimestamp) == [1, 1.5, 2.5])
    }

    @Test func oversizeReadFailureSymlinksAndCancellation() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("cache")
        let video = root.appendingPathComponent("video.mov")
        try Data([1, 2, 3]).write(to: video)
        let cache = RecentAnalysisCache(directory: folder, limits: .init(entryBytes: 100))
        let source = try #require(try await cache.fingerprint(for: video))
        try await cache.store(snapshot(video), for: source)
        #expect(try cacheFiles(root).isEmpty)
        let normal = RecentAnalysisCache(directory: folder)
        try await normal.store(snapshot(video), for: source)
        let file = try #require(try cacheFiles(root).first)
        let outside = root.appendingPathComponent("outside.json")
        try FileManager.default.moveItem(at: file, to: outside)
        let bytes = try Data(contentsOf: outside)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: outside)
        #expect(try await normal.load(for: source) == nil)
        try await normal.store(snapshot(video), for: source)
        #expect(try Data(contentsOf: outside) == bytes)
        try FileManager.default.removeItem(at: folder)
        try FileManager.default.createSymbolicLink(at: folder, withDestinationURL: root)
        #expect(try await normal.load(for: source) == nil)
        try await normal.store(snapshot(video), for: source)
        #expect(try Data(contentsOf: outside) == bytes)
        let unavailable = RecentAnalysisCache(directory: video)
        try await unavailable.store(snapshot(video), for: source)
        #expect(try await unavailable.load(for: source) == nil)
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await normal.fingerprint(for: video)
        }
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        #expect(try await normal.fingerprint(for: root.appendingPathComponent("missing.mov")) == nil)
    }

    private func snapshot(_ url: URL) -> CachedAnalysis {
        let states: [UIState] = (0..<3).map { index in
            let start = Double(index)
            let timestamp: Double = index == 0 ? 1 : start + 0.5
            let score: Float = index == 1 ? 0.75 : 1
            return UIState(interval: start..<(start + 1), representativeTimestamp: timestamp, stabilityScore: score)
        }
        let labels = [ScreenClassification(screenID: 1, name: "Accueil", stateID: 1),
                      ScreenClassification(screenID: 1, name: "Accueil", stateID: 2),
                      ScreenClassification(screenID: 1, name: "Accueil", stateID: 1)]
        return CachedAnalysis(result: AnalysisResult(sourceURL: url, duration: 3, states: states),
            catalog: ScreenCatalog(classifications: labels, usedContextualNaming: false,
                visionNames: 2, recognitionFailures: 1, errorDescription: "Reconnaissance partielle"))!
    }

    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Stillset-cache-tests-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func cacheFiles(_ root: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("cache"), includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
    }

    private func cacheContents(_ root: URL) throws -> [String: Data] {
        try Dictionary(uniqueKeysWithValues: cacheFiles(root).map { ($0.lastPathComponent, try Data(contentsOf: $0)) })
    }
}
