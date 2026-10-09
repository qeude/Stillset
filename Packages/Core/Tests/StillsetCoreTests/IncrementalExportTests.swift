import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import StillsetCore

@Suite(.timeLimit(.minutes(1)))
struct IncrementalExportTests {
    @Test func earlierOriginalPublishesWhileLaterEncoderIsBlocked() async throws {
        let folder = try outputFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let gate = ExportGate()
        let published = ExportEvents()
        let states = [state(0), state(0), state(2.5)]
        let export = Task {
            try await ScreenshotExporter.exportOriginals(states: states, from: video, to: folder, startingIndex: 9,
                onScreenshot: { index, url in await published.append(index, url) }, encode: { image, url in
                    if url.lastPathComponent.hasPrefix("011_") { try await gate.block() }
                    try await ScreenshotExporter.writePNG(image, to: url)
                })
        }
        await gate.waitUntilEntered()
        await published.waitForCount(1)
        #expect(await published.indices == [0])
        let first = try #require(await published.urls.first)
        #expect(first.lastPathComponent == "010_00-00.000.png")
        let source = try #require(CGImageSourceCreateWithURL(first as CFURL, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(image.width == 128 && image.height == 192)
        await gate.release()
        let files = try await export.value
        #expect(files.map(\.lastPathComponent) == ["010_00-00.000.png", "011_00-00.000.png", "012_00-02.500.png"])
        #expect(await published.indices == [0, 1, 2])
        #expect(try Data(contentsOf: files[0]) == Data(contentsOf: files[1]))
    }

    @Test func reverseEncoderCompletionPublishesOnlyChronologicalPrefix() async throws {
        let folder = try outputFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let gate = ExportGate()
        let encoded = ExportEvents()
        let published = ExportEvents()
        let export = Task {
            try await ScreenshotExporter.exportOriginals(states: [state(0), state(0.8), state(1.6), state(2.5)],
                from: video, to: folder, onScreenshot: { index, url in await published.append(index, url) },
                encode: { image, url in
                    if url.lastPathComponent.hasPrefix("001_") { try await gate.block() }
                    try await ScreenshotExporter.writePNG(image, to: url)
                    await encoded.append(0, url)
                })
        }
        await gate.waitUntilEntered()
        await encoded.waitForCount(3)
        #expect(await published.indices.isEmpty)
        await gate.release()
        let files = try await export.value
        #expect(await published.indices == [0, 1, 2, 3])
        #expect(files.map(\.lastPathComponent) == ["001_00-00.000.png", "002_00-00.800.png", "003_00-01.600.png", "004_00-02.500.png"])
    }

    @Test func cancellationDrainsBlockedEncoderAndRetainsCommittedPNG() async throws {
        let folder = try outputFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let gate = ExportGate()
        let published = ExportEvents()
        let export = Task {
            try await ScreenshotExporter.exportOriginals(states: [state(0), state(0.8)], from: video, to: folder,
                onScreenshot: { index, url in await published.append(index, url) }, encode: { image, url in
                    if url.lastPathComponent.hasPrefix("002_") { try await gate.block() }
                    try await ScreenshotExporter.writePNG(image, to: url)
                })
        }
        await gate.waitUntilEntered()
        await published.waitForCount(1)
        export.cancel()
        await gate.waitForCancellation()
        #expect(await gate.isBlocked)
        await gate.release()
        await #expect(throws: CancellationError.self) { try await export.value }
        #expect(await gate.isBlocked == false)
        #expect(await published.indices == [0])
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("001_00-00.000.png").path))
    }

    @Test func encoderFailurePropagatesWithoutRemovingEarlierOriginal() async throws {
        let folder = try outputFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let gate = ExportGate()
        let published = ExportEvents()
        let export = Task {
            try await ScreenshotExporter.exportOriginals(states: [state(0), state(0.8)], from: video, to: folder,
                onScreenshot: { index, url in await published.append(index, url) }, encode: { image, url in
                    if url.lastPathComponent.hasPrefix("002_") {
                        try await gate.block()
                        throw CocoaError(.fileWriteNoPermission)
                    }
                    try await ScreenshotExporter.writePNG(image, to: url)
                })
        }
        await gate.waitUntilEntered()
        await published.waitForCount(1)
        await gate.release()
        await #expect(throws: CocoaError.self) { try await export.value }
        #expect(await published.indices == [0])
        let source = try #require(CGImageSourceCreateWithURL(folder.appendingPathComponent("001_00-00.000.png") as CFURL, nil))
        #expect(CGImageSourceGetCount(source) == 1)
    }

    @Test func finalizedCallbacksPreserveExactChronologyAndEOFOccursOnce() async throws {
        let events = FinalizedEvents()
        let result = try await AnalysisPipeline.run(url: video, onProgress: { _ in },
            onDetectedScreens: { states in await events.append(states) })
        let streamed = await events.states
        #expect(streamed.map(\.id) == result.states.map(\.id))
        #expect(Set(streamed.map(\.id)).count == 5)
        #expect(streamed.map(\.representativeTimestamp) == [0.3, 1.0, 2.0, 2.3, 3.0])
        #expect(streamed.map(\.interval) == [0.0..<0.4, 0.8..<1.2, 1.6..<2.0, 2.2..<2.5, 2.7..<3.0])
        #expect(streamed.count == 5)
        await #expect(throws: CocoaError.self) {
            try await AnalysisPipeline.run(url: video, onProgress: { _ in }, onDetectedScreens: { _ in
                throw CocoaError(.fileWriteNoPermission)
            })
        }
    }

    private func state(_ time: TimeInterval) -> UIState {
        UIState(interval: time..<(time + 0.1), representativeTimestamp: time, stabilityScore: 1)
    }

    private var video: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/scroll-stops-navigation-return.mov")
    }

    private func outputFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }
}

private actor FinalizedEvents {
    private(set) var states: [UIState] = []
    func append(_ states: [UIState]) { self.states.append(contentsOf: states) }
}

private actor ExportEvents {
    private(set) var indices: [Int] = []
    private(set) var urls: [URL] = []
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []
    func append(_ index: Int, _ url: URL) {
        indices.append(index)
        urls.append(url)
        for (count, waiter) in waiters where indices.count >= count { waiter.resume() }
        waiters.removeAll { indices.count >= $0.0 }
    }
    func waitForCount(_ count: Int) async {
        if indices.count < count { await withCheckedContinuation { waiters.append((count, $0)) } }
    }
}

private actor ExportGate {
    private var entered = false
    private var cancelled = false
    private var released = false
    private var entryWaiter: CheckedContinuation<Void, Never>?
    private var cancellationWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?
    private(set) var isBlocked = false

    func block() async throws {
        entered = true
        entryWaiter?.resume()
        entryWaiter = nil
        isBlocked = true
        await withTaskCancellationHandler {
            if !released { await withCheckedContinuation { releaseWaiter = $0 } }
        } onCancel: { Task { await self.markCancelled() } }
        isBlocked = false
        try Task.checkCancellation()
    }
    func waitUntilEntered() async {
        if !entered { await withCheckedContinuation { entryWaiter = $0 } }
    }
    func waitForCancellation() async {
        if !cancelled { await withCheckedContinuation { cancellationWaiter = $0 } }
    }
    private func markCancelled() {
        cancelled = true
        cancellationWaiter?.resume()
        cancellationWaiter = nil
    }
    func release() {
        released = true
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}
