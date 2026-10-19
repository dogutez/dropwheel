import AppKit
import UniformTypeIdentifiers

enum DocumentEngine {
    static let maxBytes = 100 * 1024 * 1024
    static let maxPages = 2_000

    /// Reads with the document type pinned from the file's extension, so a file can
    /// never be sniffed into the HTML importer (WebKit, remote loads).
    static func read(_ url: URL) throws -> NSAttributedString {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= maxBytes else { throw ConversionError.tooLarge("Documents over 100 MB are not converted") }
        guard let type = UTType(filenameExtension: url.pathExtension.lowercased()),
              let format = DocumentFormat(type: type) else { throw ConversionError.unsupported }
        if format == .markdown { return try TextFormats.readMarkdown(url) }
        let documentType: NSAttributedString.DocumentType = switch format {
        case .plain, .markdown: .plain
        case .rtf: .rtf
        case .docx: .officeOpenXML
        case .doc: .docFormat
        case .odt: .openDocument
        }
        var options: [NSAttributedString.DocumentReadingOptionKey: Any] = [.documentType: documentType]
        if format == .plain {
            // A named font: the system mono face is private and documents would fall back to Times.
            let font = NSFont(name: "Menlo", size: 10) ?? NSFont.userFixedPitchFont(ofSize: 10) ?? NSFont.systemFont(ofSize: 10)
            options[.defaultAttributes] = [NSAttributedString.Key.font: font]
        }
        do {
            return try NSAttributedString(url: url, options: options, documentAttributes: nil)
        } catch {
            throw ConversionError.unreadable
        }
    }

    static func write(_ text: NSAttributedString, as format: OutputFormat, to url: URL) throws {
        let range = NSRange(location: 0, length: text.length)
        let data: Data? = switch format {
        case .txt: text.string.data(using: .utf8)
        case .rtf: text.rtf(from: range, documentAttributes: [:])
        case .docx: try? text.data(from: range, documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML])
        case .odt: try? text.data(from: range, documentAttributes: [.documentType: NSAttributedString.DocumentType.openDocument])
        case .pdf: try paginatedPDF(text)
        case .md: TextFormats.markdown(from: text).data(using: .utf8)
        // Export only (never import): writing HTML does not load anything.
        case .html: try? text.data(from: range, documentAttributes: [.documentType: NSAttributedString.DocumentType.html])
        default: throw ConversionError.unsupported
        }
        guard let data else { throw ConversionError.failed("Could not write the \(format.title) file") }
        try data.write(to: url, options: .withoutOverwriting)
    }

    /// Lays the text out on A4 pages with TextKit and draws each page into a PDF.
    static func paginatedPDF(_ text: NSAttributedString) throws -> Data {
        let page = CGSize(width: 595, height: 842)
        let margin: CGFloat = 56
        let storage = NSTextStorage(attributedString: text)
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)

        var containers: [NSTextContainer] = []
        repeat {
            let container = NSTextContainer(size: CGSize(width: page.width - margin * 2, height: page.height - margin * 2))
            layout.addTextContainer(container)
            containers.append(container)
            if NSMaxRange(layout.glyphRange(for: container)) >= layout.numberOfGlyphs { break }
        } while containers.count < maxPages

        let data = NSMutableData()
        var box = CGRect(origin: .zero, size: page)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &box, [kCGPDFContextCreator: "Dropwheel"] as CFDictionary)
        else { throw ConversionError.failed("Could not create the PDF") }

        for container in containers {
            context.beginPDFPage(nil)
            context.saveGState()
            context.translateBy(x: 0, y: page.height)
            context.scaleBy(x: 1, y: -1)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
            let glyphs = layout.glyphRange(for: container)
            let origin = CGPoint(x: margin, y: margin)
            layout.drawBackground(forGlyphRange: glyphs, at: origin)
            layout.drawGlyphs(forGlyphRange: glyphs, at: origin)
            NSGraphicsContext.restoreGraphicsState()
            context.restoreGState()
            context.endPDFPage()
        }
        context.closePDF()
        return data as Data
    }
}
