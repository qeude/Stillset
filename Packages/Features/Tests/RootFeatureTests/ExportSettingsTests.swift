import Foundation
import StillsetCore
import Testing
@testable import StillsetFeatures

@MainActor
struct ExportSettingsTests {
    @Test func preferencesFallbackIndependentlyWithoutRepairingStorage() {
        let (preferences, defaults, suite) = makePreferences()
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(preferences.captureDefault == .uniques)
        #expect(preferences.organisationDefault == .chronology)
        #expect(preferences.screenExportLayout == .singleFolder)
        #expect(defaults.persistentDomain(forName: suite) == nil)
        for invalid in [42, "unknown"] as [Any] {
            defaults.set(invalid, forKey: AppPreferences.Keys.captures)
            defaults.set(invalid, forKey: AppPreferences.Keys.organisation)
            defaults.set(invalid, forKey: AppPreferences.Keys.exportLayout)
            let fallback = AppPreferences(defaults: defaults)
            #expect(fallback.captureDefault == .uniques)
            #expect(fallback.organisationDefault == .chronology)
            #expect(fallback.screenExportLayout == .singleFolder)
        }

        defaults.set(42, forKey: AppPreferences.Keys.captures)
        defaults.set("unknown", forKey: AppPreferences.Keys.organisation)
        defaults.set("folders", forKey: AppPreferences.Keys.exportLayout)
        let decoded = AppPreferences(defaults: defaults)
        #expect(decoded.captureDefault == .uniques)
        #expect(decoded.organisationDefault == .chronology)
        #expect(decoded.screenExportLayout == .folders)
        #expect(defaults.integer(forKey: AppPreferences.Keys.captures) == 42)
        defaults.set("all", forKey: AppPreferences.Keys.captures)
        defaults.set("byScreen", forKey: AppPreferences.Keys.organisation)
        defaults.set(["singleFolder"], forKey: AppPreferences.Keys.exportLayout)
        let independentlyDecoded = AppPreferences(defaults: defaults)
        #expect(independentlyDecoded.captureDefault == .all)
        #expect(independentlyDecoded.organisationDefault == .byScreen)
        #expect(independentlyDecoded.screenExportLayout == .singleFolder)
    }

    @Test func preferencesRoundTripAndRemainIsolated() {
        let (preferences, defaults, suite) = makePreferences()
        let (other, otherDefaults, otherSuite) = makePreferences()
        defer {
            defaults.removePersistentDomain(forName: suite)
            otherDefaults.removePersistentDomain(forName: otherSuite)
        }
        preferences.captureDefault = .all
        preferences.organisationDefault = .byScreen
        preferences.screenExportLayout = .folders
        let restored = AppPreferences(defaults: UserDefaults(suiteName: suite)!)
        #expect(restored.captureDefault == .all)
        #expect(restored.organisationDefault == .byScreen)
        #expect(restored.screenExportLayout == .folders)
        #expect(other.captureDefault == .uniques)
        #expect(other.organisationDefault == .chronology)
        #expect(other.screenExportLayout == .singleFolder)
        preferences.captureDefault = .uniques
        preferences.organisationDefault = .chronology
        preferences.screenExportLayout = .singleFolder
        let reset = AppPreferences(defaults: defaults)
        #expect(reset.captureDefault == .uniques)
        #expect(reset.organisationDefault == .chronology)
        #expect(reset.screenExportLayout == .singleFolder)
    }

    @Test func defaultsApplyAtInitializationAndAcceptedImportOnly() async throws {
        let (preferences, defaults, suite) = makePreferences()
        defer { defaults.removePersistentDomain(forName: suite) }
        preferences.captureDefault = .all
        preferences.organisationDefault = .byScreen
        let model = AppModel(preferences: preferences)
        #expect(!model.showsUniqueScreens && model.groupsTimelineByScreen)
        populate(model, labels: [(1, "Compte", 1), (2, "Accueil", 2), (1, "Compte", 3)])
        model.selectAll()
        let selection = model.selectedScreenshotIDs
        preferences.captureDefault = .uniques
        preferences.organisationDefault = .chronology
        #expect(!model.showsUniqueScreens && model.groupsTimelineByScreen)
        #expect(model.selectedScreenshotIDs == selection && model.screenshots.count == 3)
        model.setUniqueScreens(true)
        model.setTimelineGrouping(false)
        preferences.captureDefault = .all
        preferences.organisationDefault = .byScreen
        #expect(model.showsUniqueScreens && !model.groupsTimelineByScreen)
        #expect(preferences.captureDefault == .all && preferences.organisationDefault == .byScreen)
        model.importVideo(URL(fileURLWithPath: "/tmp/unsupported.txt"))
        #expect(model.screenshots.count == 3 && model.selectedScreenshotIDs == selection)
        model.importVideo(URL(fileURLWithPath: "/tmp/Stillset-missing-\(UUID()).mov"))
        #expect(!model.showsUniqueScreens && model.groupsTimelineByScreen)
        #expect(model.screenshots.isEmpty && model.selectedScreenshotIDs.isEmpty)
        let acceptedURL = model.videoURL
        model.importVideo(URL(fileURLWithPath: "/tmp/rejected-while-working.mov"))
        #expect(model.videoURL == acceptedURL)
        preferences.captureDefault = .uniques
        preferences.organisationDefault = .chronology
        #expect(!model.showsUniqueScreens && model.groupsTimelineByScreen)
        model.cancel()
        for _ in 0..<2_000 where model.isWorking {
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(!model.isWorking)
    }

    @Test func exportProjectsExistingGroupRankAndChronologicalMembers() {
        let (preferences, defaults, suite) = makePreferences()
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(preferences: preferences)
        populate(model, labels: [(1, "Compte", 1), (2, "Accueil", 2), (1, "Compte", 3)])
        let files = model.screenshots.map(\.fileURL)
        model.selectScreenshot(model.screenshots[1].id, modifiers: [])
        model.selectScreenshot(model.screenshots[2].id, modifiers: [.command])
        preferences.screenExportLayout = .folders
        #expect(model.makeSelectionExportPlan() == .singleFolder([
            .init(sourceURL: files[1], screenName: "Accueil"),
            .init(sourceURL: files[2], screenName: "Compte")
        ]))
        model.setTimelineGrouping(true)
        #expect(model.makeSelectionExportPlan() == .screenFolders([
            .init(screenName: "Compte", sourceURLs: [files[2]]),
            .init(screenName: "Accueil", sourceURLs: [files[1]])
        ]))
        preferences.screenExportLayout = .singleFolder
        #expect(model.makeSelectionExportPlan() == .singleFolder([
            .init(sourceURL: files[2], screenName: "Compte"),
            .init(sourceURL: files[1], screenName: "Accueil")
        ]))
        #expect(model.selectedScreenshots.map(\.fileURL) == [files[1], files[2]])
        #expect(model.dragURLs(startingAt: model.screenshots[2].id) == [files[1], files[2]])
    }

    @Test func exportRetainsUnknownAndEqualNameGroupsAndRespectsVisibleRepeats() {
        let (preferences, defaults, suite) = makePreferences()
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(preferences: preferences)
        populate(model, labels: [(1, "Compte", 1), (2, "Compte", 2), (1, "Compte", 3),
                                 (1, "Compte", 1), nil, nil])
        let files = model.screenshots.map(\.fileURL)
        model.setTimelineGrouping(true)
        preferences.screenExportLayout = .folders
        model.selectAll()
        let uniquePlan = ScreenshotExportPlan.screenFolders([
            .init(screenName: "Compte", sourceURLs: [files[0], files[2]]),
            .init(screenName: "Compte", sourceURLs: [files[1]]),
            .init(screenName: "À identifier", sourceURLs: [files[4], files[5]])
        ])
        #expect(model.makeSelectionExportPlan() == uniquePlan)
        #expect(uniquePlan.fileCount == 5)
        model.setUniqueScreens(false)
        model.selectAll()
        #expect(model.makeSelectionExportPlan() == .screenFolders([
            .init(screenName: "Compte", sourceURLs: [files[0], files[2], files[3]]),
            .init(screenName: "Compte", sourceURLs: [files[1]]),
            .init(screenName: "À identifier", sourceURLs: [files[4], files[5]])
        ]))
        model.setUniqueScreens(true)
        #expect(model.makeSelectionExportPlan() == uniquePlan)
        for id in model.selectedScreenshotOrder { model.selectScreenshot(id, modifiers: [.command]) }
        #expect(model.makeSelectionExportPlan().fileCount == 0)
    }

    @Test func exportPlanRemainsFrozenAcrossRefinementAndPreferenceChanges() {
        let (preferences, defaults, suite) = makePreferences()
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(preferences: preferences)
        populate(model, labels: [(1, "Compte", 1), (2, "Accueil", 2), (1, "Compte", 3)])
        model.setTimelineGrouping(true)
        model.selectAll()
        let originalFiles = model.screenshots.map(\.fileURL)
        let expected = ScreenshotExportPlan.singleFolder([
            .init(sourceURL: originalFiles[0], screenName: "Compte"),
            .init(sourceURL: originalFiles[2], screenName: "Compte"),
            .init(sourceURL: originalFiles[1], screenName: "Accueil")
        ])
        let snapshot = model.makeSelectionExportPlan()
        let newFiles = originalFiles.map { $0.appendingPathExtension("refined.png") }
        model.applyRefinement(classifications: (0..<3).map {
            ScreenClassification(screenID: 3, name: "Profil", stateID: $0 + 1)
        }, files: newFiles, expectedIDs: model.screenshots.map(\.id))
        preferences.screenExportLayout = .folders
        preferences.captureDefault = .all
        preferences.organisationDefault = .byScreen
        #expect(snapshot == expected)
        #expect(model.makeSelectionExportPlan() == .screenFolders([
            .init(screenName: "Profil", sourceURLs: newFiles)
        ]))
        #expect(model.showsUniqueScreens && model.groupsTimelineByScreen)
    }

    private func makePreferences() -> (AppPreferences, UserDefaults, String) {
        let suite = "Stillset-ExportSettingsTests-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        return (AppPreferences(defaults: defaults), defaults, suite)
    }

    private func populate(_ model: AppModel, labels: [(Int, String, Int)?]) {
        model.screenshots = labels.indices.map { index in
            CapturedScreenshot(state: UIState(interval: Double(index)..<Double(index + 1),
                representativeTimestamp: Double(index), stabilityScore: 1),
                fileURL: URL(fileURLWithPath: "/tmp/export-settings-\(index).png"))
        }
        model.screenClassifications = Dictionary(uniqueKeysWithValues: labels.enumerated().compactMap { index, label in
            label.map { (model.screenshots[index].id, ScreenClassification(screenID: $0.0, name: $0.1, stateID: $0.2)) }
        })
    }
}
