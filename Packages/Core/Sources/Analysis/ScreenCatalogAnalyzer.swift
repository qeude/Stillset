import CryptoKit
import Foundation
import ImageIO
import OSLog

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

    public init() {}

    public func analyze(
        fileURLs: [URL], useContextualNaming: Bool = true, useFoundationModels: Bool = true,
        onProgress: @Sendable (Double, String) async -> Void = { _, _ in }
    ) async throws -> ScreenCatalog {
        var digests: [SHA256.Digest] = []
        var firstByDigest: [SHA256.Digest: Int] = [:]
        var sources: [Int] = []
        var failures: Set<Int> = []
        for (index, url) in fileURLs.enumerated() {
            try Task.checkCancellation()
            let digest = (try? Data(contentsOf: url, options: .mappedIfSafe)).map { SHA256.hash(data: $0) }
            if let digest { digests.append(digest) } else { failures.insert(index) }
            let source = digest.flatMap { firstByDigest[$0] } ?? index
            sources.append(source)
            if let digest, source == index { firstByDigest[digest] = index }
        }
        let matchesPrevious = digests.count == fileURLs.count && digests == previousDigests
            && useContextualNaming == previousContextualNaming
            && useFoundationModels == previousFoundationModels
        if matchesPrevious, let previousCatalog,
           previousCatalog.recognitionFailures == 0, previousCatalog.errorDescription == nil {
            await onProgress(1, "Résultats réutilisés")
            return previousCatalog
        }
        if matchesPrevious { sources = previousSources }
        var savedSources = sources
        var savedNames: [Int: ScreenNameResult] = [:]
        var labels = sources.map { ScreenClassification(screenID: $0 + 1, name: "Capture à examiner") }
        var contextual = false
        var visionNames = 0
        var errorDescription: String?
        if useContextualNaming {
            var stateSources = sources
            var recognition: [Int: ScreenVisionFallback.Recognition] = [:]
            let pendingOCR = fileURLs.indices.filter { sources[$0] == $0 }
            let readings = try await Self.concurrentMap(pendingOCR, operation: { index -> (Int, [UInt8]?, ScreenVisionFallback.Recognition?) in
                let pixels = try? Self.comparisonPixels(fileURLs[index])
                do { return (index, pixels, try await ScreenVisionFallback.recognize(fileURLs[index])) }
                catch is CancellationError { throw CancellationError() }
                catch { return (index, pixels, nil) } // Unreadable OCR still gets image analysis.
            }) { count in
                await onProgress(Double(count) / Double(pendingOCR.count) * 0.1, "Lecture des écrans avec Vision")
            }
            var samples = [[UInt8]?](repeating: nil, count: fileURLs.count)
            for (index, pixels, value) in readings {
                samples[index] = pixels
                recognition[index] = value
            }
            let needsModelNames = pendingOCR.contains { recognition[$0]?.fastName == nil && !(matchesPrevious && previousNames[$0] != nil) }
            let preparedSessions = useFoundationModels && needsModelNames && ScreenSemanticNamer.isAvailable
                ? (0..<2).map { _ in ScreenSemanticNamer.makeSession() } : []
            for session in preparedSessions { session.prewarm() }
            var representatives: [Int] = []
            for index in fileURLs.indices {
                try Task.checkCancellation()
                if sources[index] != index {
                    stateSources[index] = stateSources[sources[index]]
                    continue
                }
                // ponytail: at most three nearby representatives; uncertain comparisons retain separate states.
                let candidates = representatives.compactMap { previous -> (Int, Double)? in
                    guard let distance = Self.candidateDistance(pixels: samples[index], otherPixels: samples[previous]) else { return nil }
                    if let current = recognition[index], let other = recognition[previous],
                       current.clearlyDiffers(from: other) { return nil }
                    return (previous, distance)
                }.sorted { $0.1 == $1.1 ? $0.0 < $1.0 : $0.1 < $1.1 }.prefix(3)
                for (previous, _) in candidates {
                    if let current = recognition[index], let other = recognition[previous],
                       let same = current.sameState(as: other) {
                        if same { stateSources[index] = previous; break }
                        continue
                    }
                    guard useFoundationModels && ScreenSemanticNamer.isAvailable else { continue }
                    do {
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
                        Logger(subsystem: "com.stillflow.app", category: "ImageAnalysis").error("Image comparison failed: \(String(describing: error), privacy: .public)")
                        errorDescription = "Apple Intelligence : \(error.localizedDescription)"
                    }
                }
                if stateSources[index] == index { representatives.append(index) }
                await onProgress(Double(index + 1) / Double(fileURLs.count) * 0.3 + 0.1,
                                 "Regroupement des états : \(index + 1) sur \(fileURLs.count)")
            }
            savedSources = stateSources
            let names = try await ScreenSemanticNamer.classify(
                fileURLs: fileURLs, sources: stateSources, cachedNames: matchesPrevious ? previousNames : [:],
                recognition: recognition, preparedSessions: preparedSessions, useFoundationModels: useFoundationModels
            ) { fraction, detail in
                await onProgress(0.4 + fraction * 0.6, detail)
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
        await onProgress(1, "Captures prêtes")
        return catalog
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

    /// Refill a freed slot immediately instead of waiting for a two-item batch.
    nonisolated static func concurrentMap<Input: Sendable, Output: Sendable>(
        _ inputs: [Input], operation: @escaping @Sendable (Input) async throws -> Output,
        onProgress: @Sendable (Int) async -> Void = { _ in }
    ) async throws -> [Output] {
        try Task.checkCancellation()
        return try await withThrowingTaskGroup(of: (Int, Output).self) { group in
            var next = 0
            var completed = 0
            var results = [Output?](repeating: nil, count: inputs.count)
            for _ in 0..<min(2, inputs.count) {
                let index = next
                group.addTask { (index, try await operation(inputs[index])) }
                next += 1
            }
            while let (index, result) = try await group.next() {
                try Task.checkCancellation()
                results[index] = result
                completed += 1
                if next < inputs.count {
                    let index = next
                    group.addTask { (index, try await operation(inputs[index])) }
                    next += 1
                }
                await onProgress(completed)
            }
            return results.compactMap { $0 }
        }
    }

    nonisolated static func candidateDistance(pixels: [UInt8]?, otherPixels: [UInt8]?) -> Double? {
        guard let pixels, let otherPixels, !pixels.isEmpty, pixels.count == otherPixels.count else { return nil }
        let distance = zip(pixels, otherPixels).reduce(0.0) { $0 + abs(Double($1.0) - Double($1.1)) } / Double(pixels.count)
        return distance <= 8 ? distance : nil
    }

    nonisolated static func comparisonPixels(_ url: URL) throws -> [UInt8] {
        let image = try proxyImage(url)
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
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 800
              ] as CFDictionary) else { throw CocoaError(.fileReadCorruptFile) }
        return image
    }

}
