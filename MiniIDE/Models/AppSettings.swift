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

    init() {
        self.hosts = [Host.placeholderMini]
        self.accounts = [
            GitHubAccount(id: "personal", displayName: "Personal",
                          sshHostAlias: "github.com", email: "kameronpence@gmail.com")
        ]
        self.projects = []
    }

    var hub: Host? { hosts.first(where: { $0.isHub }) ?? hosts.first }
}
