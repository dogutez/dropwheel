import CoreGraphics
import ImageIO
import Foundation
import Testing
@testable import DropwheelCore

struct WheelGeometryTests {
    let wheel = WheelGeometry(center: .zero, innerRadius: 50, outerRadius: 150, count: 4)

    @Test(arguments: [
        (CGPoint(x: 0, y: 100), WheelGeometry.Hit.segment(0)),   // top
        (CGPoint(x: 100, y: 0), .segment(1)),                    // right
        (CGPoint(x: 0, y: -100), .segment(2)),                   // bottom
        (CGPoint(x: -100, y: 0), .segment(3)),                   // left
        (CGPoint(x: -20, y: 95), .segment(0)),                   // just left of top still wraps to 0
        (CGPoint(x: 10, y: 10), .center),
        (CGPoint(x: 200, y: 0), .outside),
    ])
    func `maps points clockwise from the top`(point: CGPoint, expected: WheelGeometry.Hit) {
        #expect(wheel.hit(point) == expected)
    }

    @Test func `every angle lands in a valid segment`() {
        let seven = WheelGeometry(center: .zero, innerRadius: 50, outerRadius: 150, count: 7)
        for degree in stride(from: 0.0, to: 360.0, by: 0.5) {
            let radians = degree * .pi / 180
            let hit = seven.hit(CGPoint(x: 100 * sin(radians), y: 100 * cos(radians)))
            guard case .segment(let index) = hit else { Issue.record("no segment at \(degree)°"); continue }
            #expect((0..<7).contains(index))
        }
    }
}

struct CatalogTests {
    @Test func `the source format is never offered`() {
        #expect(!Catalog.conversions(for: .image, sourceExtension: "JPEG").contains(.jpg))
        #expect(!Catalog.conversions(for: .document, sourceExtension: "docx").contains(.docx))
        #expect(Catalog.conversions(for: .image, sourceExtension: "webp").contains(.png))
    }

    @Test(arguments: [
        ("photo.HEIC", FileKind.image), ("scan.pdf", .pdf), ("notes.md", .document),
        ("letter.docx", .document), ("clip.mov", .video), ("song.mp3", .audio),
    ])
    func `kinds come from the file type`(name: String, kind: FileKind) {
        #expect(FileKind(url: URL(fileURLWithPath: "/tmp/\(name)")) == kind)
    }

    @Test func `html is never imported, svg goes to the vector renderer`() {
        #expect(FileKind(url: URL(fileURLWithPath: "/tmp/page.html")) == nil)
        #expect(FileKind(url: URL(fileURLWithPath: "/tmp/logo.svg")) == .vector)
        #expect(FileKind(url: URL(fileURLWithPath: "/tmp/talk.vtt")) == .subtitle)
        #expect(FileKind(url: URL(fileURLWithPath: "/tmp/data.csv")) == .table)
        #expect(FileKind(url: URL(fileURLWithPath: "/tmp/Folder", isDirectory: true)) == nil)
        #expect(FileKind(url: URL(fileURLWithPath: "/tmp/Secret Project.csv", isDirectory: true)) == nil)
    }

    @Test func `merge is offered only for several files`() {
        #expect(!Catalog.tools(for: .pdf, count: 1).contains(.merge))
        #expect(Catalog.tools(for: .pdf, count: 3).contains(.merge))
    }
}

struct OutputTests {
    @Test func `names follow Finder's numbering`() {
        #expect(Output.candidateName(base: "Page 001", ext: "jpg", attempt: 0) == "Page 001.jpg")
        #expect(Output.candidateName(base: "Page 001", ext: "jpg", attempt: 1) == "Page 001 2.jpg")
        #expect(Output.candidateName(base: "Page 001 (PNG)", ext: nil, attempt: 2) == "Page 001 (PNG) 3")
    }

    @Test func `commit never overwrites an existing file`() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("a.png")
        let existing = directory.appendingPathComponent("a.jpg")
        try Data("keep me".utf8).write(to: existing)

        let temp = Output.temporaryURL(in: directory, ext: "jpg")
        try Data("new".utf8).write(to: temp)
        let result = try Output.commit(temp, in: directory, base: "a", ext: "jpg", source: source)

        #expect(result.lastPathComponent == "a 2.jpg")
        #expect(try String(contentsOf: existing, encoding: .utf8) == "keep me")
        #expect(!FileManager.default.fileExists(atPath: temp.path))
    }
}

struct ImageEditingTests {
    func image(width: Int, height: Int) throws -> CGImage {
        let context = try #require(ImageEngine.bitmapContext(width: width, height: height))
        return try #require(context.makeImage())
    }

    @Test func `padding surrounds the image and a ratio widens the canvas`() throws {
        let photo = try image(width: 400, height: 200)
        let auto = CanvasStyle(fill: .solid(RGBA(1, 1, 1)), padding: 50, cornerRadius: 20, shadow: 10)
        let padded = try ImageEditing.render(photo, style: auto)
        #expect(padded.width == 500 && padded.height == 300)

        var square = auto
        square.ratio = .square
        let squared = try ImageEditing.render(photo, style: square)
        #expect(squared.width == 500 && squared.height == 500)
    }

    @Test func `preview scale shrinks the style with the image`() throws {
        let preview = try image(width: 200, height: 100)
        let style = CanvasStyle(fill: .gradient([RGBA(hex: 0xFF0000), RGBA(hex: 0x0000FF)], angle: 45), padding: 100, cornerRadius: 0, shadow: 0)
        let rendered = try ImageEditing.render(preview, style: style, scale: 0.5)
        #expect(rendered.width == 300 && rendered.height == 200)
    }

    @Test func `crop rectangles are clamped to the image`() {
        let size = CGSize(width: 100, height: 80)
        #expect(ImageEditing.clampedCrop(CGRect(x: 90, y: -10, width: 40, height: 30), in: size) == CGRect(x: 90, y: 0, width: 10, height: 20))
        #expect(ImageEditing.clampedCrop(CGRect(x: 500, y: 500, width: 10, height: 10), in: size) == CGRect(origin: .zero, size: size))
    }
}

struct TextFormatTests {
    @Test func `quoted fields keep delimiters, quotes and line breaks`() {
        let rows = TextFormats.parseDelimited("a,\"b, c\",\"say \"\"hi\"\"\"\r\n1,\"x\ny\",3\r\n", delimiter: ",")
        #expect(rows == [["a", "b, c", "say \"hi\""], ["1", "x\ny", "3"]])
    }

    @Test func `subtitle formatting tags survive, other tags do not`() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("a.vtt")
        try Data("WEBVTT\n\n00:01.000 --> 00:02.500 align:start\n<v Anna>Hi <i>there</i>\n".utf8).write(to: source)
        let output = directory.appendingPathComponent("a.srt")
        try TextFormats.convertSubtitles(source, to: .srt, writingTo: output)
        #expect(try String(contentsOf: output, encoding: .utf8) == "1\n00:00:01,000 --> 00:00:02,500\nHi <i>there</i>\n")
    }
}

struct MetadataCleaningTests {
    /// A photo carrying everything that identifies a person, place or device.
    func taggedPhoto(_ format: OutputFormat, in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent("tagged.\(format.fileExtension)")
        let context = try #require(ImageEngine.bitmapContext(width: 64, height: 48))
        let image = try #require(context.makeImage())
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, format.utType.identifier as CFString, 1, nil))
        let metadata = CGImageMetadataCreateMutable()
        CGImageMetadataSetValueWithPath(metadata, nil, "dc:creator" as CFString, "Jane Doe" as CFString)
        let properties: [CFString: Any] = [
            kCGImagePropertyOrientation: 6,
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 41.0, kCGImagePropertyGPSLatitudeRef: "N",
                                            kCGImagePropertyGPSLongitude: 29.0, kCGImagePropertyGPSLongitudeRef: "E"],
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifBodySerialNumber: "SN-1", kCGImagePropertyExifCameraOwnerName: "Jane"],
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFArtist: "Jane", kCGImagePropertyTIFFHostComputer: "Janes-Mac"],
            kCGImagePropertyIPTCDictionary: [kCGImagePropertyIPTCByline: ["Jane"], kCGImagePropertyIPTCCity: "Istanbul"],
        ]
        CGImageDestinationAddImageAndMetadata(destination, image, metadata, properties as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        return url
    }

    @Test(arguments: [OutputFormat.jpg, .png, .heic, .tiff])
    func `the Metadata tool leaves nothing personal`(format: OutputFormat) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try taggedPhoto(format, in: directory)
        #expect(!MetadataCheck.privateFields(in: source).isEmpty, "the fixture must start out tagged")

        let output = directory.appendingPathComponent("clean.\(format.fileExtension)")
        try ImageEngine.clean(source, writingTo: output)
        #expect(MetadataCheck.privateFields(in: output) == [])
        let bytes = try String(decoding: Data(contentsOf: output), as: UTF8.self)
        #expect(!bytes.contains("Jane") && !bytes.contains("SN-1") && !bytes.contains("Istanbul"))
    }
}

struct HousekeepingTests {
    @Test func `temp files left by a crash are swept, finished ones are not tracked`() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let abandoned = Output.temporaryURL(in: directory, ext: "png")
        try Data("half".utf8).write(to: abandoned)
        let finished = Output.temporaryURL(in: directory, ext: "png")
        try Data("done".utf8).write(to: finished)
        let result = try Output.commit(finished, in: directory, base: "photo", ext: "png", source: directory.appendingPathComponent("photo.jpg"))

        Housekeeping.sweepAbandonedFiles()
        #expect(!FileManager.default.fileExists(atPath: abandoned.path))
        #expect(FileManager.default.fileExists(atPath: result.path))
    }
}
