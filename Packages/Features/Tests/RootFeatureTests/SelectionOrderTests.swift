import AppKit
import StillsetCore
import Testing
@testable import StillsetFeatures

@MainActor
struct SelectionOrderTests {
    @Test func groupingRetainsVisitsAndUsesVisualOrderForNavigationAndRanges() {
        let (model, ids) = makeModel()
        model.screenshots = Array(model.screenshots.prefix(5))
        let screenIDs = [2, 1, 2, 1]
        model.screenClassifications = Dictionary(uniqueKeysWithValues: screenIDs.enumerated().map { index, screenID in
            (ids[index], ScreenClassification(screenID: screenID, name: "Écran \(screenID)", stateID: index + 1))
        })
        model.setUniqueScreens(false)
        model.selectScreenshot(ids[0], modifiers: [])
        model.selectScreenshot(ids[1], modifiers: [.command])
        model.setTimelineGrouping(true)
        #expect(model.timelineScreenGroups.map(\.id) == [2, 1, nil])
        #expect(model.timelineScreenGroups.last?.name == "À identifier")
        #expect(model.visibleScreenshots.map(\.id) == [ids[0], ids[2], ids[1], ids[3], ids[4]])
        #expect(model.selectedScreenshotIDs == [ids[0], ids[1]])
        model.selectScreenshot(ids[0], modifiers: [])
        model.moveFocus(by: 1)
        #expect(model.focusedScreenshotID == ids[2])
        model.selectScreenshot(ids[3], modifiers: [.shift])
        #expect(model.selectedScreenshotIDs == [ids[2], ids[1], ids[3]])
        model.selectAll()
        #expect(model.selectedScreenshotIDs == Set(ids.prefix(5)))
        model.setTimelineGrouping(false)
        #expect(model.visibleScreenshots.map(\.id) == Array(ids.prefix(5)))
        #expect(model.screenshots.count == 5 && model.selectedScreenshotIDs.count == 5)
    }

    @Test func groupingKeepsDistinctStatesAndUpdatesAfterRefinement() {
        let (model, ids) = makeModel()
        model.screenshots = Array(model.screenshots.prefix(4))
        let labels = [
            ScreenClassification(screenID: 1, name: "Compte", stateID: 1),
            ScreenClassification(screenID: 2, name: "Accueil", stateID: 2),
            ScreenClassification(screenID: 1, name: "Compte", stateID: 3),
            ScreenClassification(screenID: 1, name: "Compte", stateID: 1)
        ]
        model.screenClassifications = Dictionary(uniqueKeysWithValues: zip(ids, labels))
        model.setTimelineGrouping(true)
        #expect(model.visibleScreenshots.map(\.id) == [ids[0], ids[2], ids[1]])
        model.setUniqueScreens(false)
        #expect(model.visibleScreenshots.map(\.id) == [ids[0], ids[2], ids[3], ids[1]])
        model.selectScreenshot(ids[2], modifiers: [])
        let refined = labels.map { ScreenClassification(screenID: 3, name: "Profil", stateID: $0.stateID) }
        model.applyRefinement(classifications: refined, files: model.screenshots.map(\.fileURL),
                              expectedIDs: Array(ids.prefix(4)))
        #expect(model.timelineScreenGroups.count == 1)
        #expect(model.timelineScreenGroups.first?.name == "Profil")
        #expect(model.selectedScreenshotIDs == [ids[2]])
        #expect(model.groupsTimelineByScreen && model.screenshots.count == 4)
    }

    @Test func refinementKeepsResultsUsableAndIgnoresAnOlderImport() {
        let (model, ids) = makeModel()
        model.selectScreenshot(ids[0], modifiers: [])
        model.refinementDetail = "Affinage IA"
        #expect(model.canSaveSelection && !model.isWorking)
        let files = model.screenshots.map(\.fileURL)
        let labels = ids.map { _ in ScreenClassification(screenID: 1, name: "Compte", stateID: 1) }
        model.applyRefinement(classifications: labels, files: files, expectedIDs: [UUID()])
        #expect(model.screenClassifications.isEmpty)
        model.applyRefinement(classifications: labels, files: [], expectedIDs: ids)
        #expect(model.screenshots.count == ids.count && model.screenClassifications.isEmpty)
        model.applyRefinement(classifications: labels, files: files, expectedIDs: ids)
        #expect(model.screenshots.map(\.id) == ids && model.visibleScreenshots.count == 1)
        #expect(model.selectedScreenshotIDs == [ids[0]])
        model.cancelRefinement()
        #expect(model.refinementDetail == nil && model.canSaveSelection)
    }

    @Test func uniqueScreenFilterKeepsOccurrencesAndRestrictsSelectionAndDragging() {
        let (model, ids) = makeModel()
        model.screenClassifications = Dictionary(uniqueKeysWithValues: ids.enumerated().map { index, id in
            (id, ScreenClassification(screenID: 1, name: "Compte", stateID: index == 1 ? 1 : index + 1))
        })
        #expect(model.showsUniqueScreens)
        model.setUniqueScreens(false)
        model.selectScreenshot(ids[1], modifiers: [])
        model.setUniqueScreens(true)
        #expect(model.screenshots.count == 10)
        #expect(model.visibleScreenshots.count == 9)
        #expect(model.focusedScreenshotID == ids[0])
        #expect(model.selectedScreenshotIDs.contains(ids[1]) == false)
        model.selectScreenshot(ids[2], modifiers: [.shift])
        #expect(model.selectedScreenshots.map(\.id) == [ids[0], ids[2]])
        #expect(model.dragURLs(startingAt: ids[0]).count == 2)
        model.selectAll()
        #expect(model.selectedScreenshots.count == 9)
        #expect(model.fanSelectedScreenshots.count == 9)
        model.moveFocus(by: 1)
        #expect(model.focusedScreenshotID == ids[2])
        model.setUniqueScreens(false)
        #expect(model.visibleScreenshots.map(\.id) == ids)
        model.selectAll()
        #expect(model.selectedScreenshots.count == 10)
    }

    @Test(arguments: [true, false])
    func groupSelectionReplacesSelectionWithCurrentVisibleStates(unique: Bool) {
        let (model, ids) = makeGroupedModel()
        let sourceIDs = model.screenshots.map(\.id)
        let sourceURLs = model.screenshots.map(\.fileURL)
        model.setUniqueScreens(unique)
        model.selectScreenshot(ids[7], modifiers: [])
        model.selectScreenshot(ids[1], modifiers: [.command])
        model.followsLatest = true
        model.notice = "Captures copiées"

        model.selectTimelineScreenGroup(2)

        let expected = unique ? [ids[0], ids[2], ids[6]] : [ids[0], ids[2], ids[4], ids[6]]
        #expect(model.selectedScreenshotIDs == Set(expected))
        #expect(model.fanSelectedScreenshots.map(\.id) == expected)
        #expect(model.focusedScreenshotID == ids[0])
        #expect(model.focusNavigationID == ids[0])
        #expect(!model.followsLatest && model.notice == nil)
        #expect(expected.map { model.fanSlot(for: $0) } == Array(0..<expected.count))
        #expect(model.screenshots.map(\.id) == sourceIDs)
        #expect(model.screenshots.map(\.fileURL) == sourceURLs)
        #expect(model.dragURLs(startingAt: ids[0]) == expected.map { sourceURLs[ids.firstIndex(of: $0)!] })

        model.selectTimelineScreenGroup(2)
        #expect(model.fanSelectedScreenshots.map(\.id) == expected)
        #expect(model.focusedScreenshotID == ids[0])
    }

    @Test func groupSelectionSetsRangeAnchorAndArrowNavigation() {
        let (model, ids) = makeGroupedModel()
        model.selectScreenshot(ids[3], modifiers: [])
        model.selectTimelineScreenGroup(2)
        model.selectScreenshot(ids[3], modifiers: [.shift])
        #expect(model.selectedScreenshotIDs == [ids[0], ids[2], ids[6], ids[1], ids[3]])
        #expect(model.focusedScreenshotID == ids[0])

        model.selectTimelineScreenGroup(2)
        model.moveFocus(by: 1)
        #expect(model.focusedScreenshotID == ids[2])
        #expect(model.focusNavigationID == ids[2])
        #expect(model.selectedScreenshotIDs == [ids[0], ids[2], ids[6]])
        model.selectScreenshot(ids[3], modifiers: [.shift])
        #expect(model.selectedScreenshotIDs == [ids[2], ids[6], ids[1], ids[3]])
        model.moveFocus(by: 1)
        #expect(model.focusedScreenshotID == ids[6])
    }

    @Test func groupSelectionIncludesVisibleUnclassifiedCaptures() {
        let (model, ids) = makeGroupedModel()
        model.selectTimelineScreenGroup(nil)
        #expect(model.selectedScreenshotIDs == [ids[5], ids[7]])
        #expect(model.fanSelectedScreenshots.map(\.id) == [ids[5], ids[7]])
        #expect(model.focusedScreenshotID == ids[5])
        #expect(model.focusNavigationID == ids[5])
        model.moveFocus(by: 1)
        #expect(model.focusedScreenshotID == ids[7])
        model.selectScreenshot(ids[3], modifiers: [.shift])
        #expect(model.selectedScreenshotIDs == [ids[3], ids[5], ids[7]])
    }

    @Test func groupSelectionResolvesMembershipAfterFilteringAndRefinement() throws {
        let (model, ids) = makeGroupedModel()
        model.setUniqueScreens(false)
        let staleGroup = try #require(model.timelineScreenGroups.first { $0.id == 2 })
        #expect(staleGroup.screenshots.map(\.id) == [ids[0], ids[2], ids[4], ids[6]])
        model.setUniqueScreens(true)
        model.selectTimelineScreenGroup(staleGroup.id)
        #expect(model.selectedScreenshotIDs == [ids[0], ids[2], ids[6]])

        let labels = [
            ScreenClassification(screenID: 3, name: "Profil renommé", stateID: 10),
            ScreenClassification(screenID: 1, name: "Accueil", stateID: 20),
            ScreenClassification(screenID: 2, name: "Compte renommé", stateID: 11),
            ScreenClassification(screenID: 1, name: "Accueil", stateID: 21),
            ScreenClassification(screenID: 3, name: "Profil renommé", stateID: 10),
            ScreenClassification(screenID: 4, name: "Confirmation", stateID: 30),
            ScreenClassification(screenID: 2, name: "Compte renommé", stateID: 12),
            ScreenClassification(screenID: 4, name: "Confirmation", stateID: 31)
        ]
        let refinedURLs = ids.enumerated().map { URL(fileURLWithPath: "/tmp/stillset-refined-\($0.offset).png") }
        model.applyRefinement(classifications: labels, files: refinedURLs, expectedIDs: ids)
        model.selectTimelineScreenGroup(staleGroup.id)
        #expect(model.selectedScreenshotIDs == [ids[2], ids[6]])
        #expect(model.focusedScreenshotID == ids[2])
        #expect(model.dragURLs(startingAt: ids[2]) == [refinedURLs[2], refinedURLs[6]])
        model.selectTimelineScreenGroup(3)
        #expect(model.selectedScreenshotIDs == [ids[0]])
        model.setUniqueScreens(false)
        model.selectTimelineScreenGroup(3)
        #expect(model.selectedScreenshotIDs == [ids[0], ids[4]])
    }

    @Test func groupSelectionRejectsAnalyzingUngroupedMissingAndEmptyGroups() {
        let (model, ids) = makeGroupedModel()
        model.selectScreenshot(ids[3], modifiers: [])
        model.setTimelineGrouping(false)
        model.followsLatest = true
        model.notice = "À conserver"
        model.selectTimelineScreenGroup(2)
        #expect(model.selectedScreenshotIDs == [ids[3]])
        #expect(model.followsLatest && model.notice == "À conserver")
        model.setTimelineGrouping(true)
        model.isAnalyzing = true
        model.followsLatest = true
        model.selectTimelineScreenGroup(2)
        #expect(model.selectedScreenshotIDs == [ids[3]])
        #expect(model.followsLatest && model.notice == "À conserver")
        model.isAnalyzing = false
        model.selectTimelineScreenGroup(99)
        #expect(model.selectedScreenshotIDs == [ids[3]])
        #expect(model.focusedScreenshotID == ids[3] && model.focusNavigationID == ids[3])
        #expect(model.followsLatest && model.notice == "À conserver")
        model.selectTimelineScreenGroup(2)
        #expect(model.selectedScreenshotIDs == [ids[0], ids[2], ids[6]])
        model.screenClassifications[ids[0]] = ScreenClassification(screenID: 1, name: "Accueil", stateID: 10)
        model.screenClassifications[ids[2]] = ScreenClassification(screenID: 1, name: "Accueil", stateID: 11)
        model.screenClassifications[ids[4]] = ScreenClassification(screenID: 1, name: "Accueil", stateID: 10)
        model.screenClassifications[ids[6]] = ScreenClassification(screenID: 1, name: "Accueil", stateID: 12)
        model.selectTimelineScreenGroup(2)
        #expect(model.selectedScreenshotIDs == [ids[0], ids[2], ids[6]])
        model.screenshots = []
        model.selectTimelineScreenGroup(nil)
        #expect(model.selectedScreenshotIDs == [ids[0], ids[2], ids[6]])
    }

    @Test func groupSelectionDragAndExportKeepSourceOrderAfterGroupedRanges() throws {
        let (model, ids) = makeGroupedModel()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let source = directory.appendingPathComponent("source", isDirectory: true)
        let output = directory.appendingPathComponent("output", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        model.screenshots = try model.screenshots.enumerated().map { index, screenshot in
            let url = source.appendingPathComponent("capture-\(index).png")
            try Data([UInt8(index)]).write(to: url)
            return CapturedScreenshot(state: screenshot.state, fileURL: url)
        }
        model.selectTimelineScreenGroup(2)
        model.selectScreenshot(ids[3], modifiers: [.shift])
        #expect(model.visibleScreenshots.map(\.id) == [ids[0], ids[2], ids[6], ids[1], ids[3], ids[5], ids[7]])
        #expect(model.fanSelectedScreenshots.map(\.id) == [ids[0], ids[2], ids[6], ids[1], ids[3]])
        #expect(model.selectedScreenshots.map(\.id) == [ids[0], ids[1], ids[2], ids[3], ids[6]])
        let files = model.dragURLs(startingAt: ids[2])
        #expect(files.map(\.lastPathComponent) == ["capture-0.png", "capture-1.png", "capture-2.png", "capture-3.png", "capture-6.png"])
        #expect(model.previewDragURLs == files)
        let copied = try ScreenshotExporter.copy(files: model.selectedScreenshots.map(\.fileURL), to: output)
        #expect(copied.map(\.lastPathComponent) == ["capture-0.png", "capture-1.png", "capture-2.png", "capture-3.png", "capture-6.png"])
        #expect(try copied.map { try Data(contentsOf: $0) } == [Data([0]), Data([1]), Data([2]), Data([3]), Data([6])])
    }

    @Test func fanClosesGapsWithoutChangingSidesOrRelativeOrder() {
        let (model, _) = makeModel()
        let cards = model.screenshots.dropFirst().prefix(8).enumerated().map { index, screenshot in
            FannedScreenshot(screenshot: screenshot, selectionSlot: index + 1)
        }
        let original = FannedScreenshot.arranged(cards)
        let remaining = cards.filter { $0.selectionSlot != 1 && $0.selectionSlot != 4 }
        let contracted = FannedScreenshot.arranged(remaining)

        #expect(contracted.map(\.selectionSlot) == [2, 3, 5, 6, 7, 8])
        #expect(contracted.map(\.position) == [2, 1, 3, 4, 5, 6])
        #expect(contracted.map(\.isOnLeft) == remaining.map(\.isOnLeft))
        #expect(contracted.last?.depth == 2)
        let restored = FannedScreenshot.arranged(Array(cards.reversed()))
        #expect(restored.map(\.id) == original.map(\.id))
        #expect(restored.map(\.position) == original.map(\.position))
        let oneSide = cards.enumerated().map { index, card in
            FannedScreenshot(screenshot: card.screenshot, selectionSlot: index * 2 + 1)
        }
        let crowded = FannedScreenshot.arranged(oneSide)
        #expect(crowded.last?.depth == 3)
        #expect(Set(crowded.map(\.depth)).count == oneSide.count)
        #expect(FannedScreenshot.arranged([]).isEmpty)
    }

    @Test func reselectionRestoresFanPositionAndDepthAfterOtherSelections() {
        let (model, ids) = makeModel()
        model.selectScreenshot(ids[0], modifiers: [])
        for id in ids.dropFirst().prefix(8) {
            model.selectScreenshot(id, modifiers: [.command])
        }
        let original = model.fanSelectedScreenshots.map {
            FannedScreenshot(screenshot: $0, selectionSlot: model.fanSlot(for: $0.id))
        }
        for index in [2, 4, 6, 8] {
            model.selectScreenshot(ids[index], modifiers: [.command])
        }
        model.selectScreenshot(ids[9], modifiers: [.command])
        for index in [8, 6, 4, 2] {
            model.selectScreenshot(ids[index], modifiers: [.command])
        }
        #expect(model.fanSelectedScreenshots.map(\.id) == ids)
        for card in original {
            let restored = FannedScreenshot(screenshot: card.screenshot, selectionSlot: model.fanSlot(for: card.id))
            #expect(restored.isOnLeft == card.isOnLeft)
            #expect(restored.selectionSlot == card.selectionSlot)
        }
    }

    @Test func fanFollowsClickOrderAndReselectionRestoresOriginalOrder() {
        let (model, ids) = makeModel()

        model.selectScreenshot(ids[7], modifiers: [])
        model.selectScreenshot(ids[2], modifiers: [.command])
        model.selectScreenshot(ids[9], modifiers: [.command])
        #expect(model.fanSelectedScreenshots.map(\.id) == [ids[7], ids[2], ids[9]])
        #expect(model.selectedScreenshots.map(\.id) == [ids[2], ids[7], ids[9]])

        model.selectScreenshot(ids[2], modifiers: [.command])
        model.selectScreenshot(ids[2], modifiers: [.command])
        #expect(model.fanSelectedScreenshots.map(\.id) == [ids[7], ids[2], ids[9]])
    }

    @Test func rangeSelectionKeepsTheDirectionOfTheGesture() {
        let (model, ids) = makeModel()

        model.selectScreenshot(ids[5], modifiers: [])
        model.selectScreenshot(ids[2], modifiers: [.shift])

        #expect(model.fanSelectedScreenshots.map(\.id) == [ids[5], ids[4], ids[3], ids[2]])
    }

    @Test func addingAndRemovingCardsKeepsTheCenterAndExistingPositions() {
        let (model, ids) = makeModel()

        model.selectScreenshot(ids[7], modifiers: [])
        model.selectScreenshot(ids[2], modifiers: [.command])
        let secondSlot = model.fanSlot(for: ids[2])
        model.selectScreenshot(ids[9], modifiers: [.command])
        let thirdSlot = model.fanSlot(for: ids[9])

        #expect(model.focusedScreenshotID == ids[7])
        #expect(model.fanSlot(for: ids[2]) == secondSlot)

        model.selectScreenshot(ids[2], modifiers: [.command])
        model.selectScreenshot(ids[4], modifiers: [.command])

        #expect(model.focusedScreenshotID == ids[7])
        #expect(model.fanSlot(for: ids[9]) == thirdSlot)
        #expect(model.fanSlot(for: ids[4]) > thirdSlot)

        model.selectScreenshot(ids[2], modifiers: [.command])
        #expect(model.fanSlot(for: ids[2]) == secondSlot)
    }

    @Test func aNewCardDoesNotTakeThePlaceOfADeselectedCard() {
        let (model, ids) = makeModel()

        model.selectScreenshot(ids[7], modifiers: [])
        model.selectScreenshot(ids[2], modifiers: [.command])
        let firstSideSlot = model.fanSlot(for: ids[2])
        model.selectScreenshot(ids[2], modifiers: [.command])
        model.selectScreenshot(ids[4], modifiers: [.command])

        #expect(model.fanSlot(for: ids[4]) > firstSideSlot)
    }

    private func makeGroupedModel() -> (AppModel, [UUID]) {
        let (model, allIDs) = makeModel()
        let ids = Array(allIDs.prefix(8))
        model.screenshots = Array(model.screenshots.prefix(8))
        let labels = [
            (0, 2, 10), (1, 1, 20), (2, 2, 11), (3, 1, 21), (4, 2, 10), (6, 2, 12)
        ]
        model.screenClassifications = Dictionary(uniqueKeysWithValues: labels.map { index, screenID, stateID in
            (ids[index], ScreenClassification(screenID: screenID, name: "Écran \(screenID)", stateID: stateID))
        })
        model.setTimelineGrouping(true)
        return (model, ids)
    }

    private func makeModel() -> (AppModel, [UUID]) {
        let suite = "Stillset-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(preferences: AppPreferences(defaults: defaults))
        let ids = (0..<10).map { _ in UUID() }
        model.screenshots = ids.enumerated().map { index, id in
            CapturedScreenshot(
                state: UIState(
                    id: id,
                    interval: Double(index)..<Double(index + 1),
                    representativeTimestamp: Double(index),
                    stabilityScore: 1
                ),
                fileURL: URL(fileURLWithPath: "/tmp/stillset-\(index).png")
            )
        }
        return (model, ids)
    }
}
