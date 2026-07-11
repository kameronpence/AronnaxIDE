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
    func session(for id: UUID, target: AgentTarget, workdir: String) -> PaneSession {
        if let existing = sessions[id] {
            if existing.target != target {
                existing.restart(target: target, workdir: workdir)
            } else if existing.workdir != workdir {
                if target == .terminal { existing.updateWorkdir(workdir) }
                else { existing.restart(target: target, workdir: workdir) }
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
}
