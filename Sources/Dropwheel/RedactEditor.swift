import SwiftUI
import DropwheelCore

@Observable
final class RedactModel {
    let preview: CGImage
    let fullSize: CGSize
    var redactions: [Redaction] = [] { didSet { render() } }
    var style: Redaction.Style = .block
    var draft: CGRect?
    private(set) var rendered: CGImage?

    init(preview: CGImage, fullSize: CGSize) {
        self.preview = preview
        self.fullSize = fullSize
        render()
    }

    /// The preview is redacted by the same code that writes the file.
    private func render() {
        rendered = redactions.isEmpty ? preview : (try? ImageEditing.redact(preview, redactions)) ?? preview
    }
}

struct RedactEditor: View {
    @Bindable var model: RedactModel
    let onSave: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            HStack {
                Picker("Style", selection: $model.style) {
                    ForEach(Redaction.Style.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 260)
                Spacer()
                Text("Drag over what should be hidden").foregroundStyle(.secondary).font(.callout)
            }

            GeometryReader { proxy in
                let frame = aspectFit(model.fullSize, in: proxy.size)
                ZStack(alignment: .topLeading) {
                    if let rendered = model.rendered {
                        Image(decorative: rendered, scale: 1)
                            .resizable()
                            .interpolation(.high)
                            .frame(width: frame.width, height: frame.height)
                            .offset(x: frame.minX, y: frame.minY)
                    }
                    if let draft = model.draft {
                        let area = CGRect(x: frame.minX + draft.minX * frame.width, y: frame.minY + draft.minY * frame.height,
                                          width: draft.width * frame.width, height: draft.height * frame.height)
                        Rectangle()
                            .fill(.black.opacity(0.35))
                            .overlay(Rectangle().strokeBorder(Color.dropwheelAccent, style: StrokeStyle(lineWidth: 1.5, dash: [5, 3])))
                            .frame(width: area.width, height: area.height)
                            .offset(x: area.minX, y: area.minY)
                            .allowsHitTesting(false)
                    }
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 2)
                        .onChanged { value in
                            let a = normalized(value.startLocation, in: frame), b = normalized(value.location, in: frame)
                            model.draft = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
                        }
                        .onEnded { _ in
                            if let draft = model.draft, draft.width > 0.004, draft.height > 0.004 {
                                model.redactions.append(Redaction(rect: draft, style: model.style))
                            }
                            model.draft = nil
                        }
                )
            }
            .frame(height: 420)

            Text("Hidden areas are burned into the pixels, and the copy is saved without any metadata. Black Box removes content completely; pixelated text can sometimes be reconstructed.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack {
                Button("Undo") { _ = model.redactions.popLast() }
                    .keyboardShortcut("z")
                    .disabled(model.redactions.isEmpty)
                Button("Clear") { model.redactions.removeAll() }
                    .disabled(model.redactions.isEmpty)
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel).keyboardShortcut(.cancelAction)
                Button("Save Redacted", action: onSave)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .tint(.dropwheelAccent)
                    .disabled(model.redactions.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 620)
    }

    private func normalized(_ point: CGPoint, in frame: CGRect) -> CGPoint {
        CGPoint(x: min(max((point.x - frame.minX) / frame.width, 0), 1),
                y: min(max((point.y - frame.minY) / frame.height, 0), 1))
    }
}
