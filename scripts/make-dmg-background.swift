// Draws the DMG window background: a light wash, "Drag Dropwheel into Applications", an arrow
// between the two icons, and a first-launch hint. Light on purpose: Finder draws icon labels in
// black. Coordinates match scripts/dmg-settings.py (660 × 400 window, icons at x 170 and 490).
// usage: swift scripts/make-dmg-background.swift <out.png> <scale: 1|2>
import AppKit

let size = NSSize(width: 660, height: 400)
let scale = CGFloat(Double(CommandLine.arguments[2]) ?? 1)

func top(_ y: CGFloat) -> CGFloat { size.height - y }  // design in top-left coordinates

let image = NSImage(size: size, flipped: false) { rect in
    NSGradient(colors: [NSColor(red: 0.96, green: 0.97, blue: 1.0, alpha: 1), NSColor(red: 0.90, green: 0.96, blue: 0.98, alpha: 1)])!
        .draw(in: rect, angle: -35)

    func text(_ string: String, centerX: CGFloat, topY: CGFloat, size: CGFloat, weight: NSFont.Weight, color: NSColor) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let attributed = NSAttributedString(string: string, attributes: [
            .font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color, .paragraphStyle: paragraph,
        ])
        let bounds = attributed.boundingRect(with: NSSize(width: 600, height: 200), options: [.usesLineFragmentOrigin])
        attributed.draw(with: NSRect(x: centerX - 300, y: top(topY) - bounds.height, width: 600, height: bounds.height), options: [.usesLineFragmentOrigin])
    }

    text("Drag Dropwheel into Applications", centerX: 330, topY: 42, size: 22, weight: .semibold,
         color: NSColor(red: 0.12, green: 0.16, blue: 0.29, alpha: 1))

    // Arrow from the app icon towards Applications.
    let blue = NSColor(red: 0.24, green: 0.39, blue: 0.98, alpha: 1)
    let y = top(190)
    let shaft = NSBezierPath()
    shaft.move(to: NSPoint(x: 262, y: y))
    shaft.line(to: NSPoint(x: 384, y: y))
    shaft.lineWidth = 7
    shaft.lineCapStyle = .round
    blue.setStroke()
    shaft.stroke()
    let head = NSBezierPath()
    head.move(to: NSPoint(x: 404, y: y))
    head.line(to: NSPoint(x: 378, y: y + 17))
    head.line(to: NSPoint(x: 378, y: y - 17))
    head.close()
    blue.setFill()
    head.fill()

    text("Then open Dropwheel from Applications. The first time, if macOS blocks it, open\nSystem Settings › Privacy & Security and click “Open Anyway”.",
         centerX: 330, topY: 318, size: 12, weight: .regular, color: NSColor(red: 0.35, green: 0.39, blue: 0.47, alpha: 1))
    return true
}

let pixels = NSSize(width: size.width * scale, height: size.height * scale)
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(pixels.width), pixelsHigh: Int(pixels.height),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = size  // points, so the @2x file carries 144 dpi
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
image.draw(in: NSRect(origin: .zero, size: size))
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
