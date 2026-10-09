import Foundation
import StillsetCore
import Testing
@testable import StillsetFeatures

@MainActor
struct SessionProjectionStressTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["STILLSET_PROJECTION_STRESS"] == "1"))
    func projectionStress() async throws {
        let environment = ProcessInfo.processInfo.environment
        let n = Int(environment["STILLSET_STRESS_N"] ?? "256") ?? 0
        try #require([256, 1024, 4096].contains(n))
        let half = n / 2
        let directory = URL(fileURLWithPath: "/tmp/StillsetProjectionStress-\(UUID())")
        let states = (0..<half).map { index in
            UIState(id: UUID(uuidString: "00000000-0000-0000-0000-\(String(format: "%012d", index + 1))")!,
                interval: Double(index / 2)..<Double(index / 2 + 1), representativeTimestamp: Double(index / 2), stabilityScore: 1)
        }
        let captures = ["A", "B"].map { name in
            states.enumerated().map { index, state in
                CapturedScreenshot(state: state, fileURL: directory.appendingPathComponent("\(name)-\(index).png"))
            }
        }
        let labels = states.indices.map { ScreenClassification(screenID: $0 % 4 + 1, name: "Screen \($0 % 4 + 1)", stateID: $0 + 1) }
        let frames = (0..<16).map { [Frame(timestamp: Double($0), width: 1920, height: 1080, luma: Data([UInt8($0)]))] }
        let warmJobs = captures.map { captures in
            let job = AppModel()
            job.screenshots = captures
            job.screenClassifications = Dictionary(uniqueKeysWithValues: zip(states.map(\.id), labels))
            job.setAnalysisPreviewFrames(frames[0])
            return job
        }
        let warmSession = SessionModel(preferences: AppPreferences(defaults: UserDefaults(suiteName: "StillsetStressWarm-\(UUID())")!),
            imports: VideoImportQueue(models: warmJobs), catalogRunner: { _, _, _ in SessionCatalogResult(classifications: []) })
        _ = bundle(warmSession)
        await warmSession.waitForCatalog()
        var records: [[String: Any]] = []
        for individual in [false, true] {
            let runner = ControlledAnalysisRunner()
            let a = AppModel(), b = AppModel()
            a.admit(directory.appendingPathComponent("A.mov"))
            b.admit(directory.appendingPathComponent("B.mov"))
            let completions = [a.startAnalysis(runner: runner.run), b.startAnalysis(runner: runner.run)]
            let runs = [await runner.waitForStart(a), await runner.waitForStart(b)]
            let invalid = (0..<20).map { index in
                let job = AppModel()
                job.admit(directory.appendingPathComponent("invalid-\(index).mp4"), failure: "Expected invalid fixture")
                return job
            }
            a.setAnalysisPreviewFrames(frames[0])
            b.setAnalysisPreviewFrames(frames[0])
            let queue = VideoImportQueue(models: [a, b] + invalid)
            let defaults = UserDefaults(suiteName: "StillsetStress-\(UUID())")!
            let session = SessionModel(preferences: AppPreferences(defaults: defaults), imports: queue,
                catalogRunner: { _, _, _ in SessionCatalogResult(classifications: []) })
            session.setUniqueScreens(false)
            session.setTimelineGrouping(false)
            session.followsLatest = true
            let counter = PublicationCount()
            for job in [a, b] {
                let publication = job.onPublication
                job.onPublication = { counter.value += 1; publication?() }
            }
            let ids = [a, b].flatMap { job in states.map { OccurrenceID(videoID: job.id, stateID: $0.id) } }
            func record(_ phase: String, _ body: () -> Int) -> Int {
                let publications = counter.value
                let builds = buildCount(session)
                let start = DispatchTime.now().uptimeNanoseconds
                let checksum = body()
                let elapsed = DispatchTime.now().uptimeNanoseconds - start
                records.append(["phase": phase, "arrival_mode": individual ? "individual" : "batch", "elapsed_ns": elapsed,
                    "callbacks": counter.value - publications, "builds": buildCount(session) - builds,
                    "checksum": checksum, "ready": session.screenshots.count, "metadata": session.catalogSnapshot.inputs.count,
                    "selected": session.selectedScreenshotIDs.count, "geometry_changes": 0,
                    "terminal": a.importState == .completed && b.importState == .completed ? "completed" : "running"])
                return checksum
            }
            let detectedCount = record("detections") {
                for run in runs { run.publish { $0.detectedScreens = states } }
                return session.occurrences.count
            }
            #expect(detectedCount == n)
            #if !STILLSET_BASELINE_PROJECTION
            #expect(records.last?["builds"] as? Int == 2)
            #endif
            #expect(session.occurrences.map(\.id) == ids)
            var samples: [UInt64] = []
            let arrived = record("structural_arrivals") {
                if individual {
                    for index in states.indices {
                        for video in 0..<2 {
                            let start = DispatchTime.now().uptimeNanoseconds
                            runs[video].publish { $0.screenshots.append(captures[video][index]) }
                            samples.append(DispatchTime.now().uptimeNanoseconds - start)
                        }
                    }
                } else {
                    for video in 0..<2 {
                        let start = DispatchTime.now().uptimeNanoseconds
                        runs[video].publish { $0.screenshots = captures[video] }
                        samples.append(DispatchTime.now().uptimeNanoseconds - start)
                    }
                }
                return session.screenshots.count
            }
            #expect(arrived == n)
            #if !STILLSET_BASELINE_PROJECTION
            #expect(records.last?["builds"] as? Int == (individual ? n : 2))
            #endif
            #expect(session.screenshots.map(\.id) == ids)
            #expect(session.screenshots.map(\.fileURL) == captures.flatMap { $0.map(\.fileURL) })
            #expect(session.focusedScreenshotID == ids.last)
            let sorted = samples.sorted()
            records[records.count - 1]["latency_samples"] = sorted.count
            records[records.count - 1]["median_ns"] = sorted[sorted.count / 2]
            records[records.count - 1]["p95_ns"] = sorted[min(sorted.count - 1, (sorted.count * 95 + 99) / 100 - 1)]
            records[records.count - 1]["max_ns"] = sorted.last!
            _ = record("local_classifications") {
                for run in runs { run.publish { $0.screenClassifications = Dictionary(uniqueKeysWithValues: zip(states.map(\.id), labels)) } }
                return session.timelineScreenGroups.count
            }
            #expect(session.timelineScreenGroups.count == 8)
            #if !STILLSET_BASELINE_PROJECTION
            #expect(records.last?["builds"] as? Int == 2)
            #endif
            _ = bundle(session)
            let readChecksum = record("getter_reads") { (0..<16).reduce(0) { sum, _ in sum + bundle(session) } }
            #expect(readChecksum == 16 * (36 * n + 67))
            let presentationChecksum = record("progress_and_equal_geometry_preview") {
                var sum = 0
                for index in frames.indices {
                    for run in runs {
                        run.publish {
                            $0.progress = AnalysisProgress(stage: .decoding, fraction: Double(index) / 16, detail: "Stress \(index)")
                            $0.setAnalysisPreviewFrames(frames[index])
                        }
                    }
                    sum += bundle(session)
                }
                return sum
            }
            #expect(presentationChecksum == 16 * (36 * n + 67))
            #expect(session.occurrences.map(\.aspectRatio) == Array(repeating: CGFloat(16) / 9, count: n))
            let visibilityCount = record("visibility") {
                for _ in 0..<8 {
                    session.setUniqueScreens(true)
                    session.setTimelineGrouping(true)
                    session.setUniqueScreens(false)
                    session.setTimelineGrouping(false)
                }
                return session.visibleScreenshots.count
            }
            #expect(visibilityCount == n)
            let selectionChecksum = record("selection") {
                for _ in 0..<16 {
                    session.selectScreenshot(ids[0], modifiers: [])
                    session.selectScreenshot(ids[n - 1], modifiers: .shift)
                }
                return bundle(session)
            }
            #expect(selectionChecksum == 47 * n + 56)
            #expect(session.selectedScreenshots.map(\.id) == ids)
            #expect(session.makeSelectionExportPlan() == .singleFolder(captures.flatMap { captures in
                captures.enumerated().map { .init(sourceURL: $0.element.fileURL, screenName: labels[$0.offset].name) }
            }))
            let terminalCallbacks = counter.value
            let terminalBuilds = buildCount(session)
            for job in [a, b] { runner.finish(job, with: .completed) }
            for completion in completions { await completion.value }
            await session.waitForCatalog()
            #expect(counter.value - terminalCallbacks == 2)
            #if !STILLSET_BASELINE_PROJECTION
            #expect(buildCount(session) - terminalBuilds == 2)
            #endif
            records.append(["phase": "terminal_delivery", "arrival_mode": individual ? "individual" : "batch",
                "elapsed_ns": NSNull(), "callbacks": counter.value - terminalCallbacks,
                "builds": buildCount(session) - terminalBuilds, "checksum": session.catalogSnapshot.inputs.count,
                "ready": session.screenshots.count, "metadata": session.catalogSnapshot.inputs.count,
                "selected": session.selectedScreenshotIDs.count, "geometry_changes": 0, "terminal": "completed"])
            let globalLabels = labels + labels
            var applied = false
            let metadataCount = record("metadata_application") {
                applied = session.applyCatalog(globalLabels, snapshot: session.catalogSnapshot, refined: false)
                return session.visibleScreenshots.count
            }
            #expect(applied && metadataCount == n)
            session.setUniqueScreens(true)
            #expect(session.visibleScreenshots.map(\.id) == Array(ids.prefix(half)))
            #expect(session.timelineScreenGroups.map(\.id) == Array(ids.prefix(4)))
            #expect(session.timelineScreenGroups.map(\.videoCount) == [2, 2, 2, 2])
            #expect(bundle(session) == 15 * n + 35 * half + 28)
            #expect(queue.models.filter { $0.importState.failure != nil }.count == 20)
            #expect(a.importState == .completed && b.importState == .completed)
            #if !STILLSET_BASELINE_PROJECTION
            #expect(records.filter { ["getter_reads", "progress_and_equal_geometry_preview", "visibility", "selection"].contains($0["phase"] as? String ?? "") }
                .allSatisfy { $0["builds"] as? Int == 0 })
            #expect(records.last?["builds"] as? Int == 1)
            #endif
            for job in [a, b] { job.onPublication = nil }
        }
        for var record in records {
            #if STILLSET_BASELINE_PROJECTION
            record["builds"] = NSNull()
            #endif
            record["n"] = n
            record["label"] = environment["STILLSET_STRESS_LABEL"] ?? "unlabelled"
            record["os"] = ProcessInfo.processInfo.operatingSystemVersionString
            record["fixture"] = "two held jobs, twenty expected invalid jobs, missing PNGs, preconstructed captures, timestamp ties, composite collisions"
            record["configuration"] = environment["STILLSET_STRESS_CONFIGURATION"] ?? "unspecified"
            record["swift"] = environment["STILLSET_STRESS_SWIFT_VERSION"] ?? "unspecified"
            record["expected_invalid_failures"] = 20
            record["seed"] = 1
            #if arch(arm64)
            record["architecture"] = "arm64"
            #else
            record["architecture"] = "x86_64"
            #endif
            print(String(decoding: try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]), as: UTF8.self))
        }
    }

    private func bundle(_ session: SessionModel) -> Int {
        let entries = session.occurrences
        var bucketCount = 0
        for job in session.imports.models {
            #if STILLSET_BASELINE_PROJECTION
            bucketCount += session.occurrences.filter { $0.id.videoID == job.id }.count
            #else
            bucketCount += session.projection.occurrencesByVideo[job.id, default: []].count
            #endif
        }
        let focusRank = session.focusedScreenshotID.flatMap { id in entries.firstIndex { $0.id == id } } ?? -1
        return entries.count + session.catalogSnapshot.inputs.count * 3 + session.visibleScreenshots.count * 5
            + session.timelineScreenGroups.count * 7 + bucketCount * 11 + session.selectedScreenshots.count * 13
            + session.makeSelectionExportPlan().fileCount * 17 + focusRank * 19
    }

    private func buildCount(_ session: SessionModel) -> Int {
        #if STILLSET_BASELINE_PROJECTION
        0
        #else
        session.projectionBuildCount
        #endif
    }
}

@MainActor
private final class PublicationCount { var value = 0 }

#if STILLSET_BASELINE_PROJECTION
private extension AppModel {
    func setAnalysisPreviewFrames(_ frames: [Frame]) { analysisPreviewFrames = frames }
}
#endif
