import Foundation
import StillsetCore

actor IncrementalCaptures {
    typealias Export = @Sendable ([UIState], URL, URL, Int, @escaping @Sendable (Int, URL) async -> Void) async throws -> [URL]

    private let videoURL: URL
    private let folderURL: URL
    private let preparedRecognition: ScreenCatalogAnalyzer.PreparedRecognition?
    private let onCapture: @Sendable (CapturedScreenshot) async -> Void
    private let export: Export
    private var pending: Task<Void, Error>?
    private var acceptsStates = true
    private var admittedCount = 0
    private var buffered: [UIState] = []
    private(set) var completed: [CapturedScreenshot] = []

    init(videoURL: URL, folderURL: URL, preparedRecognition: ScreenCatalogAnalyzer.PreparedRecognition?,
         export: @escaping Export = { states, video, folder, ordinal, callback in
             try await ScreenshotExporter.export(states: states, from: video, to: folder,
                                                 startingIndex: ordinal, onScreenshot: callback)
         }, onCapture: @escaping @Sendable (CapturedScreenshot) async -> Void) {
        self.videoURL = videoURL
        self.folderURL = folderURL
        self.preparedRecognition = preparedRecognition
        self.export = export
        self.onCapture = onCapture
    }

    func append(_ states: [UIState]) async throws {
        try Task.checkCancellation()
        guard acceptsStates else { throw CancellationError() }
        for state in states {
            buffered.append(state)
            if admittedCount == 0 || buffered.count == 4 {
                try await drain()
                try Task.checkCancellation()
                guard acceptsStates else { throw CancellationError() }
                startBufferedExport()
            }
        }
    }

    private func startBufferedExport() {
        let states = buffered
        buffered.removeAll(keepingCapacity: true)
        let ordinal = admittedCount
        admittedCount += states.count
        let export = export
        let videoURL = videoURL
        let folderURL = folderURL
        pending = Task {
            try Task.checkCancellation()
            _ = try await export(states, videoURL, folderURL, ordinal) { index, url in
                if ordinal + index == 0 { self.preparedRecognition?.start(fileURL: url) }
                await self.commit(CapturedScreenshot(state: states[index], fileURL: url))
            }
        }
    }

    func finish() async throws -> [CapturedScreenshot] {
        acceptsStates = false
        try await drain()
        try Task.checkCancellation()
        if !buffered.isEmpty {
            startBufferedExport()
            try await drain()
        }
        try Task.checkCancellation()
        return completed
    }

    func cancelAndDrain() async {
        acceptsStates = false
        buffered.removeAll()
        if let pending {
            pending.cancel()
            _ = await pending.result
        }
        pending = nil
    }

    private func drain() async throws {
        guard let pending else { return }
        try await withTaskCancellationHandler {
            try await pending.value
        } onCancel: { pending.cancel() }
        self.pending = nil
    }

    private func commit(_ capture: CapturedScreenshot) async {
        completed.append(capture)
        await onCapture(capture)
    }
}
