import Foundation
import Combine

/// App-wide configuration. For M0 this is in-memory with sensible defaults;
/// persistence (UserDefaults + config file) and ~/.ssh/config import land later.
final class AppSettings: ObservableObject {
    @Published var hosts: [Host]
    @Published var accounts: [GitHubAccount]
    @Published var projects: [Project]

    /// tmux session name used for the primary shell on a host.
    @Published var primaryTmuxSession: String = "main"

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
    }

    var hub: Host? { hosts.first(where: { $0.isHub }) ?? hosts.first }
}
