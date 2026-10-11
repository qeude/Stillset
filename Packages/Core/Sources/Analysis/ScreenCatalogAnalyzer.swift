import CryptoKit
import Foundation
import ImageIO
import OSLog
import Synchronization

public struct ScreenClassification: Sendable, Equatable {
    public let screenID: Int
    public let name: String
    public let stateID: Int

    public init(screenID: Int, name: String, stateID: Int? = nil) {
        self.screenID = screenID
        self.name = name.replacingOccurrences(of: "—", with: " ").split(whereSeparator: \.isWhitespace).joined(separator: " ")
        self.stateID = stateID ?? screenID
    }
}

public struct ScreenCatalog: Sendable {
    public let classifications: [ScreenClassification]
    public let usedContextualNaming: Bool
    public let visionNames: Int
    public let recognitionFailures: Int
    public let errorDescription: String?

    public init(classifications: [ScreenClassification], usedContextualNaming: Bool,
                visionNames: Int, recognitionFailures: Int, errorDescription: String?) {
        self.classifications = classifications
        self.usedContextualNaming = usedContextualNaming
        self.visionNames = visionNames
        self.recognitionFailures = recognitionFailures
        self.errorDescription = errorDescription
    }
}

actor ScreenRecognitionCache {
    static let shared = ScreenRecognitionCache()
    private let maximumEntries = 128
    private let maximumBytes = 16 * 1024 * 1024
    private var values: [SHA256.Digest: ScreenVisionFallback.Recognition] = [:]
    private var order: [SHA256.Digest] = []
    private var byteCount = 0

    func values(for digests: [SHA256.Digest]) -> [SHA256.Digest: ScreenVisionFallback.Recognition] {
        Dictionary(uniqueKeysWithValues: Set(digests).compactMap { digest in
            values[digest].map { (digest, $0) }
        })
    }

    func insert(_ recognition: ScreenVisionFallback.Recognition, for digest: SHA256.Digest) {
        guard values[digest] == nil else { return }
        let size = Self.estimatedSize(recognition)
        guard size <= maximumBytes else { return }
        while order.count >= maximumEntries || byteCount + size > maximumBytes {
            let removed = order.removeFirst()
            if let value = values.removeValue(forKey: removed) {
                byteCount -= Self.estimatedSize(value)
            }
        }
        order.append(digest)
        values[digest] = recognition
        byteCount += size
    }

    private static func estimatedSize(_ recognition: ScreenVisionFallback.Recognition) -> Int {
        recognition.pixels.count + (recognition.title?.utf8.count ?? 0)
            + (recognition.pickerName?.utf8.count ?? 0)
            + recognition.lines.reduce(0) { $0 + $1.rowPixels.count + $1.text.utf8.count + 128 }
    }
}

/// Screen identity is metadata: every input keeps its occurrence and original PNG.
public actor ScreenCatalogAnalyzer {
    private var previousDigests: [SHA256.Digest] = []
    private var previousCatalog: ScreenCatalog?
    private var previousContextualNaming = false
    private var previousFoundationModels = true
    private var previousSources: [Int] = []
    private var previousNames: [Int: ScreenNameResult] = [:]
    private var comparisons: [Set<SHA256.Digest>: Bool] = [:]
    private let recognitionOperation: (@Sendable (URL) async throws -> ScreenVisionFallback.Recognition)?
    private let recognitionCache: ScreenRecognitionCache
    private var completeEvidence: [SHA256.Digest: Evidence] = [:]

    struct Evidence: Sendable {
        let comparisonPixels: [UInt8]
        let recognition: ScreenVisionFallback.Recognition?
        var recognitionFailure: DiagnosticFailure? = nil
    }

    typealias Thumbnail = @Sendable (Data) throws -> CGImage
    typealias Recognition = @Sendable (Data, CGImage) async throws -> ScreenVisionFallback.Recognition

    nonisolated static func extractEvidence(_ data: Data, thumbnail: Thumbnail, recognize: Recognition) async throws -> Evidence {
        try Task.checkCancellation()
        let image = try thumbnail(data)
        let pixels = try comparisonPixels(image)
        do {
            let recognition = try await recognize(data, image)
            try Task.checkCancellation()
            return Evidence(comparisonPixels: pixels, recognition: recognition)
        } catch is CancellationError { throw CancellationError() }
        catch { return Evidence(comparisonPixels: pixels, recognition: nil, recognitionFailure: .classify(error)) }
    }

    /// One import's first PNG recognition. Cancellation is terminal, including before start.
    public final class PreparedRecognition: Sendable {
        private enum State {
            case idle
            case pending(SHA256.Digest?, Task<Evidence, Error>)
            case cancelled(Task<Evidence, Error>?)
        }

        private let state = Mutex<State>(.idle)
        private let recognize: Recognition
        private let thumbnail: Thumbnail

        public init() {
            recognize = { _, image in try await ScreenVisionFallback.recognize(image) }
            thumbnail = ScreenCatalogAnalyzer.proxyImage
        }

        init(recognize: @escaping @Sendable (Data) async throws -> ScreenVisionFallback.Recognition) {
            self.recognize = { data, _ in try await recognize(data) }
            thumbnail = ScreenCatalogAnalyzer.proxyImage
        }

        init(recognizeImage: @escaping Recognition, thumbnail: @escaping Thumbnail = ScreenCatalogAnalyzer.proxyImage) {
            recognize = recognizeImage
            self.thumbnail = thumbnail
        }

        /// Starts at most once, using an immutable snapshot of the exported PNG.
        public func start(fileURL: URL, work: ProcessingLane = .standalone()) {
            state.withLock { state in
                guard case .idle = state else { return }
                guard !Task.isCancelled else { state = .cancelled(nil); return }
                let snapshot = Result { try Data(contentsOf: fileURL) }
                let digest = try? snapshot.map { SHA256.hash(data: $0) }.get()
                let recognize = recognize
                let thumbnail = thumbnail
                state = .pending(digest, Task.detached(priority: .userInitiated) {
                    try Task.checkCancellation()
                    return try await work.perform {
                        try await ScreenCatalogAnalyzer.extractEvidence(snapshot.get(), thumbnail: thumbnail, recognize: recognize)
                    }
                })
            }
        }

        public func cancel() {
            state.withLock { state in
                if case let .pending(_, task) = state {
                    task.cancel()
                    state = .cancelled(task)
                } else if case .idle = state { state = .cancelled(nil) }
            }
        }

        public func cancelAndDrain() async {
            cancel()
            let task = state.withLock { state in
                if case let .cancelled(task) = state { return task }
                return nil
            }
            if let task { _ = await task.result }
        }

        fileprivate func task(matching digest: SHA256.Digest?) async throws -> Task<Evidence, Error>? {
            let (task, matches) = try state.withLock { state -> (Task<Evidence, Error>?, Bool) in
                switch state {
                case .idle: return (nil, false)
                case .cancelled: throw CancellationError()
                case let .pending(preparedDigest, task):
                    if let digest, digest == preparedDigest { return (task, true) }
                    task.cancel()
                    state = .cancelled(task)
                    return (task, false)
                }
            }
            if matches { return task }
            if let task { _ = await task.result }
            try Task.checkCancellation()
            return nil
        }
    }

    private let recognize: Recognition
    private let thumbnail: Thumbnail

    public init() {
        recognize = { _, image in try await ScreenVisionFallback.recognize(image) }
        thumbnail = Self.proxyImage
        recognitionOperation = nil
        recognitionCache = .shared
    }

    init(recognize: @escaping @Sendable (Data) async throws -> ScreenVisionFallback.Recognition) {
        self.recognize = { data, _ in try await recognize(data) }
        thumbnail = Self.proxyImage
        recognitionOperation = nil
        recognitionCache = .init()
    }

    init(recognizeImage: @escaping Recognition, thumbnail: @escaping Thumbnail = ScreenCatalogAnalyzer.proxyImage) {
        recognize = recognizeImage
        self.thumbnail = thumbnail
        recognitionOperation = nil
        recognitionCache = .init()
    }

    init(recognitionOperation: @escaping @Sendable (URL) async throws -> ScreenVisionFallback.Recognition,
         recognitionCache: ScreenRecognitionCache = .init()) {
        self.recognitionOperation = recognitionOperation
        self.recognitionCache = recognitionCache
        recognize = { _, image in try await ScreenVisionFallback.recognize(image) }
        thumbnail = Self.proxyImage
    }

    public func analyze(
        fileURLs: [URL], work: ProcessingLane = .standalone(), useContextualNaming: Bool = true, useFoundationModels: Bool = true,
        preparedRecognition: PreparedRecognition? = nil, diagnostics: DiagnosticOperationHandle? = nil,
        onProgress: @Sendable (Double, String) async throws -> Void = { _, _ in }
    ) async throws -> ScreenCatalog {
        try await withTaskCancellationHandler {
            do {
                let result = try await catalog(fileURLs: fileURLs, work: work, useContextualNaming: useContextualNaming,
                                               useFoundationModels: useFoundationModels,
                                               preparedRecognition: preparedRecognition, diagnostics: diagnostics, onProgress: onProgress)
                await preparedRecognition?.cancelAndDrain()
                try Task.checkCancellation()
                return result
            } catch {
                await preparedRecognition?.cancelAndDrain()
                throw error
            }
        } onCancel: { preparedRecognition?.cancel() }
    }

    private func catalog(
        fileURLs: [URL], work: ProcessingLane, useContextualNaming: Bool, useFoundationModels: Bool,
        preparedRecognition: PreparedRecognition?, diagnostics: DiagnosticOperationHandle?, onProgress: @Sendable (Double, String) async throws -> Void
    ) async throws -> ScreenCatalog {
        try Task.checkCancellation()
        await diagnostics?.stage(.cataloging)
        var fileDigests: [SHA256.Digest?] = []
        var firstDigest: SHA256.Digest?
        var digests: [SHA256.Digest] = []
        var firstByDigest: [SHA256.Digest: Int] = [:]
        var sources: [Int] = []
        var failures: Set<Int> = []
        for (index, url) in fileURLs.enumerated() {
            try Task.checkCancellation()
            let digest = try await work.perform {
                (try? Data(contentsOf: url)).map { SHA256.hash(data: $0) }
            }
            if index == 0 { firstDigest = digest }
            if let digest { digests.append(digest) } else { failures.insert(index) }
            let source = digest.flatMap { firstByDigest[$0] } ?? index
            fileDigests.append(digest)
            sources.append(source)
            if let digest, source == index { firstByDigest[digest] = index }
        }
        let matchesPrevious = digests.count == fileURLs.count && digests == previousDigests
            && useContextualNaming == previousContextualNaming
            && useFoundationModels == previousFoundationModels
        let cached = matchesPrevious && previousCatalog?.recognitionFailures == 0 && previousCatalog?.errorDescription == nil
        let needsPrepared = useContextualNaming && !cached && firstDigest.map { completeEvidence[$0] == nil } == true
        let preparedTask = try await preparedRecognition?.task(matching: needsPrepared ? firstDigest : nil)
        if cached, let previousCatalog {
            try await onProgress(1, String(localized: "Results reused", bundle: .module))
            return previousCatalog
        }
        var savedSources = sources
        var savedNames: [Int: ScreenNameResult] = [:]
        var labels = sources.map { ScreenClassification(screenID: $0 + 1, name: String(localized: "Screenshot to Review", bundle: .module)) }
        var contextual = false
        var visionNames = 0
        var errorDescription: String?
        if useContextualNaming {
            var stateSources = sources
            var recognition: [Int: ScreenVisionFallback.Recognition] = [:]
            let pendingOCR = fileURLs.indices.filter { sources[$0] == $0 }
            let cachedRecognitions = await recognitionCache.values(for: fileDigests.compactMap { $0 })
            let recognitionOperation = recognitionOperation
            let recognitionCache = recognitionCache
            let cachedEvidence = completeEvidence
            let fileDigests = fileDigests
            let recognize = recognize
            let thumbnail = thumbnail
            // Prepared OCR owns its lane already; finish other evidence before waiting for it.
            let readingOrder = preparedTask == nil ? pendingOCR : pendingOCR.filter { $0 != 0 } + pendingOCR.filter { $0 == 0 }
            await diagnostics?.stage(.recognition)
            let readings = try await Self.orderedMap(readingOrder, work: work, operation: { index -> (Int, Evidence?) in
                do {
                    if let digest = fileDigests[index], let evidence = cachedEvidence[digest] { return (index, evidence) }
                    let evidence: Evidence
                    if index == 0, let preparedTask { evidence = try await preparedTask.value }
                    else {
                        let data = try Data(contentsOf: fileURLs[index])
                        guard SHA256.hash(data: data) == fileDigests[index] else { throw CocoaError(.fileReadUnknown) }
                        let recognition: Recognition = { data, image in
                            if let digest = fileDigests[index], let cached = cachedRecognitions[digest] { return cached }
                            if let recognitionOperation { return try await recognitionOperation(fileURLs[index]) }
                            return try await recognize(data, image)
                        }
                        evidence = try await Self.extractEvidence(data, thumbnail: thumbnail, recognize: recognition)
                    }
                    try Task.checkCancellation()
                    if let digest = fileDigests[index] {
                        await self.remember(evidence, for: digest)
                        if let value = evidence.recognition, value.title != nil, !value.lines.isEmpty {
                            await recognitionCache.insert(value, for: digest)
                        }
                    }
                    return (index, evidence)
                }
                catch is CancellationError { throw CancellationError() }
                catch {
                    await diagnostics?.issue(.classify(error), at: .recognition)
                    return (index, nil)
                }
            }) { count in
                try await onProgress(Double(count) / Double(pendingOCR.count) * 0.1, String(localized: "Reading screens with Vision", bundle: .module))
            }
            var samples = [[UInt8]?](repeating: nil, count: fileURLs.count)
            for (index, evidence) in readings {
                if let failure = evidence?.recognitionFailure { await diagnostics?.issue(failure, at: .recognition) }
                samples[index] = evidence?.comparisonPixels
                recognition[index] = evidence?.recognition
            }
            await diagnostics?.stage(.comparison)
            var representatives: [Int] = []
            for index in fileURLs.indices {
                try Task.checkCancellation()
                if sources[index] != index {
                    stateSources[index] = stateSources[sources[index]]
                    continue
                }
                var distances: [(Int, Double)] = []
                let currentPixels = samples[index]
                let currentRecognition = recognition[index]
                for start in stride(from: 0, to: representatives.count, by: 256) {
                    let chunk = representatives[start..<min(start + 256, representatives.count)].map {
                        ($0, samples[$0], recognition[$0])
                    }
                    let matches = try await work.perform {
                        chunk.compactMap { previous, pixels, other -> (Int, Double)? in
                            guard let distance = Self.candidateDistance(pixels: currentPixels, otherPixels: pixels) else { return nil }
                            if let currentRecognition, let other, currentRecognition.clearlyDiffers(from: other) { return nil }
                            return (previous, distance)
                        }
                    }
                    distances.append(contentsOf: matches)
                }
                let unsorted = distances
                let threeNearestRepresentatives = try await work.perform {
                    Array(unsorted.sorted { $0.1 == $1.1 ? $0.0 < $1.0 : $0.1 < $1.1 }.prefix(3))
                }
                for (previous, _) in threeNearestRepresentatives {
                    if let current = recognition[index], let other = recognition[previous] {
                        let evidence = try await work.perform { current.sameState(as: other) }
                        if let same = evidence {
                            if same { stateSources[index] = previous; break }
                            continue
                        }
                    }
                    guard useFoundationModels && ScreenSemanticNamer.isAvailable else { continue }
                    do {
                        // The model runs out of process, so it does not hold a lane or pay its cooldown.
                        let compare: @Sendable () async throws -> Bool = {
                            try await ScreenSemanticNamer.sameContent(fileURLs[previous], fileURLs[index])
                        }
                        let same = digests.count == fileURLs.count
                            ? try await cachedComparison(Set([digests[previous], digests[index]]), operation: compare)
                            : try await compare()
                        if same {
                            stateSources[index] = previous
                            break
                        }
                    } catch is CancellationError { throw CancellationError() }
                    catch {
                        Logger(subsystem: "com.qeude.stillset", category: "ImageAnalysis").error("Image comparison failed")
                        await diagnostics?.issue(.classify(error), at: .comparison)
                        errorDescription = String(localized: "Apple Intelligence: \(error.localizedDescription)", bundle: .module)
                    }
                }
                if stateSources[index] == index { representatives.append(index) }
                try await onProgress(Double(index + 1) / Double(fileURLs.count) * 0.3 + 0.1,
                                 String(localized: "Grouping states: \(index + 1) of \(fileURLs.count)", bundle: .module))
            }
            savedSources = stateSources
            let names = try await ScreenSemanticNamer.classify(
                fileURLs: fileURLs, sources: stateSources, work: work, cachedNames: matchesPrevious && stateSources == previousSources ? previousNames : [:],
                recognition: recognition, useFoundationModels: useFoundationModels, diagnostics: diagnostics
            ) { fraction, detail in
                try await onProgress(0.4 + fraction * 0.6, detail)
            }
            contextual = names.allSatisfy { $0.error == nil && !$0.usedVision }
            visionNames = names.filter(\.usedVision).count
            var known: [String] = []
            for index in fileURLs.indices {
                try Task.checkCancellation()
                let source = stateSources[index]
                if source != index {
                    labels[index] = labels[source]
                } else {
                    let name = names[index].name
                    if names[index].error == nil { savedNames[index] = names[index] }
                    let screen = known.firstIndex(of: name) ?? known.count
                    if screen == known.count { known.append(name) }
                    labels[index] = ScreenClassification(screenID: screen + 1, name: name, stateID: source + 1)
                }
                if let error = names[index].error {
                    failures.insert(index)
                    errorDescription = error
                }
            }
        }
        try Task.checkCancellation()
        let catalog = ScreenCatalog(classifications: labels, usedContextualNaming: contextual,
                                    visionNames: visionNames, recognitionFailures: failures.count, errorDescription: errorDescription)
        if digests.count == fileURLs.count {
            previousDigests = digests
            previousCatalog = catalog
            previousContextualNaming = useContextualNaming
            previousFoundationModels = useFoundationModels
            previousSources = savedSources
            previousNames = savedNames
        }
        try await onProgress(1, String(localized: "Screenshots ready", bundle: .module))
        try Task.checkCancellation()
        return catalog
    }

    private func remember(_ evidence: Evidence, for digest: SHA256.Digest) {
        if evidence.recognition != nil { completeEvidence[digest] = evidence }
    }

    func cachedComparison(
        _ pair: Set<SHA256.Digest>, operation: @Sendable () async throws -> Bool
    ) async throws -> Bool {
        try Task.checkCancellation()
        if let result = comparisons[pair] { return result }
        let result = try await operation()
        try Task.checkCancellation()
        // ponytail: bounded session cache; evict the whole cache if 512 distinct pairs are exceeded.
        if comparisons.count >= 512 { comparisons.removeAll(keepingCapacity: true) }
        comparisons[pair] = result
        return result
    }

    nonisolated static func orderedMap<Input: Sendable, Output: Sendable>(
        _ inputs: [Input], work: ProcessingLane = .standalone(),
        operation: @escaping @Sendable (Input) async throws -> Output,
        onProgress: @Sendable (Int) async throws -> Void = { _ in }
    ) async throws -> [Output] {
        var results: [Output] = []
        for input in inputs {
            let value = try await work.perform { try await operation(input) }
            results.append(value)
            try await onProgress(results.count)
            try Task.checkCancellation()
        }
        return results
    }

    nonisolated static func candidateDistance(pixels: [UInt8]?, otherPixels: [UInt8]?) -> Double? {
        guard let pixels, let otherPixels, !pixels.isEmpty, pixels.count == otherPixels.count else { return nil }
        let distance = zip(pixels, otherPixels).reduce(0.0) { $0 + abs(Double($1.0) - Double($1.1)) } / Double(pixels.count)
        return distance <= 8 ? distance : nil
    }

    nonisolated static func comparisonPixels(_ url: URL) throws -> [UInt8] {
        try comparisonPixels(Data(contentsOf: url))
    }

    nonisolated static func comparisonPixels(_ data: Data) throws -> [UInt8] {
        try comparisonPixels(proxyImage(data))
    }

    nonisolated static func comparisonPixels(_ image: CGImage) throws -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: 32 * 64)
        try pixels.withUnsafeMutableBytes { bytes in
            guard let context = CGContext(data: bytes.baseAddress, width: 32, height: 64,
                                          bitsPerComponent: 8, bytesPerRow: 32,
                                          space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0) else {
                throw CocoaError(.coderInvalidValue)
            }
            context.draw(image, in: CGRect(x: 0, y: 0, width: 32, height: 64))
        }
        return pixels
    }

    nonisolated static func proxyImage(_ url: URL) throws -> CGImage {
        try proxyImage(Data(contentsOf: url))
    }

    nonisolated static func proxyImage(_ data: Data) throws -> CGImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 800
              ] as CFDictionary) else { throw CocoaError(.fileReadCorruptFile) }
        return image
    }

}
