import Foundation
import Combine

/// App-wide configuration: hosts (imported from `~/.ssh/config`), GitHub accounts,
/// and the agent workdir / tmux session. The editable bits persist to UserDefaults.
final class AppSettings: ObservableObject {
    /// Hosts shown across the app: discovered from `~/.ssh/config` plus any the user
    /// added in Settings (persisted). Read-only — mutate via `addHost`/`removeHost`.
    @Published private(set) var hosts: [Host] = []
    private var discoveredHosts: [Host] = []
    private var customHosts: [Host] = []
    @Published var projects: [Project]

    // MARK: - SSH write guardrails
    /// Hosts flagged "protected" — the Terminal warns + confirms before connecting.
    @Published private(set) var protectedHostIDs: Set<String> = []
    /// Hosts flagged "read-only" — the app blocks its own writes (vault save, git
    /// commit/push/checkout, beads changes) that target them.
    @Published private(set) var readOnlyHostIDs: Set<String> = []
    /// When true, every app-initiated write asks for confirmation first (all hosts).
    @Published var confirmWrites = false {
        didSet { UserDefaults.standard.set(confirmWrites, forKey: Keys.confirmWrites) }
    }

    func isProtected(_ host: Host?) -> Bool { host.map { protectedHostIDs.contains($0.id) } ?? false }
    func isReadOnly(_ host: Host?) -> Bool { host.map { readOnlyHostIDs.contains($0.id) } ?? false }

    func setProtected(_ id: String, _ on: Bool) {
        if on { protectedHostIDs.insert(id) } else { protectedHostIDs.remove(id) }
        UserDefaults.standard.set(Array(protectedHostIDs), forKey: Keys.protectedHosts)
    }
    func setReadOnly(_ id: String, _ on: Bool) {
        if on { readOnlyHostIDs.insert(id) } else { readOnlyHostIDs.remove(id) }
        UserDefaults.standard.set(Array(readOnlyHostIDs), forKey: Keys.readOnlyHosts)
    }

    /// tmux session name used for the primary shell on a host.
    @Published var primaryTmuxSession: String = "main" {
        didSet { UserDefaults.standard.set(primaryTmuxSession, forKey: Keys.tmuxSession) }
    }

    /// The Obsidian vault on the hub — the agents' shared "memory" and the Vault pane's
    /// root. Also the agents' fallback launch dir when no project is selected. Project
    /// code lives under `projectsRoot` (`<vault>/Projects`).
    @Published var agentWorkdir: String = "/Users/kepler/Documents/AI_OS" {
        didSet { UserDefaults.standard.set(agentWorkdir, forKey: Keys.agentWorkdir) }
    }

    /// Where project folders live: `<vault>/Projects`.
    var projectsRoot: String { (agentWorkdir as NSString).appendingPathComponent("Projects") }

    /// Per-agent permission posture the Coding pane launches each agent with — the
    /// two CLIs have different modes, so they're tracked separately. Switching one
    /// relaunches only that agent's session in the new mode.
    @Published var claudeMode: ClaudeMode = .acceptEdits {
        didSet { UserDefaults.standard.set(claudeMode.rawValue, forKey: Keys.claudeMode) }
    }
    @Published var codexMode: CodexMode = .askForApproval {
        didSet { UserDefaults.standard.set(codexMode.rawValue, forKey: Keys.codexMode) }
    }

    private enum Keys {
        static let agentWorkdir = "settings.agentWorkdir"
        static let tmuxSession = "settings.primaryTmuxSession"
        static let customHosts = "settings.customHosts"
        static let protectedHosts = "settings.protectedHosts"
        static let readOnlyHosts = "settings.readOnlyHosts"
        static let confirmWrites = "settings.confirmWrites"
        static let claudeMode = "settings.claudeMode"
        static let codexMode = "settings.codexMode"
    }

    /// Add (or replace by id) a user-defined host and persist it.
    func addHost(_ host: Host) {
        customHosts.removeAll { $0.id == host.id }
        customHosts.append(host)
        saveCustomHosts()
        rebuildHosts()
    }

    /// Remove a user-added host. Discovered (ssh-config) and hub hosts can't be removed.
    func removeHost(id: String) {
        guard customHosts.contains(where: { $0.id == id }) else { return }
        customHosts.removeAll { $0.id == id }
        saveCustomHosts()
        rebuildHosts()
    }

    /// True for hosts the user added (and can remove) vs. discovered/hub hosts.
    func isCustomHost(_ id: String) -> Bool { customHosts.contains { $0.id == id } }

    private func rebuildHosts() {
        var merged = discoveredHosts
        for host in customHosts where !merged.contains(where: { $0.id == host.id }) {
            merged.append(host)
        }
        hosts = merged
    }

    private func saveCustomHosts() {
        if let data = try? JSONEncoder().encode(customHosts) {
            UserDefaults.standard.set(data, forKey: Keys.customHosts)
        }
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
        self.discoveredHosts = discovered
        self.projects = []

        // Apply persisted overrides. These are subsequent assignments (the stored
        // properties already have initial values), so they fire the persistence
        // didSet — harmless and idempotent.
        let defaults = UserDefaults.standard
        if let workdir = defaults.string(forKey: Keys.agentWorkdir) { agentWorkdir = workdir }
        // Migrate the old vault location to the restructured one.
        if agentWorkdir == "/Users/kepler/Documents/Projects/AI_OS" {
            agentWorkdir = "/Users/kepler/Documents/AI_OS"
        }
        if let session = defaults.string(forKey: Keys.tmuxSession) { primaryTmuxSession = session }
        if let data = defaults.data(forKey: Keys.customHosts),
           let decoded = try? JSONDecoder().decode([Host].self, from: data) {
            customHosts = decoded
        }
        protectedHostIDs = Set(defaults.stringArray(forKey: Keys.protectedHosts) ?? [])
        readOnlyHostIDs = Set(defaults.stringArray(forKey: Keys.readOnlyHosts) ?? [])
        confirmWrites = defaults.bool(forKey: Keys.confirmWrites)
        if let raw = defaults.string(forKey: Keys.claudeMode), let m = ClaudeMode(rawValue: raw) { claudeMode = m }
        if let raw = defaults.string(forKey: Keys.codexMode), let m = CodexMode(rawValue: raw) { codexMode = m }
        rebuildHosts()   // hosts = discovered + custom
    }

    var hub: Host? { hosts.first(where: { $0.isHub }) ?? hosts.first }
}
