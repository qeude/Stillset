import AVFoundation
import Darwin
import Foundation
import ImageIO
import Synchronization
import UniformTypeIdentifiers

public enum ScreenshotExporter {
    /// Keep the streamed files valid for existing drags and clipboard references.
    public static func prepareNamedFiles(
        files: [URL], screenNames: [String], work: ProcessingLane = .standalone()
    ) async throws -> [URL] {
        guard files.count == screenNames.count else { throw ScreenshotExportError.invalidNameCount }
        let width = max(3, String(files.count).count)
        var named: [URL] = []
        for (index, file) in files.enumerated() {
            let title = screenNames[index]
            let destination = try await work.perform {
                let name = numberedName(index: index, width: width, screenName: title)
                if file.lastPathComponent == name + ".png", FileManager.default.fileExists(atPath: file.path) { return file }
                let destination = nonconflictingURL(folder: file.deletingLastPathComponent(), name: name)
                do { try FileManager.default.linkItem(at: file, to: destination) }
                catch { try FileManager.default.copyItem(at: file, to: destination) }
                return destination
            }
            named.append(destination)
        }
        return named
    }

    @discardableResult
    public static func copy(
        plan: ScreenshotExportPlan,
        to folderURL: URL,
        work: ProcessingLane = .standalone(),
        onProgress: @Sendable (Double, String) async throws -> Void = { _, _ in }
    ) async throws -> [URL] {
        let count = plan.fileCount
        var copied: [URL] = []
        copied.reserveCapacity(count)
        switch plan {
        case .singleFolder(let entries):
            let width = max(3, String(count).count)
            for (index, entry) in entries.enumerated() {
                let name = numberedName(index: index, width: width, screenName: entry.screenName)
                let file = try await work.perform { try copySource(entry.sourceURL, to: folderURL, name: name) }
                copied.append(file)
                try await onProgress(Double(copied.count) / Double(count), String(localized: "Screenshot \(copied.count) of \(count)", bundle: .module))
            }
        case .screenFolders(let allGroups):
            let groups = allGroups.filter { !$0.sourceURLs.isEmpty }
            let groupWidth = max(3, String(groups.count).count)
            for (index, group) in groups.enumerated() {
                let folder = try await work.perform {
                    try createExportFolder(in: folderURL,
                        name: numberedName(index: index, width: groupWidth, screenName: group.screenName))
                }
                let fileWidth = max(3, String(group.sourceURLs.count).count)
                for (fileIndex, source) in group.sourceURLs.enumerated() {
                    let name = numberedName(index: fileIndex, width: fileWidth, screenName: group.screenName)
                    let file = try await work.perform { try copySource(source, to: folder, name: name) }
                    copied.append(file)
                    try await onProgress(Double(copied.count) / Double(count), String(localized: "Screenshot \(copied.count) of \(count)", bundle: .module))
                }
            }
        }
        try Task.checkCancellation()
        return copied
    }

    private static func copySource(_ source: URL, to folder: URL, name: String) throws -> URL {
        var suffix = 1
        while true {
            try Task.checkCancellation()
            let component = suffix == 1 ? name : "\(name)-\(suffix)"
            let destination = folder.appendingPathComponent("\(component).png")
            do {
                try FileManager.default.copyItem(at: source, to: destination)
                return destination
            } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileWriteFileExistsError {
                suffix += 1
            }
        }
    }

    @discardableResult
    public static func copy(
        files: [URL], to folderURL: URL, work: ProcessingLane = .standalone(),
        onProgress: @Sendable (Double, String) async throws -> Void = { _, _ in }
    ) async throws -> [URL] {
        var copied: [URL] = []
        for (index, file) in files.enumerated() {
            let destination = try await work.perform {
                let destination = nonconflictingURL(folder: folderURL, name: file.deletingPathExtension().lastPathComponent)
                try FileManager.default.copyItem(at: file, to: destination)
                return destination
            }
            copied.append(destination)
            try await onProgress(Double(index + 1) / Double(files.count), String(localized: "Screenshot \(index + 1) of \(files.count)", bundle: .module))
        }
        try Task.checkCancellation()
        return copied
    }

    @discardableResult
    public static func export(
        states: [UIState], from videoURL: URL, to folderURL: URL,
        startingIndex: Int = 0,
        work: ProcessingLane = .standalone(),
        onProgress: @escaping @Sendable (Double, String) async throws -> Void = { _, _ in },
        onScreenshot: @escaping @Sendable (Int, URL) async throws -> Void = { _, _ in }
    ) async throws -> [URL] {
        try await exportOriginals(states: states, from: videoURL, to: folderURL,
                                  startingIndex: startingIndex, work: work,
                                  onProgress: onProgress, onScreenshot: onScreenshot, encode: writePNG)
    }

    static func exportOriginals(
        states: [UIState], from videoURL: URL, to folderURL: URL, startingIndex: Int = 0,
        work: ProcessingLane? = nil,
        onProgress: @escaping @Sendable (Double, String) async throws -> Void = { _, _ in },
        onScreenshot: @escaping @Sendable (Int, URL) async throws -> Void = { _, _ in },
        encode: @escaping @Sendable (CGImage, URL) async throws -> Void
    ) async throws -> [URL] {
        let asset = AVURLAsset(url: videoURL)
        let generator = Mutex(AVAssetImageGenerator(asset: asset))
        generator.withLock {
            $0.appliesPreferredTrackTransform = true
            $0.requestedTimeToleranceBefore = .zero
            $0.requestedTimeToleranceAfter = .zero
        }
        defer { generator.withLock { $0.cancelAllCGImageGeneration() } }
        return try await withTaskCancellationHandler {
            var outputURLs: [URL] = []
            outputURLs.reserveCapacity(states.count)
            let times = states.map { CMTime(seconds: $0.representativeTimestamp, preferredTimescale: 600) }
            for start in stride(from: 0, to: states.count, by: 4) {
                try Task.checkCancellation()
                let indices = Array(start..<min(start + 4, states.count))
                let decode: @Sendable () async throws -> [(Int, CGImage)] = {
                    var remaining = indices
                    var decoded: [(Int, CGImage)] = []
                    let images = generator.withLock { $0.images(for: indices.map { times[$0] }) }
                    for await result in images {
                        try Task.checkCancellation()
                        let image = try result.image
                        guard let position = remaining.firstIndex(where: { CMTimeCompare(times[$0], result.requestedTime) == 0 }) else {
                            throw ScreenshotExportError.invalidImageSequence
                        }
                        decoded.append((remaining.remove(at: position), image))
                    }
                    try Task.checkCancellation()
                    guard remaining.isEmpty else { throw ScreenshotExportError.invalidImageSequence }
                    return decoded
                }
                let decoded: [(Int, CGImage)]
                if let work { decoded = try await work.perform(decode) }
                else { decoded = try await decode() }
                try await withThrowingTaskGroup(of: (Int, URL).self) { group in
                    for (index, image) in decoded {
                        let baseName = String(format: "%03d_%@", startingIndex + index + 1,
                                              timestampName(states[index].representativeTimestamp))
                        let destinationURL = nonconflictingURL(folder: folderURL, name: baseName)
                        group.addTask {
                            if let work { try await work.perform { try await encode(image, destinationURL) } }
                            else { try await encode(image, destinationURL) }
                            return (index, destinationURL)
                        }
                    }
                    var ready: [Int: URL] = [:]
                    var next = start
                    while let (index, url) = try await group.next() {
                        try Task.checkCancellation()
                        ready[index] = url
                        while let url = ready.removeValue(forKey: next) {
                            try Task.checkCancellation()
                            outputURLs.append(url)
                            try await onScreenshot(next, url)
                            try await onProgress(Double(next + 1) / Double(states.count), String(localized: "Screenshot \(next + 1) of \(states.count)", bundle: .module))
                            try Task.checkCancellation()
                            next += 1
                        }
                    }
                }
            }
            try Task.checkCancellation()
            return outputURLs
        } onCancel: { generator.withLock { $0.cancelAllCGImageGeneration() } }
    }

    static func writePNG(_ image: CGImage, to url: URL) async throws {
        try Task.checkCancellation()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .utility).async {
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

    private static func numberedName(index: Int, width: Int, screenName: String) -> String {
        let title = screenName.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        let slug = title.split { !$0.isLetter && !$0.isNumber }.joined(separator: "-")
        return String(format: "%0*d", width, index + 1) + "_" + (slug.isEmpty ? "ecran" : String(slug.prefix(64)))
    }

    private static func createExportFolder(in parent: URL, name: String) throws -> URL {
        var suffix = 1
        while true {
            try Task.checkCancellation()
            let component = suffix == 1 ? name : "\(name)-\(suffix)"
            let folder = parent.appendingPathComponent(component, isDirectory: true)
            if folder.path.withCString({ mkdir($0, 0o777) }) == 0 { return folder }
            let code = errno
            guard code == EEXIST else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [NSFilePathErrorKey: folder.path])
            }
            suffix += 1
        }
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
        case .invalidImageSequence: String(localized: "The video did not provide every requested screenshot.", bundle: .module)
        case .invalidNameCount: String(localized: "Every screenshot must have a screen name.", bundle: .module)
        case .cannotCreateFile(let url): String(localized: "Could not create \(url.lastPathComponent).", bundle: .module)
        case .cannotWriteFile(let url): String(localized: "Could not write \(url.lastPathComponent).", bundle: .module)
        }
    }
}
