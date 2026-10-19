import SwiftUI
import DropwheelCore

/// Materials don't render in off-screen snapshots; debug builds can swap in a translucent fill
/// (DROPWHEEL_DEMO_GLASS=1) to make README screenshots that look like the real glass.
#if DEBUG
private let demoGlass = ProcessInfo.processInfo.environment["DROPWHEEL_DEMO_GLASS"] == "1"
#else
private let demoGlass = false
#endif

private func glass(_ material: Material, demoOpacity: Double) -> AnyShapeStyle {
    demoGlass ? AnyShapeStyle(Color.white.opacity(demoOpacity)) : AnyShapeStyle(material)
}

/// The wheel: round "drops" orbiting a glass ring, with the file in the centre. Drop `i` sits at
/// 12 o'clock + i·span, clockwise, matching `WheelGeometry`'s segments, so what is drawn is
/// what is hit (each drop owns the whole wedge around it, which keeps aiming forgiving).
struct WheelView: View {
    let model: WheelModel
    @Environment(\.colorScheme) private var scheme

    private let inner = WheelModel.innerRadius
    private let outer = WheelModel.outerRadius
    /// Radius of the circle the drops' centres sit on.
    private let orbit: CGFloat = 104
    /// Width of the glass band the drops sit on.
    private let band: CGFloat = 80
    private var collapsed: Bool { model.phase != .choosing }
    private var side: CGFloat { outer * 2 + 60 }

    var body: some View {
        ZStack {
            if !collapsed {
                // A glass band under the drops (a ring, not a disc: the middle stays open).
                Circle()
                    .fill(glass(.ultraThinMaterial, demoOpacity: 0.38))
                    .mask(Circle().strokeBorder(lineWidth: band))
                    .overlay(Circle().strokeBorder(.white.opacity(scheme == .dark ? 0.14 : 0.6), lineWidth: 0.5))
                    .overlay(Circle().strokeBorder(.white.opacity(scheme == .dark ? 0.14 : 0.6), lineWidth: 0.5).padding(band))
                    .frame(width: (orbit + band / 2) * 2, height: (orbit + band / 2) * 2)
                    .shadow(color: .black.opacity(0.22), radius: 18, y: 8)
                    .transition(.scale(scale: 0.86).combined(with: .opacity))

                drops
                    .id(model.ring)
                    .transition(.asymmetric(insertion: .scale(scale: 0.8).combined(with: .opacity), removal: .opacity))
            }

            CenterBadge(model: model, radius: inner - 6)
                .shadow(color: .black.opacity(collapsed ? 0.25 : 0.12), radius: collapsed ? 16 : 6, y: collapsed ? 6 : 2)
        }
        .frame(width: side, height: side)
        .scaleEffect(model.isPresented ? 1 : 0.82)
        .opacity(model.isPresented ? 1 : 0)
        .animation(.spring(response: 0.3, dampingFraction: 0.78), value: model.isPresented)
        .animation(.spring(response: 0.34, dampingFraction: 0.8), value: model.ring)
        .animation(.spring(response: 0.34, dampingFraction: 0.86), value: collapsed)
        .animation(.spring(response: 0.22, dampingFraction: 0.7), value: model.hovered)
    }

    private var drops: some View {
        let items = model.items
        // As large as the orbit allows without neighbours touching, capped for few items.
        let spacing = 2 * orbit * sin(.pi / Double(max(items.count, 2)))
        let diameter = min(74, spacing - 12)
        return ZStack {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                DropBubble(item: item, highlighted: model.hovered == .segment(index), diameter: diameter, scheme: scheme)
                    .position(position(index: index, count: items.count))
            }
        }
        .frame(width: side, height: side)
    }

    private func position(index: Int, count: Int) -> CGPoint {
        let angle = (-90 + Double(index) * 360 / Double(count)) * .pi / 180
        return CGPoint(x: side / 2 + orbit * cos(angle), y: side / 2 + orbit * sin(angle))
    }
}

private struct DropBubble: View {
    let item: WheelItem
    let highlighted: Bool
    let diameter: CGFloat
    let scheme: ColorScheme

    var body: some View {
        ZStack {
            Circle()
                .fill(highlighted ? AnyShapeStyle(LinearGradient.dropwheel) : AnyShapeStyle(restingFill))
                .overlay(Circle().strokeBorder(.white.opacity(highlighted ? 0.6 : (scheme == .dark ? 0.15 : 0.9)), lineWidth: 1))
                .shadow(color: highlighted ? Color.dropwheelAccent.opacity(0.5) : .black.opacity(0.14),
                        radius: highlighted ? 12 : 3, y: highlighted ? 4 : 1.5)
            label
                .foregroundStyle(highlighted ? AnyShapeStyle(.white) : AnyShapeStyle(.primary.opacity(0.85)))
                .frame(width: diameter - 8)
        }
        .frame(width: diameter, height: diameter)
        .scaleEffect(highlighted ? 1.16 : 1)
        .zIndex(highlighted ? 1 : 0)
    }

    private var restingFill: Color {
        scheme == .dark ? Color(white: 0.22).opacity(0.92) : Color.white.opacity(0.92)
    }

    @ViewBuilder private var label: some View {
        if let symbol = item.symbol {
            VStack(spacing: 3) {
                Image(systemName: symbol).font(.system(size: 15, weight: .semibold))
                Text(item.title.uppercased())
                    .font(.system(size: 7.5, weight: .bold))
                    .tracking(0.3)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        } else {
            Text(item.title)
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
    }
}

private struct CenterBadge: View {
    let model: WheelModel
    let radius: CGFloat

    var body: some View {
        ZStack {
            Circle()
                .fill(glass(.regularMaterial, demoOpacity: 0.92))
                .overlay(Circle().strokeBorder(model.hovered == .center && model.availableRings.count > 1 ? Color.dropwheelAccent : .clear, lineWidth: 2))
                .overlay {
                    // Progress ring around the bubble while a long job runs.
                    if case .working = model.phase, let progress = model.progress {
                        Circle()
                            .trim(from: 0, to: progress)
                            .stroke(Color.dropwheelAccent, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                            .padding(1.5)
                            .animation(.linear(duration: 0.25), value: progress)
                    }
                }
            content
                .multilineTextAlignment(.center)
                .frame(width: radius * 2 - 18)
        }
        .frame(width: radius * 2, height: radius * 2)
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .choosing:
            if let item = model.hoveredItem {
                Text(item.title)
                    .font(.system(size: item.symbol == nil ? 18 : 13, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.dropwheelAccent)
            } else {
                VStack(spacing: 2) {
                    Text(model.fileName).font(.system(size: 10.5, weight: .semibold)).lineLimit(2).truncationMode(.middle)
                    Text(model.fileDetail).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                    // Which modifier opens which ring; the current one is highlighted.
                    HStack(spacing: 5) {
                        ForEach(model.availableRings, id: \.self) { ring in
                            Text(ring.key)
                                .font(.system(size: 11, weight: .bold, design: .rounded))
                                .foregroundStyle(ring == model.ring ? Color.dropwheelAccent : .secondary)
                                .help(ring.title)
                        }
                    }
                    .padding(.top, 2)
                }
            }
        case .working(let label):
            VStack(spacing: 3) {
                if let progress = model.progress {
                    Text("\(Int(progress * 100))%")
                        .font(.system(size: 17, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                } else {
                    ProgressView().controlSize(.small)
                }
                Text(label).font(.system(size: 10, weight: .semibold)).lineLimit(1)
                Text("Click to cancel").font(.system(size: 8.5, weight: .medium)).foregroundStyle(.secondary)
            }
        case .cancelled:
            VStack(spacing: 4) {
                Image(systemName: "xmark.circle.fill").font(.system(size: 20)).foregroundStyle(.secondary)
                Text("Cancelled").font(.system(size: 10, weight: .semibold))
            }
        case .done(let message):
            VStack(spacing: 4) {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 22)).foregroundStyle(.green)
                Text(message).font(.system(size: 9.5, weight: .semibold)).lineLimit(3).truncationMode(.middle)
                Text("Click to show").font(.system(size: 8.5, weight: .medium)).foregroundStyle(.secondary)
            }
        case .failed(let message):
            VStack(spacing: 4) {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 20)).foregroundStyle(.orange)
                Text(message).font(.system(size: 9, weight: .medium)).lineLimit(4)
            }
        }
    }
}

extension Color {
    /// Dropwheel blue; the hover gradient runs from this towards cyan ("water").
    static let dropwheelAccent = Color(red: 0.16, green: 0.42, blue: 0.96)
}

extension LinearGradient {
    static let dropwheel = LinearGradient(
        colors: [Color(red: 0.24, green: 0.39, blue: 0.98), Color(red: 0.02, green: 0.71, blue: 0.83)],
        startPoint: .topLeading, endPoint: .bottomTrailing)
}
