import AppKit
import OSLog
import SwiftUI
import DropwheelCore

/// A borderless, non-activating floating panel: it never steals focus from the app the
/// drag started in, and it follows the user across Spaces and full-screen apps.
final class WheelPanel: NSPanel {
    init(model: WheelModel, dropView: DropTargetView) {
        let side = WheelModel.outerRadius * 2 + 60
        super.init(contentRect: NSRect(x: 0, y: 0, width: side, height: side),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        animationBehavior = .none

        let container = NSView(frame: NSRect(x: 0, y: 0, width: side, height: side))
        let host = NSHostingView(rootView: WheelView(model: model))
        host.frame = container.bounds
        host.autoresizingMask = [.width, .height]
        dropView.frame = container.bounds
        dropView.autoresizingMask = [.width, .height]
        container.addSubview(host)
        container.addSubview(dropView) // on top, so it is the drag destination
        contentView = container
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Transparent layer over the wheel that receives the dropped files, and afterwards lets you
/// click (reveal) or drag (take away) the result from the centre bubble.
final class DropTargetView: NSView, NSDraggingSource {
    var geometry: () -> WheelGeometry = { WheelGeometry(center: .zero, innerRadius: 0, outerRadius: 0, count: 0) }
    var onHover: (WheelGeometry.Hit) -> Void = { _ in }
    var onDrop: (Int, [URL]) -> Bool = { _, _ in false }
    /// Finished files that can be dragged out of the bubble.
    var results: [URL] = []
    /// What a click on the bubble does (cancel while working, reveal when done); nil = nothing.
    var onCenterClick: (() -> Void)?
    private var resultMouseDown: NSEvent?

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func hit(_ sender: any NSDraggingInfo) -> WheelGeometry.Hit {
        geometry().hit(convert(sender.draggingLocation, from: nil))
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        // Which operations each modifier leaves us (⌘ and ⌃ narrow the mask). Persisted, for support.
        Logger(subsystem: "io.github.dogutez.dropwheel", category: "drop").notice("Drag entered with source mask \(sender.draggingSourceOperationMask.rawValue, privacy: .public)")
        return draggingUpdated(sender)
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        let hit = hit(sender)
        onHover(hit)
        guard case .segment = hit else { return [] }
        return Self.operation(for: sender.draggingSourceOperationMask)
    }

    /// AppKit narrows the source mask by modifier (⌘ → generic, ⌃ → link), so accept the
    /// first harmless one. Never .move or .delete: the original must stay where it is.
    static func operation(for mask: NSDragOperation) -> NSDragOperation {
        [.copy, .generic, .link].first { mask.contains($0) } ?? []
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        onHover(.outside)
    }

    // MARK: Result bubble

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // While choosing, behave like any view (drops depend on it). Once finished, only the
        // bubble takes clicks.
        guard onCenterClick != nil else { return super.hitTest(point) }
        return geometry().hit(convert(point, from: superview)) == .center ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        resultMouseDown = onCenterClick == nil ? nil : event
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = resultMouseDown, !results.isEmpty else { return }
        resultMouseDown = nil
        let icon = NSWorkspace.shared.icon(forFiles: results.map(\.path)) ?? NSWorkspace.shared.icon(for: .data)
        let origin = convert(start.locationInWindow, from: nil)
        let items = results.map { url in
            let item = NSDraggingItem(pasteboardWriter: url as NSURL)
            item.setDraggingFrame(NSRect(x: origin.x - 32, y: origin.y - 32, width: 64, height: 64), contents: icon)
            return item
        }
        beginDraggingSession(with: items, event: start, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        if resultMouseDown != nil { onCenterClick?() }
        resultMouseDown = nil
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard case .segment(let index) = hit(sender),
              let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
              !urls.isEmpty
        else { return false }
        return onDrop(index, urls)
    }
}
