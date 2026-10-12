import Foundation
import Synchronization
// Vision's legacy request is not Sendable, but its cancel call must overlap a blocked perform.
@preconcurrency import Vision

final class RequestCancellation: Sendable {
    private struct State: Sendable {
        var isCancelled = false
        var isFinished = false
        var cancel: (@Sendable () -> Void)?
    }

    private let state = Mutex(State())
    private let enqueue: @Sendable (@escaping @Sendable () -> Void) -> Void

    init(enqueue: @escaping @Sendable (@escaping @Sendable () -> Void) -> Void = {
        DispatchQueue.global(qos: .utility).async(execute: $0)
    }) {
        self.enqueue = enqueue
    }

    var isCancelled: Bool { state.withLock { $0.isCancelled } }
    var isFinished: Bool { state.withLock { $0.isFinished } }

    func install(cancel: @escaping @Sendable () -> Void) -> Bool {
        let result = state.withLock { state -> (installed: Bool, cancelImmediately: Bool) in
            guard !state.isCancelled, !state.isFinished else { return (false, state.isCancelled) }
            state.cancel = cancel
            return (true, false)
        }
        if result.cancelImmediately { cancel() }
        return result.installed
    }

    func cancel() {
        let shouldDispatch = state.withLock { state -> Bool in
            guard !state.isCancelled else { return false }
            state.isCancelled = true
            return state.cancel != nil
        }
        guard shouldDispatch else { return }
        enqueue { self.invokeCancellationIfNeeded() }
    }

    func finish() {
        state.withLock {
            $0.isFinished = true
            $0.cancel = nil
        }
    }

    private func invokeCancellationIfNeeded() {
        let handler = state.withLock { state -> (@Sendable () -> Void)? in
            guard state.isCancelled, !state.isFinished else { return nil }
            let handler = state.cancel
            state.cancel = nil
            return handler
        }
        handler?()
    }
}

/// Local foreground evidence resolves clear cases before invoking the language model.
enum ScreenVisionFallback {
    struct TextLine: Sendable {
        let text: String
        let box: CGRect
        let confidence: Float
        var rowPixels: [UInt8] = []
    }

    struct Recognition: Sendable {
        let title: String?
        let pickerName: String?
        let lines: [TextLine]
        var titleConfidence: Float = 0
        var pixels: [UInt8] = []

        var fastName: String? {
            if let pickerName { return pickerName }
            // A lowercase start is a clipped sentence of body text, not a header.
            guard titleConfidence >= 0.85, let title, !title.isEmpty, title.count <= 60, title.first?.isLowercase != true,
                  // A lone leading letter may be an icon read as text (a magnifier as "Q"), and only the image tells; leave it to the model.
                  title.split(separator: " ").first.map({ $0.count > 1 || $0.contains(where: \.isNumber) }) == true
            else { return nil }
            // ponytail: repeated inset labels are ambiguous forms; keep their state classification with the model.
            let labels = lines.filter {
                (0.06...0.14).contains($0.box.minX) && (0.12...0.75).contains($0.box.midY)
                    && $0.box.height <= 0.025 && $0.text.contains(where: \.isLetter)
            }
            let consecutive = zip(labels, labels.dropFirst()).filter {
                (0.05...0.12).contains($0.0.box.midY - $0.1.box.midY)
                    && abs($0.0.box.minX - $0.1.box.minX) < 0.02
            }
            return consecutive.count >= 2 ? nil : title
        }

        /// Two independent reads of the same string agree even when each was read with low confidence.
        func hasSameTitle(as other: Self) -> Bool {
            guard let title, let otherTitle = other.title, !title.isEmpty else { return false }
            return Self.normalized(title) == Self.normalized(otherTitle)
        }

        /// Same header and the same reliable text above the tab bar. Pixels can still differ through animated chrome.
        func isNearMiss(of other: Self) -> Bool {
            guard hasSameTitle(as: other) else { return false }
            func content(_ recognition: Self) -> Set<String> {
                Set(recognition.lines.filter { $0.confidence >= 0.9 && $0.box.midY > 0.14 }.map { Self.normalized($0.text) })
            }
            let current = content(self), previous = content(other)
            guard current.count >= 4, previous.count >= 4 else { return false }
            return Double(current.intersection(previous).count) / Double(current.union(previous).count) >= 0.85
        }

        /// The same page scrolled: several reliable content lines are shared, wherever they sit. Navigation chrome is excluded.
        func isScrolledContinuation(of other: Self) -> Bool {
            func content(_ recognition: Self) -> Set<String> {
                Set(recognition.lines.filter {
                    $0.confidence >= 0.9 && (0.18...0.94).contains($0.box.midY) && $0.text.count >= 4
                }.map { Self.normalized($0.text) })
            }
            let current = content(self), previous = content(other)
            let shared = current.intersection(previous).count
            return shared >= 3 && Double(shared) / Double(min(current.count, previous.count)) >= 0.5
        }

        /// Equal titles, or titles neither of which was read well enough to tell the screens apart.
        func hasComparableTitle(with other: Self) -> Bool {
            hasSameTitle(as: other) || (titleConfidence < 0.85 && other.titleConfidence < 0.85)
        }

        /// Every reliable line in the content area has the same text at the same place in the other screen, and conversely.
        func hasSameContentText(as other: Self) -> Bool {
            func reliable(_ recognition: Self) -> [TextLine] {
                recognition.lines.filter { $0.confidence >= 0.9 && (0.18...0.94).contains($0.box.midY) }
            }
            let current = reliable(self), previous = reliable(other)
            func covered(_ lines: [TextLine], by others: [TextLine]) -> Bool {
                lines.allSatisfy { line in
                    others.contains { Self.normalized($0.text) == Self.normalized(line.text) && abs($0.box.midY - line.box.midY) < 0.012 }
                }
            }
            // A reliable line may be read with less confidence in the other frame, so match against every line there.
            return current.count >= 4 && previous.count >= 4 && covered(current, by: other.lines) && covered(previous, by: lines)
        }

        /// Why `sameState` cannot decide. Diagnostics only.
        func ambiguity(with other: Self) -> String {
            if title == nil || other.title == nil { return "missingTitle" }
            if titleConfidence < 0.85 || other.titleConfidence < 0.85 { return "lowTitleConfidence" }
            if lines.isEmpty || other.lines.isEmpty { return "noText" }
            return "sameTitleInconclusive"
        }

        /// nil means ambiguous. Text agreement alone never authorizes grouping.
        func sameState(as other: Self) -> Bool? {
            guard let title, let otherTitle = other.title, !lines.isEmpty, !other.lines.isEmpty else { return nil }
            let confident = titleConfidence >= 0.85 && other.titleConfidence >= 0.85
            if confident, Self.normalized(title) != Self.normalized(otherTitle) { return false }
            // A header read with low confidence (stylized text over artwork) cannot prove a difference.
            // The rest of the page and its pixels still decide, so a misread header is left out of the comparison.
            func body(_ lines: [TextLine], _ title: String) -> [TextLine] {
                confident ? lines : lines.filter { Self.normalized($0.text) != Self.normalized(title) }
            }
            let lines = body(lines, title)
            let otherLines = body(other.lines, otherTitle)
            guard !lines.isEmpty, !otherLines.isEmpty else { return nil }
            if clearlyDiffers(from: other) { return false }
            let current = Dictionary(grouping: lines, by: { Self.contentText($0.text) })
            let previous = Dictionary(grouping: otherLines, by: { Self.contentText($0.text) })
            guard Set(current.keys) == Set(previous.keys), current.allSatisfy({ previous[$0.key]?.count == $0.value.count }) else {
                // Stable text gaining a reliable badge/value/error is a changed state, not scrolling.
                let reliable = Set(lines.filter { $0.confidence >= 0.9 }.map { Self.contentText($0.text) })
                let otherReliable = Set(otherLines.filter { $0.confidence >= 0.9 }.map { Self.contentText($0.text) })
                // Near-identical pixels with the same reliable text differ only by OCR jitter on faint lines.
                if reliable.count >= 3, reliable == otherReliable,
                   let difference = Self.tileDifference(pixels, other.pixels, width: 128, height: 256), difference <= 3 {
                    return true
                }
                let union = reliable.union(otherReliable)
                if reliable.count >= 4, otherReliable.count >= 4,
                   Double(reliable.intersection(otherReliable).count) / Double(union.count) < 0.5 { return false }
                let common = Set(current.keys).intersection(previous.keys)
                let stationary = common.count >= 3 && common.allSatisfy { key in
                    guard let a = current[key], let b = previous[key], a.count == 1, b.count == 1 else { return false }
                    return abs(a[0].box.midY - b[0].box.midY) < 0.008
                }
                let additions = lines.filter { previous[Self.contentText($0.text)] == nil }
                    + otherLines.filter { current[Self.contentText($0.text)] == nil }
                return stationary && additions.allSatisfy { $0.confidence >= 0.85 } ? false : nil
            }
            if let difference = Self.tileDifference(pixels, other.pixels, width: 128, height: 256), difference <= 6 {
                return true
            }
            // ponytail: compact numeric-list scrolls; unfamiliar layouts stay ambiguous.
            let body = lines.filter { Self.normalized($0.text) != Self.normalized(title) }
            guard body.count >= 3, body.allSatisfy({ Self.isNumeric($0.text) && $0.box.minX < 0.25 && $0.box.maxX < 0.7 }) else { return nil }
            for line in lines {
                guard let matches = previous[Self.contentText(line.text)], matches.count == 1,
                      abs(line.box.midY - matches[0].box.midY) <= 0.04 else { return nil }
                let isOption = Self.isNumeric(line.text)
                if isOption, matches[0].box.minX >= 0.25 || matches[0].box.maxX >= 0.7 { return nil }
                // OCR already checks the labels. The central control band stays visible under a sticky header,
                // and includes both the radio's centre and side strokes without comparing jittering glyphs.
                let textStart = max(0, Int(floor((min(line.box.minX, matches[0].box.minX) - 0.04) / 0.93 * 128)))
                let textEnd = min(128, Int(ceil(max(line.box.maxX, matches[0].box.maxX) / 0.93 * 128)))
                let differences = (-1...1).compactMap { shift in
                    Self.tileDifference(line.rowPixels, matches[0].rowPixels, width: 128, height: 24,
                        rowShift: shift, excludedColumns: isOption ? textStart..<textEnd : nil, rowInset: isOption ? 8 : 1)
                }
                guard let difference = differences.min(), difference <= 12 else { return nil }
            }
            return true
        }

        private static func contentText(_ text: String) -> String {
            text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }

        private static func isNumeric(_ text: String) -> Bool {
            text.range(of: #"^[+0-9][0-9\s.,+–-]*(?:km)?$"#, options: [.regularExpression, .caseInsensitive]) != nil
        }

        private static func tileDifference(_ first: [UInt8], _ second: [UInt8], width: Int, height: Int,
                                           rowShift: Int = 0, excludedColumns: Range<Int>? = nil, rowInset: Int = 1) -> Double? {
            guard first.count == width * height * 4, second.count == first.count,
                  rowInset > 0, rowInset * 2 < height else { return nil }
            var maximum = 0.0
            for top in stride(from: rowInset, to: height - rowInset, by: 6) {
                for left in stride(from: 0, to: width, by: 8) {
                    var total = 0.0
                    var count = 0
                    for y in top..<min(top + 6, height - rowInset) where (0..<height).contains(y + rowShift) {
                        for x in left..<min(left + 8, width) where excludedColumns?.contains(x) != true {
                            let a = (y * width + x) * 4
                            let b = ((y + rowShift) * width + x) * 4
                            for channel in 0..<3 { total += abs(Double(first[a + channel]) - Double(second[b + channel])) }
                            count += 3
                        }
                    }
                    if count > 0 { maximum = max(maximum, total / Double(count)) }
                }
            }
            return maximum
        }
        func clearlyDiffers(from other: Self) -> Bool {
            let reliable = lines.filter { $0.confidence >= 0.9 }
            let otherReliable = other.lines.filter { $0.confidence >= 0.9 }
            let texts = Set(reliable.map { Self.normalized($0.text) })
            let otherTexts = Set(otherReliable.map { Self.normalized($0.text) })
            // Only reject substitutions at the same position. Text moved by scrolling is not a substitution.
            return reliable.contains { line in
                let text = Self.normalized(line.text)
                guard !otherTexts.contains(text) else { return false }
                return otherReliable.contains { candidate in
                    !texts.contains(Self.normalized(candidate.text))
                        && abs(line.box.midY - candidate.box.midY) < 0.008
                        && abs(line.box.minX - candidate.box.minX) < 0.02
                        && abs(line.box.height - candidate.box.height) < 0.008
                }
            }
        }

        private static func normalized(_ text: String) -> String {
            text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
                .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }
    }

    static func name(_ url: URL) async throws -> String? {
        try await recognize(url).title
    }

    static func recognize(_ url: URL) async throws -> Recognition {
        try Task.checkCancellation()
        return try await recognize(Data(contentsOf: url))
    }

    static func recognize(_ data: Data) async throws -> Recognition {
        try Task.checkCancellation()
        return try await recognize(ScreenCatalogAnalyzer.proxyImage(data))
    }

    static func recognize(_ image: CGImage) async throws -> Recognition {
        try Task.checkCancellation()
        let cancellation = RequestCancellation()
        let recognition: Recognition = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                // Vision waits on internal queues; keep synchronous work off Swift's cooperative executor.
                DispatchQueue.global(qos: .utility).async {
                    do {
                        guard !cancellation.isCancelled else { throw CancellationError() }
                        let request = VNRecognizeTextRequest()
                        guard cancellation.install(cancel: {
                            request.cancel()
                        }) else { throw CancellationError() }
                        request.recognitionLevel = .accurate
                        request.recognitionLanguages = ["fr-FR", "en-US"]
                        request.usesLanguageCorrection = false
                        guard !cancellation.isCancelled else { throw CancellationError() }
                        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
                        let lines = (request.results ?? []).filter {
                            $0.boundingBox.maxY <= 0.94 && ($0.topCandidates(1).first?.confidence ?? 0) >= 0.3
                        }.sorted {
                            let row = Int($0.boundingBox.midY * 60)
                            let otherRow = Int($1.boundingBox.midY * 60)
                            return row == otherRow ? $0.boundingBox.minX < $1.boundingBox.minX : row > otherRow
                        }
                        let titles = lines.filter {
                            $0.boundingBox.width >= 0.12
                                && ($0.topCandidates(1).first?.string.contains(where: \.isLetter) ?? false)
                                && ($0.topCandidates(1).first?.string.count ?? 0) <= 80
                        }
                        let page = titles.first { $0.boundingBox.midY >= 0.65 }
                        // ponytail: centered, bright header over a dimmed page identifies common bottom sheets.
                        // Other overlay layouts need a broader labelled corpus before extending this heuristic.
                        let pageBrightness = page.map { brightness(image, $0.boundingBox) } ?? 255
                        let sheet = titles.first {
                            (0.2...0.75).contains($0.boundingBox.midY)
                                && abs($0.boundingBox.midX - 0.5) <= 0.1
                                && brightness(image, $0.boundingBox) > pageBrightness + 45
                        }
                        let title = sheet ?? page ?? titles.first
                        let titleText = title?.topCandidates(1).first?.string
                        // ponytail: only a bright sheet with multiple numeric options skips the model.
                        // Forms and ambiguous headings keep image analysis; expand with labelled fixtures.
                        let recognizedLines = lines.compactMap { line in
                            line.topCandidates(1).first.map {
                                TextLine(text: $0.string, box: line.boundingBox, confidence: $0.confidence,
                                    rowPixels: pixels(image, box: CGRect(x: 0.02, y: max(0, line.boundingBox.midY - 0.03),
                                        width: 0.93, height: min(0.06, 1 - max(0, line.boundingBox.midY - 0.03))), width: 128, height: 24))
                            }
                        }
                        let picker = sheet.flatMap { header in
                            numericPickerName(title: header.topCandidates(1).first?.string ?? "",
                                confidence: header.topCandidates(1).first?.confidence ?? 0,
                                body: recognizedLines.filter { $0.box.midY < header.boundingBox.minY })
                        }
                        let recognition = Recognition(
                            title: titleText.map { ScreenClassification(screenID: 0, name: droppingLeadingIcon($0)).name },
                            pickerName: picker,
                            lines: recognizedLines.filter { $0.box.midY <= (sheet.map { $0.boundingBox.maxY + 0.04 } ?? 0.94) },
                            titleConfidence: title?.topCandidates(1).first?.confidence ?? 0,
                            pixels: pixels(image, box: CGRect(x: 0, y: 0, width: 1,
                                height: sheet.map { $0.boundingBox.maxY + 0.04 } ?? 0.94), width: 128, height: 256)
                        )
                        cancellation.finish()
                        continuation.resume(returning: recognition)
                    } catch {
                        cancellation.finish()
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
        try Task.checkCancellation()
        return recognition
    }

    /// Vision reads a leading icon (a chevron, a close cross) as a one-character word. A symbol is never a word in any language.
    static func droppingLeadingIcon(_ text: String) -> String {
        let words = text.split(separator: " ", maxSplits: 1)
        guard words.count == 2, words[0].count == 1, !words[0].contains(where: { $0.isLetter || $0.isNumber }) else { return text }
        return String(words[1])
    }

    static func numericPickerName(title: String, confidence: Float, body: [TextLine]) -> String? {
        guard confidence >= 0.85, !title.isEmpty, title.count <= 40,
              body.filter({ $0.confidence >= 0.85 }).count >= 3,
              body.allSatisfy({ $0.text.range(of: #"^[+0-9][0-9\s.,+–-]*(?:km)?$"#,
                  options: [.regularExpression, .caseInsensitive]) != nil }) else { return nil }
        return String(localized: "Choose \(title)", bundle: .module)
    }

    private static func pixels(_ image: CGImage, box: CGRect, width: Int, height: Int) -> [UInt8] {
        let rect = CGRect(x: box.minX * Double(image.width), y: (1 - box.maxY) * Double(image.height),
                          width: box.width * Double(image.width), height: box.height * Double(image.height))
        guard let cropped = image.cropping(to: rect) else { return [] }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let rendered = pixels.withUnsafeMutableBytes { bytes in
            guard let context = CGContext(data: bytes.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            context.draw(cropped, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return rendered ? pixels : []
    }

    private static func brightness(_ image: CGImage, _ box: CGRect) -> Int {
        let rect = CGRect(x: box.minX * Double(image.width), y: (1 - box.maxY) * Double(image.height),
                          width: box.width * Double(image.width), height: box.height * Double(image.height))
        guard let cropped = image.cropping(to: rect) else { return 0 }
        var pixels = [UInt8](repeating: 0, count: 64 * 16)
        pixels.withUnsafeMutableBytes { bytes in
            guard let context = CGContext(data: bytes.baseAddress, width: 64, height: 16,
                                          bitsPerComponent: 8, bytesPerRow: 64,
                                          space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0) else { return }
            context.draw(cropped, in: CGRect(x: 0, y: 0, width: 64, height: 16))
        }
        return Int(pixels.max() ?? 0)
    }
}
