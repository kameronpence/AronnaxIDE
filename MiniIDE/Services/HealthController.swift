import Foundation
import Combine

/// Probes the fleet's health for the Health panel: each host's reachability and,
/// for the hub, which tmux sessions are alive (the shell + the per-project agents).
/// Reachability reuses the shared ControlMaster, bounded by a wall-clock timeout so
/// a stale post-sleep socket can't hang a probe.
@MainActor
final class HealthController: ObservableObject {
    struct HostHealth: Identifiable {
        let id: String
        let name: String
        let isHub: Bool
        var reachable: Bool?       // nil = still checking
        var sessions: [String]     // alive tmux sessions (hub only)
    }

    @Published private(set) var hosts: [HostHealth] = []
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastUpdated: Date?

    private var hostList: [Host] = []
    private var timer: Timer?
    private var refreshTask: Task<Void, Never>?
    private var started = false
    private let interval: TimeInterval = 20

    func start(hosts: [Host]) {
        self.hostList = hosts
        // Seed rows in "checking" state so the panel isn't empty on first paint.
        if self.hosts.isEmpty {
            self.hosts = hosts.map {
                HostHealth(id: $0.id, name: $0.displayName, isHub: $0.isHub,
                           reachable: nil, sessions: [])
            }
        }
        guard !started else { return }
        started = true
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        started = false        // allow start() to re-arm the timer when the panel reappears
        refreshTask?.cancel()  // drop in-flight ssh probes when the panel goes away
        refreshTask = nil
        isRefreshing = false
    }

    func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        let hosts = hostList
        refreshTask = Task {
            // Probe every host concurrently so one slow/down host doesn't stall the
            // rest; collect by index to keep the displayed order stable.
            let results = await withTaskGroup(of: (Int, HostHealth).self) { group -> [HostHealth] in
                for (index, host) in hosts.enumerated() {
                    group.addTask {
                        let reachable = await Self.reachable(host, timeout: 10)
                        var sessions: [String] = []
                        if host.isHub && reachable {
                            sessions = await Self.tmuxSessions(host)
                        }
                        return (index, HostHealth(id: host.id, name: host.displayName,
                                                  isHub: host.isHub, reachable: reachable,
                                                  sessions: sessions))
                    }
                }
                var collected = [HostHealth?](repeating: nil, count: hosts.count)
                for await (index, health) in group { collected[index] = health }
                return collected.compactMap { $0 }
            }
            if Task.isCancelled { return }   // panel went away — drop stale results
            self.hosts = results
            self.lastUpdated = Date()
            self.isRefreshing = false
            self.refreshTask = nil
        }
    }

    private static func tmuxSessions(_ host: Host) async -> [String] {
        // tmux lives on the Homebrew PATH a non-login shell lacks, so wrap in zsh -lc.
        let command = "zsh -lc 'tmux list-sessions -F \"#{session_name}\" 2>/dev/null'"
        // Bound it: a stale master can make runShell hang, which would otherwise wedge
        // the whole refresh (isRefreshing stuck true → no further refreshes).
        let stdout: String? = await withTaskGroup(of: String?.self) { group in
            group.addTask {
                guard let r = try? await SSHManager.shared.runShell(command, on: host),
                      r.ok else { return nil }
                return r.stdout
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        guard let stdout else { return [] }
        return stdout
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            // Drop the app's own transient probe sessions (e.g. the usage scraper's
            // `miniide-usage-<uuid>`) so Health shows only real shell/agent sessions.
            .filter { !$0.isEmpty && !$0.hasPrefix("miniide-") }
            .sorted()
    }

    /// `isReachable` bounded by a wall-clock timeout (a stale mux socket isn't bounded
    /// by ConnectTimeout, so an unbounded probe could hang until keepalive detection).
    private static func reachable(_ host: Host, timeout seconds: Double) async -> Bool {
        await withTaskGroup(of: Bool?.self) { group in
            group.addTask { await SSHManager.shared.isReachable(host) }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first ?? false
        }
    }
}
