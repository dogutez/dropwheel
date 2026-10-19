import AppKit
import SwiftUI

/// The welcome window: how the three keys work, the privacy promise in one paragraph and,
/// on first run, the two choices (open at login, automatic updates).
final class Onboarding: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var onClose: (() -> Void)?

    /// `choices` is nil when reopened from the menu (no checkboxes then).
    func show(showsUpdates: Bool, choices: ((_ openAtLogin: Bool, _ automaticUpdates: Bool) -> Void)?, onClose: (() -> Void)? = nil) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }
        self.onClose = onClose
        let view = OnboardingView(showsUpdates: showsUpdates, isFirstRun: choices != nil) { [weak self] login, updates in
            choices?(login, updates)
            self?.window?.close()
        }
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        self.window = window
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        onClose?()
        onClose = nil
        Task { window = nil }
    }
}

private struct OnboardingView: View {
    let showsUpdates: Bool
    let isFirstRun: Bool
    let onDone: (_ openAtLogin: Bool, _ automaticUpdates: Bool) -> Void
    @State private var openAtLogin = true
    @State private var automaticUpdates = true

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 60, height: 60)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Welcome to Dropwheel")
                        .font(.system(size: 22, weight: .bold))
                    Text("Drag any file, hold a key, and drop it on the wheel.")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
            }

            VStack(spacing: 12) {
                KeyRow(symbol: "⇧", name: "shift", title: "Convert", detail: "PNG, JPG, HEIC, PDF, DOCX, MP4, M4A and more")
                KeyRow(symbol: "⌘", name: "command", title: "Tools", detail: "Remove background, compress, crop, edit, redact, metadata")
                KeyRow(symbol: "⌃", name: "control", title: "Actions", detail: "AirDrop, keep on a shelf, copy, copy path, open in Terminal")
            }

            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(LinearGradient.dropwheel)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Private by design").font(.system(size: 13, weight: .semibold))
                    Text("Your files never leave this Mac. The first time you drop a file from a folder, Dropwheel asks once to save there. Results appear right next to the original.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.dropwheelAccent.opacity(0.08)))

            if isFirstRun {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("Open Dropwheel when I log in", isOn: $openAtLogin)
                    if showsUpdates {
                        Toggle(isOn: $automaticUpdates) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Install updates automatically")
                                Text("Checks github.com once a day. Every update is signature-checked.")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .toggleStyle(.checkbox)
            }

            HStack {
                if !isFirstRun {
                    Text("You can reopen this from the menu bar icon.")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                Button(isFirstRun ? "Get Started" : "Done") { onDone(openAtLogin, automaticUpdates) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .tint(.dropwheelAccent)
                    .controlSize(.large)
            }
        }
        .padding(.horizontal, 30)
        .padding(.top, 34)
        .padding(.bottom, 26)
        .frame(width: 500)
    }
}

private struct KeyRow: View {
    let symbol: String
    let name: String
    let title: String
    let detail: String

    var body: some View {
        HStack(spacing: 14) {
            VStack(spacing: 1) {
                Text(symbol).font(.system(size: 19, weight: .medium))
                Text(name).font(.system(size: 8.5, weight: .medium)).foregroundStyle(.secondary)
            }
            .frame(width: 62, height: 46)
            .background(
                RoundedRectangle(cornerRadius: 9)
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .shadow(color: .black.opacity(0.18), radius: 0.5, y: 1.5)
            )
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5))
            .accessibilityLabel(name)

            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 14, weight: .semibold))
                Text(detail).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }
}
