import SwiftUI
import DropwheelCore

/// The image's on-screen frame: aspect-fit inside the available space.
func aspectFit(_ size: CGSize, in space: CGSize) -> CGRect {
    let scale = min(space.width / size.width, space.height / size.height)
    let fitted = CGSize(width: size.width * scale, height: size.height * scale)
    return CGRect(x: (space.width - fitted.width) / 2, y: (space.height - fitted.height) / 2, width: fitted.width, height: fitted.height)
}

@Observable
final class EditModel {
    let preview: CGImage
    let fullSize: CGSize
    var adjustments = Adjustments() { didSet { render() } }
    private(set) var rendered: CGImage?

    init(preview: CGImage, fullSize: CGSize) {
        self.preview = preview
        self.fullSize = fullSize
        render()
    }

    var outputSize: CGSize { adjustments.outputSize(for: fullSize) }

    private func render() {
        var look = adjustments
        look.scale = 1 // the preview always fills the frame; the size is shown as text
        rendered = try? ImageEditing.adjust(preview, look)
    }
}

struct EditEditor: View {
    @Bindable var model: EditModel
    let onSave: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            ZStack {
                if let rendered = model.rendered {
                    Image(decorative: rendered, scale: 1).resizable().interpolation(.high).scaledToFit()
                }
            }
            .frame(width: 520, height: 340)

            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 10) {
                slider("Exposure", $model.adjustments.exposure, -2...2, neutral: 0) { String(format: "%+.1f EV", $0) }
                slider("Contrast", $model.adjustments.contrast, 0.5...1.5, neutral: 1) { "\(Int(($0 - 1) * 200))" }
                slider("Saturation", $model.adjustments.saturation, 0...2, neutral: 1) { "\(Int(($0 - 1) * 100))" }
                slider("Warmth", $model.adjustments.warmth, -1...1, neutral: 0) { "\(Int($0 * 100))" }
                slider("Sharpness", $model.adjustments.sharpness, 0...1, neutral: 0) { "\(Int($0 * 100))" }
                GridRow {
                    Text("Orientation").foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        iconButton("Rotate Left", "rotate.left") { model.adjustments.rotate(clockwise: false) }
                        iconButton("Rotate Right", "rotate.right") { model.adjustments.rotate(clockwise: true) }
                        iconButton("Flip Horizontal", "arrow.left.and.right") { model.adjustments.flipHorizontal.toggle() }
                        iconButton("Flip Vertical", "arrow.up.and.down") { model.adjustments.flipVertical.toggle() }
                    }
                }
                GridRow {
                    Text("Size").foregroundStyle(.secondary)
                    HStack {
                        Picker("Size", selection: $model.adjustments.scale) {
                            ForEach([1.0, 0.75, 0.5, 0.25], id: \.self) { Text("\(Int($0 * 100))%").tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(width: 240)
                        Text("\(Int(model.outputSize.width)) × \(Int(model.outputSize.height)) px")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
            }

            HStack {
                Button("Reset") { model.adjustments = Adjustments() }
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel).keyboardShortcut(.cancelAction)
                Button("Save", action: onSave)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .tint(.dropwheelAccent)
                    .disabled(model.adjustments.isIdentity)
            }
        }
        .padding(20)
        .frame(width: 560)
    }

    private func slider(_ title: String, _ value: Binding<Double>, _ range: ClosedRange<Double>, neutral: Double,
                        format: @escaping (Double) -> String) -> some View {
        GridRow {
            Text(title).foregroundStyle(.secondary)
            HStack {
                Slider(value: value, in: range).tint(.dropwheelAccent)
                Text(format(value.wrappedValue))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 64, alignment: .trailing)
                    .onTapGesture(count: 2) { value.wrappedValue = neutral }
                    .help("Double-click to reset")
            }
        }
    }

    private func iconButton(_ title: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).frame(width: 22) }
            .help(title)
            .accessibilityLabel(title)
    }
}
