import AVFoundation
import Foundation

public enum DiagnosticOperation: String, Codable, Sendable {
    case videoImport, analysis, reanalysis, refinement, sessionCatalog, screenshotExport, sessionExport
}

public enum DiagnosticStage: String, Codable, Sendable, CaseIterable {
    case validating, decoding, detecting, capturing, cataloging, recognition, comparison, semanticNaming, visionFallback, saving
}

public enum DiagnosticFailure: String, Codable, Sendable, CaseIterable {
    case unknown, unsupportedImport, noVideoTrack, noVideoFrames, noStableStates, cannotReadVideo
    case invalidImageSequence, invalidNameCount, cannotCreateFile, cannotWriteFile, sourceChanged
    case permissionDenied, fileMissing, diskFull, invalidData, unsupportedFeature, mediaDecodeFailed

    public static func classify(_ error: Error) -> Self {
        if let error = error as? VideoAnalysisError {
            switch error {
            case .noVideoTrack: return .noVideoTrack
            case .noVideoFrames: return .noVideoFrames
            case .noStableStates: return .noStableStates
            case .cannotReadVideo: return .cannotReadVideo
            }
        }
        if let error = error as? ScreenshotExportError {
            switch error {
            case .invalidImageSequence: return .invalidImageSequence
            case .invalidNameCount: return .invalidNameCount
            case .cannotCreateFile: return .cannotCreateFile
            case .cannotWriteFile: return .cannotWriteFile
            }
        }
        let nsError = error as NSError
        switch (nsError.domain, nsError.code) {
        case (NSCocoaErrorDomain, CocoaError.fileReadNoPermission.rawValue),
             (NSCocoaErrorDomain, CocoaError.fileWriteNoPermission.rawValue): return .permissionDenied
        case (NSCocoaErrorDomain, CocoaError.fileNoSuchFile.rawValue),
             (NSCocoaErrorDomain, CocoaError.fileReadNoSuchFile.rawValue): return .fileMissing
        case (NSCocoaErrorDomain, CocoaError.fileWriteOutOfSpace.rawValue): return .diskFull
        case (NSCocoaErrorDomain, CocoaError.coderInvalidValue.rawValue),
             (NSCocoaErrorDomain, CocoaError.fileReadCorruptFile.rawValue): return .invalidData
        case (NSCocoaErrorDomain, CocoaError.featureUnsupported.rawValue): return .unsupportedFeature
        case (AVFoundationErrorDomain, AVError.decoderNotFound.rawValue),
             (AVFoundationErrorDomain, AVError.decodeFailed.rawValue): return .mediaDecodeFailed
        default: return .unknown
        }
    }
}

public enum DiagnosticOutcome: Sendable {
    case success, cancelled, failed(DiagnosticFailure)

    public static func failure(_ error: Error, cancelled: Bool = false) -> Self {
        cancelled || error is CancellationError ? .cancelled : .failed(.classify(error))
    }
}

public enum DiagnosticExportError: Error { case cannotWrite }

/// An attempt identifier belongs only to this journal, never to a recording or machine.
public actor DiagnosticOperationHandle {
    private let journal: DiagnosticJournal
    private let id: UUID
    private let operation: DiagnosticOperation
    private var finished = false
    private var stages: Set<DiagnosticStage> = []
    private var issues: Set<Issue> = []

    private struct Issue: Hashable {
        let stage: DiagnosticStage
        let failure: DiagnosticFailure
    }

    fileprivate init(journal: DiagnosticJournal, id: UUID, operation: DiagnosticOperation) {
        self.journal = journal
        self.id = id
        self.operation = operation
    }

    public func stage(_ stage: DiagnosticStage) async {
        guard !finished, stages.insert(stage).inserted else { return }
        await journal.append(id: id, operation: operation, kind: .stage, stage: stage)
    }

    public func issue(_ failure: DiagnosticFailure, at stage: DiagnosticStage) async {
        guard !finished, issues.insert(Issue(stage: stage, failure: failure)).inserted else { return }
        await journal.append(id: id, operation: operation, kind: .issue, stage: stage, failure: failure)
    }

    public func finish(_ outcome: DiagnosticOutcome) async {
        guard !finished else { return }
        finished = true
        switch outcome {
        case .success: await journal.append(id: id, operation: operation, kind: .finished, outcome: .success)
        case .cancelled: await journal.append(id: id, operation: operation, kind: .finished, outcome: .cancelled)
        case .failed(let failure): await journal.append(id: id, operation: operation, kind: .finished, outcome: .failed, failure: failure)
        }
    }
}

/// All loading, serialization and file work runs synchronously on this actor's executor.
/// Callers await submission, so no dispatch backlog or per-event tasks accumulate.
public actor DiagnosticJournal {
    private static let maximumEvents = 256
    private static let maximumBytes = 256 * 1024
    private static let retention: Int64 = 7 * 24 * 60 * 60
    private let storeURL: URL
    private let metadata: Metadata
    private let now: @Sendable () -> Date
    private var loaded = false
    private var events: [Record] = []
    private var sequence: UInt64 = 0
    private var status = Persistence.available

    public init(storeURL: URL, appVersion: String?, appBuild: String?) {
        self.init(storeURL: storeURL, appVersion: appVersion, appBuild: appBuild, now: { Date() })
    }

    init(storeURL: URL, appVersion: String?, appBuild: String?, now: @escaping @Sendable () -> Date) {
        self.storeURL = storeURL
        self.now = now
        let os = ProcessInfo.processInfo.operatingSystemVersion
        #if arch(arm64)
        let architecture = Architecture.arm64
        #elseif arch(x86_64)
        let architecture = Architecture.x86_64
        #else
        let architecture = Architecture.unknown
        #endif
        metadata = Metadata(appVersion: Self.version(appVersion), appBuild: Self.version(appBuild),
            osVersion: [os.majorVersion, os.minorVersion, os.patchVersion], architecture: architecture)
    }

    public func prepare() {
        load()
        prune()
        persist()
    }

    public func begin(_ operation: DiagnosticOperation) -> DiagnosticOperationHandle {
        let id = UUID()
        append(id: id, operation: operation, kind: .started)
        return DiagnosticOperationHandle(journal: self, id: id, operation: operation)
    }

    public func export(to destination: URL) throws {
        load()
        prune()
        persist()
        do {
            let data = try boundedSnapshot()
            try data.write(to: destination, options: .atomic)
        } catch { throw DiagnosticExportError.cannotWrite }
    }

    fileprivate func append(id: UUID, operation: DiagnosticOperation, kind: Kind,
                            stage: DiagnosticStage? = nil, outcome: Outcome? = nil, failure: DiagnosticFailure? = nil) {
        load()
        prune()
        if sequence == UInt64.max { events.removeAll(); sequence = 0 }
        sequence += 1
        events.append(Record(sequence: sequence, timestamp: timestamp, id: id, operation: operation,
            kind: kind, stage: stage, outcome: outcome, failure: failure, metadata: metadata))
        prune()
        persist()
    }

    private var timestamp: Int64 { Int64(now().timeIntervalSince1970) }

    private func load() {
        guard !loaded else { return }
        loaded = true
        guard FileManager.default.fileExists(atPath: storeURL.path) else { return }
        do {
            let file = try FileHandle(forReadingFrom: storeURL)
            defer { try? file.close() }
            let data = try file.read(upToCount: Self.maximumBytes + 1) ?? Data()
            guard data.count <= Self.maximumBytes else { throw InvalidStore.invalid }
            let report = try JSONDecoder().decode(Report.self, from: data)
            guard report.schema == 1, report.events.count <= Self.maximumEvents, report.metadata.valid,
                  zip(report.events, report.events.dropFirst()).allSatisfy({ $0.sequence < $1.sequence }),
                  report.events.allSatisfy({ $0.sequence > 0 && $0.valid }) else { throw InvalidStore.invalid }
            events = report.events
            sequence = events.last?.sequence ?? 0
            status = report.persistence
            prune()
        } catch {
            events = []
            status = .unavailable
        }
        persist()
    }

    private func prune() {
        let current = timestamp
        events.removeAll { $0.timestamp < current - Self.retention || $0.timestamp > current + 60 }
        if events.count > Self.maximumEvents { events.removeFirst(events.count - Self.maximumEvents) }
    }

    private func boundedSnapshot() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        while true {
            let data = try encoder.encode(Report(schema: 1, persistence: status, metadata: metadata, events: events))
            if data.count <= Self.maximumBytes { return data }
            guard !events.isEmpty else { throw InvalidStore.invalid }
            events.removeFirst()
        }
    }

    private func persist() {
        do {
            let data = try boundedSnapshot()
            try FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: storeURL, options: .atomic)
        } catch { status = .unavailable }
    }

    private static func version(_ text: String?) -> [Int]? {
        guard let text, !text.isEmpty, text.utf8.count <= 32,
              text.utf8.allSatisfy({ (48...57).contains($0) || $0 == 46 }) else { return nil }
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...4).contains(parts.count) else { return nil }
        let values = parts.compactMap { Int($0) }
        guard values.count == parts.count, values.allSatisfy({ (0...999_999).contains($0) }) else { return nil }
        return values
    }

    private enum InvalidStore: Error { case invalid }
    fileprivate enum Kind: String, Codable { case started, stage, issue, finished }
    fileprivate enum Outcome: String, Codable { case success, cancelled, failed }
    private enum Persistence: String, Codable { case available, unavailable }
    private struct Report: Codable {
        let schema: Int
        let persistence: Persistence
        let metadata: Metadata
        let events: [Record]
    }
    private enum Architecture: String, Codable { case arm64, x86_64, unknown }
    private struct Metadata: Codable {
        let appVersion: [Int]?
        let appBuild: [Int]?
        let osVersion: [Int]
        let architecture: Architecture

        var valid: Bool {
            func validVersion(_ values: [Int]?) -> Bool {
                values.map { (1...4).contains($0.count) && $0.allSatisfy { (0...999_999).contains($0) } } ?? true
            }
            return validVersion(appVersion) && validVersion(appBuild) && osVersion.count == 3
                && osVersion.allSatisfy { (0...999_999).contains($0) }
        }
    }
    private struct Record: Codable {
        let sequence: UInt64
        let timestamp: Int64
        let id: UUID
        let operation: DiagnosticOperation
        let kind: Kind
        let stage: DiagnosticStage?
        let outcome: Outcome?
        let failure: DiagnosticFailure?
        let metadata: Metadata

        var valid: Bool {
            guard metadata.valid, timestamp >= 0 else { return false }
            switch kind {
            case .started: return stage == nil && outcome == nil && failure == nil
            case .stage: return stage != nil && outcome == nil && failure == nil
            case .issue: return stage != nil && outcome == nil && failure != nil
            case .finished: return stage == nil && outcome != nil && ((outcome == .failed) == (failure != nil))
            }
        }
    }
}
