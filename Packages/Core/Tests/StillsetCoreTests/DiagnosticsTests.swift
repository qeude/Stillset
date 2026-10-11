import Foundation
import CoreGraphics
import Synchronization
import Testing
@testable import StillsetCore

struct DiagnosticsTests {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func report(_ url: URL) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    private func events(_ url: URL) throws -> [[String: Any]] {
        try #require(report(url)["events"] as? [[String: Any]])
    }

    @Test func emptyHistoryIncludesCurrentMetadata() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = DiagnosticJournal(storeURL: root.appendingPathComponent("store"), appVersion: "0.1.0", appBuild: "1")
        let export = root.appendingPathComponent("export")
        try await journal.export(to: export)
        let output = try report(export)
        let metadata = try #require(output["metadata"] as? [String: Any])
        #expect(metadata["appVersion"] as? [Int] == [0, 1, 0])
        #expect(metadata["appBuild"] as? [Int] == [1])
        let os = ProcessInfo.processInfo.operatingSystemVersion
        #expect(metadata["osVersion"] as? [Int] == [os.majorVersion, os.minorVersion, os.patchVersion])
        #if arch(arm64)
        #expect(metadata["architecture"] as? String == "arm64")
        #elseif arch(x86_64)
        #expect(metadata["architecture"] as? String == "x86_64")
        #endif
        #expect(try events(export).isEmpty)
        #expect(output["persistence"] as? String == "available")
    }

    @Test func hostileErrorsAndMetadataNeverReachDiskOrExport() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let canary = "PRIVATE-video-name-OCR-username-serial-123"
        let hostileURL = root.appendingPathComponent(canary)
        let hostile = NSError(domain: canary, code: 42, userInfo: [NSLocalizedDescriptionKey: canary,
            NSFilePathErrorKey: hostileURL.path, NSUnderlyingErrorKey: NSError(domain: canary, code: 1)])
        let store = root.appendingPathComponent("store")
        let journal = DiagnosticJournal(storeURL: store, appVersion: canary, appBuild: "1." + canary)
        let operation = await journal.begin(.analysis)
        await operation.stage(.decoding)
        await operation.issue(.classify(hostile), at: .semanticNaming)
        await operation.issue(.classify(ScreenshotExportError.cannotWriteFile(hostileURL)), at: .saving)
        await operation.finish(.failure(hostile))
        let export = root.appendingPathComponent("export")
        try await journal.export(to: export)
        for file in [store, export] {
            let text = try String(contentsOf: file, encoding: .utf8)
            #expect(!text.contains(canary))
            #expect(!text.contains(root.path))
            let output = try events(file)
            #expect(output.map { $0["kind"] as? String } == ["started", "stage", "issue", "issue", "finished"])
            #expect(output.last?["failure"] as? String == "unknown")
            #expect(output[3]["failure"] as? String == "cannotWriteFile")
        }
        #expect(DiagnosticFailure.classify(VideoAnalysisError.noVideoFrames) == .noVideoFrames)
        #expect(DiagnosticFailure.classify(NSError(domain: NSCocoaErrorDomain, code: CocoaError.fileWriteNoPermission.rawValue, userInfo: hostile.userInfo)) == .permissionDenied)
    }

    @Test func reloadReencodesOnlyTypedFieldsAndPreservesOriginatingVersion() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = root.appendingPathComponent("store")
        let first = DiagnosticJournal(storeURL: store, appVersion: "0.1.0", appBuild: "1")
        let operation = await first.begin(.analysis)
        await operation.finish(.success)
        var document = try report(store)
        var records = try events(store)
        records[0]["privateText"] = "PRIVATE-OCR-CANARY"
        document["privateText"] = "PRIVATE-FILENAME-CANARY"
        document["events"] = records
        try JSONSerialization.data(withJSONObject: document).write(to: store)
        let next = DiagnosticJournal(storeURL: store, appVersion: "0.2.0", appBuild: "2")
        let second = await next.begin(.reanalysis)
        await second.finish(.cancelled)
        let export = root.appendingPathComponent("export")
        try await next.export(to: export)
        let output = try events(export)
        #expect(output.count == 4)
        #expect((output[0]["metadata"] as? [String: Any])?["appVersion"] as? [Int] == [0, 1, 0])
        #expect((output[2]["metadata"] as? [String: Any])?["appVersion"] as? [Int] == [0, 2, 0])
        #expect((try report(export)["metadata"] as? [String: Any])?["appVersion"] as? [Int] == [0, 2, 0])
        #expect(output.last?["outcome"] as? String == "cancelled")
        for file in [store, export] { #expect(try !String(contentsOf: file, encoding: .utf8).contains("PRIVATE-")) }
    }

    @Test func unknownEnumCorruptAndOversizedStoresAreDiscarded() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        for mode in 0..<3 {
            let store = root.appendingPathComponent("store-\(mode)")
            if mode == 0 {
                let initial = DiagnosticJournal(storeURL: store, appVersion: "1", appBuild: "1")
                _ = await initial.begin(.analysis)
                var document = try report(store)
                var records = try events(store)
                records[0]["operation"] = "PRIVATE-UNKNOWN-TEXT"
                document["events"] = records
                try JSONSerialization.data(withJSONObject: document).write(to: store)
            } else {
                try Data(repeating: 65, count: mode == 1 ? 20 : 256 * 1024 + 1).write(to: store)
            }
            let journal = DiagnosticJournal(storeURL: store, appVersion: "1", appBuild: "1")
            let operation = await journal.begin(.screenshotExport)
            await operation.finish(.success)
            let export = root.appendingPathComponent("export-\(mode)")
            try await journal.export(to: export)
            #expect(try events(export).count == 2)
            #expect(try report(export)["persistence"] as? String == "unavailable")
            #expect(try !String(contentsOf: export, encoding: .utf8).contains("PRIVATE-"))
            #expect(try Data(contentsOf: store).count <= 256 * 1024)
        }
    }

    @Test func eventAndByteBoundsAndSevenDayPruning() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = Mutex(Date(timeIntervalSince1970: 1_000_000))
        let store = root.appendingPathComponent("store")
        let journal = DiagnosticJournal(storeURL: store, appVersion: "1", appBuild: "1", now: { clock.withLock { $0 } })
        for _ in 0..<140 {
            let operation = await journal.begin(.analysis)
            await operation.finish(.success)
        }
        let export = root.appendingPathComponent("export")
        try await journal.export(to: export)
        let retained = try events(export)
        #expect(retained.count == 256)
        #expect(retained.first?["sequence"] as? Int == 25)
        #expect(retained.last?["sequence"] as? Int == 280)
        #expect(try Data(contentsOf: store).count <= 256 * 1024)
        #expect(try Data(contentsOf: export).count <= 256 * 1024)
        clock.withLock { $0.addTimeInterval(7 * 24 * 60 * 60 + 1) }
        let reloaded = DiagnosticJournal(storeURL: store, appVersion: "1", appBuild: "1", now: { clock.withLock { $0 } })
        await reloaded.prepare()
        #expect(try events(store).isEmpty)
        let operation = await reloaded.begin(.sessionCatalog)
        await operation.stage(.cataloging)
        try await reloaded.export(to: export)
        #expect(try events(export).map { $0["kind"] as? String } == ["started", "stage"])
        clock.withLock { $0.addTimeInterval(7 * 24 * 60 * 60 + 1) }
        try await reloaded.export(to: export)
        #expect(try events(export).isEmpty)
    }

    @Test func deniedPersistenceStillExportsBoundedMemoryAndSafeWriteError() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let blocker = root.appendingPathComponent("not-a-directory")
        try Data().write(to: blocker)
        let journal = DiagnosticJournal(storeURL: blocker.appendingPathComponent("store"), appVersion: "1", appBuild: "1")
        let operation = await journal.begin(.sessionExport)
        await operation.stage(.saving)
        await operation.finish(.failed(.diskFull))
        let export = root.appendingPathComponent("export")
        try await journal.export(to: export)
        #expect(try report(export)["persistence"] as? String == "unavailable")
        #expect(try events(export).last?["failure"] as? String == "diskFull")
        for _ in 0..<140 {
            let attempt = await journal.begin(.analysis)
            await attempt.finish(.success)
        }
        try await journal.export(to: export)
        #expect(try events(export).count == 256)
        #expect(try Data(contentsOf: export).count <= 256 * 1024)
        do {
            try await journal.export(to: blocker.appendingPathComponent("PRIVATE-destination"))
            Issue.record("Export should fail")
        } catch {
            #expect(error is DiagnosticExportError)
            #expect(!String(describing: error).contains("PRIVATE-"))
        }
    }

    @Test func concurrentOperationsRemainOrderedWithExactlyOneTerminalEvent() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = DiagnosticJournal(storeURL: root.appendingPathComponent("store"), appVersion: "1", appBuild: "1")
        await withTaskGroup(of: Void.self) { group in
            for index in 0..<30 {
                group.addTask {
                    let operation = await journal.begin(.analysis)
                    await operation.stage(.decoding)
                    await operation.stage(.decoding)
                    await operation.issue(.unknown, at: .recognition)
                    await operation.issue(.unknown, at: .recognition)
                    await operation.finish(index % 2 == 0 ? .success : .cancelled)
                    await operation.finish(.failed(.unknown))
                    await operation.stage(.saving)
                }
            }
        }
        let export = root.appendingPathComponent("export")
        try await journal.export(to: export)
        let records = try events(export)
        #expect(records.count == 120)
        #expect(records.compactMap { $0["sequence"] as? Int } == Array(1...120))
        let groups = Dictionary(grouping: records) { $0["id"] as? String }
        #expect(groups.count == 30)
        for group in groups.values {
            #expect(group.map { $0["kind"] as? String } == ["started", "stage", "issue", "finished"])
        }
        #expect(records.filter { $0["outcome"] as? String == "success" }.count == 15)
        #expect(records.filter { $0["outcome"] as? String == "cancelled" }.count == 15)
    }

    @Test func recognitionFailureKeepsOnlyFixedCodeInCatalogEvidence() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("PRIVATE-video-OCR-name.png")
        try Data([1, 2, 3]).write(to: file)
        let pixels = Data(repeating: 0, count: 16)
        let provider = try #require(CGDataProvider(data: pixels as CFData))
        let image = try #require(CGImage(width: 2, height: 2, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: 8, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let hostile = NSError(domain: "PRIVATE-DOMAIN", code: 42, userInfo: [NSLocalizedDescriptionKey: "PRIVATE-OCR"])
        let analyzer = ScreenCatalogAnalyzer(recognizeImage: { _, _ in throw hostile }, thumbnail: { _ in image })
        let journal = DiagnosticJournal(storeURL: root.appendingPathComponent("store"), appVersion: "1", appBuild: "1")
        let operation = await journal.begin(.analysis)
        let catalog = try await analyzer.analyze(fileURLs: [file], useFoundationModels: false, diagnostics: operation)
        #expect(catalog.classifications.count == 1)
        await operation.finish(.success)
        let export = root.appendingPathComponent("export")
        try await journal.export(to: export)
        let issues = try events(export).filter { $0["kind"] as? String == "issue" }
        #expect(issues.count == 1)
        #expect(issues[0]["stage"] as? String == "recognition")
        #expect(issues[0]["failure"] as? String == "unknown")
        for name in ["store", "export"] {
            #expect(try !String(contentsOf: root.appendingPathComponent(name), encoding: .utf8).contains("PRIVATE-"))
        }
    }

    @Test func namingFailuresAndOCRFallbackAreSafeAndDeduplicated() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = root.appendingPathComponent("store")
        let journal = DiagnosticJournal(storeURL: store, appVersion: "1", appBuild: "1")
        let operation = await journal.begin(.refinement)
        let canary = "PRIVATE-VIDEO-NAME-OCR"
        let error = NSError(domain: canary, code: 77, userInfo: [NSLocalizedDescriptionKey: canary])
        for _ in 0..<2 {
            let result = try await ScreenSemanticNamer.nameWithFallback(root.appendingPathComponent(canary),
                recognizeTitle: { _ in throw error }, diagnostics: operation, operation: { throw error })
            #expect(result.name == "Screenshot to Review")
        }
        let result = try await ScreenSemanticNamer.nameWithFallback(root.appendingPathComponent(canary),
            recognizedTitle: .known(canary), diagnostics: operation, operation: { throw error })
        #expect(result.name == canary)
        await operation.finish(.success)
        let export = root.appendingPathComponent("export")
        try await journal.export(to: export)
        for file in [store, export] {
            #expect(try !String(contentsOf: file, encoding: .utf8).contains(canary))
            #expect(try events(file).filter { $0["kind"] as? String == "issue" }.count == 2)
        }
    }
}
