import Foundation

/// One tmux session on kepler. Agent sessions (`agent-claude-…` / `agent-codex-…`) are
/// classified and reverse-mapped to their project via the same FNV-1a suffix the app uses to
/// name them, so Health shows "Claude · AronnaxIDE" instead of an opaque hash.
struct HealthSession: Identifiable {
    let name: String
    let windows: Int
    let attached: Bool
    let agent: String?     // "Claude" / "Codex" / nil for a non-agent session
    let project: String?   // mapped project name, when the suffix resolves

    var id: String { name }
    var isAgent: Bool { agent != nil }

    init(name: String, windows: Int, attached: Bool, projectMap: [String: String]) {
        self.name = name
        self.windows = windows
        self.attached = attached
        if name.hasPrefix("agent-claude") {
            agent = "Claude"; project = projectMap[String(name.dropFirst("agent-claude".count))]
        } else if name.hasPrefix("agent-codex") {
            agent = "Codex"; project = projectMap[String(name.dropFirst("agent-codex".count))]
        } else {
            agent = nil; project = nil
        }
    }
}

/// Reads host + tmux-session health from kepler over the shared SSH connection. Same data-pane
/// pattern as Beads/Git; host-level (not project-scoped), read-only.
@MainActor
final class HealthService: ObservableObject {
    enum Phase: Equatable { case idle, loading, loaded, failed(String) }

    @Published private(set) var sessions: [HealthSession] = []
    @Published private(set) var uptime = ""
    @Published private(set) var phase: Phase = .idle

    private let connection: SSHConnection
    private var loadGeneration = 0

    init(connection: SSHConnection) { self.connection = connection }

    var agentSessions: [HealthSession] { sessions.filter(\.isAgent) }
    var otherSessions: [HealthSession] { sessions.filter { !$0.isAgent } }

    func load() async {
        loadGeneration += 1
        let gen = loadGeneration
        phase = .loading
        // Reverse-map: suffix (from each known project's workdir) → project name. Includes the
        // "kepler root" pseudo-project. Best-effort — refresh re-maps once projects have loaded.
        var projectMap: [String: String] = [:]
        for p in connection.projects {
            projectMap[AgentCommands.sessionSuffix(for: connection.workdir(for: p))] = p
        }
        // Capture list-sessions and distinguish the EXPECTED "no server running" (legitimately
        // zero sessions ⇒ empty list) from a real probe failure (tmux missing, unreadable socket,
        // bad format) which must surface as an error — otherwise a broken host looks healthy.
        // The command always exits 0; a real failure emits ONLY __ERR__.
        let fmt = "#{session_name}\t#{session_windows}\t#{?session_attached,1,0}"
        // Both "no server running on …" and "error connecting to … (No such file or directory)"
        // mean there's simply no tmux server (zero sessions) — tolerate as empty. A different
        // failure (permission denied, missing binary) falls through to __ERR__.
        let inner = "out=$(tmux list-sessions -F '\(fmt)' 2>&1); rc=$?; "
            + "if [ $rc -eq 0 ]; then s=\"$out\"; "
            + "elif printf '%s' \"$out\" | grep -qiE 'no server running|no such file or directory'; then s=''; "
            + "else echo __ERR__; exit 0; fi; "
            + "echo __SESSIONS__; printf '%s\\n' \"$s\"; echo __HOST__; uptime 2>/dev/null; true"
        let command = "zsh -lc \(AgentCommands.shellEscaped(inner))"
        do {
            let out = try await connection.executeCommand(command)
            guard gen == loadGeneration else { return }
            let text = String(decoding: Data(buffer: out), as: UTF8.self)
            if text.trimmingCharacters(in: .whitespacesAndNewlines) == "__ERR__" {
                phase = .failed("Couldn't read health"); return
            }
            let (parsed, host) = Self.parse(text, projectMap: projectMap)
            sessions = parsed
            uptime = host
            phase = .loaded
        } catch is CancellationError {
            guard gen == loadGeneration else { return }
            phase = .failed("Not connected")
        } catch {
            guard gen == loadGeneration else { return }
            phase = .failed("Couldn't read health")
        }
    }

    static func parse(_ text: String, projectMap: [String: String]) -> ([HealthSession], String) {
        var sessions: [HealthSession] = []
        var host = ""
        var section = ""
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line == "__SESSIONS__" || line == "__HOST__" { section = line; continue }
            if line.isEmpty { continue }
            switch section {
            case "__SESSIONS__":
                let f = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
                guard f.count == 3 else { break }
                let name = String(f[0])
                // Skip the Mac app's transient usage-probe sessions (20–30s lived) — internal,
                // not real user sessions. Matches the macOS Health filter.
                if name.hasPrefix("miniide-usage-") { break }
                sessions.append(HealthSession(name: name, windows: Int(f[1]) ?? 1,
                                              attached: f[2] == "1", projectMap: projectMap))
            case "__HOST__":
                host = host.isEmpty ? line : host + "\n" + line
            default:
                break
            }
        }
        return (sessions, host.trimmingCharacters(in: .whitespaces))
    }
}
