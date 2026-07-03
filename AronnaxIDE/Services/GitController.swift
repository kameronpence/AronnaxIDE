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

/// A GitHub Actions workflow run (from `gh run list --json`).
struct ActionRun: Decodable, Identifiable, Hashable {
    let status: String            // queued, in_progress, completed
    let conclusion: String?       // success, failure, cancelled, … (nil while running)
    let workflowName: String
    let headBranch: String?
    let createdAt: String

    var id: String { workflowName + createdAt }
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

    // MARK: - Actions (write — user-triggered)

    /// Stages everything and commits with `message`. Throws git's error on failure
    /// (e.g. nothing to commit, no identity configured).
    @discardableResult
    func commit(path: String, message: String) async throws -> String {
        let p = SSHManager.shellEscaped(path)
        let m = SSHManager.shellEscaped(message)
        return try await runGit("git -C \(p) add -A && git -C \(p) commit -m \(m)")
    }

    /// Pushes the current branch to its upstream. This is the step that triggers any
    /// GitHub Actions deploy workflow.
    @discardableResult
    func push(path: String) async throws -> String {
        let p = SSHManager.shellEscaped(path)
        // Explicit origin + current branch so it matches the confirmation, not whatever
        // implicit upstream happens to be configured.
        return try await runGit("git -C \(p) push origin HEAD")
    }

    /// Local branch names, with the current one first.
    func branches(path: String) async throws -> [String] {
        let p = SSHManager.shellEscaped(path)
        let out = try await runGit("git -C \(p) branch --format='%(refname:short)'")
        return out.split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Checks out `branch`. Refuses when the working tree is dirty: a plain
    /// `git checkout` silently carries non-conflicting uncommitted changes onto the
    /// target branch, so we require a clean tree and tell the user to commit/stash.
    @discardableResult
    func checkout(path: String, branch: String) async throws -> String {
        let p = SSHManager.shellEscaped(path)
        let b = SSHManager.shellEscaped(branch)
        let dirty = try await runGit("git -C \(p) status --porcelain")
        guard dirty.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw GitError.command(
                "Working tree has uncommitted changes — commit or stash before switching branches.")
        }
        return try await runGit("git -C \(p) checkout \(b)")
    }

    /// Commits across all branches whose message matches `query` (case-insensitive),
    /// newest first, as "<short-hash> <subject>" lines (capped at 50).
    func searchCommits(path: String, query: String) async throws -> [String] {
        let p = SSHManager.shellEscaped(path)
        let q = SSHManager.shellEscaped(query)
        let out = try await runGit(
            "git -C \(p) log --all -i --grep=\(q) --pretty=format:'%h %s' -50")
        return out.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }

    @discardableResult
    private func runGit(_ command: String) async throws -> String {
        // GIT_TERMINAL_PROMPT=0 so a credential prompt fails fast instead of hanging
        // the SSH command (there's no TTY to answer it).
        let full = #"export PATH="$HOME/.local/bin:/opt/homebrew/bin:$PATH" GIT_TERMINAL_PROMPT=0; "# + command
        let result = try await SSHManager.shared.runShell(full, on: host)
        guard result.ok else {
            let detail = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? result.stdout : result.stderr
            throw GitError.command(detail)
        }
        return result.stdout + result.stderr   // git writes push/commit info to both
    }

    /// Recent GitHub Actions runs for the repo (via `gh`). Returns [] if gh is
    /// unavailable, the repo has no Actions, or access is denied.
    func actionRuns(path: String, slug: String?) async -> [ActionRun] {
        let p = SSHManager.shellEscaped(path)
        // Pass --repo so gh resolves the repo even when the remote uses an SSH host
        // alias (git@github.com-work:…) that gh's auto-detection can't map.
        let repoArg = slug.map { "--repo \(SSHManager.shellEscaped($0)) " } ?? ""
        let command = #"export PATH="$HOME/.local/bin:/opt/homebrew/bin:$PATH"; "#
            + "cd \(p) && gh run list \(repoArg)--limit 5 --json status,conclusion,workflowName,headBranch,createdAt 2>/dev/null"
        guard let result = try? await SSHManager.shared.runShell(command, on: host), result.ok else { return [] }
        let trimmed = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([ActionRun].self, from: data)) ?? []
    }

    /// The `owner/repo` slug from an origin URL (alias-host safe), or nil.
    static func repoSlug(from remote: String?) -> String? {
        guard let remote,
              let re = try? NSRegularExpression(pattern: #"github\.com[^/:]*(?::\d+)?[:/]([^/]+/[^/]+)"#),
              let m = re.firstMatch(in: remote, range: NSRange(remote.startIndex..., in: remote)),
              m.numberOfRanges > 1, let r = Range(m.range(at: 1), in: remote) else { return nil }
        var slug = String(remote[r])
        if slug.hasSuffix(".git") { slug = String(slug.dropLast(4)) }
        return slug
    }

    /// The GitHub identity a push authenticates as: the SSH host-alias suffix
    /// (`github.com-work` → `work`) or the https userinfo username
    /// (`https://kameronpence@github.com` → `kameronpence`). Returns nil when it can't
    /// be determined — never guesses from the repo owner, which isn't the account.
    static func identity(remote: String?) -> String? {
        guard let remote else { return nil }
        if let re = try? NSRegularExpression(pattern: #"github\.com-([A-Za-z0-9_-]+)"#),
           let m = re.firstMatch(in: remote, range: NSRange(remote.startIndex..., in: remote)),
           m.numberOfRanges > 1, let r = Range(m.range(at: 1), in: remote) {
            return String(remote[r])
        }
        if let re = try? NSRegularExpression(pattern: #"://([^:/@]+)(?::[^@]*)?@github\.com"#),
           let m = re.firstMatch(in: remote, range: NSRange(remote.startIndex..., in: remote)),
           m.numberOfRanges > 1, let r = Range(m.range(at: 1), in: remote) {
            let user = String(remote[r])
            let tokenMarkers = ["x-access-token", "oauth2", "git", "token"]
            // Only surface a value that looks like a real GitHub username (alphanumeric +
            // hyphen, ≤39 chars). Tokens — underscores, 40-char hex, ghp_/github_pat_… —
            // and token markers are rejected so a PAT embedded in the URL is never shown.
            if !tokenMarkers.contains(user.lowercased()),
               user.range(of: #"^[A-Za-z0-9-]{1,39}$"#, options: .regularExpression) != nil {
                return user
            }
            return nil
        }
        return nil
    }

    private static func owner(from remote: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: #"github\.com[^/:]*(?::\d+)?[:/]([^/]+)/"#),
              let m = re.firstMatch(in: remote, range: NSRange(remote.startIndex..., in: remote)),
              m.numberOfRanges > 1,
              let r = Range(m.range(at: 1), in: remote) else { return nil }
        return String(remote[r])
    }
}
