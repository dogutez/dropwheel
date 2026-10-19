import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import Vision

/// Colour and geometry changes made in the Edit window.
public struct Adjustments: Sendable, Equatable {
    /// -2...2 stops.
    public var exposure: Double = 0
    /// 0.5...1.5, 1 = unchanged.
    public var contrast: Double = 1
    /// 0...2, 1 = unchanged.
    public var saturation: Double = 1
    /// -1 (cooler)...1 (warmer).
    public var warmth: Double = 0
    /// 0...1.
    public var sharpness: Double = 0
    /// Quarter turns clockwise, applied before the flips.
    public var quarterTurns = 0
    public var flipHorizontal = false
    public var flipVertical = false
    /// 0.1...1 of the original size.
    public var scale: Double = 1

    public init() {}

    public var isIdentity: Bool { self == Adjustments() }

    /// Rotating a flipped image equals flipping the other axis of a rotated image,
    /// so a turn swaps the flips and the stored order (rotate, then flip) stays valid.
    public mutating func rotate(clockwise: Bool) {
        quarterTurns = (quarterTurns + (clockwise ? 1 : 3)) % 4
        swap(&flipHorizontal, &flipVertical)
    }

    /// Pixel size after rotation and scaling.
    public func outputSize(for size: CGSize) -> CGSize {
        let turned = quarterTurns % 2 == 1 ? CGSize(width: size.height, height: size.width) : size
        return CGSize(width: (turned.width * scale).rounded(), height: (turned.height * scale).rounded())
    }
}

/// A mark drawn in the Annotate window. Positions are normalised to the image
/// (0...1, top-left origin); widths and text sizes are fractions of the image's long edge.
public struct Annotation: Sendable, Equatable {
    public enum Shape: Sendable, Equatable {
        case pen([CGPoint])
        case arrow(from: CGPoint, to: CGPoint)
        case rectangle(CGRect)
        case ellipse(CGRect)
        case text(String, at: CGPoint)
    }

    public var shape: Shape
    public var color: RGBA
    public var width: Double

    public init(shape: Shape, color: RGBA, width: Double) {
        self.shape = shape
        self.color = color
        self.width = width
    }

    /// Text is set at this multiple of the stroke width.
    public static let textScale = 6.0

    /// The two outer corners of an arrowhead whose tip is `to`, in the same units as the inputs.
    public static func arrowHead(from: CGPoint, to: CGPoint, lineWidth: CGFloat) -> (CGPoint, CGPoint) {
        let angle = atan2(to.y - from.y, to.x - from.x)
        let length = max(lineWidth * 4.5, 10)
        let spread = 0.45
        return (CGPoint(x: to.x - length * cos(angle - spread), y: to.y - length * sin(angle - spread)),
                CGPoint(x: to.x - length * cos(angle + spread), y: to.y - length * sin(angle + spread)))
    }
}

/// An area hidden in the Redact window (normalised, top-left origin).
public struct Redaction: Sendable, Equatable {
    public enum Style: String, Sendable, CaseIterable {
        case block = "Black Box", pixelate = "Pixelate (weaker)"
    }

    public var rect: CGRect
    public var style: Style

    public init(rect: CGRect, style: Style) {
        self.rect = rect
        self.style = style
    }
}

extension ImageEditing {
    private static let ciContext = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, .cacheIntermediates: false])

    // MARK: Remove background

    /// The photo's subject (all of them, if there are several) on a transparent background.
    /// Uses Vision's foreground-instance model, the one behind "Lift subject" in Photos; it runs
    /// on this Mac. `cropToSubject` trims the transparent margin around the subject.
    public static func liftSubject(_ image: CGImage, cropToSubject: Bool = false) throws -> CGImage {
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: image)
        do {
            try handler.perform([request])
        } catch {
            throw ConversionError.failed("Background removal isn't available on this Mac")
        }
        guard let observation = request.results?.first, !observation.allInstances.isEmpty else {
            throw ConversionError.failed("No subject found to keep: this works on photos of people, animals and objects")
        }
        let buffer = try observation.generateMaskedImage(ofInstances: observation.allInstances, from: handler, croppedToInstancesExtent: cropToSubject)
        let cutout = CIImage(cvPixelBuffer: buffer)
        guard let output = ciContext.createCGImage(cutout, from: cutout.extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)) else {
            throw ConversionError.failed("Could not create the cut-out")
        }
        return output
    }

    // MARK: Edit

    public static func adjust(_ image: CGImage, _ adjustments: Adjustments) throws -> CGImage {
        guard !adjustments.isIdentity else { return image }
        var result = CIImage(cgImage: image)
        // .right shows the image turned 90° clockwise.
        let turns: [CGImagePropertyOrientation] = [.up, .right, .down, .left]
        result = result.oriented(turns[adjustments.quarterTurns % 4])
        if adjustments.flipHorizontal { result = result.oriented(.upMirrored) }
        if adjustments.flipVertical { result = result.oriented(.downMirrored) }

        if adjustments.exposure != 0 {
            let filter = CIFilter.exposureAdjust()
            filter.inputImage = result
            filter.ev = Float(adjustments.exposure)
            result = filter.outputImage ?? result
        }
        if adjustments.contrast != 1 || adjustments.saturation != 1 {
            let filter = CIFilter.colorControls()
            filter.inputImage = result
            filter.contrast = Float(adjustments.contrast)
            filter.saturation = Float(adjustments.saturation)
            result = filter.outputImage ?? result
        }
        if adjustments.warmth != 0 {
            let filter = CIFilter.temperatureAndTint()
            filter.inputImage = result
            filter.neutral = CIVector(x: 6500, y: 0)
            filter.targetNeutral = CIVector(x: 6500 - adjustments.warmth * 2500, y: 0)
            result = filter.outputImage ?? result
        }
        if adjustments.sharpness > 0 {
            let filter = CIFilter.sharpenLuminance()
            filter.inputImage = result
            filter.sharpness = Float(adjustments.sharpness)
            filter.radius = Float(max(1.5, Double(max(image.width, image.height)) / 1500))
            result = filter.outputImage ?? result
        }
        if adjustments.scale < 1 {
            let filter = CIFilter.lanczosScaleTransform()
            filter.inputImage = result
            filter.scale = Float(adjustments.scale)
            filter.aspectRatio = 1
            result = filter.outputImage ?? result
        }
        let size = adjustments.outputSize(for: CGSize(width: image.width, height: image.height))
        let extent = CGRect(origin: result.extent.origin, size: size)
        guard let output = ciContext.createCGImage(result, from: extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)) else {
            throw ConversionError.failed("Could not apply the edits")
        }
        return output
    }

    // MARK: Annotate

    public static func annotate(_ image: CGImage, _ annotations: [Annotation]) throws -> CGImage {
        let width = CGFloat(image.width), height = CGFloat(image.height)
        guard let context = ImageEngine.bitmapContext(width: image.width, height: image.height) else {
            throw ConversionError.failed("Could not allocate memory for the image")
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        // Annotations are top-left based: flip once, then draw in image pixels.
        context.translateBy(x: 0, y: height)
        context.scaleBy(x: 1, y: -1)
        let longEdge = max(width, height)
        func point(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x * width, y: p.y * height) }
        func rect(_ r: CGRect) -> CGRect { CGRect(x: r.minX * width, y: r.minY * height, width: r.width * width, height: r.height * height) }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        for annotation in annotations {
            let lineWidth = annotation.width * longEdge
            context.setStrokeColor(annotation.color.cgColor)
            context.setFillColor(annotation.color.cgColor)
            context.setLineWidth(lineWidth)
            context.setLineCap(.round)
            context.setLineJoin(.round)
            switch annotation.shape {
            case .pen(let points):
                guard let first = points.first else { continue }
                context.move(to: point(first))
                for p in points.dropFirst() { context.addLine(to: point(p)) }
                if points.count == 1 { context.addLine(to: point(first)) }
                context.strokePath()
            case .arrow(let from, let to):
                let start = point(from), tip = point(to)
                let (left, right) = Annotation.arrowHead(from: start, to: tip, lineWidth: lineWidth)
                let base = CGPoint(x: (left.x + right.x) / 2, y: (left.y + right.y) / 2)
                context.move(to: start)
                context.addLine(to: base)
                context.strokePath()
                context.move(to: tip)
                context.addLine(to: left)
                context.addLine(to: right)
                context.closePath()
                context.drawPath(using: .fillStroke)
            case .rectangle(let r):
                context.stroke(rect(r))
            case .ellipse(let r):
                context.strokeEllipse(in: rect(r))
            case .text(let string, let at):
                let font = NSFont.systemFont(ofSize: lineWidth * Annotation.textScale, weight: .bold)
                let text = NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: NSColor(cgColor: annotation.color.cgColor) ?? .red])
                text.draw(at: point(at))
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        guard let output = context.makeImage() else { throw ConversionError.failed("Could not draw the annotations") }
        return output
    }

    // MARK: Redact

    /// Destroys the pixels under each area: the result is a new bitmap, there is no layer
    /// to remove later. Black boxes remove the content outright; pixelation only obscures
    /// it (pixelated text can sometimes be reconstructed), so it is the weaker option.
    public static func redact(_ image: CGImage, _ redactions: [Redaction]) throws -> CGImage {
        let width = CGFloat(image.width), height = CGFloat(image.height)
        guard let context = ImageEngine.bitmapContext(width: image.width, height: image.height) else {
            throw ConversionError.failed("Could not allocate memory for the image")
        }
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        context.draw(image, in: bounds)

        var pixelated: CGImage?
        if redactions.contains(where: { $0.style == .pixelate }) {
            let filter = CIFilter.pixellate()
            filter.inputImage = CIImage(cgImage: image).clampedToExtent()
            filter.scale = Float(max(12, max(width, height) / 45))
            filter.center = .zero
            pixelated = filter.outputImage.flatMap { ciContext.createCGImage($0, from: bounds) }
        }
        for redaction in redactions {
            // Normalised top-left rect → bitmap (y-up) rect.
            let r = redaction.rect
            let area = CGRect(x: r.minX * width, y: (1 - r.maxY) * height, width: r.width * width, height: r.height * height).integral
            switch redaction.style {
            case .block:
                context.setFillColor(CGColor(gray: 0, alpha: 1))
                context.fill(area)
            case .pixelate:
                guard let pixelated else { throw ConversionError.failed("Could not pixelate the image") }
                context.saveGState()
                context.clip(to: area)
                context.draw(pixelated, in: bounds)
                context.restoreGState()
            }
        }
        guard let output = context.makeImage() else { throw ConversionError.failed("Could not redact the image") }
        return output
    }
}

extension Converter {
    @concurrent
    public func edit(_ source: URL, with adjustments: Adjustments, into directory: URL) async throws -> URL {
        try saveImage(source, tool: .edit, into: directory) { try ImageEditing.adjust($0, adjustments) }
    }

    @concurrent
    public func annotate(_ source: URL, with annotations: [Annotation], into directory: URL) async throws -> URL {
        try saveImage(source, tool: .annotate, into: directory) { try ImageEditing.annotate($0, annotations) }
    }

    /// Redacted copies also lose every metadata field, capture date included.
    @concurrent
    public func redact(_ source: URL, with redactions: [Redaction], into directory: URL) async throws -> URL {
        try saveImage(source, tool: .redact, keepMetadata: false, into: directory) { try ImageEditing.redact($0, redactions) }
    }

    /// The subject on a transparent background, as "Name no background.png".
    @concurrent
    public func removeBackground(_ source: URL, into directory: URL) async throws -> URL {
        try await LocalCopy.prepare(source)
        return try saveImage(source, tool: .removeBackground, format: .png, into: directory) { try ImageEditing.liftSubject($0) }
    }

    private func saveImage(_ source: URL, tool: Tool, format fixedFormat: OutputFormat? = nil, keepMetadata: Bool = true, into directory: URL, _ transform: (CGImage) throws -> CGImage) throws -> URL {
        let format = try fixedFormat ?? ImageEngine.editFormat(for: source)
        return try produce(source, directory, suffix: tool.suffix, ext: format.fileExtension) { destination in
            let image = try ImageEngine.open(source)
            let result = try transform(ImageEngine.orientedImage(image))
            let metadata = keepMetadata ? ImageEngine.minimalMetadata(image) : [kCGImagePropertyOrientation: 1]
            try ImageEngine.write(result, as: format, to: destination, metadata: metadata)
        }
    }
}
