import Foundation

/// A bd issue as emitted by `bd list --json` / `bd ready --json`. Only the fields
/// the panel needs are decoded; everything else in the JSON is ignored.
struct BdIssue: Identifiable, Decodable, Hashable {
    let id: String
    let title: String
    let description: String?
    let status: String
    let priority: Int
    let issueType: String
    let labels: [String]?
    let dependencyCount: Int?
    let dependentCount: Int?
    /// Present in `bd blocked --json` (absent in `bd list`): how many unmet
    /// dependencies are blocking this issue.
    let blockedByCount: Int?
    /// Edges this issue participates in (present in `bd list --json` when it has any).
    let dependencies: [BdDependency]?

    enum CodingKeys: String, CodingKey {
        case id, title, description, status, priority, labels, dependencies
        case issueType = "issue_type"
        case dependencyCount = "dependency_count"
        case dependentCount = "dependent_count"
        case blockedByCount = "blocked_by_count"
    }
}

/// A dependency edge: `issueId` depends on `dependsOnId` (so `dependsOnId` blocks
/// `issueId`).
struct BdDependency: Decodable, Hashable {
    let issueId: String
    let dependsOnId: String
    let type: String

    enum CodingKeys: String, CodingKey {
        case issueId = "issue_id"
        case dependsOnId = "depends_on_id"
        case type
    }
}

enum BeadsError: Error, LocalizedError {
    case command(String)

    var errorDescription: String? {
        switch self {
        case .command(let why):
            let t = why.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? "bd command failed." : t
        }
    }
}

/// Runs `bd` over SSH against per-project databases on a host. `bd` lives in
/// `~/.local/bin` (off the non-login PATH), so each call prepends that to PATH and
/// runs from the project directory so bd resolves the right `.beads`.
struct BeadsController {
    let host: Host

    /// Prepended to every bd invocation so `bd` resolves on the non-login PATH.
    private static let pathPrefix = #"PATH="$HOME/.local/bin:/opt/homebrew/bin:$PATH""#

    /// Runs `bd <arguments>` in the project directory, returning stdout. Args are
    /// shell-escaped, so untrusted values (titles, descriptions) are safe.
    @discardableResult
    func runBd(_ arguments: [String], in projectPath: String) async throws -> String {
        let bd = (["bd"] + arguments).map(SSHManager.shellEscaped).joined(separator: " ")
        let command = "cd \(SSHManager.shellEscaped(projectPath)) && \(Self.pathPrefix) \(bd)"
        let result = try await SSHManager.shared.runShell(command, on: host)
        guard result.ok else {
            // bd writes some diagnostics to stdout, not stderr — surface whichever has content.
            let detail = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? result.stdout : result.stderr
            throw BeadsError.command(detail)
        }
        return result.stdout
    }

    /// Issues from a query (e.g. `["list", "--all"]`, `["ready"]`, `["blocked"]`,
    /// `["list", "--status", "closed"]`) so bd does the filtering.
    func issues(in projectPath: String, arguments: [String]) async throws -> [BdIssue] {
        let output = try await runBd(arguments + ["--json"], in: projectPath)
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        do {
            return try JSONDecoder().decode([BdIssue].self, from: Data(trimmed.utf8))
        } catch {
            // Not a valid issue array — surface what bd actually printed (e.g. an
            // error message) rather than a generic parse failure.
            throw BeadsError.command("Unexpected bd output: \(trimmed.prefix(200))")
        }
    }

    /// Creates a new issue.
    func create(in projectPath: String, title: String, type: String,
                priority: Int, description: String) async throws {
        // `--flag=value` form so values starting with '-' aren't parsed as flags.
        var args = ["create", "--title=\(title)", "--type=\(type)", "--priority=\(priority)"]
        if !description.isEmpty { args.append("--description=\(description)") }
        try await runBd(args, in: projectPath)
    }

    /// Updates an issue. The caller supplies bd update flags, e.g.
    /// `["--status", "in_progress"]` or `["--priority", "1"]`.
    func update(in projectPath: String, id: String, fields: [String]) async throws {
        try await runBd(["update", id] + fields, in: projectPath)
    }

    /// Closes an issue.
    func close(in projectPath: String, id: String) async throws {
        try await runBd(["close", id], in: projectPath)
    }

    /// Reopens a closed issue (clears `closed_at` + emits a Reopened event — more
    /// correct than `update --status open`).
    func reopen(in projectPath: String, id: String) async throws {
        try await runBd(["reopen", id], in: projectPath)
    }

    /// Appends a note to an issue (does not replace existing notes).
    func addNote(in projectPath: String, id: String, text: String) async throws {
        // `--` terminates flag parsing so a note starting with '-' isn't read as a flag.
        try await runBd(["note", id, "--", text], in: projectPath)
    }
}
