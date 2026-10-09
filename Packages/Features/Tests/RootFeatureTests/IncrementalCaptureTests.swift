import Foundation
import Testing
@testable import StillsetCore
@testable import StillsetFeatures

@Suite(.timeLimit(.minutes(1)))
struct IncrementalCaptureTests {
    @Test func decodingAdvancesWithOneBlockedExportAndPreservesAllOriginals() async throws {
        let folder = try outputFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let gate = CaptureGate()
        let events = CaptureEvents()
        let prepared = ScreenCatalogAnalyzer.PreparedRecognition()
        let captures = IncrementalCaptures(videoURL: video, folderURL: folder, preparedRecognition: prepared,
            export: { states, video, folder, ordinal, callback in
                try await ScreenshotExporter.exportOriginals(states: states, from: video, to: folder,
                    startingIndex: ordinal, onScreenshot: callback, encode: { image, url in
                        if url.lastPathComponent.hasPrefix("001_") { try await gate.block() }
                        try await ScreenshotExporter.writePNG(image, to: url)
                    })
            }, onCapture: { await events.publish($0) })
        let operation = Task {
            do {
                let result = try await AnalysisPipeline.run(url: video, onProgress: { _ in }, onDetectedScreens: { states in
                    let count = await events.detect(states)
                    try await captures.append(states)
                    if count == 1 { await gate.waitUntilEntered() }
                })
                let completed = try await captures.finish()
                await prepared.cancelAndDrain()
                return (result, completed)
            } catch {
                await captures.cancelAndDrain()
                await prepared.cancelAndDrain()
                throw error
            }
        }
        await gate.waitUntilEntered()
        await events.waitForBatches(5)
        #expect(await gate.isBlocked)
        #expect(await events.detected.count == 5)
        #expect(await events.published.isEmpty)
        await gate.release()
        let (result, completed) = try await operation.value
        #expect(completed.map(\.id) == result.states.map(\.id))
        #expect(await events.published.map(\.id) == result.states.map(\.id))
        #expect(completed.count == 5)
        #expect(completed.map { String($0.fileURL.lastPathComponent.prefix(3)) } == ["001", "002", "003", "004", "005"])
        #expect(completed.allSatisfy { FileManager.default.fileExists(atPath: $0.fileURL.path) })
        let baselineFolder = folder.appendingPathComponent("baseline")
        try FileManager.default.createDirectory(at: baselineFolder, withIntermediateDirectories: true)
        let baseline = try await ScreenshotExporter.export(states: result.states, from: video, to: baselineFolder)
        #expect(try completed.map { try Data(contentsOf: $0.fileURL) } == baseline.map { try Data(contentsOf: $0) })
    }

    @Test func firstOriginalPublishesBeforeAnotherAdmission() async throws {
        let folder = try outputFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let events = CaptureEvents()
        let prepared = ScreenCatalogAnalyzer.PreparedRecognition()
        let captures = IncrementalCaptures(videoURL: video, folderURL: folder, preparedRecognition: prepared,
            onCapture: { await events.publish($0) })
        let state = UIState(interval: 0..<0.5, representativeTimestamp: 0.3, stabilityScore: 1)
        try await captures.append([state])
        await events.waitForPublished(1)
        #expect(await events.published.map(\.id) == [state.id])
        #expect(await events.published.map { $0.fileURL.lastPathComponent } == ["001_00-00.300.png"])
        #expect(try await captures.finish().map(\.id) == [state.id])
        await prepared.cancelAndDrain()
    }

    @Test func boundedBatchesOverlapEncodersAndFlushTailOnceInOrder() async throws {
        let folder = try outputFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = CaptureGate()
        let second = CaptureGate()
        let events = CaptureEvents()
        let prepared = ScreenCatalogAnalyzer.PreparedRecognition()
        let states = (0..<10).map {
            UIState(interval: Double($0) / 10..<Double($0 + 1) / 10,
                    representativeTimestamp: Double($0) / 10, stabilityScore: 1)
        }
        let captures = IncrementalCaptures(videoURL: video, folderURL: folder, preparedRecognition: prepared,
            export: { states, video, folder, ordinal, callback in
                await events.export(states)
                return try await ScreenshotExporter.exportOriginals(states: states, from: video, to: folder,
                    startingIndex: ordinal, onScreenshot: callback, encode: { image, url in
                        let number = Int(url.lastPathComponent.prefix(3))!
                        await events.encode(number)
                        if number == 1 { try await first.block() }
                        if number == 2 { try await second.block() }
                        try await ScreenshotExporter.writePNG(image, to: url)
                    })
            }, onCapture: { await events.publish($0) })
        let operation = Task {
            do {
                try await captures.append(states)
                return try await captures.finish()
            } catch {
                await captures.cancelAndDrain()
                throw error
            }
        }
        await first.waitUntilEntered()
        #expect(await events.exported.map(\.count) == [1])
        await first.release()
        await second.waitUntilEntered()
        await events.waitForEncoding(5)
        #expect(await second.isBlocked)
        #expect(await events.exported.map(\.count) == [1, 4])
        #expect(await events.published.map(\.id) == [states[0].id])
        await second.release()
        let completed = try await operation.value
        #expect(completed.map(\.id) == states.map(\.id))
        #expect(await events.published.map(\.id) == states.map(\.id))
        #expect(await events.exported.map(\.count) == [1, 4, 4, 1])
        #expect(await events.exported.flatMap { $0 }.map(\.id) == states.map(\.id))
        #expect(completed.map { String($0.fileURL.lastPathComponent.prefix(3)) } ==
                ["001", "002", "003", "004", "005", "006", "007", "008", "009", "010"])
        #expect(try await captures.finish().map(\.id) == states.map(\.id))
        #expect(await events.exported.map(\.count) == [1, 4, 4, 1])
        let baselineFolder = folder.appendingPathComponent("baseline")
        try FileManager.default.createDirectory(at: baselineFolder, withIntermediateDirectories: true)
        let baseline = try await ScreenshotExporter.export(states: states, from: video, to: baselineFolder)
        #expect(try completed.map { try Data(contentsOf: $0.fileURL) } == baseline.map { try Data(contentsOf: $0) })
        await prepared.cancelAndDrain()
    }

    @Test func cancellationDuringAdmissionDrainsOwnedExport() async throws {
        let folder = try outputFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let gate = CaptureGate()
        let events = CaptureEvents()
        let prepared = ScreenCatalogAnalyzer.PreparedRecognition()
        let captures = IncrementalCaptures(videoURL: video, folderURL: folder, preparedRecognition: prepared,
            export: { states, video, folder, ordinal, callback in
                try await ScreenshotExporter.exportOriginals(states: states, from: video, to: folder,
                    startingIndex: ordinal, onScreenshot: callback, encode: { image, url in
                        try await gate.block()
                        try await ScreenshotExporter.writePNG(image, to: url)
                    })
            }, onCapture: { await events.publish($0) })
        let operation = Task {
            do {
                _ = try await AnalysisPipeline.run(url: video, onProgress: { _ in }, onDetectedScreens: { states in
                    _ = await events.detect(states)
                    try await captures.append(states)
                })
                return try await captures.finish()
            } catch {
                await captures.cancelAndDrain()
                await prepared.cancelAndDrain()
                throw error
            }
        }
        await gate.waitUntilEntered()
        await events.waitForBatches(5)
        operation.cancel()
        await gate.waitForCancellation()
        #expect(await gate.isBlocked)
        await gate.release()
        await #expect(throws: CancellationError.self) { try await operation.value }
        #expect(await gate.isBlocked == false)
        #expect(await events.published.isEmpty)
    }

    @Test func cancellationDuringFinalDrainDiscardsBufferedTail() async throws {
        let folder = try outputFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let gate = CaptureGate()
        let events = CaptureEvents()
        let prepared = ScreenCatalogAnalyzer.PreparedRecognition()
        let states = (0..<3).map {
            UIState(interval: Double($0)..<Double($0 + 1), representativeTimestamp: Double($0), stabilityScore: 1)
        }
        let captures = IncrementalCaptures(videoURL: video, folderURL: folder, preparedRecognition: prepared,
            export: { states, video, folder, ordinal, callback in
                await events.export(states)
                return try await ScreenshotExporter.exportOriginals(states: states, from: video, to: folder,
                    startingIndex: ordinal, onScreenshot: callback, encode: { image, url in
                        try await gate.block()
                        try await ScreenshotExporter.writePNG(image, to: url)
                    })
            }, onCapture: { await events.publish($0) })
        let operation = Task {
            do {
                try await captures.append(states)
                return try await captures.finish()
            } catch {
                await captures.cancelAndDrain()
                throw error
            }
        }
        await gate.waitUntilEntered()
        operation.cancel()
        await gate.waitForCancellation()
        #expect(await events.exported.map(\.count) == [1])
        await gate.release()
        await #expect(throws: CancellationError.self) { try await operation.value }
        #expect(await events.exported.flatMap { $0 }.map(\.id) == [states[0].id])
        #expect(await events.published.isEmpty)
        #expect(await gate.isBlocked == false)
        await #expect(throws: CancellationError.self) { try await captures.append([states[1]]) }
        await prepared.cancelAndDrain()
    }

    @Test func exportErrorsReachNextAdmissionAndFinalDrain() async throws {
        let folder = try outputFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        for finalDrain in [false, true] {
            let gate = CaptureGate()
            let prepared = ScreenCatalogAnalyzer.PreparedRecognition()
            let captures = IncrementalCaptures(videoURL: video, folderURL: folder, preparedRecognition: prepared,
                export: { states, video, folder, ordinal, callback in
                    try await ScreenshotExporter.exportOriginals(states: states, from: video, to: folder,
                        startingIndex: ordinal, onScreenshot: callback, encode: { _, _ in
                            try await gate.block()
                            throw CocoaError(.fileWriteNoPermission)
                        })
                }, onCapture: { _ in })
            let state = UIState(interval: 0..<0.5, representativeTimestamp: 0, stabilityScore: 1)
            try await captures.append([state])
            await gate.waitUntilEntered()
            await gate.release()
            if finalDrain { try await captures.append([state]) }
            await #expect(throws: CocoaError.self) {
                if finalDrain { _ = try await captures.finish() }
                else { try await captures.append(Array(repeating: state, count: 4)) }
            }
            await captures.cancelAndDrain()
            await prepared.cancelAndDrain()
            #expect(await captures.completed.isEmpty)
        }
    }

    private var video: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Core/Tests/Fixtures/scroll-stops-navigation-return.mov")
    }
    private func outputFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }
}

private actor CaptureEvents {
    private(set) var detected: [UIState] = []
    private(set) var published: [CapturedScreenshot] = []
    private(set) var exported: [[UIState]] = []
    private var encoded: Set<Int> = []
    private var encodingWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var publishWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var batches = 0
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []
    func detect(_ states: [UIState]) -> Int {
        detected.append(contentsOf: states)
        batches += 1
        for (count, waiter) in waiters where batches >= count { waiter.resume() }
        waiters.removeAll { batches >= $0.0 }
        return batches
    }
    func export(_ states: [UIState]) { exported.append(states) }
    func encode(_ number: Int) {
        encoded.insert(number)
        for (number, waiter) in encodingWaiters where encoded.contains(number) { waiter.resume() }
        encodingWaiters.removeAll { encoded.contains($0.0) }
    }
    func waitForEncoding(_ number: Int) async {
        if !encoded.contains(number) { await withCheckedContinuation { encodingWaiters.append((number, $0)) } }
    }
    func publish(_ capture: CapturedScreenshot) {
        published.append(capture)
        for (count, waiter) in publishWaiters where published.count >= count { waiter.resume() }
        publishWaiters.removeAll { published.count >= $0.0 }
    }
    func waitForPublished(_ count: Int) async {
        if published.count < count { await withCheckedContinuation { publishWaiters.append((count, $0)) } }
    }
    func waitForBatches(_ count: Int) async {
        if batches < count { await withCheckedContinuation { waiters.append((count, $0)) } }
    }
}

private actor CaptureGate {
    private var entered = false
    private var cancelled = false
    private var released = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var cancellationWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?
    private(set) var isBlocked = false
    func block() async throws {
        entered = true
        for waiter in entryWaiters { waiter.resume() }
        entryWaiters = []
        isBlocked = true
        await withTaskCancellationHandler {
            if !released { await withCheckedContinuation { releaseWaiter = $0 } }
        } onCancel: { Task { await self.markCancelled() } }
        isBlocked = false
        try Task.checkCancellation()
    }
    func waitUntilEntered() async {
        if !entered { await withCheckedContinuation { entryWaiters.append($0) } }
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
