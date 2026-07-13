import SwiftUI

/// Orientation of a split.
enum SplitAxis: Hashable, Codable {
    case horizontal   // children side by side
    case vertical     // children stacked
}

/// A recursive layout tree. Every pane is either a leaf (showing one surface) or a binary
/// split of two child trees. Arbitrary IDE-style layouts are built by nesting splits. Each
/// leaf carries a stable `id` so its live terminal survives restructuring; the payload is an
/// `AgentTarget` (Terminal / Claude / Codex).
indirect enum PaneTree: Identifiable, Codable {
    case leaf(id: UUID, target: AgentTarget)
    case split(id: UUID, axis: SplitAxis, first: PaneTree, second: PaneTree, fraction: CGFloat)

    var id: UUID {
        switch self {
        case .leaf(let id, _):            return id
        case .split(let id, _, _, _, _):  return id
        }
    }
}

/// Owns the workspace layout tree and the operations that mutate it. Ported from the macOS
/// app's WorkspaceModel; leaf payload reduced to `AgentTarget`, persisted under an iPad key.
@MainActor
final class WorkspaceModel: ObservableObject {
    @Published private(set) var tree: PaneTree {
        didSet { Self.save(tree) }
    }
    @Published var focusedID: UUID

    private static let storageKey = "ipad.workspace.layout"

    init(initial: AgentTarget = .terminal) {
        if let restored = Self.load() {
            tree = restored
            focusedID = Self.firstLeafID(restored)
        } else {
            let id = UUID()
            tree = .leaf(id: id, target: initial)
            focusedID = id
        }
    }

    private static func save(_ tree: PaneTree) {
        if let data = try? JSONEncoder().encode(tree) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }

    private static func load() -> PaneTree? {
        guard let data = UserDefaults.standard.data(forKey: storageKey) else { return nil }
        return try? JSONDecoder().decode(PaneTree.self, from: data)
    }

    var paneCount: Int { Self.leafCount(tree) }

    /// The set of live leaf ids — used to garbage-collect retired pane sessions.
    var leafIDs: Set<UUID> { Self.leafIDs(tree) }

    /// Leaf ids for PTY-backed surfaces only. Session GC keys off this so a leaf switched to a
    /// data surface (Beads) has its PTY session retired, not kept alive by the still-live id.
    var agentLeafIDs: Set<UUID> { Self.agentLeafIDs(tree) }

    func focus(_ id: UUID) { focusedID = id }

    /// The surface of the currently-focused pane — drives the top tab bar's active highlight.
    var focusedTarget: AgentTarget { Self.target(of: focusedID, in: tree) ?? .terminal }

    /// Retarget the focused pane's surface — the top tab bar's action (mirrors the desktop,
    /// where the surface tabs retarget whichever pane is focused).
    func setFocusedTarget(_ target: AgentTarget) { setTarget(target, for: focusedID) }

    func setTarget(_ target: AgentTarget, for id: UUID) {
        tree = Self.setTarget(target, for: id, in: tree)
    }

    /// Split a leaf in two along `axis`; the new pane shows the sibling surface and becomes
    /// focused. The original leaf keeps its id, so its session persists.
    func split(_ id: UUID, axis: SplitAxis) {
        guard let target = Self.target(of: id, in: tree) else { return }
        let newID = UUID()
        tree = Self.split(id, axis: axis, newTarget: Self.sibling(of: target), newID: newID, in: tree)
        focusedID = newID
    }

    /// What a freshly split pane should show. Terminal and Claude are each backed by one
    /// shared tmux session, so splitting into the *same* surface just mirrors it — open the
    /// other instead.
    private static func sibling(of target: AgentTarget) -> AgentTarget {
        switch target {
        case .terminal: return .claude
        case .claude:   return .terminal
        case .codex:    return .terminal
        case .beads:    return .terminal
        case .git:      return .terminal
        case .health:   return .terminal
        case .vault:    return .terminal
        }
    }

    /// Close a leaf, collapsing its parent split into the sibling. No-op on the last pane.
    func close(_ id: UUID) {
        guard paneCount > 1, let newTree = Self.removing(id, from: tree) else { return }
        tree = newTree
        if Self.target(of: focusedID, in: tree) == nil {
            focusedID = Self.firstLeafID(tree)
        }
    }

    func setFraction(_ fraction: CGFloat, for id: UUID) {
        tree = Self.setFraction(fraction, for: id, in: tree)
    }

    // MARK: - Pure tree transforms

    private static func setTarget(_ target: AgentTarget, for id: UUID, in node: PaneTree) -> PaneTree {
        switch node {
        case .leaf(let nid, let t):
            return .leaf(id: nid, target: nid == id ? target : t)
        case .split(let nid, let axis, let f, let s, let frac):
            return .split(id: nid, axis: axis,
                          first: setTarget(target, for: id, in: f),
                          second: setTarget(target, for: id, in: s), fraction: frac)
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

    private static func split(_ id: UUID, axis: SplitAxis, newTarget: AgentTarget,
                              newID: UUID, in node: PaneTree) -> PaneTree {
        switch node {
        case .leaf(let nid, _):
            guard nid == id else { return node }
            return .split(id: UUID(), axis: axis, first: node,
                          second: .leaf(id: newID, target: newTarget), fraction: 0.5)
        case .split(let nid, let axis2, let f, let s, let frac):
            return .split(id: nid, axis: axis2,
                          first: split(id, axis: axis, newTarget: newTarget, newID: newID, in: f),
                          second: split(id, axis: axis, newTarget: newTarget, newID: newID, in: s),
                          fraction: frac)
        }
    }

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

    private static func leafIDs(_ node: PaneTree) -> Set<UUID> {
        switch node {
        case .leaf(let id, _): return [id]
        case .split(_, _, let f, let s, _): return leafIDs(f).union(leafIDs(s))
        }
    }

    private static func agentLeafIDs(_ node: PaneTree) -> Set<UUID> {
        switch node {
        case .leaf(let id, let target): return target.isTerminal ? [id] : []
        case .split(_, _, let f, let s, _): return agentLeafIDs(f).union(agentLeafIDs(s))
        }
    }

    private static func target(of id: UUID, in node: PaneTree) -> AgentTarget? {
        switch node {
        case .leaf(let nid, let t):
            return nid == id ? t : nil
        case .split(_, _, let f, let s, _):
            return target(of: id, in: f) ?? target(of: id, in: s)
        }
    }

    private static func firstLeafID(_ node: PaneTree) -> UUID {
        switch node {
        case .leaf(let id, _):          return id
        case .split(_, _, let f, _, _): return firstLeafID(f)
        }
    }
}

// MARK: - Views

/// The top surface-tab bar (mirrors the desktop's `WorkspaceTopBar`): a row of tabs that
/// retarget the FOCUSED pane's surface, with the active surface highlighted. The per-pane
/// dropdown still switches an individual pane; these tabs act on whichever pane is focused.
/// Text-only (no icons) and horizontally scrollable so all surfaces fit on any width.
struct WorkspaceTopBar: View {
    @ObservedObject var model: WorkspaceModel

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(AgentTarget.allCases) { target in
                    let active = model.focusedTarget == target
                    Button { model.setFocusedTarget(target) } label: {
                        Text(target.label)
                            .font(.callout)
                            .padding(.horizontal, 12).padding(.vertical, 7)
                            .background(active ? Color.accentColor.opacity(0.18) : .clear,
                                        in: RoundedRectangle(cornerRadius: 7))
                            .foregroundStyle(active ? Color.accentColor : .secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
        }
    }
}

/// Renders a workspace layout tree, binding each leaf to a live terminal session.
struct WorkspaceView: View {
    @ObservedObject var model: WorkspaceModel
    let manager: PaneSessionManager
    let workdir: String

    var body: some View {
        PaneNodeView(node: model.tree, model: model, manager: manager, workdir: workdir)
            // GC sessions whose leaves were closed OR switched to a data surface (retire is a
            // no-op for still-live agent ids, so this is safe on splits too).
            .onChange(of: model.agentLeafIDs) { _, live in manager.retire(keeping: live) }
    }
}

private struct PaneNodeView: View {
    let node: PaneTree
    @ObservedObject var model: WorkspaceModel
    let manager: PaneSessionManager
    let workdir: String

    @ViewBuilder
    var body: some View {
        switch node {
        case .leaf(let id, let target):
            LeafPaneView(id: id, target: target, model: model, manager: manager, workdir: workdir)
        case .split(let id, let axis, let first, let second, let fraction):
            SplitNodeView(splitID: id, axis: axis, first: first, second: second,
                          fraction: fraction, model: model, manager: manager, workdir: workdir)
        }
    }
}

/// A binary split: two child trees with a draggable divider. Plain HStack/VStack so
/// adding/removing children never hangs.
private struct SplitNodeView: View {
    let splitID: UUID
    let axis: SplitAxis
    let first: PaneTree
    let second: PaneTree
    let fraction: CGFloat
    @ObservedObject var model: WorkspaceModel
    let manager: PaneSessionManager
    let workdir: String

    @State private var dragStart: CGFloat?
    /// Wider than the desktop's 8pt so it's a comfortable finger target on touch.
    private let thickness: CGFloat = 16
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
                    PaneNodeView(node: first, model: model, manager: manager, workdir: workdir)
                        .frame(width: firstExtent)
                    divider(isHorizontal: true, usable: usable)
                    PaneNodeView(node: second, model: model, manager: manager, workdir: workdir)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                VStack(spacing: 0) {
                    PaneNodeView(node: first, model: model, manager: manager, workdir: workdir)
                        .frame(height: firstExtent)
                    divider(isHorizontal: false, usable: usable)
                    PaneNodeView(node: second, model: model, manager: manager, workdir: workdir)
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
                    .fill(Color(uiColor: .separator))
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

/// A single pane: a header (surface switcher + split/close controls) over its surface.
/// M3 shows a placeholder surface; M4 wires the real terminal.
private struct LeafPaneView: View {
    let id: UUID
    let target: AgentTarget
    @ObservedObject var model: WorkspaceModel
    let manager: PaneSessionManager
    let workdir: String

    /// Keyboard focus: the sole pane, or the explicitly-focused one.
    private var hasKeyboard: Bool { model.focusedID == id }
    /// Show the accent border only when there's more than one pane to distinguish.
    private var showBorder: Bool { model.focusedID == id && model.paneCount > 1 }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            surface
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // Stable per-leaf identity (survives tree restructuring), but flips when the leaf
                // crosses the terminal↔data boundary so the surface cleanly swaps view types.
                .id("\(id.uuidString)-\(target.isTerminal)")
        }
        .overlay(
            Rectangle().strokeBorder(
                showBorder ? Color.accentColor : Color(uiColor: .separator),
                lineWidth: showBorder ? 2 : 1)
        )
        .padding(2)
        .simultaneousGesture(TapGesture().onEnded { model.focus(id) })
    }

    /// The pane body: a PTY-backed terminal surface, or a non-terminal data surface (Beads).
    @ViewBuilder private var surface: some View {
        switch target {
        case .terminal, .claude, .codex:
            // The session is keyed by this leaf's id; switching among terminal surfaces reopens
            // its PTY in place. Data leaves never create a session (GC'd via agentLeafIDs).
            LeafSurfaceView(session: manager.session(for: id, target: target, workdir: workdir),
                            isFocused: hasKeyboard)
        case .beads:
            BeadsView(connection: manager.connection, workdir: workdir)
        case .git:
            GitView(connection: manager.connection, workdir: workdir)
        case .health:
            HealthView(connection: manager.connection)
        case .vault:
            VaultView(connection: manager.connection)
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Picker("Surface", selection: Binding(
                get: { target },
                set: { model.setTarget($0, for: id); model.focus(id) }
            )) {
                ForEach(AgentTarget.allCases) { t in Text(t.label).tag(t) }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()

            Spacer()

            leafButton("rectangle.split.2x1") { model.split(id, axis: .horizontal) }
            leafButton("rectangle.split.1x2") { model.split(id, axis: .vertical) }
            if model.paneCount > 1 {
                leafButton("xmark") { model.close(id) }
            }
        }
        .imageScale(.large)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture { model.focus(id) }
    }

    private func leafButton(_ systemName: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .frame(minWidth: 44, minHeight: 44)   // comfortable touch target
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// The pane's live terminal plus a tap-to-reconnect overlay when its PTY has ended on its own
/// (agent quit, dropped channel). Observes the session so the overlay appears/clears with state.
private struct LeafSurfaceView: View {
    @ObservedObject var session: PaneSession
    let isFocused: Bool

    var body: some View {
        TerminalSurface(session: session, isFocused: isFocused)
            .overlay(alignment: .bottom) {
                if session.ended {
                    Button { session.attach() } label: {
                        Label("\(session.status) — tap to reconnect", systemImage: "arrow.clockwise")
                            .font(.callout)
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            .background(.thinMaterial, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .padding(.bottom, 10)
                }
            }
    }
}
