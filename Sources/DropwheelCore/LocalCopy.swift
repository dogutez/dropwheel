import Darwin
import Foundation
import OSLog

/// Makes sure a dropped file's bytes are on this Mac and readable before any engine opens it.
///
/// With iCloud's "Optimise Mac Storage", Desktop and Documents files can be placeholders whose
/// content lives only in iCloud. Asking for the download explicitly (rather than hoping a read
/// triggers it) works from inside the sandbox, and failures get a reason instead of a generic
/// "couldn't be read".
public enum LocalCopy {
    private static let log = Logger(subsystem: "io.github.dogutez.dropwheel", category: "read")
    static let downloadTimeout: TimeInterval = 180

    public static func isPlaceholder(_ url: URL) -> Bool {
        var info = stat()
        guard stat(url.path, &info) == 0 else { return false }
        return info.st_flags & UInt32(SF_DATALESS) != 0
    }

    public static func prepare(_ url: URL) async throws {
        guard !url.hasDirectoryPath else { return }
        if isPlaceholder(url) {
            log.notice("Source is an iCloud placeholder; requesting download")
            try? FileManager.default.startDownloadingUbiquitousItem(at: url)
            var coordinationError: NSError?
            NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { _ in }
            let deadline = Date().addingTimeInterval(downloadTimeout)
            while isPlaceholder(url) {
                guard Date() < deadline else {
                    log.error("iCloud download did not finish")
                    throw ConversionError.failed("This file is only in iCloud and didn't download. Open it once in Finder (or choose “Download Now”), then try again.")
                }
                try await Task.sleep(for: .milliseconds(250))
            }
        }
        // Right after an iCloud download the sandbox can refuse the first reads for a moment
        // (seen in the field: EPERM, then fine on the next drop), so retry briefly.
        var descriptor = open(url.path, O_RDONLY)
        var code = errno
        var attempts = 0
        while descriptor < 0, code == EPERM || code == EACCES, attempts < 12 {
            attempts += 1
            try await Task.sleep(for: .milliseconds(250))
            descriptor = open(url.path, O_RDONLY)
            code = errno
        }
        if attempts > 0 { log.notice("Read needed \(attempts, privacy: .public) retries") }
        guard descriptor >= 0 else {
            log.error("open() failed with errno \(code, privacy: .public)")
            if code == EPERM || code == EACCES {
                throw ConversionError.failed("macOS didn't let Dropwheel read this file. Drop it on the wheel again; if it keeps happening, choose “Allow a Folder…” in the menu bar.")
            }
            throw ConversionError.failed("The file couldn't be opened (\(String(cString: strerror(code))))")
        }
        close(descriptor)
    }
}
