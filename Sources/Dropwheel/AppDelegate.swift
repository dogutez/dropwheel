import AppKit
import ServiceManagement
import DropwheelCore

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let access = FolderAccess()
    private lazy var wheel = WheelController(access: access)
    private lazy var editors = EditorWindows(access: access)
    private lazy var fileActions = FileActions(access: access)
    private let updates = Updates()
    private let onboarding = Onboarding()
    private let watcher = DragWatcher()
    private var statusItem: NSStatusItem?
    private let defaults = UserDefaults.standard

    func applicationDidFinishLaunching(_ notification: Notification) {
        defaults.register(defaults: ["enabled": true])
        watcher.isEnabled = defaults.bool(forKey: "enabled")
        wheel.onEdit = { [unowned self] tool, file in editors.open(tool, for: file) }
        wheel.onFileAction = { [unowned self] action, urls in fileActions.perform(action, on: urls) }
        watcher.isWheelVisible = { [unowned self] in wheel.isVisible && wheel.model.isPresented }
        watcher.onModifierDrag = { [unowned self] files, ring in wheel.show(for: files, ring: ring) }
        watcher.onRingChange = { [unowned self] ring in wheel.model.show(ring) }
        watcher.onTick = { [unowned self] in wheel.trackPointer() }
        watcher.onRelease = { [unowned self] in wheel.dragEnded() }
        watcher.start()
        access.withAllFolders { Housekeeping.sweepAbandonedFiles() }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "circle.circle", accessibilityDescription: "Dropwheel")
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item

        #if DEBUG
        // Debug builds only: DROPWHEEL_DEMO=pdf shows the wheel for a fake "Page 001.pdf".
        let environment = ProcessInfo.processInfo.environment
        // DROPWHEEL_SELFTEST=<dir>: run every action on every file there, as the (sandboxed) app.
        if let path = environment["DROPWHEEL_SELFTEST"] {
            Task {
                let directory = URL(fileURLWithPath: path)
                // Test bundles get the folder through a temporary-exception entitlement, not a bookmark.
                @MainActor func grant(_ file: URL) -> FolderAccess.Grant {
                    access.grant(for: file) ?? FolderAccess.Grant(directory: file.deletingLastPathComponent()) {}
                }
                let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
                print("listed \(files.count) files")
                for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                    guard let kind = FileKind(url: file) else { continue }
                    let actions = Catalog.conversions(for: kind, sourceExtension: file.pathExtension).map(Action.convert)
                        + Catalog.tools(for: kind, count: 1).filter { !$0.isInteractive }.map(Action.tool)
                    for action in actions {
                        let grant = grant(file)
                        do {
                            let outputs = try await Converter().run(action, source: file, into: grant.directory)
                            print("OK  ", file.lastPathComponent, action.title, "->", outputs.map(\.lastPathComponent))
                        } catch {
                            print("FAIL", file.lastPathComponent, action.title, error.localizedDescription)
                        }
                        grant.release()
                    }
                    guard kind == .image else { continue }
                    // The editor tools, with fixed parameters instead of a window.
                    var adjustments = Adjustments()
                    adjustments.rotate(clockwise: true)
                    adjustments.warmth = 0.5
                    let mark = Annotation(shape: .arrow(from: CGPoint(x: 0.2, y: 0.8), to: CGPoint(x: 0.7, y: 0.3)), color: RGBA(hex: 0xF2545B), width: 0.01)
                    let size = (try? ImageEditing.preview(file, maxEdge: 64).fullSize) ?? CGSize(width: 100, height: 100)
                    let edits: [(String, (URL) async throws -> URL)] = [
                        ("Crop", { try await Converter().crop(file, to: CGRect(x: 0, y: 0, width: size.width / 2, height: size.height / 2), into: $0) }),
                        ("Add BG", { try await Converter().addBackground(file, style: .defaults(for: size, fill: .solid(RGBA(hex: 0x3B82F6))), into: $0) }),
                        ("Add BG cut-out", {
                            var style = CanvasStyle.defaults(for: size, fill: .gradient([RGBA(hex: 0x3D63FA), RGBA(hex: 0x06B6D4)], angle: 45))
                            style.removeBackground = true
                            return try await Converter().addBackground(file, style: style, into: $0)
                        }),
                        ("Edit", { try await Converter().edit(file, with: adjustments, into: $0) }),
                        ("Annotate", { try await Converter().annotate(file, with: [mark], into: $0) }),
                        ("Redact", { try await Converter().redact(file, with: [Redaction(rect: CGRect(x: 0.1, y: 0.1, width: 0.3, height: 0.2), style: .pixelate)], into: $0) }),
                    ]
                    for (title, run) in edits {
                        let grant = grant(file)
                        do {
                            print("OK  ", file.lastPathComponent, title, "->", try await run(grant.directory).lastPathComponent)
                        } catch {
                            print("FAIL", file.lastPathComponent, title, error.localizedDescription)
                        }
                        grant.release()
                    }
                }
                exit(0)
            }
            return
        }
        // DROPWHEEL_UPDATE_TEST=1: check the (local) feed now and install whatever it offers.
        if environment["DROPWHEEL_UPDATE_TEST"] == "1" {
            updates.runUpdateTest()
            return
        }
        // DROPWHEEL_ONBOARDING=1: show the welcome window (with DROPWHEEL_DEMO_SNAPSHOT to save it).
        if environment["DROPWHEEL_ONBOARDING"] == "1" {
            onboarding.show(showsUpdates: true, choices: { _, _ in })
            if let path = environment["DROPWHEEL_DEMO_SNAPSHOT"] {
                Task {
                    try? await Task.sleep(for: .seconds(1.2))
                    let largest = NSApp.windows.filter(\.isVisible).max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
                    guard let view = largest?.contentView,
                          let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
                    view.cacheDisplay(in: view.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                    NSApp.terminate(nil)
                }
            }
            return
        }
        // DROPWHEEL_EDIT=crop|background:<image>: open an editor directly.
        if let request = environment["DROPWHEEL_EDIT"], let colon = request.firstIndex(of: ":"),
           let tool = Tool(rawValue: String(request[..<colon])) {
            editors.open(tool, for: URL(fileURLWithPath: String(request[request.index(after: colon)...])))
            if let path = environment["DROPWHEEL_DEMO_SNAPSHOT"] {
                Task {
                    try? await Task.sleep(for: .seconds(1.5))
                    guard let view = NSApp.windows.first(where: { $0.isVisible && !($0 is WheelPanel) && $0.contentViewController != nil })?.contentView,
                          let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
                    view.cacheDisplay(in: view.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                    NSApp.terminate(nil)
                }
            }
            return
        }
        if let demo = environment["DROPWHEEL_DEMO"] {
            let ring: WheelModel.Ring = switch environment["DROPWHEEL_DEMO_RING"] {
            case "tools": .tools
            case "actions": .actions
            default: .convert
            }
            wheel.show(for: [URL(fileURLWithPath: "/tmp/Page 001.\(demo)")], ring: ring)
            if let index = environment["DROPWHEEL_DEMO_HOVER"].flatMap(Int.init) { wheel.model.hovered = .segment(index) }
            if let progress = environment["DROPWHEEL_DEMO_PROGRESS"].flatMap(Double.init) {
                wheel.model.phase = .working("Compress")
                wheel.model.progress = progress
            }
            if let path = environment["DROPWHEEL_DEMO_SNAPSHOT"] {
                Task {
                    try? await Task.sleep(for: .seconds(1))
                    guard let view = NSApp.windows.first(where: { $0 is WheelPanel })?.contentView,
                          let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
                    view.cacheDisplay(in: view.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                    NSApp.terminate(nil)
                }
            }
            return
        }
        #endif

        if !defaults.bool(forKey: "onboarded") { onboard() }
    }

    // MARK: Onboarding

    private func onboard() {
        onboarding.show(showsUpdates: updates.isAvailable, choices: { [unowned self] login, automatic in
            if login { setOpenAtLogin(true) }
            if updates.isAvailable { updates.isAutomatic = automatic }
        }, onClose: { [unowned self] in
            // Closing the window also counts as seen; nothing is switched on without the button.
            defaults.set(true, forKey: "onboarded")
        })
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let header = NSMenuItem(title: "Drag a file + ⇧ convert · ⌘ tools · ⌃ actions", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(item("Enabled", #selector(toggleEnabled), checked: watcher.isEnabled))
        menu.addItem(.separator())

        let folders = access.folders
        let savesTitle = folders.isEmpty ? "No folders allowed yet (asks on first drop)" : "May save next to originals in:"
        let saves = NSMenuItem(title: savesTitle, action: nil, keyEquivalent: "")
        saves.isEnabled = false
        menu.addItem(saves)
        for folder in folders {
            let row = NSMenuItem(title: "  " + folder.path.replacingOccurrences(of: FolderAccess.home.path, with: "~"), action: nil, keyEquivalent: "")
            row.isEnabled = false
            menu.addItem(row)
        }
        menu.addItem(item("Allow a Folder…", #selector(addFolder)))
        if !folders.isEmpty { menu.addItem(item("Forget Allowed Folders", #selector(forgetFolders))) }
        menu.addItem(.separator())

        menu.addItem(item("Open at Login", #selector(toggleLogin), checked: SMAppService.mainApp.status == .enabled))
        if updates.isAvailable {
            menu.addItem(item("Install Updates Automatically", #selector(toggleAutomaticUpdates), checked: updates.isAutomatic))
            menu.addItem(item("Check for Updates…", #selector(checkForUpdates)))
        }
        menu.addItem(item("Privacy & Security…", #selector(showPrivacy)))
        menu.addItem(item("Welcome Guide…", #selector(showGuide)))
        menu.addItem(item("About Dropwheel", #selector(showAbout)))
        menu.addItem(.separator())
        menu.addItem(item("Quit Dropwheel", #selector(NSApplication.terminate(_:)), key: "q", target: NSApp))
    }

    private func item(_ title: String, _ action: Selector, checked: Bool = false, key: String = "", target: AnyObject? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = target ?? self
        item.state = checked ? .on : .off
        return item
    }

    @objc private func toggleEnabled() {
        watcher.isEnabled.toggle()
        defaults.set(watcher.isEnabled, forKey: "enabled")
    }

    @objc private func addFolder() { access.requestFolder() }

    @objc private func forgetFolders() { access.forgetAll() }

    @objc private func toggleAutomaticUpdates() { updates.isAutomatic.toggle() }

    @objc private func showGuide() {
        onboarding.show(showsUpdates: updates.isAvailable, choices: nil)
    }

    @objc private func showAbout() {
        NSApp.activate()
        NSApp.orderFrontStandardAboutPanel(nil)
    }

    @objc private func checkForUpdates() { updates.checkNow() }

    @objc private func toggleLogin() {
        setOpenAtLogin(SMAppService.mainApp.status != .enabled)
    }

    private func setOpenAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSApp.activate()
            let alert = NSAlert()
            alert.messageText = "Couldn't change the login item"
            alert.informativeText = "\(error.localizedDescription)\n\nYou can add Dropwheel in System Settings › General › Login Items."
            alert.runModal()
        }
    }

    @objc private func showPrivacy() {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "Privacy & Security"
        alert.informativeText = """
            • Your files never leave this Mac. Dropwheel is sandboxed without the network entitlement, so macOS blocks it from connecting anywhere.
            • The only exception is the updater (Sparkle), a separate component. If automatic updates are on, it asks github.com once a day for a new version (that reveals your IP address and the app version) and installs it only if its signature matches. Turn it off under “Install Updates Automatically”.
            • No Accessibility, Input Monitoring or Screen Recording permission. It only looks at the mouse buttons and whether ⇧ ⌘ ⌃ are held, never at keystrokes, and never reads the clipboard (Copy and Copy Path write to it when you ask).
            • It reads the files you drop on it. It saves only into folders you allow; macOS gives that permission as read and write for the whole folder, so allow only the folders you use.
            • Originals are never changed, moved or overwritten.
            • Converted images drop location, device and owner metadata. The Metadata tool removes all of it from photos, PDFs (document info, XMP, comment authors) and videos. Redact saves with no metadata at all.
            • Every file Dropwheel writes carries macOS's quarantine flag.
            • No analytics, no accounts. Apart from Sparkle, no third-party code. File names are kept out of system logs.
            """
        alert.runModal()
    }
}
