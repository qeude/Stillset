import AppKit
import StillsetCore
import Testing
@testable import StillsetFeatures

@MainActor
struct SelectionOrderTests {
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

    private func makeModel() -> (AppModel, [UUID]) {
        let model = AppModel()
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
