import SwiftUI
import DropwheelCore

enum AnnotateTool: String, CaseIterable, Identifiable {
    case pen = "Pen", arrow = "Arrow", box = "Box", ellipse = "Ellipse", text = "Text"

    var id: Self { self }

    var symbol: String {
        switch self {
        case .pen: "scribble"
        case .arrow: "arrow.up.right"
        case .box: "rectangle"
        case .ellipse: "circle"
        case .text: "textformat"
        }
    }
}

@Observable
final class AnnotateModel {
    static let colors: [RGBA] = [0xF2545B, 0xFF9F0A, 0xFFD60A, 0x30D158, 0x0A84FF, 0xBF5AF2, 0x000000, 0xFFFFFF].map(RGBA.init(hex:))
    static let weights: [(title: String, value: Double)] = [("S", 0.004), ("M", 0.008), ("L", 0.014)]

    let preview: CGImage
    let fullSize: CGSize
    var annotations: [Annotation] = []
    var draft: Annotation?
    var tool: AnnotateTool = .arrow
    var color = AnnotateModel.colors[0]
    var weight = AnnotateModel.weights[1].value
    var text = "Text"

    init(preview: CGImage, fullSize: CGSize) {
        self.preview = preview
        self.fullSize = fullSize
    }
}

struct AnnotateEditor: View {
    @Bindable var model: AnnotateModel
    let onSave: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 12) {
                Picker("Tool", selection: $model.tool) {
                    ForEach(AnnotateTool.allCases) { Image(systemName: $0.symbol).help($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 200)
                HStack(spacing: 5) {
                    ForEach(AnnotateModel.colors, id: \.self) { color in
                        Button { model.color = color } label: {
                            Circle()
                                .fill(Color(.sRGB, red: color.red, green: color.green, blue: color.blue))
                                .overlay(Circle().strokeBorder(.primary.opacity(0.2), lineWidth: 1))
                                .padding(2)
                                .overlay(Circle().strokeBorder(model.color == color ? Color.dropwheelAccent : .clear, lineWidth: 2))
                                .frame(width: 22, height: 22)
                        }
                        .buttonStyle(.plain)
                    }
                }
                Picker("Weight", selection: $model.weight) {
                    ForEach(AnnotateModel.weights, id: \.value) { Text($0.title).tag($0.value) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 90)
            }
            if model.tool == .text {
                HStack {
                    TextField("Text to place", text: $model.text).textFieldStyle(.roundedBorder)
                    Text("Click the image to place it").foregroundStyle(.secondary).font(.callout)
                }
            }

            GeometryReader { proxy in
                let frame = aspectFit(model.fullSize, in: proxy.size)
                ZStack(alignment: .topLeading) {
                    Image(decorative: model.preview, scale: 1)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: frame.width, height: frame.height)
                        .offset(x: frame.minX, y: frame.minY)
                    Canvas { context, _ in
                        for annotation in model.annotations + (model.draft.map { [$0] } ?? []) {
                            draw(annotation, in: frame, context: &context)
                        }
                    }
                    .allowsHitTesting(false)
                }
                .contentShape(Rectangle())
                .gesture(drawGesture(frame: frame))
            }
            .frame(height: 420)

            HStack {
                Button("Undo") { _ = model.annotations.popLast() }
                    .keyboardShortcut("z")
                    .disabled(model.annotations.isEmpty)
                Button("Clear") { model.annotations.removeAll() }
                    .disabled(model.annotations.isEmpty)
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel).keyboardShortcut(.cancelAction)
                Button("Save", action: onSave)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .tint(.dropwheelAccent)
                    .disabled(model.annotations.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 620)
    }

    private func normalized(_ point: CGPoint, in frame: CGRect) -> CGPoint {
        CGPoint(x: min(max((point.x - frame.minX) / frame.width, 0), 1),
                y: min(max((point.y - frame.minY) / frame.height, 0), 1))
    }

    private func drawGesture(frame: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let start = normalized(value.startLocation, in: frame)
                let point = normalized(value.location, in: frame)
                let box = CGRect(x: min(start.x, point.x), y: min(start.y, point.y), width: abs(point.x - start.x), height: abs(point.y - start.y))
                let shape: Annotation.Shape? = switch model.tool {
                case .pen:
                    if case .pen(let points)? = model.draft?.shape { .pen(points + [point]) } else { .pen([start, point]) }
                case .arrow: .arrow(from: start, to: point)
                case .box: .rectangle(box)
                case .ellipse: .ellipse(box)
                case .text: nil
                }
                model.draft = shape.map { Annotation(shape: $0, color: model.color, width: model.weight) }
            }
            .onEnded { value in
                defer { model.draft = nil }
                let start = normalized(value.startLocation, in: frame)
                let end = normalized(value.location, in: frame)
                if model.tool == .text {
                    let text = model.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !text.isEmpty {
                        model.annotations.append(Annotation(shape: .text(text, at: end), color: model.color, width: model.weight))
                    }
                    return
                }
                // A click without a drag draws nothing (except a dot with the pen).
                guard let draft = model.draft, model.tool == .pen || hypot(end.x - start.x, end.y - start.y) > 0.005 else { return }
                model.annotations.append(draft)
            }
    }

    /// Mirrors `ImageEditing.annotate` at screen scale, so the preview matches the saved file.
    private func draw(_ annotation: Annotation, in frame: CGRect, context: inout GraphicsContext) {
        let lineWidth = annotation.width * max(frame.width, frame.height)
        let color = Color(.sRGB, red: annotation.color.red, green: annotation.color.green, blue: annotation.color.blue)
        let style = StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round)
        func point(_ p: CGPoint) -> CGPoint { CGPoint(x: frame.minX + p.x * frame.width, y: frame.minY + p.y * frame.height) }
        func rect(_ r: CGRect) -> CGRect {
            CGRect(x: frame.minX + r.minX * frame.width, y: frame.minY + r.minY * frame.height, width: r.width * frame.width, height: r.height * frame.height)
        }
        switch annotation.shape {
        case .pen(let points):
            var path = Path()
            path.addLines(points.map(point))
            context.stroke(path, with: .color(color), style: style)
        case .arrow(let from, let to):
            let start = point(from), tip = point(to)
            let (left, right) = Annotation.arrowHead(from: start, to: tip, lineWidth: lineWidth)
            var shaft = Path()
            shaft.move(to: start)
            shaft.addLine(to: CGPoint(x: (left.x + right.x) / 2, y: (left.y + right.y) / 2))
            context.stroke(shaft, with: .color(color), style: style)
            var head = Path()
            head.addLines([tip, left, right])
            head.closeSubpath()
            context.fill(head, with: .color(color))
            context.stroke(head, with: .color(color), style: style)
        case .rectangle(let r):
            context.stroke(Path(rect(r)), with: .color(color), style: style)
        case .ellipse(let r):
            context.stroke(Path(ellipseIn: rect(r)), with: .color(color), style: style)
        case .text(let string, let at):
            let text = Text(string).font(.system(size: lineWidth * Annotation.textScale, weight: .bold)).foregroundStyle(color)
            context.draw(text, at: point(at), anchor: .topLeading)
        }
    }
}
