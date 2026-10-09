import AppKit
import Testing
@testable import StillsetFeatures

@MainActor
@Suite(.serialized)
struct TimelineKeyboardTests {
    @Test func headerMouseMovementKeepsItsClickWhenThereAreNoDragURLs() throws {
        let source = TimelineDragSourceView(frame: CGRect(x: 0, y: 0, width: 240, height: 32))
        source.urlsForDrag = { [] }
        var clicks = 0
        source.onClick = { _ in clicks += 1 }
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseDragged, .leftMouseUp] {
            let event = try #require(NSEvent.mouseEvent(with: type, location: CGPoint(x: 10, y: 10),
                modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                eventNumber: 0, clickCount: 1, pressure: 0))
            switch type {
            case .leftMouseDown: source.mouseDown(with: event)
            case .leftMouseDragged: source.mouseDragged(with: event)
            default: source.mouseUp(with: event)
            }
        }
        #expect(clicks == 1)
        #expect(source.frozenDragURLs.isEmpty)
    }

    @Test func disposableSourceRemovalKeepsActualResponderAndSelectionNavigation() throws {
        #expect(Thread.isMainThread)
        let model = RenderFixture.session()
        let ids = model.screenshots.map(\.id)
        let (window, target, owner) = harness(model)
        defer { target.unregister(owner); window.close() }
        let source = TimelineDragSourceView(frame: CGRect(x: 0, y: 0, width: 130, height: 150))
        source.keyboardTarget = target
        window.contentView?.addSubview(source)
        model.selectScreenshot(ids[0], modifiers: [])
        #expect(source.activateKeyboard())
        #expect(window.firstResponder === owner)
        owner.keyDown(with: try key(124, flags: .command))
        #expect(model.focusedScreenshotID == ids[4])
        source.removeFromSuperview()
        source.detach()
        #expect(window.firstResponder === owner)
        owner.keyDown(with: try key(123))
        #expect(model.focusedScreenshotID == ids[3])
        #expect(model.selectedScreenshotOrder == [ids[3]])
        owner.keyDown(with: try key(123, flags: [.shift, .command], repeated: true))
        #expect(model.focusedScreenshotID == ids[0])
        #expect(model.selectedScreenshotOrder == [ids[3], ids[2], ids[1], ids[0]])
        #expect(model.timelineRevealRequest?.target == ids[0])
    }

    @Test func mismatchDetachedAXAndTextControlDoNotAcquireOwner() {
        let model = RenderFixture.session()
        let (window, target, owner) = harness(model)
        let other = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        other.isReleasedWhenClosed = false
        defer { target.unregister(owner); window.close(); other.close() }
        let text = NSTextView(frame: CGRect(x: 0, y: 0, width: 200, height: 40))
        window.contentView?.addSubview(text)
        #expect(window.makeFirstResponder(text))
        owner.onArrow = { _, _ in Issue.record("Text input must stay with its owner") }
        #expect(window.firstResponder === text)
        #expect(!target.activate(in: other))
        #expect(window.firstResponder === text)
        let source = TimelineDragSourceView(frame: .zero)
        source.keyboardTarget = target
        source.onClick = { model.selectScreenshot(model.screenshots[1].id, modifiers: $0) }
        #expect(!source.activateKeyboard())
        window.contentView?.addSubview(source)
        #expect(source.accessibilityPerformPress())
        #expect(model.focusedScreenshotID == model.screenshots[1].id)
        #expect(window.firstResponder === text)
    }

    @Test func rejectedActivationReturnsWindowResultAndTeardownReleasesHold() {
        _ = NSApplication.shared
        let target = TimelineKeyboardTarget()
        let owner = TimelineKeyboardView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        owner.target = target
        target.view = owner
        let window = RejectingTimelineWindow(contentRect: CGRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView?.addSubview(owner)
        #expect(!target.activate(in: window))
        let source = TimelineDragSourceView(frame: .zero)
        source.keyboardTarget = target
        source.urlsForDrag = { [URL(fileURLWithPath: "/literal.png")] }
        #expect(source.prepareDrag().map(\.path) == ["/literal.png"])
        #expect(target.heldSource === source)
        target.unregister(owner)
        #expect(target.view == nil && target.heldSource == nil)
        #expect(source.frozenDragURLs.isEmpty)
        #expect(owner.onArrow == nil)
    }

    @Test func dragResolvesCurrentChronologyFreezesAndReleasesAcrossEviction() throws {
        let model = RenderFixture.session()
        let captures = model.imports.models[0].screenshots
        let ids = model.screenshots.map(\.id)
        model.selectScreenshot(ids[4], modifiers: [])
        model.selectScreenshot(ids[1], modifiers: .command)
        let target = TimelineKeyboardTarget()
        var source: TimelineDragSourceView? = TimelineDragSourceView(frame: .zero)
        weak var weakSource = source
        source?.keyboardTarget = target
        source?.urlsForDrag = { model.dragURLs(startingAt: ids[4]) }
        model.imports.models[0].screenshots = captures.enumerated().map { index, capture in
            CapturedScreenshot(replacingURL: URL(fileURLWithPath: "/renamed-\(index).png"), of: capture)
        }
        #expect(source?.prepareDrag().map(\.path) == ["/renamed-1.png", "/renamed-4.png"])
        model.imports.models[0].screenshots = captures
        #expect(source?.frozenDragURLs.map(\.path) == ["/renamed-1.png", "/renamed-4.png"])
        source?.detach()
        source = nil
        #expect(weakSource != nil && target.heldSource === weakSource)
        do {
            let retained = try #require(target.heldSource)
            retained.finishDrag()
            #expect(target.heldSource == nil && retained.frozenDragURLs.isEmpty)
        }
        #expect(weakSource == nil)
    }

    @Test func onlySupportedArrowsReachModelAndStaleDismantleCannotClearNewOwner() throws {
        let model = RenderFixture.session()
        let (window, target, owner) = harness(model)
        defer { target.unregister(owner); window.close() }
        let sink = TimelineKeySink()
        owner.nextResponder = sink
        let focus = model.focusedScreenshotID
        owner.keyDown(with: try key(123, flags: .option))
        owner.keyDown(with: try key(124, flags: .control))
        owner.keyDown(with: try key(53))
        #expect(sink.keys == [123, 124, 53])
        #expect(model.focusedScreenshotID == focus)
        let obsolete = TimelineKeyboardView(frame: .zero)
        target.unregister(obsolete)
        #expect(target.view === owner)
        #expect(target.activate(in: window))
        TimelineKeyboardBridge.dismantleNSView(owner, coordinator: ())
        #expect(target.view == nil)
        #expect(window.firstResponder !== owner)
    }

    private func harness(_ model: SessionModel) -> (NSWindow, TimelineKeyboardTarget, TimelineKeyboardView) {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let target = TimelineKeyboardTarget()
        let owner = TimelineKeyboardView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        owner.target = target
        owner.onArrow = { model.moveFocus(by: $0, modifiers: $1) }
        target.view = owner
        window.contentView?.addSubview(owner)
        return (window, target, owner)
    }

    private func key(_ code: UInt16, flags: NSEvent.ModifierFlags = [], repeated: Bool = false) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 1,
            windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: repeated, keyCode: code))
    }
}

@MainActor
private final class RejectingTimelineWindow: NSWindow {
    override func makeFirstResponder(_ responder: NSResponder?) -> Bool { false }
}

@MainActor
private final class TimelineKeySink: NSResponder {
    var keys: [UInt16] = []
    override func keyDown(with event: NSEvent) { keys.append(event.keyCode) }
}
