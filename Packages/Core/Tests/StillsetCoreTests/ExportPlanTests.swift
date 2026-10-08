import Foundation
import Synchronization
import Testing
@testable import StillsetCore

struct ExportPlanTests {
    @Test func flatSaveUsesDenseSafeNamesAndIndependentOriginalBytes() throws {
        let root = try makeFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let output = try makeSubfolder("output", in: root)
        let first = try source("042_old-name.png", bytes: [0, 255, 17], in: root)
        let second = try source("099_other.png", bytes: [4, 18, 32], in: root)
        let plan = ScreenshotExportPlan.singleFolder([
            .init(sourceURL: second, screenName: "../Réglages / Profil"),
            .init(sourceURL: first, screenName: "À identifier"),
            .init(sourceURL: second, screenName: "💥"),
            .init(sourceURL: first, screenName: String(repeating: "a", count: 90))
        ])
        let progress = Mutex<[Double]>([])
        let copied = try ScreenshotExporter.copy(plan: plan, to: output) { fraction, _ in
            progress.withLock { $0.append(fraction) }
        }
        #expect(plan.fileCount == 4)
        #expect(copied.map(\.lastPathComponent) == [
            "001_reglages-profil.png", "002_a-identifier.png", "003_ecran.png",
            "004_\(String(repeating: "a", count: 64)).png"
        ])
        #expect(copied.allSatisfy { $0.deletingLastPathComponent() == output })
        #expect(try copied.map { try Data(contentsOf: $0) } == [Data([4, 18, 32]), Data([0, 255, 17]), Data([4, 18, 32]), Data([0, 255, 17])])
        #expect(progress.withLock { $0 } == [0.25, 0.5, 0.75, 1])
        let sourceAttributes = try FileManager.default.attributesOfItem(atPath: first.path)
        let copyAttributes = try FileManager.default.attributesOfItem(atPath: copied[1].path)
        #expect(sourceAttributes[.systemFileNumber] as? NSNumber != copyAttributes[.systemFileNumber] as? NSNumber)
        try Data([99]).write(to: copied[1])
        #expect(try Data(contentsOf: first) == Data([0, 255, 17]))
        try FileManager.default.removeItem(at: second)
        #expect(try Data(contentsOf: copied[0]) == Data([4, 18, 32]))
    }

    @Test func screenFoldersKeepDistinctEqualNamesSkipEmptyGroupsAndReportGlobalProgress() throws {
        let root = try makeFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let output = try makeSubfolder("output", in: root)
        let a = try source("a.png", bytes: [1], in: root)
        let b = try source("b.png", bytes: [2], in: root)
        let plan = ScreenshotExportPlan.screenFolders([
            .init(screenName: "Empty", sourceURLs: []),
            .init(screenName: "Compte", sourceURLs: [b, a]),
            .init(screenName: "Compte", sourceURLs: [a]),
            .init(screenName: "À identifier", sourceURLs: [b])
        ])
        let updates = Mutex<[(Double, String)]>([])
        let copied = try ScreenshotExporter.copy(plan: plan, to: output) { fraction, detail in
            updates.withLock { $0.append((fraction, detail)) }
        }
        #expect(plan.fileCount == 4)
        #expect(copied.map { $0.path.replacingOccurrences(of: output.path + "/", with: "") } == [
            "001_compte/001_compte.png", "001_compte/002_compte.png",
            "002_compte/001_compte.png", "003_a-identifier/001_a-identifier.png"
        ])
        #expect(try copied.map { try Data(contentsOf: $0) } == [Data([2]), Data([1]), Data([1]), Data([2])])
        #expect(updates.withLock { $0.map(\.0) } == [0.25, 0.5, 0.75, 1])
        #expect(updates.withLock { $0.map(\.1) } == [
            "Screenshot 1 of 4", "Screenshot 2 of 4", "Screenshot 3 of 4", "Screenshot 4 of 4"
        ])
        #expect(try FileManager.default.contentsOfDirectory(atPath: output.path).sorted() == ["001_compte", "002_compte", "003_a-identifier"])
    }

    @Test func flatCollisionsPreserveFilesFoldersAndDanglingSymlinks() throws {
        let root = try makeFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let output = try makeSubfolder("output", in: root)
        let input = try source("input.png", bytes: [7, 8], in: root)
        let existing = try source("001_compte.png", bytes: [42], in: output)
        let directory = try makeSubfolder("001_compte-2.png", in: output)
        let link = output.appendingPathComponent("001_compte-3.png")
        let absent = root.appendingPathComponent("absent.png")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: absent)
        let plan = ScreenshotExportPlan.singleFolder([.init(sourceURL: input, screenName: "Compte")])
        let copied = try ScreenshotExporter.copy(plan: plan, to: output)
        #expect(copied.map(\.lastPathComponent) == ["001_compte-4.png"])
        #expect(try Data(contentsOf: existing) == Data([42]))
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == absent.path)
        #expect(!FileManager.default.fileExists(atPath: absent.path))
        #expect(try ScreenshotExporter.copy(plan: plan, to: output).map(\.lastPathComponent) == ["001_compte-5.png"])
        #expect(try Data(contentsOf: input) == Data([7, 8]))
    }

    @Test func folderCollisionsCreateFreshFoldersWithoutFollowingSymlinks() throws {
        let root = try makeFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let output = try makeSubfolder("output", in: root)
        let input = try source("input.png", bytes: [7], in: root)
        let existing = try makeSubfolder("001_compte", in: output)
        let sentinel = try source("keep.png", bytes: [42], in: existing)
        let existingFile = try source("001_compte-2", bytes: [43], in: output)
        let outside = try makeSubfolder("outside", in: root)
        let link = output.appendingPathComponent("001_compte-3")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        let dangling = output.appendingPathComponent("001_compte-4")
        let absent = root.appendingPathComponent("absent")
        try FileManager.default.createSymbolicLink(at: dangling, withDestinationURL: absent)
        let plan = ScreenshotExportPlan.screenFolders([.init(screenName: "Compte", sourceURLs: [input])])
        let copied = try ScreenshotExporter.copy(plan: plan, to: output)
        #expect(copied[0].deletingLastPathComponent().lastPathComponent == "001_compte-5")
        #expect(try Data(contentsOf: copied[0]) == Data([7]))
        #expect(try Data(contentsOf: sentinel) == Data([42]))
        #expect(try Data(contentsOf: existingFile) == Data([43]))
        #expect(try FileManager.default.contentsOfDirectory(atPath: existing.path) == ["keep.png"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == outside.path)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: dangling.path) == absent.path)
        #expect(try ScreenshotExporter.copy(plan: plan, to: output)[0].deletingLastPathComponent().lastPathComponent == "001_compte-6")
    }

    @Test func missingSourcePropagatesAndLeavesCompletedCopies() throws {
        let root = try makeFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let output = try makeSubfolder("output", in: root)
        let input = try source("input.png", bytes: [7], in: root)
        let plan = ScreenshotExportPlan.singleFolder([
            .init(sourceURL: input, screenName: "Compte"),
            .init(sourceURL: root.appendingPathComponent("missing.png"), screenName: "Accueil")
        ])
        #expect(throws: (any Error).self) { try ScreenshotExporter.copy(plan: plan, to: output) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: output.path) == ["001_compte.png"])
        #expect(try Data(contentsOf: output.appendingPathComponent("001_compte.png")) == Data([7]))
        #expect(throws: (any Error).self) {
            try ScreenshotExporter.copy(plan: .screenFolders([.init(screenName: "Compte", sourceURLs: [input])]),
                                        to: root.appendingPathComponent("missing-parent"))
        }
    }

    @Test func cancellationKeepsCompletedCopiesAndStopsBeforeNextFolder() async throws {
        let root = try makeFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let output = try makeSubfolder("output", in: root)
        let input = try source("input.png", bytes: [7], in: root)
        let plan = ScreenshotExportPlan.screenFolders([
            .init(screenName: "Compte", sourceURLs: [input]),
            .init(screenName: "Accueil", sourceURLs: [input])
        ])
        let task = Task.detached {
            try ScreenshotExporter.copy(plan: plan, to: output) { _, _ in
                withUnsafeCurrentTask { $0?.cancel() }
            }
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try FileManager.default.contentsOfDirectory(atPath: output.path) == ["001_compte"])
        #expect(try Data(contentsOf: output.appendingPathComponent("001_compte/001_compte.png")) == Data([7]))
        #expect(try Data(contentsOf: input) == Data([7]))
    }

    @Test func cancelledAndEmptyPlansCreateNoOutputs() async throws {
        let root = try makeFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let output = try makeSubfolder("output", in: root)
        let input = try source("input.png", bytes: [7], in: root)
        #expect(try ScreenshotExporter.copy(plan: .singleFolder([]), to: output).isEmpty)
        #expect(try ScreenshotExporter.copy(plan: .screenFolders([.init(screenName: "Compte", sourceURLs: [])]), to: output).isEmpty)
        let task = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return try ScreenshotExporter.copy(plan: .screenFolders([.init(screenName: "Compte", sourceURLs: [input])]), to: output)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try FileManager.default.contentsOfDirectory(atPath: output.path).isEmpty)
    }

    private func makeFolder() throws -> URL {
        try makeSubfolder("Stillset-ExportPlanTests-\(UUID())", in: FileManager.default.temporaryDirectory)
    }

    private func makeSubfolder(_ name: String, in parent: URL) throws -> URL {
        let folder = parent.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        return folder
    }

    private func source(_ name: String, bytes: [UInt8], in folder: URL) throws -> URL {
        let url = folder.appendingPathComponent(name)
        try Data(bytes).write(to: url)
        return url
    }
}
