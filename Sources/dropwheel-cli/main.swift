import Foundation
import ImageIO
import DropwheelCore

// Headless driver for the conversion engine:
//   dropwheel-cli list <file>                     what the wheel would offer
//   dropwheel-cli run <action> <file> [out-dir]   action = jpg, png, pdf, docx, ..., compress, clean, half, rotate
//   dropwheel-cli crop x,y,w,h <image>            crop (pixels, top-left origin)
//   dropwheel-cli background <image>              default "Add BG" style
//   dropwheel-cli edit rotate|flip|warm|half <image>
//   dropwheel-cli redact x,y,w,h <image>          normalised rect, black box
//   dropwheel-cli annotate <image>                sample arrow, box and text
//   dropwheel-cli pixel x,y <image>               RGBA at a pixel (top-left origin)
//   dropwheel-cli mean <image>                    average RGB
//   dropwheel-cli merge <out-dir> <file> <file> ...  PDFs/images into one PDF
//   dropwheel-cli inspect <image>                 metadata ImageIO sees (for privacy checks)

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first, arguments.count >= 2 else {
    fail("usage: dropwheel-cli list|run|inspect ...")
}

switch command {
case "list":
    let url = URL(fileURLWithPath: arguments[1])
    guard let kind = FileKind(url: url) else { fail("unsupported file") }
    print("kind:", kind.rawValue)
    print("convert:", Catalog.conversions(for: kind, sourceExtension: url.pathExtension).map(\.title).joined(separator: " "))
    print("tools:", Catalog.tools(for: kind).map(\.title).joined(separator: ", "))

case "run":
    guard arguments.count >= 3, let action = Action(argument: arguments[1]) else { fail("usage: dropwheel-cli run <action> <file> [out-dir]") }
    let source = URL(fileURLWithPath: arguments[2])
    let directory = arguments.count > 3 ? URL(fileURLWithPath: arguments[3]) : source.deletingLastPathComponent()
    // Progress goes to stderr; DROPWHEEL_CANCEL_AFTER=<seconds> cancels mid-way (for testing).
    let job = Task {
        try await ConversionProgress.$handler.withValue({ fraction in
            FileHandle.standardError.write(Data("progress \(Int(fraction * 100))%\n".utf8))
        }) {
            try await Converter().run(action, source: source, into: directory)
        }
    }
    if let delay = ProcessInfo.processInfo.environment["DROPWHEEL_CANCEL_AFTER"].flatMap(Double.init) {
        try? await Task.sleep(for: .seconds(delay))
        job.cancel()
    }
    do {
        for output in try await job.value { print(output.path) }
    } catch is CancellationError {
        fail("cancelled")
    } catch {
        fail("error: \(error.localizedDescription)")
    }

case "crop":
    let numbers = arguments[1].split(separator: ",").compactMap { Double($0) }
    guard numbers.count == 4, arguments.count >= 3 else { fail("usage: dropwheel-cli crop x,y,w,h <image>") }
    let source = URL(fileURLWithPath: arguments[2])
    do {
        let rect = CGRect(x: numbers[0], y: numbers[1], width: numbers[2], height: numbers[3])
        print(try await Converter().crop(source, to: rect, into: source.deletingLastPathComponent()).path)
    } catch {
        fail("error: \(error.localizedDescription)")
    }

case "background":
    let source = URL(fileURLWithPath: arguments[1])
    do {
        let size = try ImageEditing.preview(source, maxEdge: 64).fullSize
        let style = CanvasStyle.defaults(for: size, fill: .gradient([RGBA(hex: 0xFFB347), RGBA(hex: 0xF2545B), RGBA(hex: 0xB83280)], angle: 45))
        print(try await Converter().addBackground(source, style: style, into: source.deletingLastPathComponent()).path)
    } catch {
        fail("error: \(error.localizedDescription)")
    }

case "edit":
    guard arguments.count >= 3 else { fail("usage: dropwheel-cli edit rotate|flip|warm|half <image>") }
    var adjustments = Adjustments()
    switch arguments[1] {
    case "rotate": adjustments.rotate(clockwise: true)
    case "flip": adjustments.flipHorizontal = true
    case "warm": adjustments.warmth = 1
    case "half": adjustments.scale = 0.5
    default: fail("unknown edit")
    }
    let source = URL(fileURLWithPath: arguments[2])
    do { print(try await Converter().edit(source, with: adjustments, into: source.deletingLastPathComponent()).path) } catch { fail("error: \(error.localizedDescription)") }

case "redact":
    let numbers = arguments[1].split(separator: ",").compactMap { Double($0) }
    guard numbers.count == 4, arguments.count >= 3 else { fail("usage: dropwheel-cli redact x,y,w,h <image>") }
    let source = URL(fileURLWithPath: arguments[2])
    let area = Redaction(rect: CGRect(x: numbers[0], y: numbers[1], width: numbers[2], height: numbers[3]), style: .block)
    do { print(try await Converter().redact(source, with: [area], into: source.deletingLastPathComponent()).path) } catch { fail("error: \(error.localizedDescription)") }

case "annotate":
    let source = URL(fileURLWithPath: arguments[1])
    let red = RGBA(hex: 0xF2545B)
    let marks = [
        Annotation(shape: .arrow(from: CGPoint(x: 0.2, y: 0.8), to: CGPoint(x: 0.6, y: 0.4)), color: red, width: 0.01),
        Annotation(shape: .rectangle(CGRect(x: 0.55, y: 0.1, width: 0.35, height: 0.2)), color: red, width: 0.008),
        Annotation(shape: .text("Hello Dropwheel", at: CGPoint(x: 0.1, y: 0.05)), color: RGBA(1, 1, 1), width: 0.01),
    ]
    do { print(try await Converter().annotate(source, with: marks, into: source.deletingLastPathComponent()).path) } catch { fail("error: \(error.localizedDescription)") }

case "pixel", "mean":
    let url = URL(fileURLWithPath: arguments[command == "pixel" ? 2 : 1])
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
          let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
          let data = context.data else { fail("not an image") }
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    let bytes = data.assumingMemoryBound(to: UInt8.self)
    if command == "pixel" {
        let xy = arguments[1].split(separator: ",").compactMap { Int($0) }
        let offset = (xy[1] * image.width + xy[0]) * 4  // bitmap memory rows run top to bottom
        print("size \(image.width)x\(image.height) rgba", (0..<4).map { bytes[offset + $0] })
    } else {
        var sums = [0.0, 0.0, 0.0]
        for i in 0..<(image.width * image.height) { for c in 0..<3 { sums[c] += Double(bytes[i * 4 + c]) } }
        print("mean rgb", sums.map { Int($0 / Double(image.width * image.height)) })
    }

case "merge":
    guard arguments.count >= 4 else { fail("usage: dropwheel-cli merge <out-dir> <file> <file> ...") }
    do {
        print(try await Converter().merge(arguments[2...].map { URL(fileURLWithPath: $0) }, into: URL(fileURLWithPath: arguments[1])).path)
    } catch {
        fail("error: \(error.localizedDescription)")
    }

case "privacy":
    let fields = MetadataCheck.privateFields(in: URL(fileURLWithPath: arguments[1]))
    print(fields.isEmpty ? "clean" : "private metadata: " + fields.joined(separator: ", "))

case "inspect":
    let url = URL(fileURLWithPath: arguments[1])
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] else { fail("not an image") }
    for key in properties.keys.sorted() {
        print(key, "=", properties[key].map { "\($0)" }?.replacingOccurrences(of: "\n", with: " ") ?? "")
    }

default:
    fail("unknown command \(command)")
}
