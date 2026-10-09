import AppKit
import SwiftUI

@MainActor
final class TimelineKeyboardTarget {
    weak var view: TimelineKeyboardView?
    private(set) var heldSource: TimelineDragSourceView?

    func activate(in expectedWindow: NSWindow? = nil) -> Bool {
        guard let view, let window = view.window,
              expectedWindow == nil || expectedWindow === window else { return false }
        return window.makeFirstResponder(view)
    }

    func beganDrag(_ source: TimelineDragSourceView) {
        if heldSource !== source { heldSource?.finishDrag() }
        heldSource = source
        processingSignposter.emitEvent("TimelineHeldSourceBegin")
    }

    func endedDrag(_ source: TimelineDragSourceView) {
        guard heldSource === source else { return }
        heldSource = nil
        processingSignposter.emitEvent("TimelineHeldSourceEnd")
    }

    func unregister(_ bridge: TimelineKeyboardView) {
        guard view === bridge else { return }
        if bridge.window?.firstResponder === bridge { bridge.window?.makeFirstResponder(nil) }
        heldSource?.finishDrag()
        view = nil
        bridge.onArrow = nil
    }
}

struct TimelineKeyboardBridge: NSViewRepresentable {
    let target: TimelineKeyboardTarget
    let onArrow: @MainActor (Int, NSEvent.ModifierFlags) -> Void

    func makeNSView(context: Context) -> TimelineKeyboardView {
        let view = TimelineKeyboardView()
        view.onArrow = onArrow
        view.target = target
        target.view = view
        view.setAccessibilityElement(false)
        return view
    }

    func updateNSView(_ view: TimelineKeyboardView, context: Context) {
        view.onArrow = onArrow
    }

    static func dismantleNSView(_ view: TimelineKeyboardView, coordinator: ()) {
        view.target?.unregister(view)
    }
}

final class TimelineKeyboardView: NSView {
    weak var target: TimelineKeyboardTarget?
    var onArrow: (@MainActor (Int, NSEvent.ModifierFlags) -> Void)?
    override var acceptsFirstResponder: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func keyDown(with event: NSEvent) {
        guard !event.modifierFlags.contains(.control), !event.modifierFlags.contains(.option),
              let onArrow, event.keyCode == 123 || event.keyCode == 124 else {
            super.keyDown(with: event)
            return
        }
        onArrow(event.keyCode == 123 ? -1 : 1, event.modifierFlags)
    }
}
