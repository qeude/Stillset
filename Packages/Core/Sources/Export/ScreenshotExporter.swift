import AVFoundation
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum ScreenshotExporter {
    /// Keep the streamed files valid for existing drags and clipboard references.
    public static func prepareNamedFiles(files: [URL], screenNames: [String]) throws -> [URL] {
        guard files.count == screenNames.count else { throw ScreenshotExportError.invalidNameCount }
        let width = max(3, String(files.count).count)
        return try files.enumerated().map { index, file in
            try Task.checkCancellation()
            let title = screenNames[index].folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            let slug = title.split { !$0.isLetter && !$0.isNumber }.joined(separator: "-")
            let name = String(format: "%0*d", width, index + 1) + "_" + (slug.isEmpty ? "ecran" : String(slug.prefix(64)))
            if file.lastPathComponent == name + ".png", FileManager.default.fileExists(atPath: file.path) { return file }
            let destination = nonconflictingURL(folder: file.deletingLastPathComponent(), name: name)
            do {
                try FileManager.default.linkItem(at: file, to: destination)
            } catch {
                try FileManager.default.copyItem(at: file, to: destination)
            }
            return destination
        }
    }

    @discardableResult
    public static func copy(
        files: [URL],
        to folderURL: URL,
        onProgress: @Sendable (Double, String) -> Void = { _, _ in }
    ) throws -> [URL] {
        var copied: [URL] = []
        copied.reserveCapacity(files.count)

        for (index, fileURL) in files.enumerated() {
            try Task.checkCancellation()
            let destinationURL = nonconflictingURL(
                folder: folderURL,
                name: fileURL.deletingPathExtension().lastPathComponent
            )
            try FileManager.default.copyItem(at: fileURL, to: destinationURL)
            copied.append(destinationURL)
            onProgress(Double(index + 1) / Double(files.count), "Screenshot \(index + 1) of \(files.count)")
        }
        return copied
    }

    @discardableResult
    public static func export(
        states: [UIState],
        from videoURL: URL,
        to folderURL: URL,
        onProgress: @Sendable (Double, String) -> Void = { _, _ in },
        onScreenshot: @Sendable (Int, URL) async -> Void = { _, _ in }
    ) async throws -> [URL] {
        let asset = AVURLAsset(url: videoURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        var outputURLs: [URL] = []
        outputURLs.reserveCapacity(states.count)

        defer { generator.cancelAllCGImageGeneration() }
        let times = states.map { CMTime(seconds: $0.representativeTimestamp, preferredTimescale: 600) }
        // Native batch decoding reuses video work; four originals bound encoding memory.
        for start in stride(from: 0, to: states.count, by: 4) {
            try Task.checkCancellation()
            let indices = Array(start..<min(start + 4, states.count))
            let completed = try await withThrowingTaskGroup(of: (Int, URL).self) { group in
                var remaining = indices
                for await result in generator.images(for: indices.map { times[$0] }) {
                    try Task.checkCancellation()
                    let image = try result.image
                    guard let position = remaining.firstIndex(where: { CMTimeCompare(times[$0], result.requestedTime) == 0 }) else {
                        throw ScreenshotExportError.invalidImageSequence
                    }
                    let index = remaining.remove(at: position)
                    let baseName = String(format: "%03d_%@", index + 1, timestampName(states[index].representativeTimestamp))
                    let destinationURL = nonconflictingURL(folder: folderURL, name: baseName)
                    group.addTask {
                        try await writePNG(image, to: destinationURL)
                        return (index, destinationURL)
                    }
                }
                try Task.checkCancellation()
                guard remaining.isEmpty else { throw ScreenshotExportError.invalidImageSequence }
                var files: [(Int, URL)] = []
                for try await file in group { files.append(file) }
                return files.sorted { $0.0 < $1.0 }
            }
            for (index, url) in completed {
                try Task.checkCancellation()
                outputURLs.append(url)
                await onScreenshot(index, url)
                onProgress(Double(index + 1) / Double(states.count), "Screenshot \(index + 1) of \(states.count)")
            }
        }
        return outputURLs
    }

    private static func writePNG(_ image: CGImage, to url: URL) async throws {
        try Task.checkCancellation()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
                    continuation.resume(throwing: ScreenshotExportError.cannotCreateFile(url))
                    return
                }
                CGImageDestinationAddImage(destination, image, nil)
                guard CGImageDestinationFinalize(destination) else {
                    continuation.resume(throwing: ScreenshotExportError.cannotWriteFile(url))
                    return
                }
                continuation.resume()
            }
        }
        try Task.checkCancellation()
    }

    private static func timestampName(_ timestamp: TimeInterval) -> String {
        let wholeMilliseconds = max(0, Int((timestamp * 1000).rounded()))
        let minutes = wholeMilliseconds / 60_000
        let seconds = (wholeMilliseconds / 1000) % 60
        let milliseconds = wholeMilliseconds % 1000
        return String(format: "%02d-%02d.%03d", minutes, seconds, milliseconds)
    }

    private static func nonconflictingURL(folder: URL, name: String) -> URL {
        let first = folder.appendingPathComponent("\(name).png")
        guard FileManager.default.fileExists(atPath: first.path) else { return first }
        var suffix = 2
        while true {
            let candidate = folder.appendingPathComponent("\(name)-\(suffix).png")
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            suffix += 1
        }
    }
}

public enum ScreenshotExportError: LocalizedError {
    case invalidImageSequence
    case invalidNameCount
    case cannotCreateFile(URL)
    case cannotWriteFile(URL)

    public var errorDescription: String? {
        switch self {
        case .invalidImageSequence: "The video did not provide every requested screenshot."
        case .invalidNameCount: "Every screenshot must have a screen name."
        case .cannotCreateFile(let url): "Could not create \(url.lastPathComponent)."
        case .cannotWriteFile(let url): "Could not write \(url.lastPathComponent)."
        }
    }
}
