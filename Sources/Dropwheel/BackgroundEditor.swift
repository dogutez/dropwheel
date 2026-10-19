import AppKit
import SwiftUI
import DropwheelCore

enum BackgroundPresets {
    static let gradients: [CanvasStyle.Fill] = [
        .gradient([RGBA(hex: 0x3D63FA), RGBA(hex: 0x06B6D4)], angle: 45),
        .gradient([RGBA(hex: 0xFFB347), RGBA(hex: 0xF2545B), RGBA(hex: 0xB83280)], angle: 45),
        .gradient([RGBA(hex: 0xFFD3A5), RGBA(hex: 0xFD6585)], angle: 45),
        .gradient([RGBA(hex: 0xF9D423), RGBA(hex: 0xFF4E50)], angle: 90),
        .gradient([RGBA(hex: 0xFBC2EB), RGBA(hex: 0xA6C1EE)], angle: 45),
        .gradient([RGBA(hex: 0xE0EAFC), RGBA(hex: 0xCFDEF3)], angle: 90),
        .gradient([RGBA(hex: 0xA8FF78), RGBA(hex: 0x78FFD6)], angle: 45),
        .gradient([RGBA(hex: 0x43CBFF), RGBA(hex: 0x9708CC)], angle: 45),
        .gradient([RGBA(hex: 0x2B5876), RGBA(hex: 0x4E4376)], angle: 45),
        .gradient([RGBA(hex: 0x0F2027), RGBA(hex: 0x2C5364)], angle: 90),
    ]

    static let solids: [CanvasStyle.Fill] = [
        0xFFFFFF, 0xFFD60A, 0xA3E635, 0x22C55E, 0x14B8A6, 0x38BDF8, 0x3B82F6, 0x1F2937, 0x7C3AED,
    ].map { .solid(RGBA(hex: $0)) }
}

/// Edits a `CanvasStyle` and re-renders a downscaled preview with the same renderer
/// the saved file uses, so what you see is what you get.
@Observable
final class BackgroundModel {
    let image: CGImage
    let fullSize: CGSize
    private let initial: CanvasStyle
    var style: CanvasStyle { didSet { render() } }
    private(set) var rendered: CGImage?

    /// Slider ceilings, in full-resolution pixels.
    var maxPadding: Double { Double(max(fullSize.width, fullSize.height)) * 0.4 }
    var maxCorner: Double { Double(min(fullSize.width, fullSize.height)) / 2 }
    var maxShadow: Double { Double(max(fullSize.width, fullSize.height)) * 0.08 }

    init(image: CGImage, fullSize: CGSize) {
        self.image = image
        self.fullSize = fullSize
        initial = CanvasStyle.defaults(for: fullSize, fill: BackgroundPresets.gradients[0])
        style = initial
        render()
    }

    func reset() { style = initial }

    private func render() {
        rendered = try? ImageEditing.render(image, style: style, scale: Double(image.width) / Double(fullSize.width))
    }
}

struct BackgroundEditor: View {
    @Bindable var model: BackgroundModel
    let onSave: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            ZStack {
                if let rendered = model.rendered {
                    Image(decorative: rendered, scale: 1)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
                }
            }
            .frame(width: 520, height: 340)

            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 12) {
                GridRow {
                    Text("Background").foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 7) { ForEach(BackgroundPresets.gradients, id: \.self, content: swatch) }
                        HStack(spacing: 7) {
                            ForEach(BackgroundPresets.solids, id: \.self, content: swatch)
                            ColorPicker("Custom colour", selection: customColor, supportsOpacity: false).labelsHidden()
                        }
                    }
                }
                sliderRow("Padding", value: $model.style.padding, range: 0...model.maxPadding)
                sliderRow("Corners", value: $model.style.cornerRadius, range: 0...model.maxCorner)
                sliderRow("Shadow", value: $model.style.shadow, range: 0...model.maxShadow)
                GridRow {
                    Text("Ratio").foregroundStyle(.secondary)
                    Picker("Ratio", selection: $model.style.ratio) {
                        ForEach(CanvasStyle.Ratio.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 260)
                }
            }

            HStack {
                Button("Reset") { model.reset() }
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel).keyboardShortcut(.cancelAction)
                Button("Save with Background", action: onSave)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .tint(.dropwheelAccent)
            }
        }
        .padding(20)
        .frame(width: 560)
    }

    private func sliderRow(_ title: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        GridRow {
            Text(title).foregroundStyle(.secondary)
            HStack {
                Slider(value: value, in: range).tint(.dropwheelAccent)
                Text("\(Int(value.wrappedValue)) px")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 64, alignment: .trailing)
            }
        }
    }

    private func swatch(_ fill: CanvasStyle.Fill) -> some View {
        let selected = model.style.fill == fill
        return Button { model.style.fill = fill } label: {
            Circle()
                .fill(fill.shapeStyle)
                .overlay(Circle().strokeBorder(.primary.opacity(0.15), lineWidth: 1))
                .padding(2.5)
                .overlay(Circle().strokeBorder(selected ? Color.dropwheelAccent : .clear, lineWidth: 2))
                .frame(width: 26, height: 26)
        }
        .buttonStyle(.plain)
    }

    /// The colour well edits a solid fill; picking from it switches to that solid colour.
    private var customColor: Binding<Color> {
        Binding {
            if case .solid(let rgba) = model.style.fill { return rgba.color }
            return .white
        } set: { color in
            let srgb = NSColor(color).usingColorSpace(.sRGB) ?? .white
            model.style.fill = .solid(RGBA(srgb.redComponent, srgb.greenComponent, srgb.blueComponent))
        }
    }
}

private extension RGBA {
    var color: Color { Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha) }
}

private extension CanvasStyle.Fill {
    var shapeStyle: AnyShapeStyle {
        switch self {
        case .solid(let rgba):
            AnyShapeStyle(rgba.color)
        case .gradient(let colors, let angle):
            // Same direction convention as the renderer: 0° left→right, 90° top→bottom.
            AnyShapeStyle(LinearGradient(colors: colors.map(\.color),
                                         startPoint: UnitPoint(x: 0.5 - cos(angle * .pi / 180) / 2, y: 0.5 - sin(angle * .pi / 180) / 2),
                                         endPoint: UnitPoint(x: 0.5 + cos(angle * .pi / 180) / 2, y: 0.5 + sin(angle * .pi / 180) / 2)))
        }
    }
}
