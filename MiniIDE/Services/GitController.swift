import Foundation

/// Git status for one repository on a host.
struct GitStatus: Equatable {
    var branch: String?
    var ahead: Int = 0
    var behind: Int = 0
    var dirty: Int = 0
    var dirtyKnown = true
    var remote: String?
    var owner: String?
    var commits: [String] = []
    var valid = false

    var isClean: Bool { dirty == 0 }
}

enum GitError: Error, LocalizedError {
    case command(String)
    var errorDescription: String? {
        switch self {
        case .command(let why):
            let t = why.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? "git command failed." : t
        }
    }
}

/// Read-only git inspection over SSH: branch, ahead/behind, dirty count, the origin
/// remote (+ owner), and recent commits for a repo on a host.
struct GitController {
    let host: Host

    func status(path: String) async throws -> GitStatus {
        let p = SSHManager.shellEscaped(path)
        let command = """
        echo "VALID:$(git -C \(p) rev-parse --is-inside-work-tree 2>/dev/null)"
        echo "BRANCH:$(git -C \(p) rev-parse --abbrev-ref HEAD 2>/dev/null)"
        echo "AHEAD:$(git -C \(p) rev-list --count @{u}..HEAD 2>/dev/null)"
        echo "BEHIND:$(git -C \(p) rev-list --count HEAD..@{u} 2>/dev/null)"
        if st=$(git -C \(p) status --porcelain 2>/dev/null); then echo "DIRTY:$(printf '%s' "$st" | grep -c .)"; else echo "DIRTY:?"; fi
        echo "REMOTE:$(git -C \(p) remote get-url origin 2>/dev/null)"
        echo "---LOG---"
        git -C \(p) log -6 --pretty=format:'%h %s' 2>/dev/null || true
        """
        let result = try await SSHManager.shared.runShell(command, on: host)
        guard result.ok else {
            let detail = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? result.stdout : result.stderr
            throw GitError.command(detail)
        }
        let status = Self.parse(result.stdout)
        guard status.valid else { throw GitError.command("Not a readable git repository.") }
        return status
    }

    static func parse(_ text: String) -> GitStatus {
        var s = GitStatus()
        var inLog = false
        for line in text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if line == "---LOG---" { inLog = true; continue }
            if inLog {
                if !line.trimmingCharacters(in: .whitespaces).isEmpty { s.commits.append(line) }
                continue
            }
            if let v = value(line, "VALID:") { s.valid = (v == "true") }
            else if let v = value(line, "BRANCH:") { s.branch = v.isEmpty ? nil : v }
            else if let v = value(line, "AHEAD:") { s.ahead = Int(v) ?? 0 }
            else if let v = value(line, "BEHIND:") { s.behind = Int(v) ?? 0 }
            else if let v = value(line, "DIRTY:") {
                if let n = Int(v) { s.dirty = n } else { s.dirtyKnown = false }
            }
            else if let v = value(line, "REMOTE:") {
                s.remote = v.isEmpty ? nil : v
                s.owner = owner(from: v)
            }
        }
        return s
    }

    private static func value(_ line: String, _ prefix: String) -> String? {
        guard line.hasPrefix(prefix) else { return nil }
        return String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
    }

    private static func owner(from remote: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: #"github\.com[^/:]*[:/]([^/]+)/"#),
              let m = re.firstMatch(in: remote, range: NSRange(remote.startIndex..., in: remote)),
              m.numberOfRanges > 1,
              let r = Range(m.range(at: 1), in: remote) else { return nil }
        return String(remote[r])
    }
}
