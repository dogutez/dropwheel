import AppKit
import OSLog

/// Dropwheel runs in the App Sandbox, so it can only write where the user said it may.
/// Folders granted through the open panel are remembered as security-scoped bookmarks.
/// There is no fallback location: without a grant nothing is written.
final class FolderAccess {
    struct Grant {
        let directory: URL
        let release: () -> Void
    }

    private let key = "grantedFolderBookmarks"
    private let log = Logger(subsystem: "io.github.dogutez.dropwheel", category: "access")

    /// The real home folder; inside the sandbox `NSHomeDirectory()` is the container.
    static let home: URL = {
        if let entry = getpwuid(getuid()), let dir = entry.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: dir), isDirectory: true)
        }
        return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
    }()

    var folders: [URL] { resolvedBookmarks().map(\.url) }

    /// Write access to the source's folder, if the user has allowed it (or a folder above it).
    func grant(for source: URL) -> Grant? {
        let parent = source.deletingLastPathComponent().standardizedFileURL.path
        for (url, _) in resolvedBookmarks() {
            guard Self.contains(url.standardizedFileURL.path, parent) else { continue }
            if url.startAccessingSecurityScopedResource() {
                return Grant(directory: source.deletingLastPathComponent()) { url.stopAccessingSecurityScopedResource() }
            }
        }
        return nil
    }

    /// Like `grant(for:)`, but when the file's folder isn't allowed yet, asks once for exactly
    /// that folder (the panel opens on it; one click on Allow).
    func grantOrAsk(for source: URL) -> Grant? {
        if let existing = grant(for: source) { return existing }
        let folder = source.deletingLastPathComponent()
        let name = FileManager.default.displayName(atPath: folder.path)
        guard requestFolder(at: folder, message: "To save next to your file, Dropwheel needs your OK once for “\(name)”. Click Allow.") else {
            return nil
        }
        return grant(for: source)
    }

    /// Runs `body` with every allowed folder accessible (used to tidy up after a crash).
    func withAllFolders(_ body: () -> Void) {
        let open = resolvedBookmarks().map(\.url).filter { $0.startAccessingSecurityScopedResource() }
        defer { open.forEach { $0.stopAccessingSecurityScopedResource() } }
        body()
    }

    static func notAllowedMessage(for source: URL) -> String {
        let name = FileManager.default.displayName(atPath: source.deletingLastPathComponent().path)
        return "Not saved: Dropwheel isn't allowed to save in “\(name)”. Drop the file again and click Allow, or use “Allow a Folder…” in the menu bar."
    }

    private static func contains(_ root: String, _ path: String) -> Bool {
        path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }

    /// Shows the open panel on `folder`; clicking Allow with nothing selected grants that
    /// folder itself. Returns true if a folder was granted.
    @discardableResult
    func requestFolder(
        at folder: URL = FolderAccess.home,
        message: String = "Choose a folder Dropwheel may save converted files into (next to the originals). Dropwheel can then read and write files in that folder and the folders inside it."
    ) -> Bool {
        NSApp.activate()
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = folder
        panel.prompt = "Allow"
        panel.message = message
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        do {
            let data = try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
            // Allowing the same folder twice adds nothing.
            let path = url.standardizedFileURL.path
            var stored = resolvedBookmarks().filter { $0.url.standardizedFileURL.path != path }.map(\.data)
            stored.append(data)
            UserDefaults.standard.set(stored, forKey: key)
            return true
        } catch {
            log.error("Bookmark creation failed: \((error as NSError).domain, privacy: .public) \((error as NSError).code, privacy: .public)")
            let alert = NSAlert()
            alert.messageText = "Couldn't remember that folder"
            alert.informativeText = error.localizedDescription
            alert.runModal()
            return false
        }
    }

    func forgetAll() {
        UserDefaults.standard.removeObject(forKey: key)
    }

    private func storedBookmarks() -> [Data] {
        UserDefaults.standard.array(forKey: key) as? [Data] ?? []
    }

    private func resolvedBookmarks() -> [(url: URL, data: Data)] {
        var refreshed: [Data] = []
        var result: [(URL, Data)] = []
        for data in storedBookmarks() {
            var stale = false
            guard let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale) else {
                continue // dropped: the folder is gone or the bookmark no longer validates
            }
            var current = data
            if stale, url.startAccessingSecurityScopedResource() {
                current = (try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)) ?? data
                url.stopAccessingSecurityScopedResource()
            }
            refreshed.append(current)
            result.append((url, current))
        }
        if refreshed != storedBookmarks() { UserDefaults.standard.set(refreshed, forKey: key) }
        return result
    }
}
