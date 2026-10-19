import AppKit
import SwiftUI

/// The ⌃ ring. None of these write files: they hand the items to macOS (AirDrop, the
/// clipboard, Terminal) or hold them in a floating shelf to drag out later.
final class FileActions: NSObject, NSSharingServiceDelegate {
    private let access: FolderAccess
    private var shelves: [ShelfPanel] = []

    init(access: FolderAccess) {
        self.access = access
    }

    func perform(_ action: FileAction, on urls: [URL]) {
        switch action {
        case .airDrop:
            guard let service = NSSharingService(named: .sendViaAirDrop), service.canPerform(withItems: urls) else {
                alert("AirDrop isn't available", "Turn on Wi-Fi and Bluetooth, then try again.")
                return
            }
            NSApp.activate()
            service.delegate = self
            service.perform(withItems: urls)
        case .float:
            let shelf = ShelfPanel(urls: urls, at: NSEvent.mouseLocation) { [weak self] shelf in
                self?.shelves.removeAll { $0 === shelf }
            }
            shelves.append(shelf)
            shelf.orderFrontRegardless()
        case .copy:
            // Paste in Finder to get a copy of the files, or into a mail/chat to attach them.
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects(urls.map { $0 as NSURL })
        case .copyPath:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(urls.map(\.path).joined(separator: "\n"), forType: .string)
        case .terminal:
            let folder = urls[0].hasDirectoryPath ? urls[0] : urls[0].deletingLastPathComponent()
            guard let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else { return }
            // A dropped file's folder is only reachable inside an allowed folder; hold that access
            // until Terminal has received it.
            let grant = urls[0].hasDirectoryPath ? nil : access.grant(for: urls[0])
            NSWorkspace.shared.open([folder], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration()) { _, error in
                Task { @MainActor [weak self] in
                    grant?.release()
                    guard let error else { return }
                    self?.alert("Couldn't open Terminal there",
                                "\(error.localizedDescription)\n\nIf the file is outside the folders Dropwheel may use, choose “Allow a Folder…” in the menu bar, or drop the folder itself.")
                }
            }
        }
    }

    func sharingService(_ sharingService: NSSharingService, didFailToShareItems items: [Any], error: any Error) {
        // Cancelling the AirDrop sheet also lands here; only report real failures.
        guard (error as NSError).code != NSUserCancelledError else { return }
        alert("AirDrop failed", error.localizedDescription)
    }

    private func alert(_ title: String, _ message: String) {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }
}

/// A small always-on-top card holding files; drag them out of it whenever you are ready.
final class ShelfPanel: NSPanel {
    private let onClose: (ShelfPanel) -> Void

    init(urls: [URL], at point: NSPoint, onClose: @escaping (ShelfPanel) -> Void) {
        self.onClose = onClose
        let size = NSSize(width: 132, height: 150)
        super.init(contentRect: NSRect(x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width, height: size.height),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .floating
        isMovableByWindowBackground = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isReleasedWhenClosed = false

        let effect = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        effect.material = .hudWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 18
        effect.layer?.masksToBounds = true
        let source = ShelfDragView(urls: urls)
        source.frame = effect.bounds
        source.autoresizingMask = [.width, .height]
        effect.addSubview(source)
        let close = NSButton(image: NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Close")!, target: self, action: #selector(closeShelf))
        close.isBordered = false
        close.contentTintColor = .secondaryLabelColor
        close.frame = NSRect(x: 8, y: size.height - 26, width: 18, height: 18)
        effect.addSubview(close)
        contentView = effect
    }

    override var canBecomeKey: Bool { false }

    @objc private func closeShelf() {
        orderOut(nil)
        onClose(self)
    }
}

/// Shows the file icon and name; dragging it hands the files to wherever they're dropped.
private final class ShelfDragView: NSView, NSDraggingSource {
    private let urls: [URL]
    private let icon: NSImage
    private var mouseDownEvent: NSEvent?

    init(urls: [URL]) {
        self.urls = urls
        icon = NSWorkspace.shared.icon(forFiles: urls.map(\.path)) ?? NSWorkspace.shared.icon(for: .data)
        super.init(frame: .zero)
        let image = NSImageView(image: icon)
        image.frame = NSRect(x: 34, y: 52, width: 64, height: 64)
        image.autoresizingMask = [.minXMargin, .maxXMargin]
        addSubview(image)
        let label = NSTextField(labelWithString: urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) items")
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.alignment = .center
        label.lineBreakMode = .byTruncatingMiddle
        label.frame = NSRect(x: 8, y: 22, width: 116, height: 16)
        addSubview(label)
        let hint = NSTextField(labelWithString: "Drag out")
        hint.font = .systemFont(ofSize: 9.5)
        hint.textColor = .secondaryLabelColor
        hint.alignment = .center
        hint.frame = NSRect(x: 8, y: 7, width: 116, height: 13)
        addSubview(hint)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    // Claim the mouse so a drag starts here instead of moving the panel.
    override var mouseDownCanMoveWindow: Bool { false }

    override func mouseDown(with event: NSEvent) {
        mouseDownEvent = event
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = mouseDownEvent else { return }
        mouseDownEvent = nil
        // The top strip moves the shelf; anywhere else drags the files out.
        if convert(start.locationInWindow, from: nil).y > bounds.height - 30 {
            window?.performDrag(with: start)
            return
        }
        let items = urls.enumerated().map { index, url in
            let item = NSDraggingItem(pasteboardWriter: url as NSURL)
            let frame = NSRect(x: 34 + index * 4, y: 52 - index * 4, width: 64, height: 64)
            item.setDraggingFrame(frame, contents: icon)
            return item
        }
        beginDraggingSession(with: items, event: start, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        // Copy only: the shelf never moves the original out from under the user.
        .copy
    }
}
