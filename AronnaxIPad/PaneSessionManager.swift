import Foundation

/// The registry of live pane sessions — one shared `SSHConnection`, one `PaneSession` per
/// pane leaf (keyed by the leaf's `UUID`). Panes get-or-create their session here; the
/// workspace retires sessions whose leaves were closed. All PTY channels multiplex over the
/// single connection.
@MainActor
final class PaneSessionManager: ObservableObject {
    let connection: SSHConnection
    private var sessions: [UUID: PaneSession] = [:]

    init(connection: SSHConnection) { self.connection = connection }

    /// The session for a leaf, creating it (and its PTY) on first request. The session (and
    /// its SwiftTerm view) persist across restructuring — keyed by the stable leaf id. When
    /// something changed since last time:
    ///  - surface switch → reopen the channel on the new target;
    ///  - project switch → agents reattach to the new project's tmux session, but a plain
    ///    terminal keeps running (its workdir is just noted for a future reopen).
    /// Get-or-create the session for a leaf. This is a PURE getter — no restart side effects — so
    /// it's safe to call during SwiftUI body evaluation. Surface/project changes are applied
    /// separately via `apply(...)` from a view's `.onChange`, so `@Published` mutation never races
    /// the render pass. The initial values are used only when the session is first created.
    func session(for id: UUID, initialTarget: AgentTarget, initialWorkdir: String) -> PaneSession {
        if let existing = sessions[id] { return existing }
        let created = PaneSession(id: id, target: initialTarget, workdir: initialWorkdir, connection: connection)
        sessions[id] = created
        return created
    }

    /// Apply a surface/project change to a leaf's session — called from `.onChange` (not body):
    ///  - surface switch → reopen the channel on the new target;
    ///  - project switch → agents reattach to the new project's tmux session, but a plain
    ///    terminal keeps running (its workdir is just noted for a future reopen).
    func apply(target: AgentTarget, workdir: String, to id: UUID) {
        guard let session = sessions[id] else { return }
        if session.target != target {
            session.restart(target: target, workdir: workdir)
        } else if session.workdir != workdir {
            if target == .terminal { session.updateWorkdir(workdir) }
            else { session.restart(target: target, workdir: workdir) }
        }
    }

    /// Tear down and forget one leaf's session (leaf closed).
    func retire(_ id: UUID) {
        sessions[id]?.teardown()
        sessions[id] = nil
    }

    /// Garbage-collect any session whose leaf is no longer in the tree.
    func retire(keeping live: Set<UUID>) {
        for id in sessions.keys where !live.contains(id) { retire(id) }
    }

    /// Reopen every live pane's PTY — used after a background disconnect. Each session
    /// reattaches to its tmux session on kepler (agents and the plain terminal alike), so the
    /// on-screen work resumes where it left off. Safe to call once the connection is starting;
    /// each `attach` awaits the reconnected client before opening its channel.
    func reattachAll() {
        for session in sessions.values { session.attach() }
    }
}
