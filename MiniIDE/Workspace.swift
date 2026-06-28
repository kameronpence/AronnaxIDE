import SwiftUI

/// Orientation of a split.
enum SplitAxis: Hashable {
    case horizontal   // children side by side
    case vertical     // children stacked
}

/// A recursive layout tree. Every pane is either a leaf (showing one surface) or a
/// binary split of two child trees. Arbitrary IDE-style layouts — 2 columns + a
/// bottom row, 4-way grids, … — are built by nesting splits. Each leaf carries a
/// stable `id` so its live content (terminals, web views) survives restructuring.
indirect enum PaneTree: Identifiable {
    case leaf(id: UUID, tab: WorkspaceTab)
    case split(id: UUID, axis: SplitAxis, first: PaneTree, second: PaneTree, fraction: CGFloat)

    var id: UUID {
        switch self {
        case .leaf(let id, _):            return id
        case .split(let id, _, _, _, _):  return id
        }
    }
}

/// Owns the workspace layout tree and the operations that mutate it.
@MainActor
final class WorkspaceModel: ObservableObject {
    @Published private(set) var tree: PaneTree
    @Published var focusedID: UUID

    init(initial: WorkspaceTab = .terminal) {
        let id = UUID()
        tree = .leaf(id: id, tab: initial)
        focusedID = id
    }

    var paneCount: Int { Self.leafCount(tree) }
    var focusedTab: WorkspaceTab { Self.tab(of: focusedID, in: tree) ?? .terminal }

    func focus(_ id: UUID) { focusedID = id }

    func setTab(_ tab: WorkspaceTab, for id: UUID) {
        tree = Self.setTab(tab, for: id, in: tree)
    }

    func setFocusedTab(_ tab: WorkspaceTab) {
        setTab(tab, for: focusedID)
    }

    /// Split a leaf in two along `axis`; the new pane shows the same surface and
    /// becomes focused. The original leaf keeps its id, so its session persists.
    func split(_ id: UUID, axis: SplitAxis) {
        guard let tab = Self.tab(of: id, in: tree) else { return }
        let newID = UUID()
        tree = Self.split(id, axis: axis, newTab: Self.sibling(of: tab), newID: newID, in: tree)
        focusedID = newID
    }

    /// What a freshly split pane should show. Terminal and Coding are each backed by
    /// one shared tmux session, so splitting them into the *same* surface just mirrors
    /// the session — open the other one instead. Everything else is an independent
    /// instance, so duplicating it (two browsers, two notes) is useful.
    private static func sibling(of tab: WorkspaceTab) -> WorkspaceTab {
        switch tab {
        case .terminal: return .coding
        case .coding:   return .terminal
        default:        return tab
        }
    }

    /// Close a leaf, collapsing its parent split into the sibling. No-op on the last pane.
    func close(_ id: UUID) {
        guard paneCount > 1, let newTree = Self.removing(id, from: tree) else { return }
        tree = newTree
        if Self.tab(of: focusedID, in: tree) == nil {
            focusedID = Self.firstLeafID(tree)
        }
    }

    func setFraction(_ fraction: CGFloat, for id: UUID) {
        tree = Self.setFraction(fraction, for: id, in: tree)
    }

    // MARK: - Pure tree transforms

    private static func setTab(_ tab: WorkspaceTab, for id: UUID, in node: PaneTree) -> PaneTree {
        switch node {
        case .leaf(let nid, let t):
            return .leaf(id: nid, tab: nid == id ? tab : t)
        case .split(let nid, let axis, let f, let s, let frac):
            return .split(id: nid, axis: axis,
                          first: setTab(tab, for: id, in: f),
                          second: setTab(tab, for: id, in: s), fraction: frac)
        }
    }

    private static func setFraction(_ frac: CGFloat, for id: UUID, in node: PaneTree) -> PaneTree {
        switch node {
        case .leaf:
            return node
        case .split(let nid, let axis, let f, let s, let old):
            return .split(id: nid, axis: axis,
                          first: setFraction(frac, for: id, in: f),
                          second: setFraction(frac, for: id, in: s),
                          fraction: nid == id ? frac : old)
        }
    }

    private static func split(_ id: UUID, axis: SplitAxis, newTab: WorkspaceTab,
                              newID: UUID, in node: PaneTree) -> PaneTree {
        switch node {
        case .leaf(let nid, _):
            guard nid == id else { return node }
            return .split(id: UUID(), axis: axis, first: node,
                          second: .leaf(id: newID, tab: newTab), fraction: 0.5)
        case .split(let nid, let axis2, let f, let s, let frac):
            return .split(id: nid, axis: axis2,
                          first: split(id, axis: axis, newTab: newTab, newID: newID, in: f),
                          second: split(id, axis: axis, newTab: newTab, newID: newID, in: s),
                          fraction: frac)
        }
    }

    /// Returns the tree with the leaf `id` removed (parent split collapses to the
    /// sibling), or nil if this whole subtree was the removed leaf.
    private static func removing(_ id: UUID, from node: PaneTree) -> PaneTree? {
        switch node {
        case .leaf(let nid, _):
            return nid == id ? nil : node
        case .split(let nid, let axis, let f, let s, let frac):
            let nf = removing(id, from: f)
            let ns = removing(id, from: s)
            if nf == nil { return ns }
            if ns == nil { return nf }
            return .split(id: nid, axis: axis, first: nf!, second: ns!, fraction: frac)
        }
    }

    private static func leafCount(_ node: PaneTree) -> Int {
        switch node {
        case .leaf: return 1
        case .split(_, _, let f, let s, _): return leafCount(f) + leafCount(s)
        }
    }

    private static func tab(of id: UUID, in node: PaneTree) -> WorkspaceTab? {
        switch node {
        case .leaf(let nid, let t):
            return nid == id ? t : nil
        case .split(_, _, let f, let s, _):
            return tab(of: id, in: f) ?? tab(of: id, in: s)
        }
    }

    private static func firstLeafID(_ node: PaneTree) -> UUID {
        switch node {
        case .leaf(let id, _):        return id
        case .split(_, _, let f, _, _): return firstLeafID(f)
        }
    }
}

// MARK: - Views

/// Renders a workspace layout tree.
struct WorkspaceView: View {
    @ObservedObject var model: WorkspaceModel

    var body: some View {
        PaneNodeView(node: model.tree, model: model)
    }
}

private struct PaneNodeView: View {
    let node: PaneTree
    @ObservedObject var model: WorkspaceModel

    @ViewBuilder
    var body: some View {
        switch node {
        case .leaf(let id, let tab):
            LeafPaneView(id: id, tab: tab, model: model)
        case .split(let id, let axis, let first, let second, let fraction):
            SplitNodeView(splitID: id, axis: axis, first: first, second: second,
                          fraction: fraction, model: model)
        }
    }
}

/// A binary split: two child trees with a draggable divider. Plain HStack/VStack
/// (never NSSplitView/AnyLayout) so adding/removing children never hangs.
private struct SplitNodeView: View {
    let splitID: UUID
    let axis: SplitAxis
    let first: PaneTree
    let second: PaneTree
    let fraction: CGFloat
    @ObservedObject var model: WorkspaceModel

    @State private var dragStart: CGFloat?
    private let thickness: CGFloat = 8
    private let minFraction: CGFloat = 0.15
    private let maxFraction: CGFloat = 0.85

    var body: some View {
        GeometryReader { geo in
            let isH = axis == .horizontal
            let total = isH ? geo.size.width : geo.size.height
            let usable = max(total - thickness, 1)
            let firstExtent = usable * min(max(fraction, minFraction), maxFraction)

            if isH {
                HStack(spacing: 0) {
                    PaneNodeView(node: first, model: model).frame(width: firstExtent)
                    divider(isHorizontal: true, usable: usable)
                    PaneNodeView(node: second, model: model)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                VStack(spacing: 0) {
                    PaneNodeView(node: first, model: model).frame(height: firstExtent)
                    divider(isHorizontal: false, usable: usable)
                    PaneNodeView(node: second, model: model)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
    }

    private func divider(isHorizontal: Bool, usable: CGFloat) -> some View {
        Color.clear
            .frame(width: isHorizontal ? thickness : nil,
                   height: isHorizontal ? nil : thickness)
            .overlay(
                Rectangle()
                    .fill(Color(nsColor: .separatorColor))
                    .frame(width: isHorizontal ? 1 : nil,
                           height: isHorizontal ? nil : 1)
            )
            .contentShape(Rectangle())
            .gesture(
                DragGesture()
                    .onChanged { value in
                        let start = dragStart ?? fraction
                        if dragStart == nil { dragStart = fraction }
                        let move = (isHorizontal ? value.translation.width : value.translation.height) / usable
                        model.setFraction(min(max(start + move, minFraction), maxFraction), for: splitID)
                    }
                    .onEnded { _ in dragStart = nil }
            )
    }
}

/// A single pane: a header (content dropdown + split/close controls) over its surface.
private struct LeafPaneView: View {
    let id: UUID
    let tab: WorkspaceTab
    @ObservedObject var model: WorkspaceModel

    private var isFocused: Bool { model.focusedID == id && model.paneCount > 1 }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            WorkspaceSurface(tab: tab)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .id(id)   // tie the live surface to this leaf so it survives restructuring
        }
        .overlay(
            Rectangle().strokeBorder(
                isFocused ? Color.accentColor : Color(nsColor: .separatorColor),
                lineWidth: isFocused ? 2 : 1)
        )
        .padding(2)
        // Focus this pane on any click inside it (header or content), without
        // consuming the event — so the surface tabs always retarget where you're working.
        .simultaneousGesture(TapGesture().onEnded { model.focus(id) })
    }

    private var header: some View {
        HStack(spacing: 6) {
            Picker("Content", selection: Binding(
                get: { tab },
                set: { model.setTab($0, for: id); model.focus(id) }
            )) {
                ForEach(WorkspaceTab.allCases) { t in
                    Label(t.rawValue, systemImage: t.systemImage).tag(t)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()

            Spacer()

            Button { model.split(id, axis: .horizontal) } label: {
                Image(systemName: "rectangle.split.2x1")
            }
            .buttonStyle(.plain)
            .help("Split right")

            Button { model.split(id, axis: .vertical) } label: {
                Image(systemName: "rectangle.split.1x2")
            }
            .buttonStyle(.plain)
            .help("Split down")

            if model.paneCount > 1 {
                Button { model.close(id) } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Close pane")
            }
        }
        .font(.callout)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .onTapGesture { model.focus(id) }
    }
}
