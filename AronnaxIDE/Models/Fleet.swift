import Foundation

/// How the app reaches a machine over SSH.
enum HostReach: Codable, Hashable {
    case direct
    case proxyJump(via: String) // host id/alias of the jump host (the mini)
}

/// A machine the app can connect to. The mini is the hub; EC2/Lightsail are
/// reached via ProxyJump through it.
struct Host: Identifiable, Codable, Hashable {
    var id: String          // stable id / ssh alias, e.g. "mini", "ec2-staging"
    var displayName: String
    var sshAlias: String    // what we pass to `ssh` (often == id, from ~/.ssh/config)
    var user: String?
    var reach: HostReach
    var isHub: Bool          // true for the mini

    /// The hub: Kameron's Mac mini, reached via the `kepler` alias in `~/.ssh/config`
    /// (User kepler). Point that alias's HostName at kepler's **Tailscale** IP
    /// (100.106.82.21) — it works on any network (Tailscale routes over the LAN directly
    /// when home), whereas the LAN IP (10.63.1.x, DHCP-assigned) only works at home and
    /// drifts. The iOS app uses the same Tailscale IP, which is why it connects anywhere.
    static let kepler = Host(
        id: "kepler", displayName: "Kepler (Mac mini)", sshAlias: "kepler",
        user: "kepler", reach: .direct, isHub: true
    )
}

/// A named GitHub identity. The actual keys live on the host's ~/.ssh; the app
/// only selects/displays which identity a project uses.
struct GitHubAccount: Identifiable, Codable, Hashable {
    var id: String          // "personal", "work"
    var displayName: String
    var sshHostAlias: String // e.g. "github.com-personal"
    var email: String
}

/// Ties code location + GitHub identity + deploy target together.
struct Project: Identifiable, Codable, Hashable {
    var id: String
    var name: String
    var hostID: String       // where the repo lives
    var path: String         // repo path on that host
    var accountID: String    // GitHubAccount.id used for pushes
    var deployHostID: String? // where it deploys (prod EC2, Lightsail, …)
}
