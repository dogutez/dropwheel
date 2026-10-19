// Renders the app icon to a 1024 px PNG: a deep-blue-to-cyan tile with a white water drop in the
// middle and a ring of smaller drops orbiting it (one highlighted), echoing the wheel.
// usage: swift scripts/make-icon.swift <out.png>
import AppKit

let side: CGFloat = 1024
let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
    let tile = rect.insetBy(dx: 100, dy: 100)
    let squircle = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)
    NSGradient(colors: [
        NSColor(red: 0.09, green: 0.19, blue: 0.55, alpha: 1),
        NSColor(red: 0.15, green: 0.39, blue: 0.92, alpha: 1),
        NSColor(red: 0.02, green: 0.71, blue: 0.83, alpha: 1),
    ])!.draw(in: squircle, angle: 60)

    let center = NSPoint(x: rect.midX, y: rect.midY)
    let context = NSGraphicsContext.current!.cgContext

    // Orbit: a faint track and seven drops on it, the one at the upper right highlighted.
    let orbit: CGFloat = 268
    NSColor.white.withAlphaComponent(0.22).setStroke()
    let track = NSBezierPath(ovalIn: NSRect(x: center.x - orbit, y: center.y - orbit, width: orbit * 2, height: orbit * 2))
    track.lineWidth = 64
    track.stroke()
    for index in 0..<7 {
        let angle = (90 - Double(index) * 360 / 7) * .pi / 180
        let point = NSPoint(x: center.x + orbit * cos(angle), y: center.y + orbit * sin(angle))
        let radius: CGFloat = index == 1 ? 50 : 34
        context.saveGState()
        context.setAlpha(index == 1 ? 1 : 0.62)
        NSColor.white.setFill()
        NSBezierPath(ovalIn: NSRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)).fill()
        context.restoreGState()
    }

    // The drop: a circle drawn into a point at the top.
    let r: CGFloat = 104
    let body = NSPoint(x: center.x, y: center.y - 48)
    let tip = NSPoint(x: center.x, y: body.y + r * 2.15)
    let drop = NSBezierPath()
    drop.move(to: tip)
    drop.curve(to: NSPoint(x: body.x - r, y: body.y),
               controlPoint1: NSPoint(x: body.x - r * 0.18, y: tip.y - r * 0.55),
               controlPoint2: NSPoint(x: body.x - r, y: body.y + r * 0.72))
    drop.appendArc(withCenter: body, radius: r, startAngle: 180, endAngle: 360, clockwise: false)
    drop.curve(to: tip,
               controlPoint1: NSPoint(x: body.x + r, y: body.y + r * 0.72),
               controlPoint2: NSPoint(x: body.x + r * 0.18, y: tip.y - r * 0.55))
    drop.close()
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -10), blur: 30, color: NSColor.black.withAlphaComponent(0.25).cgColor)
    NSColor.white.setFill()
    drop.fill()
    context.restoreGState()
    return true
}

let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil)!
let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])!
try! png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
