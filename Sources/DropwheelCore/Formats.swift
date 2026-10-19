import Foundation
import UniformTypeIdentifiers

/// The broad family a dropped file belongs to. Decides which wheel is offered.
public enum FileKind: String, Sendable, CaseIterable {
    case image, vector, pdf, document, video, audio, subtitle, table

    public init?(url: URL) {
        // A folder named "x.csv" is still a folder.
        guard !url.hasDirectoryPath else { return nil }
        let ext = url.pathExtension.lowercased()
        // Formats whose system type identifiers are missing or too generic.
        switch ext {
        case "srt", "vtt": self = .subtitle; return
        case "csv", "tsv": self = .table; return
        default: break
        }
        guard let type = UTType(filenameExtension: ext) else { return nil }
        self.init(type: type)
    }

    public init?(type: UTType) {
        if type.conforms(to: .pdf) {
            self = .pdf
        } else if type.conforms(to: .svg) {
            self = .vector
        } else if type.conforms(to: .image) {
            self = .image
        } else if type.conforms(to: .movie) {
            self = .video
        } else if type.conforms(to: .audio) {
            self = .audio
        } else if DocumentFormat(type: type) != nil {
            self = .document
        } else {
            return nil
        }
    }
}

/// Text document formats read through NSAttributedString. HTML is deliberately absent:
/// its importer runs WebKit and can try to fetch remote resources.
enum DocumentFormat {
    case plain, markdown, rtf, docx, doc, odt

    init?(type: UTType) {
        if type.conforms(to: .rtf) { self = .rtf }
        else if type.identifier == "net.daringfireball.markdown" || type.preferredFilenameExtension == "md" { self = .markdown }
        else if type.identifier == "org.openxmlformats.wordprocessingml.document" { self = .docx }
        else if type.identifier == "com.microsoft.word.doc" { self = .doc }
        else if type.identifier == "org.oasis-open.opendocument.text" { self = .odt }
        else if type.conforms(to: .plainText) { self = .plain }
        else { return nil }
    }
}

public enum OutputFormat: String, Sendable, CaseIterable {
    case jpg, png, heic, tiff, gif, bmp, pdf
    case txt, rtf, docx, odt, html, md
    case srt, vtt, csv, tsv
    case mp4, mov, m4a, wav, aiff, flac

    public var fileExtension: String { rawValue }
    public var title: String { rawValue.uppercased() }

    var utType: UTType {
        switch self {
        case .jpg: .jpeg
        case .png: .png
        case .heic: .heic
        case .tiff: .tiff
        case .gif: .gif
        case .bmp: .bmp
        case .pdf: .pdf
        case .txt: .plainText
        case .rtf: .rtf
        case .docx: UTType("org.openxmlformats.wordprocessingml.document") ?? .data
        case .odt: UTType("org.oasis-open.opendocument.text") ?? .data
        case .html: .html
        case .md: UTType("net.daringfireball.markdown") ?? .plainText
        case .srt, .vtt: .plainText
        case .csv: .commaSeparatedText
        case .tsv: .tabSeparatedText
        case .flac: UTType("org.xiph.flac") ?? .audio
        case .mp4: .mpeg4Movie
        case .mov: .quickTimeMovie
        case .m4a: .mpeg4Audio
        case .wav: .wav
        case .aiff: .aiff
        }
    }

    /// Formats that cannot hold transparency; images are flattened onto white first.
    var isOpaque: Bool { self == .jpg || self == .bmp }

    /// True when a file with this extension is already in this format.
    func matches(extension ext: String) -> Bool {
        let ext = ext.lowercased()
        return switch self {
        case .jpg: ["jpg", "jpeg", "jpe"].contains(ext)
        case .tiff: ["tif", "tiff"].contains(ext)
        case .heic: ["heic", "heif"].contains(ext)
        case .aiff: ["aif", "aiff"].contains(ext)
        case .md: ["md", "markdown"].contains(ext)
        case .html: ["html", "htm"].contains(ext)
        default: ext == rawValue
        }
    }

    /// The writable image format matching an image's own type, if any.
    init?(imageType: UTType) {
        guard let match = [OutputFormat.jpg, .png, .heic, .tiff, .gif, .bmp]
            .first(where: { imageType.conforms(to: $0.utType) }) else { return nil }
        self = match
    }
}

/// Edits that keep the file's family. Crop and Add BG open an editor first.
public enum Tool: String, Sendable, CaseIterable {
    case compress, clean, half, rotate, crop, background, edit, annotate, redact, split, merge
    case removeBackground = "removebg"

    /// Needs an editor window before anything is written.
    public var isInteractive: Bool { [.crop, .background, .edit, .annotate, .redact].contains(self) }

    public var title: String {
        switch self {
        case .compress: "Compress"
        case .clean: "Metadata"
        case .half: "Half Size"
        case .rotate: "Rotate"
        case .crop: "Crop"
        case .background: "Add BG"
        case .removeBackground: "Remove BG"
        case .edit: "Edit"
        case .annotate: "Annotate"
        case .redact: "Redact"
        case .split: "Split"
        case .merge: "Merge"
        }
    }

    public var symbol: String {
        switch self {
        case .compress: "arrow.down.right.and.arrow.up.left"
        case .clean: "tag.slash"
        case .half: "square.resize.down"
        case .rotate: "rotate.right"
        case .crop: "crop"
        case .background: "photo.on.rectangle.angled"
        case .removeBackground: "person.and.background.dotted"
        case .edit: "slider.horizontal.3"
        case .annotate: "pencil.tip.crop.circle"
        case .redact: "eye.slash"
        case .split: "scissors"
        case .merge: "square.stack.3d.up"
        }
    }

    /// Appended to the output's name so it never reads as the original.
    var suffix: String {
        switch self {
        case .compress: "compressed"
        case .clean: "clean"
        case .half: "half"
        case .rotate: "rotated"
        case .crop: "cropped"
        case .background: "with background"
        case .removeBackground: "no background"
        case .edit: "edited"
        case .annotate: "annotated"
        case .redact: "redacted"
        case .split: "pages"
        case .merge: "merged"
        }
    }
}

public enum Action: Hashable, Sendable {
    case convert(OutputFormat)
    case tool(Tool)

    public var title: String {
        switch self {
        case .convert(let format): format.title
        case .tool(let tool): tool.title
        }
    }

    /// Parses the CLI spelling: a format extension or a tool name.
    public init?(argument: String) {
        if let format = OutputFormat(rawValue: argument.lowercased()) {
            self = .convert(format)
        } else if let tool = Tool(rawValue: argument.lowercased()) {
            self = .tool(tool)
        } else {
            return nil
        }
    }
}

public enum Catalog {
    /// Conversion targets in wheel order (clockwise from the top), minus the file's own format.
    public static func conversions(for kind: FileKind, sourceExtension ext: String) -> [OutputFormat] {
        let all: [OutputFormat] = switch kind {
        case .image: [.jpg, .png, .heic, .pdf, .tiff, .gif, .bmp]
        case .vector: [.png, .jpg, .pdf, .heic, .tiff]
        case .pdf: [.docx, .jpg, .png, .txt, .md, .rtf]
        case .document: [.pdf, .docx, .txt, .md, .html, .rtf, .odt]
        case .video: [.mp4, .mov, .m4a, .gif]
        case .audio: [.m4a, .wav, .aiff, .flac]
        case .subtitle: [.srt, .vtt, .txt]
        case .table: [.csv, .tsv]
        }
        return all.filter { !$0.matches(extension: ext) }
    }

    /// Merge only makes sense for several files at once.
    public static func tools(for kind: FileKind, count: Int) -> [Tool] {
        tools(for: kind).filter { $0 != .merge || count > 1 }
    }

    public static func tools(for kind: FileKind) -> [Tool] {
        switch kind {
        // Same order as the reference video: clockwise from the top.
        case .image: [.compress, .clean, .edit, .annotate, .background, .removeBackground, .crop, .redact, .merge]
        case .pdf: [.compress, .clean, .split, .merge]
        case .video: [.compress, .clean]
        case .vector, .document, .audio, .subtitle, .table: []
        }
    }
}
