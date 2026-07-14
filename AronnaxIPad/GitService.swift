import Foundation

/// A working-tree change from `git status --porcelain` (2-char XY code + path).
struct GitChange: Identifiable {
    let code: String
    let path: String
    /// Stable across reloads (a path is unique within one status output) so the list diffs
    /// instead of re-animating every row on refresh.
    var id: String { code + path }
    /// The full set of porcelain-v1 unmerged (conflict) codes — all must be detected as a whole,
    /// since e.g. `AA`/`DD` would otherwise look like an ordinary add/delete on the first column.
    private static let unmerged: Set<String> = ["DD", "AU", "UD", "UA", "DU", "AA", "UU"]

    /// A human word for the change. Conflicts are matched on the whole 2-char code first; other
    /// states use the more meaningful non-space column.
    var label: String {
        if Self.unmerged.contains(code) { return "conflict" }
        let c = code.trimmingCharacters(in: .whitespaces)
        switch c.first {
        case "M": return "modified"
        case "A": return "added"
        case "D": return "deleted"
        case "R": return "renamed"
        case "C": return "copied"
        case "?": return "untracked"
        default:  return "changed"
        }
    }
}

/// One `git log` entry (short hash + subject).
struct GitCommit: Identifiable {
    let id: String       // short hash
    let subject: String
}

/// Parsed `git` state for the active project.
struct GitInfo {
    var branch = ""
    var ahead = 0
    var behind = 0
    var hasUpstream = false
    var changes: [GitChange] = []
    var commits: [GitCommit] = []
}

/// Runs read-only `git` over the shared SSH connection and parses it, so a pane can show the
/// active project's branch, ahead/behind, working-tree changes, and recent commits. Same
/// data-pane pattern as `BeadsService` (login shell in the project dir, marker-delimited output,
/// generation-guarded loads). Read-only for v1 — no commit/push actions.
@MainActor
final class GitService: ObservableObject {
    enum Phase: Equatable {
        case idle, loading, loaded, empty
        case failed(String)
    }

    @Published private(set) var info = GitInfo()
    @Published private(set) var phase: Phase = .idle

    private let connection: SSHConnection
    private var loadGeneration = 0

    init(connection: SSHConnection) { self.connection = connection }

    /// One command emits every section behind a marker and always exits 0, so we can tell
    /// not-a-repo (`__NOTREPO__` ⇒ empty) from an operational failure (`__ERR__` ⇒ error) —
    /// Citadel's executeCommand throws on any nonzero exit, which would otherwise merge them.
    func load(workdir: String) async {
        loadGeneration += 1
        let gen = loadGeneration
        phase = .loading
        let dir = AgentCommands.shellEscaped(workdir)
        // Run `status` FIRST into a var so a genuine failure (permissions, corruption) emits ONLY
        // __ERR__ and never gets masked by the trailing `true`. The tolerated failures stay
        // tolerated: no upstream (rev-list) and no commits yet (log) just produce empty sections.
        let inner = "cd \(dir) 2>/dev/null && { if git rev-parse --git-dir >/dev/null 2>&1; then "
            + "st=$(git status --porcelain 2>/dev/null) || { echo __ERR__; exit 0; }; "
            + "echo __BRANCH__; git rev-parse --abbrev-ref HEAD 2>/dev/null; "
            + "echo __AB__; git rev-list --count --left-right @{u}...HEAD 2>/dev/null; "
            + "echo __STATUS__; printf '%s\\n' \"$st\"; "
            + "echo __LOG__; git log -15 --pretty=format:'%h %s' 2>/dev/null; "
            + "true; else echo __NOTREPO__; fi } || echo __ERR__"
        let command = "zsh -lc \(AgentCommands.shellEscaped(inner))"
        do {
            let out = try await connection.executeCommand(command)
            guard gen == loadGeneration else { return }
            let text = String(decoding: Data(buffer: out), as: UTF8.self)
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            switch trimmed {
            case "__NOTREPO__", "":
                info = GitInfo(); phase = .empty
            case "__ERR__":
                phase = .failed("Couldn't read git")
            default:
                info = Self.parse(text)
                phase = .loaded
            }
        } catch is CancellationError {
            guard gen == loadGeneration else { return }
            phase = .failed("Not connected")
        } catch {
            guard gen == loadGeneration else { return }
            phase = .failed("Couldn't read git")
        }
    }

    /// Marker-delimited parse. `__AB__` is `git rev-list --left-right` output: `behind<TAB>ahead`
    /// (empty when there's no upstream).
    static func parse(_ text: String) -> GitInfo {
        var info = GitInfo()
        var section = ""
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line == "__BRANCH__" || line == "__AB__" || line == "__STATUS__" || line == "__LOG__" {
                section = line; continue
            }
            if line == "__NOTREPO__" || line == "__ERR__" || line.isEmpty { continue }
            switch section {
            case "__BRANCH__":
                info.branch = line
            case "__AB__":
                let parts = line.split(separator: "\t")
                if parts.count == 2, let b = Int(parts[0]), let a = Int(parts[1]) {
                    info.behind = b; info.ahead = a; info.hasUpstream = true
                }
            case "__STATUS__":
                guard line.count >= 3 else { break }
                let code = String(line.prefix(2))
                let path = String(line.dropFirst(3))
                info.changes.append(GitChange(code: code, path: path))
            case "__LOG__":
                if let sp = line.firstIndex(of: " ") {
                    info.commits.append(GitCommit(id: String(line[..<sp]),
                                                  subject: String(line[line.index(after: sp)...])))
                }
            default:
                break
            }
        }
        return info
    }
}
