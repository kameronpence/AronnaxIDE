import Foundation
import SwiftUI

/// A git repository discovered on a host: its path, current branch, and the
/// GitHub owner parsed from its `origin` remote (so you can see at a glance which
/// identity it pushes under — e.g. `kameronpence` vs `GATSA`).
struct DiscoveredProject: Identifiable, Hashable {
    let path: String
    var branch: String?
    var remote: String?
    var owner: String?

    var id: String { path }
    var name: String { (path as NSString).lastPathComponent }
}

/// Discovers git repositories on a host under a root directory (e.g. the agent
/// workdir on the hub) and exposes them for the sidebar. Read-only: it only runs
/// `find` + `git rev-parse` / `git remote`.
@MainActor
final class ProjectService: ObservableObject {
    @Published var projects: [DiscoveredProject] = []
    @Published var isLoading = false

    private var host: Host?
    private var root = ""
    private var started = false

    func start(host: Host?, root: String) {
        guard !started else { return }
        started = true
        self.host = host
        self.root = root
        refresh()
    }

    func refresh() {
        guard let host, !isLoading else { return }
        isLoading = true
        let root = self.root
        Task {
            // Keep the last-known list if discovery fails (nil); only overwrite on a
            // real result, so a transient SSH hiccup doesn't blank the sidebar.
            if let found = await Self.discover(host: host, root: root) {
                self.projects = found
            }
            self.isLoading = false
        }
    }

    private static func discover(host: Host, root: String) async -> [DiscoveredProject]? {
        let dir = SSHManager.shellEscaped(root)
        let command = """
        find \(dir) -maxdepth 3 -name .git -type d 2>/dev/null | while IFS= read -r d; do
          repo=$(dirname "$d")
          br=$(git -C "$repo" rev-parse --abbrev-ref HEAD 2>/dev/null)
          rm=$(git -C "$repo" remote get-url origin 2>/dev/null)
          printf '%s\\t%s\\t%s\\n' "$repo" "$br" "$rm"
        done
        """
        guard let result = try? await SSHManager.shared.runShell(command, on: host),
              result.ok else { return nil }
        return result.stdout
            .split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { line -> DiscoveredProject? in
                let parts = line.components(separatedBy: "\t")
                guard let path = parts.first, !path.isEmpty else { return nil }
                let branch = parts.count > 1 && !parts[1].isEmpty ? parts[1] : nil
                let remote = parts.count > 2 && !parts[2].isEmpty ? parts[2] : nil
                return DiscoveredProject(path: path, branch: branch, remote: remote,
                                         owner: owner(from: remote))
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// The GitHub owner segment of an origin URL — handles plain `github.com[:/]<owner>/`
    /// and SSH host aliases like `github.com-work:<owner>/`.
    private static func owner(from remote: String?) -> String? {
        guard let remote,
              let re = try? NSRegularExpression(pattern: #"github\.com[^/:]*[:/]([^/]+)/"#),
              let m = re.firstMatch(in: remote, range: NSRange(remote.startIndex..., in: remote)),
              m.numberOfRanges > 1,
              let r = Range(m.range(at: 1), in: remote) else { return nil }
        return String(remote[r])
    }
}
