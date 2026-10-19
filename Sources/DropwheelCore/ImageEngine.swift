import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum ImageEngine {
    /// Refuse anything larger before decoding: guards against decompression bombs.
    static let maxPixels = 250_000_000
    /// Frames beyond this are ignored when building a PDF from a multi-frame image.
    static let maxFrames = 500

    struct Source {
        let source: CGImageSource
        let type: UTType
        let width: Int
        let height: Int
        let properties: [CFString: Any]

        var frameCount: Int { min(CGImageSourceGetCount(source), ImageEngine.maxFrames) }
        var longEdge: Int { max(width, height) }
        var dpi: CGFloat {
            let value = properties[kCGImagePropertyDPIWidth] as? Double ?? 72
            return value > 0 ? CGFloat(value) : 72
        }
        var orientation: Int { properties[kCGImagePropertyOrientation] as? Int ?? 1 }
    }

    static func open(_ url: URL) throws -> Source {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options),
              let typeID = CGImageSourceGetType(source) as String?,
              let type = UTType(typeID),
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { throw ConversionError.unreadable }
        guard width > 0, height > 0, width * height <= maxPixels else {
            throw ConversionError.tooLarge("Image is larger than \(maxPixels / 1_000_000) megapixels")
        }
        return Source(source: source, type: type, width: width, height: height, properties: properties)
    }

    /// Decodes a frame with its EXIF orientation applied, optionally downscaled.
    static func orientedImage(_ source: Source, index: Int = 0, longEdge: Int? = nil) throws -> CGImage {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: longEdge ?? source.longEdge,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source.source, index, options as CFDictionary) else {
            throw ConversionError.unreadable
        }
        return image
    }

    /// The only metadata a converted image carries: resolution and capture time.
    /// Location, device serials, owner names and maker notes are left behind.
    static func minimalMetadata(_ source: Source) -> [CFString: Any] {
        var metadata: [CFString: Any] = [
            kCGImagePropertyDPIWidth: source.dpi,
            kCGImagePropertyDPIHeight: source.dpi,
            kCGImagePropertyOrientation: 1,
        ]
        if let exif = source.properties[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            let kept = exif.filter { [kCGImagePropertyExifDateTimeOriginal, kCGImagePropertyExifOffsetTimeOriginal].contains($0.key) }
            if !kept.isEmpty { metadata[kCGImagePropertyExifDictionary] = kept }
        }
        return metadata
    }

    // MARK: Actions

    static func convert(_ url: URL, to format: OutputFormat, writingTo destination: URL) throws {
        let source = try open(url)
        if format == .pdf {
            try writeFramesAsPDF(source, to: destination)
        } else {
            try write(orientedImage(source), as: format, to: destination, metadata: minimalMetadata(source))
        }
    }

    /// Re-encodes lossy formats at a lower quality; lossless ones become HEIC
    /// (keeps transparency) or JPEG. Returns the extension actually written.
    static func compressedFormat(for url: URL) throws -> OutputFormat {
        let source = try open(url)
        switch OutputFormat(imageType: source.type) {
        case .jpg: return .jpg
        case .heic: return .heic
        default: return try hasAlpha(orientedImage(source)) ? .heic : .jpg
        }
    }

    static func compress(_ url: URL, as format: OutputFormat, writingTo destination: URL) throws {
        let source = try open(url)
        let quality = format == .heic ? 0.55 : 0.65
        try write(orientedImage(source), as: format, to: destination, metadata: minimalMetadata(source), quality: quality)
    }

    /// The format a same-family edit is saved in: the source's own format when ImageIO
    /// can write it, PNG otherwise (e.g. WebP, AVIF).
    static func editFormat(for url: URL) throws -> OutputFormat {
        OutputFormat(imageType: try open(url).type) ?? .png
    }

    static func halve(_ url: URL, as format: OutputFormat, writingTo destination: URL) throws {
        let source = try open(url)
        let image = try orientedImage(source, longEdge: max(1, source.longEdge / 2))
        try write(image, as: format, to: destination, metadata: minimalMetadata(source))
    }

    static func rotate(_ url: URL, as format: OutputFormat, writingTo destination: URL) throws {
        let source = try open(url)
        let image = try orientedImage(source)
        guard let context = bitmapContext(width: image.height, height: image.width) else {
            throw ConversionError.failed("Could not allocate memory for the rotated image")
        }
        // Quarter turn clockwise: move the origin, then rotate by -90°.
        context.translateBy(x: 0, y: CGFloat(image.width))
        context.rotate(by: -.pi / 2)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let rotated = context.makeImage() else { throw ConversionError.failed("Could not rotate the image") }
        try write(rotated, as: format, to: destination, metadata: minimalMetadata(source))
    }

    /// Removes every metadata block (EXIF, GPS, TIFF, IPTC, XMP, maker notes). It first tries
    /// without re-encoding the pixels, then *checks the result*: ImageIO only honours the
    /// "replace metadata" request for some formats (JPEG yes; HEIC, PNG and TIFF keep
    /// everything), so anything left over means the pixels are written again with no metadata.
    static func clean(_ url: URL, writingTo destination: URL) throws {
        let source = try open(url)
        if (try? copyWithoutMetadata(source, to: destination)) == nil || !privateMetadata(at: destination).isEmpty {
            let format = OutputFormat(imageType: source.type) ?? .png
            try write(orientedImage(source), as: format, to: destination, metadata: [:], quality: 0.95)
        }
        let leftovers = privateMetadata(at: destination)
        guard leftovers.isEmpty else {
            throw ConversionError.failed("Metadata could not be removed from this file (\(leftovers.joined(separator: ", ")))")
        }
    }

    /// Lossless path: same compressed pixels, empty metadata. Orientation is the one tag kept
    /// so the photo stays upright.
    private static func copyWithoutMetadata(_ source: Source, to destination: URL) throws {
        let writable = CGImageDestinationCopyTypeIdentifiers() as? [String] ?? []
        guard writable.contains(source.type.identifier), source.frameCount == 1,
              let target = CGImageDestinationCreateWithURL(destination as CFURL, source.type.identifier as CFString, 1, nil)
        else { throw ConversionError.unsupported }
        let metadata = CGImageMetadataCreateMutable()
        if source.orientation != 1 {
            CGImageMetadataSetValueMatchingImageProperty(
                metadata, kCGImagePropertyTIFFDictionary, kCGImagePropertyOrientation, source.orientation as CFNumber)
        }
        let options: [CFString: Any] = [
            kCGImageDestinationMetadata: metadata,
            kCGImageDestinationMergeMetadata: false,
            kCGImageMetadataShouldExcludeXMP: true,
            kCGImageMetadataShouldExcludeGPS: true,
        ]
        var error: Unmanaged<CFError>?
        guard CGImageDestinationCopyImageSource(target, source.source, options as CFDictionary, &error) else {
            throw ConversionError.failed("Could not strip the metadata")
        }
    }

    /// Names of metadata blocks in a file that could identify a person, place or device.
    /// Empty means clean. Structural fields ImageIO always writes (size, colour space,
    /// orientation, resolution, tiling, compression) don't count.
    static func privateMetadata(at url: URL) -> [String] {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] else { return [] }
        let structuralExif: Set<String> = [kCGImagePropertyExifColorSpace, kCGImagePropertyExifPixelXDimension,
                                           kCGImagePropertyExifPixelYDimension, kCGImagePropertyExifVersion].map { $0 as String }.reduce(into: []) { $0.insert($1) }
        let structuralTIFF: Set<String> = [kCGImagePropertyTIFFOrientation, kCGImagePropertyTIFFXResolution, kCGImagePropertyTIFFYResolution,
                                           kCGImagePropertyTIFFResolutionUnit, kCGImagePropertyTIFFTileWidth, kCGImagePropertyTIFFTileLength,
                                           kCGImagePropertyTIFFCompression, kCGImagePropertyTIFFPhotometricInterpretation].map { $0 as String }.reduce(into: []) { $0.insert($1) }
        let exifKey = kCGImagePropertyExifDictionary as String, tiffKey = kCGImagePropertyTIFFDictionary as String
        let formatKeys: Set<String> = [kCGImagePropertyPNGDictionary, kCGImagePropertyJFIFDictionary,
                                       kCGImagePropertyHEIFDictionary, kCGImagePropertyGIFDictionary].map { $0 as String }.reduce(into: []) { $0.insert($1) }
        let pngText: Set<String> = [kCGImagePropertyPNGAuthor, kCGImagePropertyPNGComment, kCGImagePropertyPNGCopyright,
                                    kCGImagePropertyPNGDescription, kCGImagePropertyPNGSoftware, kCGImagePropertyPNGTitle].map { $0 as String }.reduce(into: []) { $0.insert($1) }
        var found: [String] = []
        for (key, value) in properties where key.hasPrefix("{") {
            let fields = Set((value as? [String: Any])?.keys.map { $0 } ?? [])
            if key == exifKey {
                if !fields.subtracting(structuralExif).isEmpty { found.append("EXIF") }
            } else if key == tiffKey {
                if !fields.subtracting(structuralTIFF).isEmpty { found.append("TIFF") }
            } else if formatKeys.contains(key) {
                // Format bookkeeping (frame delays, JFIF version…); only PNG text chunks are personal.
                if !fields.isDisjoint(with: pngText) { found.append("PNG text") }
            } else {
                found.append(key.trimmingCharacters(in: CharacterSet(charactersIn: "{}"))) // GPS, IPTC, MakerApple, ExifAux, 8BIM, …
            }
        }
        if let metadata = CGImageSourceCopyMetadataAtIndex(source, 0, nil),
           let tags = CGImageMetadataCopyTags(metadata) as? [CGImageMetadataTag] {
            let personal = tags.compactMap { CGImageMetadataTagCopyPrefix($0) as String? }.filter { !["tiff", "exif"].contains($0) }
            if !personal.isEmpty { found.append("XMP") }
        }
        return Array(Set(found)).sorted()
    }

    // MARK: Writing

    static func write(_ image: CGImage, as format: OutputFormat, to url: URL, metadata: [CFString: Any], quality: Double = 0.9) throws {
        if format == .pdf {
            try writePDF([image], dpi: metadata[kCGImagePropertyDPIWidth] as? CGFloat ?? 72, to: url)
            return
        }
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, format.utType.identifier as CFString, 1, nil) else {
            throw ConversionError.failed("\(format.title) is not supported on this Mac")
        }
        var properties = metadata
        properties[kCGImageDestinationLossyCompressionQuality] = quality
        let pixels = format.isOpaque && hasAlpha(image) ? try flattened(image) : image
        CGImageDestinationAddImage(destination, pixels, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw ConversionError.failed("Could not write the \(format.title) file")
        }
    }

    /// Every frame as a PDF page, decoded and written one at a time. The pixel budget covers
    /// all frames together, so a file with hundreds of huge frames can't exhaust memory or disk.
    private static func writeFramesAsPDF(_ source: Source, to url: URL) throws {
        var budget = maxPixels
        var box = CGRect(x: 0, y: 0, width: CGFloat(source.width) * 72 / source.dpi, height: CGFloat(source.height) * 72 / source.dpi)
        guard let context = CGContext(url as CFURL, mediaBox: &box, [kCGPDFContextCreator: "Dropwheel"] as CFDictionary) else {
            throw ConversionError.failed("Could not create the PDF")
        }
        defer { context.closePDF() }
        for index in 0..<source.frameCount {
            try Task.checkCancellation()
            let properties = CGImageSourceCopyPropertiesAtIndex(source.source, index, nil) as? [CFString: Any] ?? [:]
            let pixels = (properties[kCGImagePropertyPixelWidth] as? Int ?? source.width) * (properties[kCGImagePropertyPixelHeight] as? Int ?? source.height)
            budget -= min(pixels, source.width * source.height) // later frames are decoded at most at frame 0's size
            guard budget >= 0 else {
                throw ConversionError.tooLarge("This image has too many large frames (over \(maxPixels / 1_000_000) megapixels in total)")
            }
            try autoreleasepool {
                let frame = try orientedImage(source, index: index)
                var page = pageBox(for: frame, dpi: source.dpi)
                context.beginPage(mediaBox: &page)
                context.draw(frame, in: page)
                context.endPage()
            }
            ConversionProgress.report(Double(index + 1) / Double(source.frameCount))
        }
    }

    static func writePDF(_ images: [CGImage], dpi: CGFloat, to url: URL) throws {
        guard let first = images.first else { throw ConversionError.unreadable }
        var box = pageBox(for: first, dpi: dpi)
        guard let context = CGContext(url as CFURL, mediaBox: &box, [kCGPDFContextCreator: "Dropwheel"] as CFDictionary) else {
            throw ConversionError.failed("Could not create the PDF")
        }
        for image in images {
            var box = pageBox(for: image, dpi: dpi)
            context.beginPage(mediaBox: &box)
            context.draw(image, in: box)
            context.endPage()
        }
        context.closePDF()
    }

    private static func pageBox(for image: CGImage, dpi: CGFloat) -> CGRect {
        CGRect(x: 0, y: 0, width: CGFloat(image.width) * 72 / dpi, height: CGFloat(image.height) * 72 / dpi)
    }

    static func hasAlpha(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: false
        default: true
        }
    }

    /// Composites onto white, for formats that would otherwise turn transparency black.
    private static func flattened(_ image: CGImage) throws -> CGImage {
        guard let context = bitmapContext(width: image.width, height: image.height) else {
            throw ConversionError.failed("Could not allocate memory for the image")
        }
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(rect)
        context.draw(image, in: rect)
        guard let result = context.makeImage() else { throw ConversionError.failed("Could not flatten the image") }
        return result
    }

    static func bitmapContext(width: Int, height: Int) -> CGContext? {
        CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }
}

/// Lists metadata in an image that could identify a person, place or device (empty = clean).
public enum MetadataCheck {
    public static func privateFields(in url: URL) -> [String] {
        ImageEngine.privateMetadata(at: url)
    }
}
