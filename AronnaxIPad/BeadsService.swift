import Foundation

/// One issue from `bd … --json`. Only the fields the pane renders are decoded; bd emits more.
struct Bead: Identifiable, Decodable, Equatable {
    let id: String
    let title: String
    let status: String
    let priority: Int
    let issueType: String

    enum CodingKeys: String, CodingKey {
        case id, title, status, priority
        case issueType = "issue_type"
    }

    /// P0…P4 label; bd priorities are ints (0 = critical).
    var priorityLabel: String { "P\(priority)" }
}

/// Runs the beads CLI (`bd`) on kepler over the shared SSH connection and parses its JSON, so a
/// pane can show the active project's issues. This is the first "data pane" — the same
/// run-a-command-and-render pattern Git / Vault / Health will reuse. Read-only for v1.
@MainActor
final class BeadsService: ObservableObject {
    enum Phase: Equatable {
        case idle, loading, loaded, empty
        case failed(String)
    }

    @Published private(set) var beads: [Bead] = []
    @Published private(set) var phase: Phase = .idle

    private let connection: SSHConnection
    /// Bumped on every load(). A load only publishes if it's still the latest, so a slow request
    /// for a previous project (or a superseded refresh) can't overwrite newer results.
    private var loadGeneration = 0

    init(connection: SSHConnection) { self.connection = connection }

    /// Beads grouped by their ACTUAL status, most-actionable first. `bd list` omits closed
    /// issues; it does not emit a "blocked" status (blocked issues stay `open`), so we don't
    /// fabricate a Blocked/Ready split we can't derive from this data — we just show the real
    /// statuses. Any unexpected status still appears (title-cased) rather than being dropped.
    var groups: [(title: String, beads: [Bead])] {
        let rank = ["in_progress": 0, "open": 1, "blocked": 2, "deferred": 3]
        let titles = ["in_progress": "In Progress", "open": "Open",
                      "blocked": "Blocked", "deferred": "Deferred"]
        return Dictionary(grouping: beads, by: \.status)
            .sorted { (rank[$0.key] ?? 99) < (rank[$1.key] ?? 99) }
            .map { status, items in
                (titles[status] ?? status.capitalized, items.sorted { $0.priority < $1.priority })
            }
    }

    /// Fetch the active project's issues. `bd` lives in ~/.local/bin, which a bare exec channel
    /// may not have on PATH, so we run it through a login shell in the project dir.
    ///
    /// The command always exits 0 and reports its outcome via a marker so we can tell the cases
    /// apart (Citadel's executeCommand throws on ANY nonzero exit, which would otherwise collapse
    /// them all): `bd where` probes for a resolvable `.beads` DB → `__NODB__` (a project with no
    /// beads: empty, not an error); a failed `bd list` or bad dir → `__ERR__` (a real failure the
    /// user should see); otherwise the JSON array.
    func load(workdir: String) async {
        loadGeneration += 1
        let gen = loadGeneration
        phase = .loading
        let dir = AgentCommands.shellEscaped(workdir)
        let inner = "cd \(dir) 2>/dev/null && { if bd where >/dev/null 2>&1; then "
            + "bd list --json 2>/dev/null || echo __ERR__; else echo __NODB__; fi } || echo __ERR__"
        let command = "zsh -lc \(AgentCommands.shellEscaped(inner))"
        do {
            let out = try await connection.executeCommand(command)
            guard gen == loadGeneration else { return }   // superseded by a newer load
            let trimmed = String(decoding: Data(buffer: out), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            switch trimmed {
            case "__NODB__", "":
                beads = []; phase = .empty
            case "__ERR__":
                phase = .failed("Couldn't read beads")
            default:
                let decoded = try JSONDecoder().decode([Bead].self, from: Data(trimmed.utf8))
                beads = decoded
                phase = decoded.isEmpty ? .empty : .loaded
            }
        } catch is CancellationError {
            guard gen == loadGeneration else { return }
            phase = .failed("Not connected")
        } catch {
            guard gen == loadGeneration else { return }
            phase = .failed("Couldn't read beads")
        }
    }
}
