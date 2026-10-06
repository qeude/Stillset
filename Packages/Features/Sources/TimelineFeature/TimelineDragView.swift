import AppKit
import ImageIO
import SwiftUI

struct TimelineDragView: NSViewRepresentable {
    let fileURLs: [URL]
    let accessibilityText: String
    let onClick: (@MainActor (NSEvent.ModifierFlags) -> Void)?
    let onArrow: @MainActor (Int) -> Void

    func makeNSView(context: Context) -> TimelineDragSourceView {
        let view = TimelineDragSourceView()
        view.fileURLs = fileURLs
        view.onClick = onClick
        view.onArrow = onArrow
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.button)
        view.setAccessibilityLabel(accessibilityText)
        view.toolTip = onClick == nil ? accessibilityText : "\(accessibilityText) · ⌘ clic : sélection · ⇧ clic : plage"
        return view
    }

    func updateNSView(_ view: TimelineDragSourceView, context: Context) {
        view.fileURLs = fileURLs
        view.onClick = onClick
        view.onArrow = onArrow
        view.setAccessibilityLabel(accessibilityText)
        view.toolTip = onClick == nil ? accessibilityText : "\(accessibilityText) · ⌘ clic : sélection · ⇧ clic : plage"
    }
}

final class TimelineDragSourceView: NSView, NSDraggingSource {
    var fileURLs: [URL] = []
    var onClick: (@MainActor (NSEvent.ModifierFlags) -> Void)?
    var onArrow: (@MainActor (Int) -> Void)?
    private var mouseDownEvent: NSEvent?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        mouseDownEvent = event
    }

    override func mouseUp(with event: NSEvent) {
        guard mouseDownEvent != nil else { return }
        mouseDownEvent = nil
        onClick?(event.modifierFlags)
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 123: onArrow?(-1)
        case 124: onArrow?(1)
        default: super.keyDown(with: event)
        }
    }

    override func accessibilityPerformPress() -> Bool {
        onClick?([])
        return true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let mouseDownEvent, !fileURLs.isEmpty else { return }
        self.mouseDownEvent = nil

        let point = convert(mouseDownEvent.locationInWindow, from: nil)
        let items = fileURLs.enumerated().map { index, url in
            let item = NSDraggingItem(pasteboardWriter: url as NSURL)
            let image = dragImage(for: url)
            let scale = min(110 / image.size.width, 110 / image.size.height)
            let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
            let offset = CGFloat(min(index, 6)) * 4
            item.setDraggingFrame(
                NSRect(x: point.x - size.width / 2 + offset, y: point.y - size.height / 2 + offset,
                       width: size.width, height: size.height),
                contents: image
            )
            return item
        }
        let session = beginDraggingSession(with: items, event: mouseDownEvent, source: self)
        session.draggingFormation = .stack
    }

    private func dragImage(for url: URL) -> NSImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceThumbnailMaxPixelSize: 240
              ] as CFDictionary) else {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return NSImage(cgImage: thumbnail, size: NSSize(width: thumbnail.width, height: thumbnail.height))
    }

    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        .copy
    }
}
