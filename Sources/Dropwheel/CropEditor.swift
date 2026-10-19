import SwiftUI
import DropwheelCore

enum CropAspect: String, CaseIterable, Identifiable {
    case free = "Free", square = "1:1", wide = "16:9", tall = "9:16", classic = "4:3", portrait = "3:4"

    var id: Self { self }

    /// Width ÷ height in pixels, or nil for a free crop.
    var ratio: CGFloat? {
        switch self {
        case .free: nil
        case .square: 1
        case .wide: 16.0 / 9
        case .tall: 9.0 / 16
        case .classic: 4.0 / 3
        case .portrait: 3.0 / 4
        }
    }
}

/// The crop rectangle is kept normalised (0...1, top-left origin) so it is independent of
/// the preview's size; it is converted to full-resolution pixels only when saving.
@Observable
final class CropModel {
    static let minSide: CGFloat = 0.03

    let preview: CGImage
    let fullSize: CGSize
    var rect = CGRect(x: 0, y: 0, width: 1, height: 1)
    var aspect: CropAspect = .free {
        didSet { fitAspect() }
    }

    init(preview: CGImage, fullSize: CGSize) {
        self.preview = preview
        self.fullSize = fullSize
    }

    /// The aspect ratio in normalised units (pixels ÷ image proportions).
    var normalizedRatio: CGFloat? {
        aspect.ratio.map { $0 * fullSize.height / fullSize.width }
    }

    var pixelRect: CGRect {
        ImageEditing.clampedCrop(
            CGRect(x: rect.minX * fullSize.width, y: rect.minY * fullSize.height,
                   width: rect.width * fullSize.width, height: rect.height * fullSize.height),
            in: fullSize)
    }

    func reset() {
        aspect = .free
        rect = CGRect(x: 0, y: 0, width: 1, height: 1)
    }

    /// The largest centred rectangle of the chosen ratio.
    private func fitAspect() {
        guard let ratio = normalizedRatio else { return }
        var width: CGFloat = 1, height = 1 / ratio
        if height > 1 { height = 1; width = ratio }
        rect = CGRect(x: (1 - width) / 2, y: (1 - height) / 2, width: width, height: height)
    }

    func setPixelWidth(_ pixels: Int) {
        var width = min(max(CGFloat(pixels) / fullSize.width, Self.minSide), 1)
        var height = rect.height
        if let ratio = normalizedRatio {
            height = width / ratio
            if height > 1 { height = 1; width = ratio }
        }
        rect = CGRect(x: min(rect.minX, 1 - width), y: min(rect.minY, 1 - height), width: width, height: height)
    }

    func setPixelHeight(_ pixels: Int) {
        var height = min(max(CGFloat(pixels) / fullSize.height, Self.minSide), 1)
        var width = rect.width
        if let ratio = normalizedRatio {
            width = height * ratio
            if width > 1 { width = 1; height = 1 / ratio }
        }
        rect = CGRect(x: min(rect.minX, 1 - width), y: min(rect.minY, 1 - height), width: width, height: height)
    }
}

struct CropEditor: View {
    @Bindable var model: CropModel
    let onApply: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            GeometryReader { proxy in
                let frame = fittedFrame(in: proxy.size)
                ZStack(alignment: .topLeading) {
                    Image(decorative: model.preview, scale: 1)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: frame.width, height: frame.height)
                        .offset(x: frame.minX, y: frame.minY)
                    CropOverlay(model: model, frame: frame)
                }
            }
            .frame(height: 440)

            HStack(spacing: 10) {
                Text("Aspect ratio").foregroundStyle(.secondary)
                Picker("Aspect ratio", selection: $model.aspect) {
                    ForEach(CropAspect.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            HStack(spacing: 8) {
                Text("W").foregroundStyle(.secondary)
                TextField("Width", value: Binding(get: { Int(model.pixelRect.width) }, set: { model.setPixelWidth($0) }), format: .number.grouping(.never))
                    .frame(width: 74)
                Text("H").foregroundStyle(.secondary)
                TextField("Height", value: Binding(get: { Int(model.pixelRect.height) }, set: { model.setPixelHeight($0) }), format: .number.grouping(.never))
                    .frame(width: 74)
                Text("px").foregroundStyle(.secondary)
                Spacer()
            }
            .textFieldStyle(.roundedBorder)
            .monospacedDigit()

            HStack {
                Button("Reset") { model.reset() }
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel).keyboardShortcut(.cancelAction)
                Button("Apply", action: onApply)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .tint(.dropwheelAccent)
            }
        }
        .padding(20)
        .frame(width: 560)
    }

    /// The image's on-screen frame: aspect-fit inside the available space.
    private func fittedFrame(in space: CGSize) -> CGRect {
        let scale = min(space.width / model.fullSize.width, space.height / model.fullSize.height)
        let size = CGSize(width: model.fullSize.width * scale, height: model.fullSize.height * scale)
        return CGRect(x: (space.width - size.width) / 2, y: (space.height - size.height) / 2, width: size.width, height: size.height)
    }
}

/// Dimmed surround, frame, rule-of-thirds and eight drag handles (four when a ratio is locked).
private struct CropOverlay: View {
    let model: CropModel
    let frame: CGRect
    @State private var startRect: CGRect?

    private struct Handle: Identifiable {
        let x: Int  // -1 left edge, 0 centre, 1 right edge
        let y: Int  // -1 top edge, 0 centre, 1 bottom edge
        var id: String { "\(x),\(y)" }
        var isCorner: Bool { x != 0 && y != 0 }
    }

    private var handles: [Handle] {
        let all = [(-1, -1), (0, -1), (1, -1), (1, 0), (1, 1), (0, 1), (-1, 1), (-1, 0)].map { Handle(x: $0.0, y: $0.1) }
        return model.normalizedRatio == nil ? all : all.filter(\.isCorner)
    }

    private var cropFrame: CGRect {
        CGRect(x: frame.minX + model.rect.minX * frame.width, y: frame.minY + model.rect.minY * frame.height,
               width: model.rect.width * frame.width, height: model.rect.height * frame.height)
    }

    var body: some View {
        let crop = cropFrame
        ZStack(alignment: .topLeading) {
            Path { path in
                path.addRect(frame)
                path.addRect(crop)
            }
            .fill(.black.opacity(0.5), style: FillStyle(eoFill: true))

            Path { path in
                for third in [1.0 / 3, 2.0 / 3] {
                    path.move(to: CGPoint(x: crop.minX + crop.width * third, y: crop.minY))
                    path.addLine(to: CGPoint(x: crop.minX + crop.width * third, y: crop.maxY))
                    path.move(to: CGPoint(x: crop.minX, y: crop.minY + crop.height * third))
                    path.addLine(to: CGPoint(x: crop.maxX, y: crop.minY + crop.height * third))
                }
            }
            .stroke(.white.opacity(0.35), lineWidth: 0.5)

            Rectangle()
                .strokeBorder(Color.dropwheelAccent, lineWidth: 2)
                .contentShape(Rectangle())
                .frame(width: crop.width, height: crop.height)
                .offset(x: crop.minX, y: crop.minY)
                .gesture(moveGesture)

            ForEach(handles) { handle in
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.dropwheelAccent)
                    .frame(width: handle.isCorner ? 12 : (handle.x == 0 ? 22 : 6), height: handle.isCorner ? 12 : (handle.y == 0 ? 22 : 6))
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
                    .position(x: crop.midX + CGFloat(handle.x) * crop.width / 2, y: crop.midY + CGFloat(handle.y) * crop.height / 2)
                    .gesture(resizeGesture(handle))
            }
        }
    }

    private var moveGesture: some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                let start = startRect ?? model.rect
                startRect = start
                let x = min(max(start.minX + value.translation.width / frame.width, 0), 1 - start.width)
                let y = min(max(start.minY + value.translation.height / frame.height, 0), 1 - start.height)
                model.rect.origin = CGPoint(x: x, y: y)
            }
            .onEnded { _ in startRect = nil }
    }

    private func resizeGesture(_ handle: Handle) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let start = startRect ?? model.rect
                startRect = start
                let dx = value.translation.width / frame.width, dy = value.translation.height / frame.height
                model.rect = resized(start, handle: handle, dx: dx, dy: dy)
            }
            .onEnded { _ in startRect = nil }
    }

    private func resized(_ start: CGRect, handle: Handle, dx: CGFloat, dy: CGFloat) -> CGRect {
        let minSide = CropModel.minSide
        if let ratio = model.normalizedRatio {
            // Corner drag with a locked ratio: the opposite corner stays put.
            let anchorX = handle.x > 0 ? start.minX : start.maxX
            let anchorY = handle.y > 0 ? start.minY : start.maxY
            let maxWidth = min(handle.x > 0 ? 1 - anchorX : anchorX, (handle.y > 0 ? 1 - anchorY : anchorY) * ratio)
            let width = min(max(start.width + CGFloat(handle.x) * dx, minSide), maxWidth)
            let height = width / ratio
            return CGRect(x: handle.x > 0 ? anchorX : anchorX - width, y: handle.y > 0 ? anchorY : anchorY - height, width: width, height: height)
        }
        var minX = start.minX, maxX = start.maxX, minY = start.minY, maxY = start.maxY
        if handle.x < 0 { minX = min(max(start.minX + dx, 0), maxX - minSide) }
        if handle.x > 0 { maxX = max(min(start.maxX + dx, 1), minX + minSide) }
        if handle.y < 0 { minY = min(max(start.minY + dy, 0), maxY - minSide) }
        if handle.y > 0 { maxY = max(min(start.maxY + dy, 1), minY + minSide) }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}
