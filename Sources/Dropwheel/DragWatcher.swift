import AppKit

/// Notices "a file is being dragged and ⇧, ⌘ or ⌃ is held" anywhere on screen.
///
/// Needs no Accessibility or Input Monitoring permission: it only listens for global
/// *mouse* events and reads `NSEvent.modifierFlags` / `pressedMouseButtons`, which are
/// public state. It never sees keystrokes, and it only reads the drag pasteboard (never
/// the clipboard), only for file URLs, and only while a modifier is down mid-drag.
final class DragWatcher {
    var isEnabled = true
    var isWheelVisible: () -> Bool = { false }
    var onModifierDrag: ([URL], WheelModel.Ring) -> Void = { _, _ in }
    var onRingChange: (WheelModel.Ring) -> Void = { _ in }
    var onTick: () -> Void = {}
    var onRelease: () -> Void = {}

    private var monitors: [Any] = []
    private var timer: Timer?
    private var baseline = NSPasteboard(name: .drag).changeCount
    private var lastRing: WheelModel.Ring?

    func start() {
        let down = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            MainActor.assumeIsolated { self?.mouseDown() }
        }
        let dragged = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDragged) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        monitors = [down, dragged].compactMap { $0 }
    }

    private func mouseDown() {
        baseline = NSPasteboard(name: .drag).changeCount
        lastRing = WheelModel.Ring(modifiers: NSEvent.modifierFlags)
        guard timer == nil else { return }
        // Polls only while the button is held, so a stationary cursor + Shift still works.
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = 0.005
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        guard NSEvent.pressedMouseButtons & 1 != 0 else {
            timer?.invalidate()
            timer = nil
            lastRing = nil
            onRelease()
            return
        }
        let ring = WheelModel.Ring(modifiers: NSEvent.modifierFlags)
        if isWheelVisible() {
            // Pressing another modifier switches rings; letting go keeps the current one.
            if let ring, ring != lastRing { onRingChange(ring) }
            onTick()
        } else if let ring, isEnabled, let files = draggedFiles() {
            onModifierDrag(files, ring)
        }
        lastRing = ring
    }

    /// File URLs on the drag pasteboard, if a new file drag started since mouse-down.
    private func draggedFiles() -> [URL]? {
        let pasteboard = NSPasteboard(name: .drag)
        guard pasteboard.changeCount != baseline,
              let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
              !urls.isEmpty
        else { return nil }
        return urls
    }
}
