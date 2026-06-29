import Foundation
import Combine

/// App-wide configuration: hosts (imported from `~/.ssh/config`), GitHub accounts,
/// and the agent workdir / tmux session. The editable bits persist to UserDefaults.
final class AppSettings: ObservableObject {
    @Published var hosts: [Host]
    @Published var accounts: [GitHubAccount] {
        didSet {
            if let data = try? JSONEncoder().encode(accounts) {
                UserDefaults.standard.set(data, forKey: Keys.accounts)
            }
        }
    }
    @Published var projects: [Project]

    /// tmux session name used for the primary shell on a host.
    @Published var primaryTmuxSession: String = "main" {
        didSet { UserDefaults.standard.set(primaryTmuxSession, forKey: Keys.tmuxSession) }
    }

    /// Fallback working directory on the hub where the CLI agents launch (the Obsidian
    /// vault that is their shared "memory"). When a project is selected the panes use
    /// that project's directory instead — see `activePath`.
    @Published var agentWorkdir: String = "/Users/kepler/Documents/Projects/AI_OS" {
        didSet { UserDefaults.standard.set(agentWorkdir, forKey: Keys.agentWorkdir) }
    }

    private enum Keys {
        static let agentWorkdir = "settings.agentWorkdir"
        static let tmuxSession = "settings.primaryTmuxSession"
        static let accounts = "settings.githubAccounts"
    }

    /// The project selected in the sidebar — the directory the Coding, Vault, Beads,
    /// and Git panes all operate in. `nil` means "no project picked yet" (panes fall
    /// back to the agent workdir).
    @Published var selectedProjectPath: String?

    /// The directory the panes should work in: the selected project, else the workdir.
    var activePath: String { selectedProjectPath ?? agentWorkdir }
    var selectedProjectName: String? {
        selectedProjectPath.map { ($0 as NSString).lastPathComponent }
    }

    /// Alias of the hub in `~/.ssh/config`.
    static let hubAlias = "kepler"

    init() {
        // Discover hosts from ~/.ssh/config; always guarantee the hub is present
        // (with isHub set) even if the config can't be read or omits it.
        var discovered = SSHConfigParser.loadHosts(hubAlias: AppSettings.hubAlias)
        if let idx = discovered.firstIndex(where: {
            $0.id.caseInsensitiveCompare(AppSettings.hubAlias) == .orderedSame
        }) {
            // Fill any hub field the config omitted from the known defaults so the
            // hub connection never regresses (e.g. a missing `User`).
            if discovered[idx].user == nil { discovered[idx].user = Host.kepler.user }
        } else {
            discovered.insert(Host.kepler, at: 0)
        }
        self.hosts = discovered
        self.accounts = [
            GitHubAccount(id: "personal", displayName: "Personal",
                          sshHostAlias: "github.com", email: "kameronpence@gmail.com")
        ]
        self.projects = []

        // Apply persisted overrides. These are subsequent assignments (the stored
        // properties already have initial values), so they fire the persistence
        // didSet — harmless and idempotent.
        let defaults = UserDefaults.standard
        if let workdir = defaults.string(forKey: Keys.agentWorkdir) { agentWorkdir = workdir }
        if let session = defaults.string(forKey: Keys.tmuxSession) { primaryTmuxSession = session }
        if let data = defaults.data(forKey: Keys.accounts),
           let decoded = try? JSONDecoder().decode([GitHubAccount].self, from: data) {
            accounts = decoded
        }
    }

    var hub: Host? { hosts.first(where: { $0.isHub }) ?? hosts.first }
}
