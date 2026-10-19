import AppKit
import CoreGraphics
import PDFKit

enum PDFEngine {
    /// Pages beyond this are not rasterised; a 5,000-page PDF should not fill the disk.
    static let maxRasterPages = 300
    /// Per-page pixel ceiling when rendering at 2x.
    static let maxPagePixels = 40_000_000.0
    /// Across all pages of one PDF → images job (≈ 1.5 gigapixels): many pages get smaller images
    /// instead of tens of gigabytes of output.
    static let maxTotalPixels = 1_500_000_000.0

    static func open(_ url: URL) throws -> PDFDocument {
        guard let document = PDFDocument(url: url) else { throw ConversionError.unreadable }
        guard !document.isLocked else { throw ConversionError.failed("This PDF is password-protected") }
        return document
    }

    static func pageCount(_ url: URL) throws -> Int {
        min(try open(url).pageCount, maxRasterPages)
    }

    /// Renders one page (zero-based) to a bitmap at 144 dpi on a white background.
    static func render(_ url: URL, page index: Int, pixelCap: Double = maxPagePixels) throws -> CGImage {
        guard let document = CGPDFDocument(url as CFURL), let page = document.page(at: index + 1) else {
            throw ConversionError.unreadable
        }
        let box = page.getBoxRect(.cropBox)
        let quarterTurned = abs(page.rotationAngle) % 180 == 90
        let size = quarterTurned ? CGSize(width: box.height, height: box.width) : box.size
        let scale = min(2.0, (min(pixelCap, maxPagePixels) / max(1, size.width * size.height)).squareRoot())
        let width = max(1, Int(size.width * scale)), height = max(1, Int(size.height * scale))
        guard let context = ImageEngine.bitmapContext(width: width, height: height) else {
            throw ConversionError.failed("Could not allocate memory for page \(index + 1)")
        }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        context.concatenate(page.getDrawingTransform(.cropBox, rect: CGRect(origin: .zero, size: size), rotate: 0, preserveAspectRatio: true))
        context.drawPDFPage(page)
        guard let image = context.makeImage() else { throw ConversionError.failed("Could not render page \(index + 1)") }
        return image
    }

    static func writePage(_ url: URL, page: Int, of pageCount: Int = 1, as format: OutputFormat, to destination: URL) throws {
        let image = try render(url, page: page, pixelCap: maxTotalPixels / Double(max(pageCount, 1)))
        try ImageEngine.write(image, as: format, to: destination, metadata: [kCGImagePropertyDPIWidth: 144, kCGImagePropertyDPIHeight: 144])
    }

    static func text(_ url: URL) throws -> NSAttributedString {
        let document = try open(url)
        let result = NSMutableAttributedString()
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index), let text = page.attributedString else { continue }
            if result.length > 0 { result.append(NSAttributedString(string: "\n\n")) }
            result.append(text)
        }
        guard result.length > 0 else {
            throw ConversionError.failed("This PDF has no selectable text (it may be a scan)")
        }
        return result
    }

    static func compress(_ url: URL, writingTo destination: URL) throws {
        let document = try open(url)
        let options: [PDFDocumentWriteOption: Any] = [.saveImagesAsJPEGOption: true, .optimizeImagesForScreenOption: true]
        guard document.write(to: destination, withOptions: options) else {
            throw ConversionError.failed("Could not write the compressed PDF")
        }
    }

    /// Rebuilds the PDF from its pages into a new document, so nothing document-level comes
    /// along: the Info dictionary (title, author, keywords, dates) and the XMP metadata packet
    /// both stay behind. Comments keep their text but lose their author and timestamps.
    static func clean(_ url: URL, writingTo destination: URL) throws {
        let source = try open(url)
        let result = PDFDocument()
        for index in 0..<source.pageCount {
            guard let page = source.page(at: index)?.copy() as? PDFPage else { continue }
            for annotation in page.annotations {
                annotation.userName = nil
                annotation.modificationDate = nil
                annotation.removeValue(forAnnotationKey: PDFAnnotationKey(rawValue: "/CreationDate"))
                annotation.removeValue(forAnnotationKey: PDFAnnotationKey(rawValue: "/T"))
                annotation.removeValue(forAnnotationKey: PDFAnnotationKey(rawValue: "/M"))
            }
            result.insert(page, at: result.pageCount)
        }
        // macOS still writes its own "Producer" (the macOS version); PDFKit offers no way around it.
        result.documentAttributes = [:]
        guard result.write(to: destination) else { throw ConversionError.failed("Could not write the PDF") }
    }
}

extension PDFEngine {
    /// One PDF per page, written into `folder` as "Name 01.pdf", "Name 02.pdf", …
    static func split(_ url: URL, into folder: URL) throws {
        let document = try open(url)
        guard document.pageCount > 1 else { throw ConversionError.failed("This PDF has only one page") }
        let stem = url.deletingPathExtension().lastPathComponent
        let digits = String(document.pageCount).count
        for index in 0..<min(document.pageCount, DocumentEngine.maxPages) {
            try Task.checkCancellation()
            guard let page = document.page(at: index)?.copy() as? PDFPage else { continue }
            let single = PDFDocument()
            single.insert(page, at: 0)
            let number = String(repeating: "0", count: digits - String(index + 1).count) + String(index + 1)
            guard single.write(to: folder.appendingPathComponent("\(stem) \(number).pdf")) else {
                throw ConversionError.failed("Could not write page \(index + 1)")
            }
        }
    }

    /// PDFs and images, in the order given, as one PDF. Images become pages at their own resolution.
    static func merge(_ sources: [URL], to destination: URL) throws {
        let result = PDFDocument()
        for source in sources {
            try Task.checkCancellation()
            switch FileKind(url: source) {
            case .pdf:
                let document = try open(source)
                for index in 0..<document.pageCount {
                    if let page = document.page(at: index)?.copy() as? PDFPage { result.insert(page, at: result.pageCount) }
                }
            case .image:
                let image = try ImageEngine.open(source)
                let pixels = try ImageEngine.orientedImage(image)
                let size = NSSize(width: CGFloat(pixels.width) * 72 / image.dpi, height: CGFloat(pixels.height) * 72 / image.dpi)
                if let page = PDFPage(image: NSImage(cgImage: pixels, size: size)) { result.insert(page, at: result.pageCount) }
            default:
                continue
            }
        }
        guard result.pageCount > 0 else { throw ConversionError.unreadable }
        guard result.write(to: destination) else { throw ConversionError.failed("Could not write the merged PDF") }
    }
}

/// SVG via AppKit's renderer (ImageIO can't read SVG). The sandbox has no network and no
/// file access beyond the dropped file, so external references in an SVG cannot load.
enum VectorEngine {
    static let maxBytes = 20 * 1024 * 1024
    static let maxEdge: CGFloat = 4096

    static func convert(_ url: URL, to format: OutputFormat, writingTo destination: URL) throws {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= maxBytes else { throw ConversionError.tooLarge("SVG files over 20 MB are not converted") }
        guard let image = NSImage(contentsOf: url), image.size.width > 0, image.size.height > 0 else { throw ConversionError.unreadable }
        let box = CGRect(origin: .zero, size: image.size)

        if format == .pdf {
            // Stays vector: the SVG is drawn straight into the PDF.
            var mediaBox = box
            guard let context = CGContext(destination as CFURL, mediaBox: &mediaBox, [kCGPDFContextCreator: "Dropwheel"] as CFDictionary) else {
                throw ConversionError.failed("Could not create the PDF")
            }
            context.beginPDFPage(nil)
            draw(image, in: box, context: context)
            context.endPDFPage()
            context.closePDF()
            return
        }

        // Rasterise sharply: up to 4× the declared size, never past 4096 px.
        let scale = min(4, maxEdge / max(box.width, box.height))
        let width = max(1, Int(box.width * scale)), height = max(1, Int(box.height * scale))
        guard let context = ImageEngine.bitmapContext(width: width, height: height) else {
            throw ConversionError.failed("Could not allocate memory for the image")
        }
        context.scaleBy(x: scale, y: scale)
        draw(image, in: box, context: context)
        guard let raster = context.makeImage() else { throw ConversionError.failed("Could not render the SVG") }
        try ImageEngine.write(raster, as: format, to: destination, metadata: [kCGImagePropertyDPIWidth: 72 * scale, kCGImagePropertyDPIHeight: 72 * scale])
    }

    private static func draw(_ image: NSImage, in box: CGRect, context: CGContext) {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        image.draw(in: box)
        NSGraphicsContext.restoreGraphicsState()
    }
}
