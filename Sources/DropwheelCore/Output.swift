import Darwin
import Foundation
import Synchronization

/// Where results land and how they get there. Every result is written to a hidden
/// temporary name in the destination folder first, then renamed into place with
/// `RENAME_EXCL`, so a half-written file is never visible and nothing is ever overwritten.
enum Output {
    static func baseName(of source: URL, suffix: String?) -> String {
        let stem = source.deletingPathExtension().lastPathComponent
        guard let suffix else { return stem }
        return "\(stem) \(suffix)"
    }

    /// Finder-style candidates: "Name.jpg", "Name 2.jpg", "Name 3.jpg", ...
    static func candidateName(base: String, ext: String?, attempt: Int) -> String {
        let stem = attempt == 0 ? base : "\(base) \(attempt + 1)"
        guard let ext else { return stem }
        return "\(stem).\(ext)"
    }

    static func temporaryURL(in directory: URL, ext: String?) -> URL {
        let name = ".dropwheel-\(UUID().uuidString)" + (ext.map { ".\($0)" } ?? "")
        let url = directory.appendingPathComponent(name, isDirectory: ext == nil)
        Journal.record(url)
        return url
    }

    /// Removes an unfinished temporary file or folder.
    static func discard(_ temp: URL) {
        try? FileManager.default.removeItem(at: temp)
        Journal.forget(temp)
    }

    /// Hidden temporary files left behind by a crash or force-quit are listed in a small journal
    /// in Dropwheel's own container and removed on the next launch (only names Dropwheel created).
    static func sweepAbandonedFiles() {
        for url in Journal.drain() where url.lastPathComponent.hasPrefix(".dropwheel-") {
            try? FileManager.default.removeItem(at: url)
        }
    }

    enum Journal {
        private static let lock = Mutex(())
        private static var file: URL? {
            guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
            let folder = support.appendingPathComponent("Dropwheel", isDirectory: true)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            return folder.appendingPathComponent("unfinished.txt")
        }

        private static func read() -> [String] {
            guard let file, let text = try? String(contentsOf: file, encoding: .utf8) else { return [] }
            return text.split(separator: "\n").map(String.init)
        }

        private static func write(_ paths: [String]) {
            guard let file else { return }
            try? Data(paths.joined(separator: "\n").utf8).write(to: file, options: .atomic)
        }

        static func record(_ url: URL) {
            lock.withLock { _ in write(read() + [url.path]) }
        }

        static func forget(_ url: URL) {
            lock.withLock { _ in write(read().filter { $0 != url.path }) }
        }

        static func drain() -> [URL] {
            lock.withLock { _ in
                let paths = read()
                write([])
                return paths.map { URL(fileURLWithPath: $0) }
            }
        }
    }

    /// Moves `temp` to the first free candidate name. Fails instead of replacing anything.
    static func commit(_ temp: URL, in directory: URL, base: String, ext: String?, source: URL) throws -> URL {
        for attempt in 0..<1000 {
            let destination = directory.appendingPathComponent(
                candidateName(base: base, ext: ext, attempt: attempt), isDirectory: ext == nil)
            if renamex_np(temp.path, destination.path, UInt32(RENAME_EXCL)) == 0 {
                Journal.forget(temp)
                propagateQuarantine(from: source, to: destination)
                return destination
            }
            guard errno == EEXIST else {
                throw ConversionError.failed("Could not save the result (\(String(cString: strerror(errno))))")
            }
        }
        throw ConversionError.failed("Too many files with this name already exist")
    }

    /// A file derived from a downloaded file stays marked as downloaded, so Gatekeeper
    /// and quarantine-aware apps keep treating it with the same caution. (Inside the app
    /// the sandbox already quarantines everything it writes; this covers the CLI.)
    static func propagateQuarantine(from source: URL, to destination: URL) {
        let name = "com.apple.quarantine"
        let size = getxattr(source.path, name, nil, 0, 0, 0)
        guard size > 0 else { return }
        var value = [UInt8](repeating: 0, count: size)
        guard getxattr(source.path, name, &value, size, 0, 0) == size else { return }
        var targets = [destination]
        if let children = try? FileManager.default.contentsOfDirectory(at: destination, includingPropertiesForKeys: nil) {
            targets += children
        }
        for target in targets {
            _ = setxattr(target.path, name, value, size, 0, 0)
        }
    }
}

/// App-level tidying that the engine owns.
public enum Housekeeping {
    /// Removes hidden temporary files an interrupted conversion left behind.
    public static func sweepAbandonedFiles() { Output.sweepAbandonedFiles() }
}
