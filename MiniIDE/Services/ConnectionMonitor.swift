import Foundation
import Combine

/// Polls the hub's reachability so the status bar can show a live Connected /
/// Disconnected indicator, and re-probes on demand after a manual reconnect.
///
/// "Reachable" means a quick `ssh <hub> true` over the shared ControlMaster
/// succeeds — the same connection the panes use — so the dot reflects the real
/// link, not merely whether a pane happens to be open.
@MainActor
final class ConnectionMonitor: ObservableObject {
    enum Status {
        case checking
        case connected
        case disconnected
    }

    @Published private(set) var status: Status = .checking

    private var timer: Timer?
    private var probeTask: Task<Void, Never>?
    private let interval: TimeInterval = 5

    /// Begin periodic probing of `host`. Safe to call again — it resets the timer.
    func start(host: Host?) {
        timer?.invalidate()
        probe(host: host, force: false)
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.probe(host: host, force: false) }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        probeTask?.cancel()
        probeTask = nil
    }

    /// Force an immediate re-probe (cancelling any in-flight one) and show the
    /// in-progress state — used by the Reconnect button.
    func recheck(host: Host?) {
        status = .checking
        probe(host: host, force: true)
    }

    /// Run one reachability check. A timer probe is coalesced when one is already
    /// in flight; a forced probe (Reconnect) cancels and replaces the in-flight one
    /// so a stale pre-reset result can't overwrite the status afterwards.
    private func probe(host: Host?, force: Bool) {
        guard let host else {
            status = .disconnected
            return
        }
        if probeTask != nil {
            guard force else { return }   // timer tick: don't pile up
            probeTask?.cancel()
        }
        probeTask = Task {
            let ok = await Self.reachable(host, timeout: 12)
            if Task.isCancelled { return }   // superseded by a newer probe
            self.status = ok ? .connected : .disconnected
            self.probeTask = nil
        }
    }

    /// `SSHManager.isReachable`, bounded by a wall-clock `timeout`. A stale
    /// ControlMaster (the muxed socket is up but dead after sleep / network loss)
    /// isn't bounded by `ConnectTimeout`, so without this a probe could hang until
    /// keepalive detection — leaving the status stale and blocking later probes.
    /// On timeout (or cancellation) the racing ssh probe is cancelled — its process
    /// terminated by `SSHManager.launch`'s cancellation handler.
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
