import Foundation

public enum ConversionError: LocalizedError, Equatable {
    case unsupported
    case unreadable
    case tooLarge(String)
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .unsupported: "That conversion isn't available for this file"
        case .unreadable: "The file couldn't be read"
        case .tooLarge(let reason), .failed(let reason): reason
        }
    }
}

/// Runs one action on one file and saves the result next to it, in `directory`.
/// Never modifies, moves or overwrites the source or any existing file.
public struct Converter: Sendable {
    public init() {}

    @concurrent
    public func run(_ action: Action, source: URL, into directory: URL) async throws -> [URL] {
        guard let kind = FileKind(url: source) else { throw ConversionError.unsupported }
        try await LocalCopy.prepare(source)
        switch (kind, action) {
        case (.image, .convert(let format)):
            return [try produce(source, directory, ext: format.fileExtension) { try ImageEngine.convert(source, to: format, writingTo: $0) }]
        case (.image, .tool(.compress)):
            let format = try ImageEngine.compressedFormat(for: source)
            return [try produce(source, directory, suffix: Tool.compress.suffix, ext: format.fileExtension) {
                try ImageEngine.compress(source, as: format, writingTo: $0)
                try requireSmaller($0, than: source)
            }]
        case (.image, .tool(.clean)):
            return [try produce(source, directory, suffix: Tool.clean.suffix, ext: source.pathExtension) { try ImageEngine.clean(source, writingTo: $0) }]
        case (.image, .tool(let tool)) where tool == .half || tool == .rotate:
            let format = try ImageEngine.editFormat(for: source)
            return [try produce(source, directory, suffix: tool.suffix, ext: format.fileExtension) {
                tool == .half ? try ImageEngine.halve(source, as: format, writingTo: $0) : try ImageEngine.rotate(source, as: format, writingTo: $0)
            }]

        case (.pdf, .convert(let format)) where format == .jpg || format == .png:
            return [try rasterize(source, directory, as: format)]
        case (.pdf, .convert(let format)) where [.txt, .rtf, .docx, .md].contains(format):
            let text = try PDFEngine.text(source)
            return [try produce(source, directory, ext: format.fileExtension) { try DocumentEngine.write(text, as: format, to: $0) }]
        case (.pdf, .tool(.compress)):
            return [try produce(source, directory, suffix: Tool.compress.suffix, ext: "pdf") {
                try PDFEngine.compress(source, writingTo: $0)
                try requireSmaller($0, than: source)
            }]
        case (.pdf, .tool(.clean)):
            return [try produce(source, directory, suffix: Tool.clean.suffix, ext: "pdf") { try PDFEngine.clean(source, writingTo: $0) }]

        case (.pdf, .tool(.split)):
            return [try produceFolder(source, directory, name: "\(source.deletingPathExtension().lastPathComponent) (\(Tool.split.suffix))") {
                try PDFEngine.split(source, into: $0)
            }]

        case (.vector, .convert(let format)):
            return [try produce(source, directory, ext: format.fileExtension) { try VectorEngine.convert(source, to: format, writingTo: $0) }]
        case (.subtitle, .convert(let format)):
            return [try produce(source, directory, ext: format.fileExtension) { try TextFormats.convertSubtitles(source, to: format, writingTo: $0) }]
        case (.table, .convert(let format)):
            return [try produce(source, directory, ext: format.fileExtension) { try TextFormats.convertTable(source, to: format, writingTo: $0) }]

        case (.document, .convert(let format)):
            let text = try DocumentEngine.read(source)
            return [try produce(source, directory, ext: format.fileExtension) { try DocumentEngine.write(text, as: format, to: $0) }]

        case (.video, .convert(let format)):
            return [try await produce(source, directory, ext: format.fileExtension) { try await MediaEngine.convertVideo(source, to: format, writingTo: $0) }]
        case (.video, .tool(.compress)):
            let ext = MediaEngine.fileType(for: source).1.fileExtension
            return [try await produce(source, directory, suffix: Tool.compress.suffix, ext: ext) {
                try await MediaEngine.compressVideo(source, writingTo: $0)
                try requireSmaller($0, than: source)
            }]
        case (.video, .tool(.clean)):
            let ext = MediaEngine.fileType(for: source).1.fileExtension
            return [try await produce(source, directory, suffix: Tool.clean.suffix, ext: ext) { try await MediaEngine.cleanVideo(source, writingTo: $0) }]

        case (.audio, .convert(let format)):
            return [try await produce(source, directory, ext: format.fileExtension) { try await MediaEngine.convertAudio(source, to: format, writingTo: $0) }]

        default:
            throw ConversionError.unsupported
        }
    }

    /// One page becomes "Name.jpg"; several become a "Name (JPG)" folder of numbered pages.
    private func rasterize(_ source: URL, _ directory: URL, as format: OutputFormat) throws -> URL {
        let pages = try PDFEngine.pageCount(source)
        guard pages > 1 else {
            return try produce(source, directory, ext: format.fileExtension) { try PDFEngine.writePage(source, page: 0, as: format, to: $0) }
        }
        let stem = source.deletingPathExtension().lastPathComponent
        return try produceFolder(source, directory, name: "\(stem) (\(format.title))") { folder in
            let digits = String(pages).count
            for page in 0..<pages {
                try Task.checkCancellation()
                let number = String(repeating: "0", count: digits - String(page + 1).count) + String(page + 1)
                try PDFEngine.writePage(source, page: page, of: pages, as: format, to: folder.appendingPathComponent("\(stem) \(number).\(format.fileExtension)"))
                ConversionProgress.report(Double(page + 1) / Double(pages))
            }
        }
    }

    /// Like `produce`, for results that are a folder of files.
    private func produceFolder(_ source: URL, _ directory: URL, name: String, _ body: (URL) throws -> Void) throws -> URL {
        let temp = Output.temporaryURL(in: directory, ext: nil)
        do {
            try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: false)
            try body(temp)
            return try Output.commit(temp, in: directory, base: name, ext: nil, source: source)
        } catch {
            Output.discard(temp)
            throw error
        }
    }

    /// Several PDFs and/or images, in order, as "First name merged.pdf".
    @concurrent
    public func merge(_ sources: [URL], into directory: URL) async throws -> URL {
        guard let first = sources.first, sources.count > 1 else { throw ConversionError.failed("Drop two or more files to merge") }
        for source in sources { try await LocalCopy.prepare(source) }
        return try produce(first, directory, suffix: Tool.merge.suffix, ext: "pdf") { try PDFEngine.merge(sources, to: $0) }
    }

    /// A "compressed" copy that is bigger than the original is discarded, not saved.
    private func requireSmaller(_ output: URL, than source: URL) throws {
        func size(_ url: URL) -> Int { (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0 }
        guard size(output) < size(source) else {
            throw ConversionError.failed("Already compact: compressing wouldn't make it smaller")
        }
    }

    func produce(_ source: URL, _ directory: URL, suffix: String? = nil, ext: String, _ body: (URL) throws -> Void) throws -> URL {
        let temp = Output.temporaryURL(in: directory, ext: ext)
        do {
            try body(temp)
            return try Output.commit(temp, in: directory, base: Output.baseName(of: source, suffix: suffix), ext: ext, source: source)
        } catch {
            Output.discard(temp)
            throw error
        }
    }

    private func produce(_ source: URL, _ directory: URL, suffix: String? = nil, ext: String, _ body: (URL) async throws -> Void) async throws -> URL {
        let temp = Output.temporaryURL(in: directory, ext: ext)
        do {
            try await body(temp)
            return try Output.commit(temp, in: directory, base: Output.baseName(of: source, suffix: suffix), ext: ext, source: source)
        } catch {
            Output.discard(temp)
            throw error
        }
    }
}
