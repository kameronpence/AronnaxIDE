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

    /// The session for a leaf, creating it (and its PTY) on first request. If the leaf's
    /// surface or project changed since last time, the existing session reopens its channel —
    /// the session (and its SwiftTerm view) persist, matching the macOS keep-the-id contract.
    func session(for id: UUID, target: AgentTarget, workdir: String) -> PaneSession {
        if let existing = sessions[id] {
            if existing.target != target || existing.workdir != workdir {
                existing.restart(target: target, workdir: workdir)
            }
            return existing
        }
        let created = PaneSession(id: id, target: target, workdir: workdir, connection: connection)
        sessions[id] = created
        return created
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

    /// Project switch: reattach only the agent panes (per-workdir tmux sessions); plain
    /// shells keep running.
    func restartAgents(workdir: String) {
        for session in sessions.values { session.restartForProject(workdir) }
    }
}
