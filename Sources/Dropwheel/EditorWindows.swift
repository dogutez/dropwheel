import AppKit
import SwiftUI
import DropwheelCore

/// Opens the image editors (Crop, Add BG, Edit, Annotate, Redact) as ordinary windows and
/// saves their result next to the original, through the same folder grants as conversions.
final class EditorWindows: NSObject, NSWindowDelegate {
    private let access: FolderAccess
    private var windows: Set<NSWindow> = []
    /// Folder access held while an editor is open: the drop alone doesn't let the sandbox read
    /// the file, the folder grant does (the same way conversions read).
    private var grants: [ObjectIdentifier: FolderAccess.Grant] = [:]

    init(access: FolderAccess) {
        self.access = access
    }

    func open(_ tool: Tool, for file: URL) {
        guard let grant = access.grantOrAsk(for: file) else {
            showError(ConversionError.failed(FolderAccess.notAllowedMessage(for: file)), title: "Couldn't open the image")
            return
        }
        Task {
            do {
                try await LocalCopy.prepare(file)
            } catch {
                grant.release()
                showError(error, title: "Couldn't open the image")
                return
            }
            present(tool, for: file, holding: grant)
        }
    }

    private func present(_ tool: Tool, for file: URL, holding grant: FolderAccess.Grant) {
        let preview: (image: CGImage, fullSize: CGSize)
        do {
            // Editors that re-render on every change get a smaller copy; the save uses full size.
            preview = try ImageEditing.preview(file, maxEdge: tool == .crop || tool == .annotate ? 1600 : 900)
        } catch {
            grant.release()
            showError(error, title: "Couldn't open the image")
            return
        }
        let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.delegate = self
        let close = { [unowned window] in window.close() }

        let content: AnyView
        switch tool {
        case .crop:
            let model = CropModel(preview: preview.image, fullSize: preview.fullSize)
            window.title = "Crop Image"
            content = AnyView(CropEditor(model: model, onApply: { [unowned self, unowned window] in
                save(window, file) { try await Converter().crop(file, to: model.pixelRect, into: $0) }
            }, onCancel: close))
        case .background:
            let model = BackgroundModel(image: preview.image, fullSize: preview.fullSize)
            window.title = "Add Background"
            content = AnyView(BackgroundEditor(model: model, onSave: { [unowned self, unowned window] in
                let style = model.style
                save(window, file) { try await Converter().addBackground(file, style: style, into: $0) }
            }, onCancel: close))
        case .edit:
            let model = EditModel(preview: preview.image, fullSize: preview.fullSize)
            window.title = "Edit Image"
            content = AnyView(EditEditor(model: model, onSave: { [unowned self, unowned window] in
                let adjustments = model.adjustments
                save(window, file) { try await Converter().edit(file, with: adjustments, into: $0) }
            }, onCancel: close))
        case .annotate:
            let model = AnnotateModel(preview: preview.image, fullSize: preview.fullSize)
            window.title = "Annotate"
            content = AnyView(AnnotateEditor(model: model, onSave: { [unowned self, unowned window] in
                let annotations = model.annotations
                save(window, file) { try await Converter().annotate(file, with: annotations, into: $0) }
            }, onCancel: close))
        case .redact:
            let model = RedactModel(preview: preview.image, fullSize: preview.fullSize)
            window.title = "Redact"
            content = AnyView(RedactEditor(model: model, onSave: { [unowned self, unowned window] in
                let redactions = model.redactions
                save(window, file) { try await Converter().redact(file, with: redactions, into: $0) }
            }, onCancel: close))
        default:
            grant.release()
            return
        }
        grants[ObjectIdentifier(window)] = grant

        window.contentViewController = NSHostingController(rootView: content)
        windows.insert(window)
        window.center()
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    private func save(_ window: NSWindow, _ file: URL, _ write: @escaping (URL) async throws -> URL) {
        guard let grant = access.grantOrAsk(for: file) else {
            showError(ConversionError.failed(FolderAccess.notAllowedMessage(for: file)), title: "Couldn't save the image")
            return
        }
        Task {
            defer { grant.release() }
            do {
                _ = try await write(grant.directory)
                window.close()
            } catch {
                showError(error, title: "Couldn't save the image")
            }
        }
    }

    private func showError(_ error: Error, title: String) {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        alert.runModal()
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        grants.removeValue(forKey: ObjectIdentifier(window))?.release()
        // Let SwiftUI finish tearing down before the window is released.
        Task { windows.remove(window) }
    }
}
