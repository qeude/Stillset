import Foundation
import StillsetCore
import Testing

struct OrderedCallbackTests {
    @Test func suspendedPNGCallbacksReleaseGlobalSlotsAndCancellationKeepsWrittenOriginals() async throws {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/scroll-stops-navigation-return.mov")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let firstFolder = folder.appendingPathComponent("first"), secondFolder = folder.appendingPathComponent("second")
        try FileManager.default.createDirectory(at: firstFolder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondFolder, withIntermediateDirectories: true)
        let lanes = try ProcessingBudget().makeLanes(count: 3)
        let gate = CallbackGate()
        let state = UIState(interval: 0..<0.4, representativeTimestamp: 0.3, stabilityScore: 1)
        let first = Task {
            try await ScreenshotExporter.export(states: [state], from: fixture, to: firstFolder, work: lanes[0],
                onScreenshot: { _, url in await gate.arrive(0, url: url) })
        }
        let second = Task {
            try await ScreenshotExporter.export(states: [state], from: fixture, to: secondFolder, work: lanes[1],
                onScreenshot: { _, url in await gate.arrive(1, url: url) })
        }
        await gate.waitForBoth()
        #expect(try await lanes[2].perform { 42 } == 42)
        first.cancel()
        await gate.release(0)
        await gate.release(1)
        await #expect(throws: CancellationError.self) { try await first.value }
        let completed = try await second.value
        let firstFile = try #require(await gate.files[0])
        #expect(try Data(contentsOf: firstFile) == Data(contentsOf: completed[0]))
        #expect(try FileManager.default.contentsOfDirectory(atPath: firstFolder.path).count == 1)
    }

    @Test func throwingOrderedCallbacksStopNewWorkAndKeepPreparedBeforeFrames() async throws {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/scroll-stops-navigation-return.mov")
        let gate = CallbackOrder()
        await #expect(throws: CallbackFailure.self) {
            try await VideoDecoder.decode(url: fixture, onFrames: { frames in
                await gate.append("frames:\(frames.count)")
                throw CallbackFailure.stopped
            }, onProgress: { _ in await gate.append("progress") }, onPrepared: { _ in await gate.append("prepared") })
        }
        #expect(await gate.events == ["prepared", "frames:8"])
    }
}
private enum CallbackFailure: Error { case stopped }
private actor CallbackOrder {
    private(set) var events: [String] = []
    func append(_ event: String) { events.append(event) }
}
private actor CallbackGate {
    private(set) var files: [Int: URL] = [:]
    private var operations: [Int: CheckedContinuation<Void, Never>] = [:]
    private var observers: [CheckedContinuation<Void, Never>] = []
    func arrive(_ id: Int, url: URL) async {
        files[id] = url
        if files.count == 2 {
            for observer in observers { observer.resume() }
            observers.removeAll()
        }
        await withCheckedContinuation { operations[id] = $0 }
    }
    func waitForBoth() async {
        if files.count == 2 { return }
        await withCheckedContinuation { observers.append($0) }
    }
    func release(_ id: Int) { operations.removeValue(forKey: id)?.resume() }
}
