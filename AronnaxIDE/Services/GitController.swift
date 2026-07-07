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

    // MARK: - GitHub account selection

    /// The parsed pieces of an origin URL: the SSH host alias (or real host) that decides
    /// which key/account authenticates, plus the `owner/repo`. Works for scp-style SSH
    /// (`git@github-gatsa:GATSA/repo.git`), `ssh://`, and HTTPS remotes — unlike the
    /// `github.com`-literal parsers, this handles arbitrary aliases (`github-gatsa`).
    struct RemoteRef: Equatable {
        var host: String       // "github.com", "github-gatsa", …  (the account selector)
        var owner: String      // "kameronpence", "GATSA"
        var repo: String       // repo name, no ".git"
        var isSSH: Bool        // true for scp/ssh:// forms — only then does `host` name the account
        var slug: String { owner + "/" + repo }
    }

    static func parseRemote(_ remote: String?) -> RemoteRef? {
        guard let remote = remote?.trimmingCharacters(in: .whitespacesAndNewlines), !remote.isEmpty else { return nil }
        // Each pattern captures host, owner, repo (in that order). Tried in order:
        //   scp-style   git@host:owner/repo[.git]        (SSH — host alias = account)
        //   ssh://      ssh://git@host[:port]/owner/repo  (SSH — host alias = account)
        //   https       https://[user@]host/owner/repo   (NOT SSH — auth is via gh/credentials)
        let patterns: [(String, Bool)] = [
            (#"^(?:[^@/]+@)?([^:/]+):([^/]+)/([^/]+?)(?:\.git)?/?$"#, true),
            (#"^ssh://(?:[^@/]+@)?([^:/]+)(?::\d+)?/([^/]+)/([^/]+?)(?:\.git)?/?$"#, true),
            (#"^https?://(?:[^@/]+@)?([^/]+)/([^/]+)/([^/]+?)(?:\.git)?/?$"#, false),
        ]
        for (pattern, isSSH) in patterns {
            guard let re = try? NSRegularExpression(pattern: pattern),
                  let m = re.firstMatch(in: remote, range: NSRange(remote.startIndex..., in: remote)),
                  m.numberOfRanges > 3,
                  let h = Range(m.range(at: 1), in: remote),
                  let o = Range(m.range(at: 2), in: remote),
                  let r = Range(m.range(at: 3), in: remote) else { continue }
            return RemoteRef(host: String(remote[h]), owner: String(remote[o]), repo: String(remote[r]), isSSH: isSSH)
        }
        return nil
    }

    /// SSH host aliases on the host whose `HostName` is `github.com` — i.e. the GitHub
    /// accounts available to push as (each alias offers a different key). Always includes
    /// bare `github.com` (the default account) even if the config doesn't name it.
    /// Parsed from the host's `~/.ssh/config`, so it stays correct as accounts are added.
    func githubAccounts() async -> [String] {
        var aliases = ["github.com"]
        if let result = try? await SSHManager.shared.runShell(Self.sshConfigDumpCommand, on: host),
           result.ok {
            aliases = Self.parseGitHubAliases(result.stdout, existing: aliases)
        }
        return aliases
    }

    /// Emits `~/.ssh/config` followed by the contents of any files it pulls in via an
    /// `Include` directive (one level, `~`/relative/glob paths expanded) — so aliases kept
    /// in an included file are enumerated too, not just the ones in the top-level config.
    static let sshConfigDumpCommand =
        #"{ cat ~/.ssh/config 2>/dev/null; awk 'tolower($1)=="include"{for(i=2;i<=NF;i++)print $i}' ~/.ssh/config 2>/dev/null | while IFS= read -r p; do case "$p" in "~/"*) p="$HOME/${p#\~/}";; /*) :;; *) p="$HOME/.ssh/$p";; esac; cat $p 2>/dev/null; done; }"#

    /// From an ssh-config body, the `Host` aliases whose block resolves `HostName github.com`.
    static func parseGitHubAliases(_ config: String, existing: [String] = ["github.com"]) -> [String] {
        var result = existing
        var current: [String] = []          // aliases declared by the open `Host` line
        var hostName: String?                // this block's HostName, if any
        func flush() {
            if hostName?.caseInsensitiveCompare("github.com") == .orderedSame {
                for a in current where !result.contains(a) { result.append(a) }
            }
            current = []; hostName = nil
        }
        for raw in config.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard let key = parts.first else { continue }
            if key.caseInsensitiveCompare("Host") == .orderedSame {
                flush()                       // close the previous block
                // Aliases up to an inline comment; skip wildcard patterns.
                current = parts.dropFirst()
                    .prefix { !$0.hasPrefix("#") }
                    .filter { !$0.contains("*") }
            } else if key.caseInsensitiveCompare("HostName") == .orderedSame, parts.count > 1,
                      !parts[1].hasPrefix("#") {
                hostName = parts[1]
            }
        }
        flush()
        return result
    }

    /// Points `origin` at `alias` (an SSH host alias for github.com), preserving
    /// `owner/repo`, so pushes authenticate as that account. Rewrites HTTPS remotes to the
    /// SSH form too. Returns a short confirmation. A write — respects the caller's guards.
    @discardableResult
    func setAccount(path: String, remote: String?, alias: String) async throws -> String {
        guard let ref = Self.parseRemote(remote) else {
            throw GitError.command("Couldn't parse the origin remote — set it manually.")
        }
        let url = "git@\(alias):\(ref.owner)/\(ref.repo).git"
        let p = SSHManager.shellEscaped(path)
        let u = SSHManager.shellEscaped(url)
        _ = try await runGit("git -C \(p) remote set-url origin \(u)")
        return "origin now pushes via \(alias) (\(ref.slug))."
    }

    /// True when a remote's host is GitHub: literal `github.com`, or an SSH alias among
    /// `accounts` — the aliases `githubAccounts()` enumerated because their `HostName`
    /// resolves to github.com. Membership-based, not a name convention, so an alias like
    /// `gatsa` (HostName github.com) still counts. Keeps GitHub-only features (account
    /// picker, `gh` Actions) off non-GitHub remotes like GitLab.
    static func isGitHubHost(_ host: String?, in accounts: [String]) -> Bool {
        guard let host else { return false }
        if host.caseInsensitiveCompare("github.com") == .orderedSame { return true }
        return accounts.contains { $0.caseInsensitiveCompare(host) == .orderedSame }
    }

    /// The `owner/repo` slug from a GitHub origin URL (alias-host safe), or nil for
    /// non-GitHub remotes. Uses the shared `parseRemote`, so it resolves SSH host aliases
    /// (`git@github-gatsa:GATSA/repo.git`) that the `github.com`-literal parser missed —
    /// `gh --repo <slug>` then works even when the remote uses a non-github.com alias.
    /// `accounts` is the enumerated GitHub-alias set used to decide the host is GitHub.
    static func repoSlug(from remote: String?, accounts: [String]) -> String? {
        guard let ref = parseRemote(remote), isGitHubHost(ref.host, in: accounts) else { return nil }
        return ref.slug
    }

    /// The GitHub identity a push authenticates as: the SSH host-alias suffix
    /// (`github.com-work` → `work`, `github-gatsa` → `gatsa`) or the https userinfo username
    /// (`https://kameronpence@github.com` → `kameronpence`). Returns nil when it can't
    /// be determined — never guesses from the repo owner, which isn't the account. Bare
    /// `github.com` (no suffix) stays nil, so the common personal remote never false-warns.
    static func identity(remote: String?) -> String? {
        guard let remote, let ref = parseRemote(remote) else { return nil }
        // SSH: the account is the suffix of the HOST ALIAS ONLY — `github.com-<x>` or
        // `github-<x>` (the `.com` is optional, so `github-gatsa` is covered). Anchored to
        // `ref.host` so a repo path like `owner/github-work.git` can't be misread as the
        // account. Bare `github.com` has no trailing `-<x>`, so it stays nil — no false warning.
        if ref.isSSH {
            guard let re = try? NSRegularExpression(pattern: #"^github(?:\.com)?-([A-Za-z0-9_-]+)$"#),
                  let m = re.firstMatch(in: ref.host, range: NSRange(ref.host.startIndex..., in: ref.host)),
                  m.numberOfRanges > 1, let r = Range(m.range(at: 1), in: ref.host) else { return nil }
            return String(ref.host[r])
        }
        // HTTPS: the userinfo username, anchored at `@github.com` (so it reads the credential,
        // not a repo name), with tokens filtered out below.
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

    /// The repo owner from an origin URL. Uses the shared `parseRemote` so it resolves SSH
    /// host aliases (`git@github-gatsa:GATSA/repo.git` → `GATSA`) that the `github.com`-literal
    /// pattern missed — otherwise `GitStatus.owner` goes nil for alias remotes and the
    /// owner capsule + wrong-account check silently vanish after switching accounts.
    private static func owner(from remote: String) -> String? {
        parseRemote(remote)?.owner
    }
}
