import AppKit
import SwiftUI

struct TimelineDragView: NSViewRepresentable {
    @Environment(\.thumbnailLoader) private var thumbnailLoader
    let urlsForDrag: @MainActor () -> [URL]
    let accessibilityText: String
    var accessibilityHint = String(localized: "⌘ click: select · ⇧ click: range", bundle: .module)
    let onClick: (@MainActor (NSEvent.ModifierFlags) -> Void)?
    let keyboardTarget: TimelineKeyboardTarget

    func makeNSView(context: Context) -> TimelineDragSourceView {
        let view = TimelineDragSourceView()
        configure(view)
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.button)
        return view
    }

    func updateNSView(_ view: TimelineDragSourceView, context: Context) { configure(view) }

    private func configure(_ view: TimelineDragSourceView) {
        view.urlsForDrag = urlsForDrag
        view.onClick = onClick
        view.keyboardTarget = keyboardTarget
        view.cachedDragImage = { [weak thumbnailLoader] url in
            guard let image = thumbnailLoader?.cachedImage(for: url) else { return nil }
            return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        }
        view.setAccessibilityLabel(accessibilityText)
        view.setAccessibilityHelp(accessibilityHint)
        view.toolTip = accessibilityText + (accessibilityHint.isEmpty ? "" : " · \(accessibilityHint)")
    }

    static func dismantleNSView(_ view: TimelineDragSourceView, coordinator: ()) {
        view.detach()
    }
}

final class TimelineDragSourceView: NSView, NSDraggingSource {
    private(set) static var liveCount = 0
    private(set) static var attachedCount = 0
    private var wasAttached = false
    var urlsForDrag: (@MainActor () -> [URL])?
    var onClick: (@MainActor (NSEvent.ModifierFlags) -> Void)?
    weak var keyboardTarget: TimelineKeyboardTarget?
    var cachedDragImage: (@MainActor (URL) -> NSImage?)?
    private var mouseDownEvent: NSEvent?
    private(set) var frozenDragURLs: [URL] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        Self.liveCount += 1
        processingSignposter.emitEvent("TimelineOverlayCreate")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    isolated deinit {
        Self.liveCount -= 1
        if wasAttached { Self.attachedCount -= 1 }
        processingSignposter.emitEvent("TimelineOverlayRelease")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        let attached = window != nil
        if attached != wasAttached {
            Self.attachedCount += attached ? 1 : -1
            wasAttached = attached
        }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    @discardableResult
    func activateKeyboard() -> Bool {
        guard let window else { return false }
        return keyboardTarget?.activate(in: window) ?? false
    }

    override func mouseDown(with event: NSEvent) {
        activateKeyboard()
        mouseDownEvent = event
    }

    override func mouseUp(with event: NSEvent) {
        guard mouseDownEvent != nil else { return }
        mouseDownEvent = nil
        onClick?(event.modifierFlags)
    }

    override func accessibilityPerformPress() -> Bool {
        guard let onClick else { return false }
        onClick([])
        return true
    }

    func prepareDrag() -> [URL] {
        frozenDragURLs = urlsForDrag?() ?? []
        if !frozenDragURLs.isEmpty { keyboardTarget?.beganDrag(self) }
        return frozenDragURLs
    }

    override func mouseDragged(with event: NSEvent) {
        guard let mouseDownEvent else { return }
        let urls = prepareDrag()
        guard !urls.isEmpty else { return }
        self.mouseDownEvent = nil
        let point = convert(mouseDownEvent.locationInWindow, from: nil)
        let items = urls.enumerated().map { index, url in
            let item = NSDraggingItem(pasteboardWriter: url as NSURL)
            let image = dragImage(for: url)
            let scale = min(110 / max(1, image.size.width), 110 / max(1, image.size.height))
            let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
            let offset = CGFloat(min(index, 6)) * 4
            item.setDraggingFrame(
                NSRect(x: point.x - size.width / 2 + offset, y: point.y - size.height / 2 + offset,
                       width: size.width, height: size.height), contents: image)
            return item
        }
        let session = beginDraggingSession(with: items, event: mouseDownEvent, source: self)
        session.draggingFormation = .stack
    }

    func finishDrag() {
        frozenDragURLs = []
        keyboardTarget?.endedDrag(self)
    }

    func detach() {
        mouseDownEvent = nil
        urlsForDrag = nil
        onClick = nil
        cachedDragImage = nil
        if frozenDragURLs.isEmpty { keyboardTarget?.endedDrag(self) }
    }

    private func dragImage(for url: URL) -> NSImage {
        cachedDragImage?(url) ?? NSWorkspace.shared.icon(forFile: url.path)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        finishDrag()
    }
}
