import AppKit
import Sparkle

/// Automatic updates through Sparkle.
///
/// The app itself has no network entitlement. Sparkle's Downloader XPC service (sandboxed,
/// network-client only) fetches the appcast and the update; its Installer service swaps the
/// app. Every update must carry an EdDSA signature matching `SUPublicEDKey` in Info.plist, so
/// a tampered download or a hijacked feed can't install anything.
///
/// A build without `SUFeedURL`/`SUPublicEDKey` (e.g. built from source) has updates switched off.
final class Updates: NSObject, SPUUpdaterDelegate, SPUStandardUserDriverDelegate {
    private var controller: SPUStandardUpdaterController?

    static var isConfigured: Bool {
        let info = Bundle.main.infoDictionary ?? [:]
        return (info["SUFeedURL"] as? String)?.hasPrefix("https://") == true && (info["SUPublicEDKey"] as? String)?.isEmpty == false
            || isLocalTestFeed
    }

    /// Debug builds may point at a local feed to test the whole update path.
    private static var isLocalTestFeed: Bool {
        #if DEBUG
        return (Bundle.main.infoDictionary?["SUFeedURL"] as? String)?.hasPrefix("http://127.0.0.1") == true
        #else
        return false
        #endif
    }

    override init() {
        super.init()
        guard Self.isConfigured else { return }
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: self)
    }

    var isAvailable: Bool { controller != nil }

    /// Check and install automatically (downloads in the background, installs on quit).
    var isAutomatic: Bool {
        get {
            guard let updater = controller?.updater else { return false }
            return updater.automaticallyChecksForUpdates && updater.automaticallyDownloadsUpdates
        }
        set {
            guard let updater = controller?.updater else { return }
            updater.automaticallyChecksForUpdates = newValue
            updater.automaticallyDownloadsUpdates = newValue
        }
    }

    func checkNow() {
        controller?.checkForUpdates(nil)
    }

    // MARK: SPUUpdaterDelegate

    #if DEBUG
    /// DROPWHEEL_UPDATE_TEST=1: install a found update immediately and relaunch (end-to-end test).
    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem, immediateInstallationBlock: @escaping () -> Void) -> Bool {
        guard ProcessInfo.processInfo.environment["DROPWHEEL_UPDATE_TEST"] == "1" else { return false }
        immediateInstallationBlock()
        return true
    }

    func runUpdateTest() {
        isAutomatic = true
        controller?.updater.checkForUpdatesInBackground()
    }
    #endif

    // MARK: SPUStandardUserDriverDelegate

    /// A menu-bar app has no Dock icon to badge; Sparkle shows a gentle reminder instead.
    var supportsGentleScheduledUpdateReminders: Bool { true }
}
