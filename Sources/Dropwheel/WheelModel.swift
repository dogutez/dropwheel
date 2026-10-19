import AppKit
import Observation
import DropwheelCore

/// Things done *with* a file rather than to it. They never write anything.
enum FileAction: String, CaseIterable {
    case airDrop, float, copy, copyPath, terminal

    var title: String {
        switch self {
        case .airDrop: "AirDrop"
        case .float: "Float"
        case .copy: "Copy"
        case .copyPath: "Copy Path"
        case .terminal: "Terminal"
        }
    }

    var symbol: String {
        switch self {
        case .airDrop: "airplayaudio"
        case .float: "pin"
        case .copy: "doc.on.doc"
        case .copyPath: "link"
        case .terminal: "terminal"
        }
    }
}

enum WheelCommand: Equatable {
    case run(Action)
    case file(FileAction)
}

struct WheelItem: Identifiable, Equatable {
    let command: WheelCommand
    let title: String
    let symbol: String?
    var id: String { title }

    init(_ action: Action) {
        command = .run(action)
        title = action.title
        if case .tool(let tool) = action { symbol = tool.symbol } else { symbol = nil }
    }

    init(_ action: FileAction) {
        command = .file(action)
        title = action.title
        symbol = action.symbol
    }
}

@Observable
final class WheelModel {
    /// Which ring is showing; chosen by the modifier held during the drag.
    enum Ring: CaseIterable {
        case convert, tools, actions

        /// ⌃ beats ⌘ beats ⇧ when several are held.
        init?(modifiers: NSEvent.ModifierFlags) {
            if modifiers.contains(.control) { self = .actions }
            else if modifiers.contains(.command) { self = .tools }
            else if modifiers.contains(.shift) { self = .convert }
            else { return nil }
        }

        var key: String {
            switch self {
            case .convert: "⇧"
            case .tools: "⌘"
            case .actions: "⌃"
            }
        }

        var title: String {
            switch self {
            case .convert: "Convert"
            case .tools: "Tools"
            case .actions: "Actions"
            }
        }
    }

    enum Phase: Equatable {
        case choosing
        case working(String)
        case done(String)
        case failed(String)
        case cancelled
    }

    static let innerRadius: CGFloat = 56
    static let outerRadius: CGFloat = 150

    /// nil for folders, unsupported files and mixed selections: only actions apply.
    var kind: FileKind?
    var convertItems: [WheelItem] = []
    var toolItems: [WheelItem] = []
    let actionItems = FileAction.allCases.map { WheelItem($0) }
    var ring: Ring = .convert
    var hovered: WheelGeometry.Hit = .outside
    var phase: Phase = .choosing
    var isPresented = false
    /// 0...1 while a long job reports progress; nil when it doesn't.
    var progress: Double?
    var fileName = ""
    var fileDetail = ""

    func items(for ring: Ring) -> [WheelItem] {
        switch ring {
        case .convert: convertItems
        case .tools: toolItems
        case .actions: actionItems
        }
    }

    var items: [WheelItem] { items(for: ring) }
    var availableRings: [Ring] { Ring.allCases.filter { !items(for: $0).isEmpty } }

    var hoveredItem: WheelItem? {
        guard case .segment(let index) = hovered, items.indices.contains(index) else { return nil }
        return items[index]
    }

    func configure(files: [URL], ring requested: Ring) {
        let first = files[0]
        let kinds = Set(files.map { FileKind(url: $0) })
        kind = kinds.count == 1 ? kinds.first ?? nil : nil
        if let kind {
            convertItems = Catalog.conversions(for: kind, sourceExtension: first.pathExtension).map { WheelItem(.convert($0)) }
            toolItems = Catalog.tools(for: kind, count: files.count).map { WheelItem(.tool($0)) }
        } else if files.count > 1, kinds.allSatisfy({ $0 == .pdf || $0 == .image }) {
            // PDFs mixed with images: the one thing that applies to all of them is Merge.
            convertItems = []
            toolItems = [WheelItem(.tool(.merge))]
        } else {
            convertItems = []
            toolItems = []
        }
        hovered = .outside
        phase = .choosing
        ring = .actions
        show(requested)
        fileName = files.count == 1 ? first.lastPathComponent : "\(files.count) items"
        let size = (try? first.resourceValues(forKeys: [.fileSizeKey]).fileSize).map {
            ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file)
        }
        fileDetail = files.count > 1 ? (kind?.rawValue.capitalized ?? "Mixed") : (first.hasDirectoryPath ? "Folder" : size ?? first.pathExtension.uppercased())
    }

    /// Switches ring if that ring has anything to offer.
    func show(_ ring: Ring) {
        guard phase == .choosing, ring != self.ring, !items(for: ring).isEmpty else { return }
        self.ring = ring
        hovered = .outside
    }

    /// Centre dwell: step to the next ring that has items.
    func cycleRing() {
        let rings = availableRings
        guard rings.count > 1, let index = rings.firstIndex(of: ring) else { return }
        show(rings[(index + 1) % rings.count])
    }
}
