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

    enum CodingKeys: String, CodingKey {
        case id, title, description, status, priority, labels
        case issueType = "issue_type"
        case dependencyCount = "dependency_count"
        case dependentCount = "dependent_count"
        case blockedByCount = "blocked_by_count"
    }
}

/// A bd project on a host: a directory containing a `.beads` database.
struct BdProject: Identifiable, Hashable {
    let path: String
    var id: String { path }
    var name: String { (path as NSString).lastPathComponent }
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

    /// Project directories (those containing a `.beads`) under `root`.
    func discoverProjects(under root: String) async throws -> [BdProject] {
        let result = try await SSHManager.shared.run(
            ["find", root, "-maxdepth", "3", "-name", ".beads", "-type", "d"], on: host)
        guard result.ok else { throw BeadsError.command(result.stderr) }
        return result.stdout
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
            .map { $0.hasSuffix("/.beads") ? String($0.dropLast("/.beads".count)) : $0 }
            .sorted()
            .map { BdProject(path: $0) }
    }

    /// Runs `bd <arguments> --json` in the project directory and decodes the issues.
    /// The caller picks the query (e.g. `["list", "--all"]`, `["ready"]`,
    /// `["blocked"]`, `["list", "--status", "closed"]`) so bd does the filtering.
    func issues(in projectPath: String, arguments: [String]) async throws -> [BdIssue] {
        let bd = (["bd"] + arguments + ["--json"]).map(SSHManager.shellEscaped).joined(separator: " ")
        let command = "cd \(SSHManager.shellEscaped(projectPath)) && \(Self.pathPrefix) \(bd)"
        let result = try await SSHManager.shared.runShell(command, on: host)
        guard result.ok else {
            // bd writes some diagnostics to stdout, not stderr — surface whichever has content.
            let detail = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? result.stdout : result.stderr
            throw BeadsError.command(detail)
        }
        let trimmed = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        do {
            return try JSONDecoder().decode([BdIssue].self, from: Data(trimmed.utf8))
        } catch {
            // Not a valid issue array — surface what bd actually printed (e.g. an
            // error message) rather than a generic parse failure.
            throw BeadsError.command("Unexpected bd output: \(trimmed.prefix(200))")
        }
    }
}
