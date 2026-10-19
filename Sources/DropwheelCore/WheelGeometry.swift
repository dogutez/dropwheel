import CoreGraphics
import Foundation

/// Maps a point to a ring segment. Segment 0 is centred at 12 o'clock and indices run
/// clockwise. Uses y-up coordinates (AppKit's), so "up" is +y.
public struct WheelGeometry: Sendable, Equatable {
    public enum Hit: Equatable, Sendable {
        case center
        case segment(Int)
        case outside
    }

    public var center: CGPoint
    public var innerRadius: CGFloat
    public var outerRadius: CGFloat
    public var count: Int

    public init(center: CGPoint, innerRadius: CGFloat, outerRadius: CGFloat, count: Int) {
        self.center = center
        self.innerRadius = innerRadius
        self.outerRadius = outerRadius
        self.count = count
    }

    public func hit(_ point: CGPoint) -> Hit {
        let dx = point.x - center.x, dy = point.y - center.y
        let distance = (dx * dx + dy * dy).squareRoot()
        if distance < innerRadius { return .center }
        guard distance <= outerRadius, count > 0 else { return .outside }
        let span = 2 * Double.pi / Double(count)
        // atan2(dx, dy): 0 at the top, growing clockwise.
        var angle = atan2(Double(dx), Double(dy)) + span / 2
        angle = angle.truncatingRemainder(dividingBy: 2 * .pi)
        if angle < 0 { angle += 2 * .pi }
        return .segment(min(count - 1, Int(angle / span)))
    }
}
