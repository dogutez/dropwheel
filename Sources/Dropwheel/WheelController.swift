import AppKit
import OSLog
import DropwheelCore

/// Shows the wheel next to the cursor, tracks the pointer, and runs the chosen action.
final class WheelController {
    let model = WheelModel()
    /// Editor tools (Crop, Add BG, …): the wheel closes and an editor window opens instead.
    var onEdit: (Tool, URL) -> Void = { _, _ in }
    /// The ⌃ ring: AirDrop, Float, Copy, …
    var onFileAction: (FileAction, [URL]) -> Void = { _, _ in }
    private let access: FolderAccess
    private let dropView = DropTargetView()
    private lazy var panel = WheelPanel(model: model, dropView: dropView)
    private let log = Logger(subsystem: "io.github.dogutez.dropwheel", category: "wheel")

    /// Bumped each time the wheel opens; stale async work checks it before touching the UI.
    private var session = 0
    private var dwellStart: Date?
    private var dwellConsumed = false
    private var currentJob: Task<Void, Never>?

    var isVisible: Bool { panel.isVisible }

    init(access: FolderAccess) {
        self.access = access
        dropView.geometry = { [unowned self] in geometry }
        dropView.onHover = { [unowned self] hit in
            if model.phase == .choosing { model.hovered = hit }
        }
        dropView.onDrop = { [unowned self] index, urls in drop(index: index, urls: urls) }
    }

    private var geometry: WheelGeometry {
        let side = panel.frame.width
        return WheelGeometry(center: CGPoint(x: side / 2, y: side / 2),
                             innerRadius: WheelModel.innerRadius, outerRadius: WheelModel.outerRadius,
                             count: model.items.count)
    }

    func show(for files: [URL], ring: WheelModel.Ring) {
        session += 1
        dwellStart = nil
        dwellConsumed = false
        model.configure(files: files, ring: ring)

        panel.setFrameOrigin(origin(near: NSEvent.mouseLocation))
        panel.ignoresMouseEvents = false
        panel.orderFrontRegardless()
        model.isPresented = true
    }

    /// Beside the cursor rather than under it, so dropping somewhere else still works.
    private func origin(near mouse: NSPoint) -> NSPoint {
        let side = panel.frame.width
        let offset = WheelModel.outerRadius + 40
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        var center = NSPoint(x: mouse.x + offset, y: mouse.y)
        if center.x + side / 2 > visible.maxX { center.x = mouse.x - offset }
        center.x = min(max(center.x, visible.minX + side / 2), visible.maxX - side / 2)
        center.y = min(max(center.y, visible.minY + side / 2), visible.maxY - side / 2)
        return NSPoint(x: center.x - side / 2, y: center.y - side / 2)
    }

    /// Called ~30×/s during the drag. Hovering the centre for a moment also flips rings.
    func trackPointer() {
        guard model.phase == .choosing else { return }
        let point = NSEvent.mouseLocation
        let local = CGPoint(x: point.x - panel.frame.minX, y: point.y - panel.frame.minY)
        let hit = geometry.hit(local)
        model.hovered = hit
        guard hit == .center, model.availableRings.count > 1 else {
            dwellStart = nil
            dwellConsumed = false
            return
        }
        guard !dwellConsumed else { return }
        if let start = dwellStart {
            if Date().timeIntervalSince(start) > 0.6 {
                model.cycleRing()
                model.hovered = .center
                dwellConsumed = true
            }
        } else {
            dwellStart = Date()
        }
    }

    /// The mouse button went up. If it wasn't a drop on the wheel, fade away.
    func dragEnded() {
        let token = session
        Task {
            // The drop callback can arrive a moment after the button is released.
            try? await Task.sleep(for: .milliseconds(250))
            if token == session, model.phase == .choosing { hide() }
        }
    }

    func hide() {
        model.isPresented = false
        let token = session
        Task {
            try? await Task.sleep(for: .milliseconds(220))
            if token == session, !model.isPresented { panel.orderOut(nil) }
        }
    }

    private func drop(index: Int, urls: [URL]) -> Bool {
        guard model.phase == .choosing, model.items.indices.contains(index) else { return false }
        let item = model.items[index]
        switch item.command {
        case .file(let action):
            hide()
            // Act after the drop has finished, so Finder isn't left waiting on us.
            Task { onFileAction(action, urls) }
            return true
        case .run(let action):
            let files = action == .tool(.merge)
                ? urls.filter { [.pdf, .image].contains(FileKind(url: $0)) }
                : urls.filter { FileKind(url: $0) == model.kind }
            guard !files.isEmpty else { return false }
            if case .tool(let tool) = action, tool.isInteractive {
                hide()
                Task { onEdit(tool, files[0]) }
                return true
            }
            run(action, on: files)
            return true
        }
    }

    private func run(_ action: Action, on files: [URL]) {
        let token = session
        model.hovered = .outside
        model.phase = .working(action.title)
        model.progress = nil
        // While working, a click on the bubble cancels.
        dropView.onCenterClick = { [unowned self] in currentJob?.cancel() }
        panel.ignoresMouseEvents = false

        currentJob = Task {
            // Not allowed to write next to the file yet: ask once, with the wheel out of the way.
            if let existing = access.grant(for: files[0]) {
                existing.release()
            } else {
                panel.orderOut(nil)
                access.grantOrAsk(for: files[0])?.release()
                guard token == session else { return }
                panel.orderFrontRegardless()
            }
            var outputs: [URL] = []
            var failure: String?
            // Merge is one job over all files; everything else runs file by file.
            let jobs: [(source: URL, run: (URL) async throws -> [URL])] = action == .tool(.merge)
                ? [(files[0], { [try await Converter().merge(files, into: $0)] })]
                : files.map { file in (file, { try await Converter().run(action, source: file, into: $0) }) }
            let total = Double(jobs.count)
            for (index, (file, job)) in jobs.enumerated() {
                guard !Task.isCancelled else { break }
                guard let grant = access.grant(for: file) else {
                    failure = FolderAccess.notAllowedMessage(for: file)
                    continue
                }
                defer { grant.release() }
                // Overall progress across files; the engines report 0...1 for the current one.
                let report: @Sendable (Double) -> Void = { [model] fraction in
                    Task { @MainActor in
                        if token == self.session { model.progress = (Double(index) + fraction) / total }
                    }
                }
                do {
                    outputs += try await ConversionProgress.$handler.withValue(report) { try await job(grant.directory) }
                } catch is CancellationError {
                    break
                } catch {
                    // Cocoa error texts can contain file and folder names: keep them out of the log.
                    log.error("Conversion failed: \(error.localizedDescription, privacy: .private) [\((error as NSError).domain, privacy: .public) \((error as NSError).code, privacy: .public)]")
                    failure = error.localizedDescription
                }
            }
            dropView.onCenterClick = nil
            guard token == session else { return }
            if Task.isCancelled {
                model.phase = .cancelled
                try? await Task.sleep(for: .seconds(1.2))
                if token == session { hide() }
                return
            }
            if let failure, outputs.isEmpty {
                model.phase = .failed(failure)
                try? await Task.sleep(for: .seconds(4))
                if token == session { hide() }
                return
            }
            model.phase = .done(summary(action: action, sources: files, outputs: outputs))
            await offerResult(outputs, token: token)
        }
    }

    /// The finished bubble shows where the result went: click it to reveal the file in Finder,
    /// or drag it out. It stays while the pointer is on it, otherwise fades after a few seconds.
    private func offerResult(_ outputs: [URL], token: Int) async {
        dropView.results = outputs
        dropView.onCenterClick = { [unowned self] in
            NSWorkspace.shared.activateFileViewerSelecting(outputs)
            hide()
        }
        panel.ignoresMouseEvents = false
        let shown = Date()
        while token == session, model.isPresented {
            let elapsed = Date().timeIntervalSince(shown)
            let point = NSEvent.mouseLocation
            let local = CGPoint(x: point.x - panel.frame.minX, y: point.y - panel.frame.minY)
            let pointerOnBubble = geometry.hit(local) == .center
            if elapsed > 30 || (elapsed > 5 && !pointerOnBubble) { break }
            try? await Task.sleep(for: .milliseconds(250))
        }
        dropView.results = []
        dropView.onCenterClick = nil
        if token == session { hide() }
    }

    /// "Photo.png" + "on Desktop" (or a size change for Compress), so it's clear what appeared where.
    private func summary(action: Action, sources: [URL], outputs: [URL]) -> String {
        let folder = outputs.first.map { FileManager.default.displayName(atPath: $0.deletingLastPathComponent().path) } ?? ""
        let place = "in \(folder)"
        guard outputs.count == 1, sources.count == 1 else { return "\(outputs.count) files\n\(place)" }
        if case .tool(.compress) = action, let before = size(of: sources[0]), let after = size(of: outputs[0]) {
            return "\(format(before)) → \(format(after))\n\(place)"
        }
        return "\(outputs[0].lastPathComponent)\n\(place)"
    }

    private func size(of url: URL) -> Int64? {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
    }

    private func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
