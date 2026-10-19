import CoreGraphics
import Foundation

/// An sRGB colour with components in 0...1.
public struct RGBA: Sendable, Hashable {
    public var red, green, blue, alpha: Double

    public init(_ red: Double, _ green: Double, _ blue: Double, _ alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    /// `RGBA(hex: 0xFF6A3D)`
    public init(hex: UInt32) {
        self.init(Double((hex >> 16) & 0xFF) / 255, Double((hex >> 8) & 0xFF) / 255, Double(hex & 0xFF) / 255)
    }

    var cgColor: CGColor { CGColor(srgbRed: red, green: green, blue: blue, alpha: alpha) }
}

/// The canvas an image is placed on by "Add BG". Lengths are in the source image's pixels.
public struct CanvasStyle: Sendable, Equatable {
    public enum Fill: Sendable, Hashable {
        case solid(RGBA)
        /// Colours run along `angle` degrees (0 = left to right, 90 = top to bottom).
        case gradient([RGBA], angle: Double)
    }

    public enum Ratio: String, Sendable, CaseIterable {
        case auto = "Auto", square = "1:1", wide = "16:9", portrait = "4:5"

        var value: Double? {
            switch self {
            case .auto: nil
            case .square: 1
            case .wide: 16.0 / 9
            case .portrait: 4.0 / 5
            }
        }
    }

    public var fill: Fill
    public var padding: Double
    public var cornerRadius: Double
    public var shadow: Double
    public var ratio: Ratio

    public init(fill: Fill, padding: Double, cornerRadius: Double, shadow: Double, ratio: Ratio = .auto) {
        self.fill = fill
        self.padding = padding
        self.cornerRadius = cornerRadius
        self.shadow = shadow
        self.ratio = ratio
    }

    /// Defaults that look right at any resolution, scaled from the image's long edge.
    public static func defaults(for size: CGSize, fill: Fill) -> CanvasStyle {
        let edge = Double(max(size.width, size.height))
        return CanvasStyle(fill: fill, padding: (edge * 0.08).rounded(), cornerRadius: (edge * 0.025).rounded(), shadow: (edge * 0.02).rounded())
    }
}

public enum ImageEditing {
    /// The image as displayed (EXIF orientation applied), downscaled for on-screen editing,
    /// plus the full-resolution oriented size that edits are expressed in.
    public static func preview(_ url: URL, maxEdge: Int) throws -> (image: CGImage, fullSize: CGSize) {
        let source = try ImageEngine.open(url)
        let image = try ImageEngine.orientedImage(source, longEdge: min(maxEdge, source.longEdge))
        let quarterTurned = (5...8).contains(source.orientation)
        let full = quarterTurned ? CGSize(width: source.height, height: source.width) : CGSize(width: source.width, height: source.height)
        return (image, full)
    }

    /// Clamps a pixel rectangle (top-left origin) to the image and to whole pixels.
    public static func clampedCrop(_ rect: CGRect, in size: CGSize) -> CGRect {
        let bounds = CGRect(origin: .zero, size: size)
        let clipped = rect.integral.intersection(bounds)
        return clipped.isNull || clipped.width < 1 || clipped.height < 1 ? bounds : clipped
    }

    static func crop(_ url: URL, to rect: CGRect, as format: OutputFormat, writingTo destination: URL) throws {
        let source = try ImageEngine.open(url)
        let image = try ImageEngine.orientedImage(source)
        let area = clampedCrop(rect, in: CGSize(width: image.width, height: image.height))
        guard let cropped = image.cropping(to: area) else { throw ConversionError.failed("Could not crop the image") }
        try ImageEngine.write(cropped, as: format, to: destination, metadata: ImageEngine.minimalMetadata(source))
    }

    static func addBackground(_ url: URL, style: CanvasStyle, writingTo destination: URL) throws {
        let source = try ImageEngine.open(url)
        let image = try ImageEngine.orientedImage(source)
        try ImageEngine.write(render(image, style: style), as: .png, to: destination, metadata: ImageEngine.minimalMetadata(source))
    }

    /// Composites `image` onto the styled canvas. `scale` shrinks the style's pixel lengths
    /// for a downscaled preview, so the preview matches the saved file.
    public static func render(_ image: CGImage, style: CanvasStyle, scale: Double = 1) throws -> CGImage {
        let width = Double(image.width), height = Double(image.height)
        let padding = max(0, style.padding * scale)
        var canvas = CGSize(width: width + padding * 2, height: height + padding * 2)
        if let ratio = style.ratio.value {
            if canvas.width / canvas.height < ratio {
                canvas.width = canvas.height * ratio
            } else {
                canvas.height = canvas.width / ratio
            }
        }
        let pixels = Int(canvas.width.rounded()) * Int(canvas.height.rounded())
        guard pixels <= ImageEngine.maxPixels else {
            throw ConversionError.tooLarge("The result would be larger than \(ImageEngine.maxPixels / 1_000_000) megapixels")
        }
        guard let context = ImageEngine.bitmapContext(width: Int(canvas.width.rounded()), height: Int(canvas.height.rounded())) else {
            throw ConversionError.failed("Could not allocate memory for the image")
        }
        let bounds = CGRect(x: 0, y: 0, width: context.width, height: context.height)
        drawFill(style.fill, in: bounds, context: context)

        let frame = CGRect(x: ((bounds.width - width) / 2).rounded(), y: ((bounds.height - height) / 2).rounded(), width: width, height: height)
        let radius = min(max(0, style.cornerRadius * scale), min(width, height) / 2)
        let shape = CGPath(roundedRect: frame, cornerWidth: radius, cornerHeight: radius, transform: nil)
        let shadow = max(0, style.shadow * scale)
        if shadow > 0 {
            context.saveGState()
            context.setShadow(offset: CGSize(width: 0, height: -shadow * 0.45), blur: shadow * 1.6, color: CGColor(gray: 0, alpha: 0.38))
            context.addPath(shape)
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fillPath()
            context.restoreGState()
        }
        context.saveGState()
        context.addPath(shape)
        context.clip()
        context.draw(image, in: frame)
        context.restoreGState()

        guard let result = context.makeImage() else { throw ConversionError.failed("Could not render the image") }
        return result
    }

    private static func drawFill(_ fill: CanvasStyle.Fill, in bounds: CGRect, context: CGContext) {
        switch fill {
        case .solid(let color):
            context.setFillColor(color.cgColor)
            context.fill(bounds)
        case .gradient(let colors, let angle):
            guard colors.count > 1,
                  let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors.map(\.cgColor) as CFArray, locations: nil)
            else {
                context.setFillColor((colors.first ?? RGBA(1, 1, 1)).cgColor)
                context.fill(bounds)
                return
            }
            // Bitmap contexts are y-up; flip so 90° runs top to bottom as documented.
            let radians = angle * .pi / 180
            let direction = CGVector(dx: cos(radians), dy: -sin(radians))
            let length = abs(bounds.width * direction.dx) + abs(bounds.height * direction.dy)
            let center = CGPoint(x: bounds.midX, y: bounds.midY)
            let start = CGPoint(x: center.x - direction.dx * length / 2, y: center.y - direction.dy * length / 2)
            let end = CGPoint(x: center.x + direction.dx * length / 2, y: center.y + direction.dy * length / 2)
            context.drawLinearGradient(gradient, start: start, end: end, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        }
    }
}

extension Converter {
    /// Saves the `rect` (pixels, top-left origin, orientation applied) as "Name cropped.ext".
    @concurrent
    public func crop(_ source: URL, to rect: CGRect, into directory: URL) async throws -> URL {
        let format = try ImageEngine.editFormat(for: source)
        return try produce(source, directory, suffix: Tool.crop.suffix, ext: format.fileExtension) {
            try ImageEditing.crop(source, to: rect, as: format, writingTo: $0)
        }
    }

    /// Saves the image on a styled canvas as "Name with background.png".
    @concurrent
    public func addBackground(_ source: URL, style: CanvasStyle, into directory: URL) async throws -> URL {
        try produce(source, directory, suffix: Tool.background.suffix, ext: "png") {
            try ImageEditing.addBackground(source, style: style, writingTo: $0)
        }
    }
}
