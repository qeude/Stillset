import Foundation
import StillsetCore
import Testing
@testable import StillsetFeatures

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct OperationOwnershipTests {
    @Test func saveDuringOrganizationKeepsFrozenOriginalsAfterAnalysisCancellation() async throws {
        let suite = "Stillset-Operations-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AppPreferences(defaults: defaults)
        let model = AppModel(preferences: preferences)
        let organization = OperationGate()
        let copying = OperationGate()
        model.beforeOrganization = { try await organization.block() }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        model.importVideo(recording)
        await organization.waitUntilEntered()
        #expect(model.isAnalyzing && model.progress.stage == .annotating)
        model.selectAll()
        let sources = model.selectedScreenshots.map(\.fileURL)
        let originalBytes = try sources.map { try Data(contentsOf: $0) }
        #expect(sources.count == 5)
        #expect(model.canSaveSelection)
        model.chooseSaveFolder = { plan in
            #expect(plan.fileCount == 5)
            #expect(!model.canSaveSelection)
            model.saveSelection()
            model.importVideo(URL(fileURLWithPath: "/tmp/replacement.mov"))
            #expect(model.videoURL == recording)
            model.selectScreenshot(model.screenshots[0].id, modifiers: [])
            model.setTimelineGrouping(true)
            preferences.screenExportLayout = .folders
            return folder
        }
        model.copyFiles = { plan, destination, progress in
            try await copying.block()
            return try ScreenshotExporter.copy(plan: plan, to: destination, onProgress: progress)
        }
        model.saveSelection()
        await copying.waitUntilEntered()
        #expect(model.saveProgress?.stage == .exporting)
        #expect(model.progress.stage == .annotating)
        model.cancel()
        await organization.release()
        await model.waitForAnalysis()
        #expect(!model.isAnalyzing && model.isWorking)
        #expect(model.progress.stage == .cancelled && model.analysisOutcome == .cancelled)
        #expect(model.saveOutcome == nil && model.saveProgress != nil)
        await copying.release()
        await model.waitForSave()
        #expect(!model.isWorking && model.canSaveSelection)
        #expect(model.exportedFolderURL == folder && model.saveOutcome == .completed)
        let outputs = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        #expect(outputs.map(\.lastPathComponent) == (1...5).map { String(format: "%03d_a-identifier.png", $0) })
        #expect(try outputs.map { try Data(contentsOf: $0) } == originalBytes)
        #expect(try sources.map { try Data(contentsOf: $0) } == originalBytes)
    }

    @Test func panelCancellationAndSaveCancellationLeaveAnalysisOwned() async throws {
        let suite = "Stillset-Operations-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(preferences: AppPreferences(defaults: defaults))
        let organization = OperationGate()
        let copying = OperationGate()
        model.beforeOrganization = { try await organization.block() }
        model.importVideo(recording)
        await organization.waitUntilEntered()
        model.selectAll()
        model.chooseSaveFolder = { _ in
            #expect(model.isAnalyzing && !model.canSaveSelection)
            model.saveSelection()
            return nil
        }
        model.saveSelection()
        #expect(model.canSaveSelection && model.saveProgress == nil && model.saveOutcome == .cancelled)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        model.chooseSaveFolder = { _ in folder }
        model.copyFiles = { plan, destination, progress in
            try await copying.block()
            return try ScreenshotExporter.copy(plan: plan, to: destination, onProgress: progress)
        }
        model.saveSelection()
        await copying.waitUntilEntered()
        model.cancelSave()
        await copying.release()
        await model.waitForSave()
        #expect(model.isAnalyzing && model.isWorking)
        #expect(model.progress.stage == .annotating && model.saveProgress == nil)
        #expect(model.analysisOutcome == nil && model.saveOutcome == .cancelled)
        #expect(model.canSaveSelection)
        #expect(model.screenshots.count == 5)
        #expect(model.screenshots.allSatisfy { FileManager.default.fileExists(atPath: $0.fileURL.path) })
        model.cancel()
        await organization.release()
        await model.waitForAnalysis()
        #expect(model.progress.stage == .cancelled)
    }

    @Test func replacingRecordingDrainsRefinementBeforeRemovingItsSources() async throws {
        let suite = "Stillset-Operations-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(preferences: AppPreferences(defaults: defaults))
        model.importVideo(recording)
        await model.waitForAnalysis()
        #expect(model.progress.stage == .complete)
        let sources = model.screenshots.map(\.fileURL)
        #expect(sources.count == 5)
        let refinement = OperationGate()
        model.beforeOrganization = { try await refinement.block() }
        model.refineScreens()
        await refinement.waitUntilEntered()
        #expect(model.refinementDetail != nil)
        model.importVideo(recording)
        #expect(model.isAnalyzing)
        #expect(sources.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
        model.cancel()
        await refinement.release()
        await model.waitForAnalysis()
        #expect(model.progress.stage == .cancelled && model.refinementDetail == nil)
        #expect(sources.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
    }

    private var recording: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Core/Tests/Fixtures/scroll-stops-navigation-return.mov")
    }
}

private actor OperationGate {
    private var entered = false
    private var released = false
    private var entryWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func block() async throws {
        entered = true
        entryWaiter?.resume()
        entryWaiter = nil
        if !released { await withCheckedContinuation { releaseWaiter = $0 } }
        try Task.checkCancellation()
    }

    func waitUntilEntered() async {
        if !entered { await withCheckedContinuation { entryWaiter = $0 } }
    }

    func release() {
        released = true
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}
