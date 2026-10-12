import CryptoKit
import Darwin
import Foundation

public struct CachedAnalysis: Sendable {
    public struct Occurrence: Sendable {
        public let state: UIState
        public let classification: ScreenClassification
    }

    public let duration: TimeInterval
    public let occurrences: [Occurrence]
    public let usedContextualNaming: Bool
    public let visionNames: Int
    public let recognitionFailures: Int
    public let errorDescription: String?

    public init?(result: AnalysisResult, catalog: ScreenCatalog) {
        guard result.states.count == catalog.classifications.count else { return nil }
        duration = result.duration
        occurrences = zip(result.states, catalog.classifications).map { Occurrence(state: $0, classification: $1) }
        usedContextualNaming = catalog.usedContextualNaming
        visionNames = catalog.visionNames
        recognitionFailures = catalog.recognitionFailures
        errorDescription = catalog.errorDescription
    }

    public func result(for sourceURL: URL) -> AnalysisResult {
        AnalysisResult(sourceURL: sourceURL, duration: duration, states: occurrences.map(\.state))
    }

    public var catalog: ScreenCatalog {
        ScreenCatalog(classifications: occurrences.map(\.classification), usedContextualNaming: usedContextualNaming,
                      visionNames: visionNames, recognitionFailures: recognitionFailures, errorDescription: errorDescription)
    }
}

public actor RecentAnalysisCache {
    public static let shared = RecentAnalysisCache()
    public static let schemaVersion = 2
    public static let analysisVersion = 5

    public struct Source: Sendable {
        fileprivate let url: URL
        fileprivate let sha256: String
        fileprivate let byteCount: Int64
        fileprivate let stamp: Stamp
        fileprivate let generation: Int
    }

    struct Limits: Sendable {
        var maxAge: TimeInterval = 30 * 24 * 60 * 60
        var totalBytes = 10 * 1024 * 1024
        var entries = 50
        var entryBytes = 1024 * 1024
    }

    private let directory: URL
    private let limits: Limits
    private let now: @Sendable () -> Date
    /// Sources fingerprinted before the last `removeAll()` belong to analyses the user asked to forget.
    private var generation = 0

    public init(directory: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("com.qeude.stillset/RecentAnalysis", isDirectory: true)) {
        self.directory = directory
        limits = Limits()
        now = { Date() }
    }

    init(directory: URL, limits: Limits, now: @escaping @Sendable () -> Date = { Date() }) {
        self.directory = directory
        self.limits = limits
        self.now = now
    }

    private enum SourceError: Error { case changed }

    public func fingerprint(for url: URL) throws -> Source? {
        do { return try hash(url) }
        catch is CancellationError { throw CancellationError() }
        catch { return nil }
    }

    private func hash(_ url: URL) throws -> Source {
        try Task.checkCancellation()
        let before = try stamp(url)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var digest = SHA256()
        var count: Int64 = 0
        while true {
            try Task.checkCancellation()
            let bytes = try handle.read(upToCount: 1024 * 1024) ?? Data()
            if bytes.isEmpty { break }
            count += Int64(bytes.count)
            digest.update(data: bytes)
        }
        try Task.checkCancellation()
        guard count > 0, count == before.size, before == (try stamp(url)) else { throw SourceError.changed }
        return Source(url: url, sha256: digest.finalize().map { String(format: "%02x", $0) }.joined(),
                      byteCount: count, stamp: before, generation: generation)
    }

    /// An unavailable source disables persistence without discarding usable captures.
    public func matches(_ source: Source) throws -> Bool? {
        do {
            let current = try hash(source.url)
            return current.sha256 == source.sha256 && current.byteCount == source.byteCount
        } catch is CancellationError { throw CancellationError() }
        catch is SourceError { return false }
        catch { return nil }
    }

    public func load(for source: Source) throws -> CachedAnalysis? {
        try Task.checkCancellation()
        guard try prune(reserving: 0, replacing: nil, incomingEntries: 0), let envelope = read(file(for: source)),
              envelope.sha256 == source.sha256, envelope.byteCount == source.byteCount else { return nil }
        return envelope.analysis
    }

    /// Forgets every saved analysis, so the next import of a recording is analyzed from scratch.
    public func removeAll() throws {
        generation += 1
        guard safeDirectory(create: false) else { return }
        try FileManager.default.removeItem(at: directory)
    }

    public func store(_ analysis: CachedAnalysis, for source: Source) throws {
        try Task.checkCancellation()
        guard source.generation == generation, safeDirectory(create: true) else { return }
        let envelope = Envelope(analysis, source: source, date: now())
        guard valid(envelope), let data = try? JSONEncoder().encode(envelope), data.count <= limits.entryBytes,
              data.count <= limits.totalBytes, limits.entries > 0 else { return }
        guard let verified = try fingerprint(for: source.url),
              verified.sha256 == source.sha256, verified.byteCount == source.byteCount else { return }
        let destination = file(for: source)
        try Task.checkCancellation()
        guard try prune(reserving: data.count, replacing: destination) else { return }
        try Task.checkCancellation()
        guard safeDirectory(create: false), !isSymlink(destination) else { return }
        try Task.checkCancellation()
        guard verified.stamp == (try? stamp(source.url)) else { return }
        try? data.write(to: destination, options: .atomic)
    }

    /// Call after successful reconstruction and a final `matches` check.
    public func markUsed(_ source: Source) throws {
        try Task.checkCancellation()
        guard source.generation == generation, safeDirectory(create: false), var envelope = read(file(for: source)),
              envelope.sha256 == source.sha256, envelope.byteCount == source.byteCount else { return }
        envelope.lastUsedAt = now().timeIntervalSince1970
        guard let data = try? JSONEncoder().encode(envelope), data.count <= limits.entryBytes else { return }
        guard try prune(reserving: data.count, replacing: file(for: source)) else { return }
        try Task.checkCancellation()
        guard safeDirectory(create: false), !isSymlink(file(for: source)) else { return }
        try? data.write(to: file(for: source), options: .atomic)
    }

    fileprivate struct Stamp: Equatable, Sendable {
        let size: Int64
        let modifiedSeconds: Int
        let modifiedNanos: Int
        let changedSeconds: Int
        let changedNanos: Int
        let inode: UInt64
    }

    private func stamp(_ url: URL) throws -> Stamp {
        var info = stat()
        guard stat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            throw CocoaError(.fileReadUnknown)
        }
        return Stamp(size: info.st_size, modifiedSeconds: info.st_mtimespec.tv_sec,
                     modifiedNanos: info.st_mtimespec.tv_nsec, changedSeconds: info.st_ctimespec.tv_sec,
                     changedNanos: info.st_ctimespec.tv_nsec, inode: info.st_ino)
    }

    private func file(for source: Source) -> URL { directory.appendingPathComponent(source.sha256 + ".json") }

    private func isSymlink(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType) == .typeSymbolicLink
    }

    private func safeDirectory(create: Bool) -> Bool {
        guard !isSymlink(directory) else { return false }
        if create { try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        return (try? FileManager.default.attributesOfItem(atPath: directory.path)[.type] as? FileAttributeType) == .typeDirectory
    }

    private func read(_ url: URL) -> Envelope? {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_size > 0, info.st_size <= limits.entryBytes,
              let data = try? handle.read(upToCount: limits.entryBytes + 1), data.count <= limits.entryBytes,
              let envelope = try? JSONDecoder().decode(Envelope.self, from: data), valid(envelope) else { return nil }
        return envelope
    }

    private func valid(_ envelope: Envelope) -> Bool {
        let date = now().timeIntervalSince1970
        guard envelope.schemaVersion == Self.schemaVersion, envelope.analysisVersion == Self.analysisVersion,
              envelope.language == Bundle.module.preferredLocalizations.first,
              envelope.sha256.count == 64, envelope.sha256.allSatisfy({ "0123456789abcdef".contains($0) }),
              envelope.byteCount > 0, envelope.lastUsedAt.isFinite, envelope.lastUsedAt <= date,
              date - envelope.lastUsedAt <= limits.maxAge,
              envelope.duration.isFinite, envelope.duration > 0, envelope.duration <= 31_536_000,
              !envelope.occurrences.isEmpty, envelope.occurrences.count <= 10_000,
              (0...envelope.occurrences.count).contains(envelope.visionNames),
              (0...envelope.occurrences.count).contains(envelope.recognitionFailures),
              envelope.errorDescription.map({ safeText($0, limit: 4096) }) ?? true else { return false }
        var ids: Set<UUID> = []
        var groups: [Int: String] = [:]
        var states: [Int: Int] = [:]
        var previousStart = 0.0
        for occurrence in envelope.occurrences {
            guard ids.insert(occurrence.id).inserted,
                  occurrence.start.isFinite, occurrence.end.isFinite, occurrence.timestamp.isFinite,
                  occurrence.score.isFinite, (0...1).contains(occurrence.score),
                  occurrence.start >= previousStart, occurrence.end > occurrence.start, occurrence.end <= envelope.duration,
                  occurrence.timestamp >= occurrence.start, occurrence.timestamp <= occurrence.end,
                  (1...10_000).contains(occurrence.screenID), (1...10_000).contains(occurrence.stateID),
                  safeText(occurrence.name, limit: 512), !occurrence.name.isEmpty,
                  ScreenClassification(screenID: occurrence.screenID, name: occurrence.name).name == occurrence.name,
                  groups[occurrence.screenID].map({ $0 == occurrence.name }) ?? true,
                  states[occurrence.stateID].map({ $0 == occurrence.screenID }) ?? true else { return false }
            previousStart = occurrence.start
            groups[occurrence.screenID] = occurrence.name
            states[occurrence.stateID] = occurrence.screenID
        }
        return true
    }

    private func safeText(_ text: String, limit: Int) -> Bool {
        text.utf8.count <= limit && !text.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }

    private func prune(reserving bytes: Int, replacing destination: URL?, incomingEntries: Int = 1) throws -> Bool {
        guard safeDirectory(create: false), let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil) else { return false }
        var retained: [(URL, Int, Double)] = []
        for url in files where url.pathExtension == "json" {
            try Task.checkCancellation()
            guard !isSymlink(url) else { continue }
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? limits.totalBytes
            if let envelope = read(url), url.lastPathComponent == envelope.sha256 + ".json" {
                if url != destination { retained.append((url, size, envelope.lastUsedAt)) }
            } else {
                do { try FileManager.default.removeItem(at: url) }
                catch { retained.append((url, size, -.infinity)) }
            }
        }
        retained.sort { $0.2 == $1.2 ? $0.0.lastPathComponent < $1.0.lastPathComponent : $0.2 < $1.2 }
        var total = retained.reduce(0) { $0 + $1.1 }
        var count = retained.count
        for entry in retained where total + bytes > limits.totalBytes || count + incomingEntries > limits.entries {
            try Task.checkCancellation()
            do {
                try FileManager.default.removeItem(at: entry.0)
                total -= entry.1
                count -= 1
            } catch { }
        }
        return total + bytes <= limits.totalBytes && count + incomingEntries <= limits.entries
    }

    private struct Envelope: Codable {
        var schemaVersion = RecentAnalysisCache.schemaVersion
        var analysisVersion = RecentAnalysisCache.analysisVersion
        var language = Bundle.module.preferredLocalizations.first ?? "en"
        let sha256: String
        let byteCount: Int64
        var lastUsedAt: Double
        let duration: Double
        let occurrences: [Occurrence]
        let usedContextualNaming: Bool
        let visionNames: Int
        let recognitionFailures: Int
        let errorDescription: String?

        init(_ analysis: CachedAnalysis, source: Source, date: Date) {
            sha256 = source.sha256
            byteCount = source.byteCount
            lastUsedAt = date.timeIntervalSince1970
            duration = analysis.duration
            occurrences = analysis.occurrences.map { Occurrence($0) }
            usedContextualNaming = analysis.usedContextualNaming
            visionNames = analysis.visionNames
            recognitionFailures = analysis.recognitionFailures
            errorDescription = analysis.errorDescription
        }

        var analysis: CachedAnalysis? {
            CachedAnalysis(result: AnalysisResult(sourceURL: URL(fileURLWithPath: "/"), duration: duration,
                states: occurrences.map { UIState(id: $0.id, interval: $0.start..<$0.end,
                    representativeTimestamp: $0.timestamp, stabilityScore: $0.score) }),
                catalog: ScreenCatalog(classifications: occurrences.map {
                    ScreenClassification(screenID: $0.screenID, name: $0.name, stateID: $0.stateID)
                }, usedContextualNaming: usedContextualNaming, visionNames: visionNames,
                    recognitionFailures: recognitionFailures, errorDescription: errorDescription))
        }
    }

    private struct Occurrence: Codable {
        let id: UUID
        let start: Double
        let end: Double
        let timestamp: Double
        let score: Float
        let screenID: Int
        let stateID: Int
        let name: String

        init(_ occurrence: CachedAnalysis.Occurrence) {
            id = occurrence.state.id
            start = occurrence.state.interval.lowerBound
            end = occurrence.state.interval.upperBound
            timestamp = occurrence.state.representativeTimestamp
            score = occurrence.state.stabilityScore
            screenID = occurrence.classification.screenID
            stateID = occurrence.classification.stateID
            name = occurrence.classification.name
        }
    }
}
