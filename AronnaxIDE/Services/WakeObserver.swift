import Foundation
import Combine
import Network
import AppKit

/// Emits a signal whenever connectivity should be re-established: after the Mac
/// wakes from sleep, or when the network path becomes usable again after a drop
/// (Wi-Fi change, VPN flap, cable replug).
///
/// Because all real work lives in tmux on the mini, consumers react to this by
/// *reconnecting* (re-attaching the existing session), never by restarting work.
/// Observers compare `reconnectSignal` to the last value they handled.
@MainActor
final class WakeObserver: ObservableObject {
    /// Monotonic counter; bumped once per wake / network-recovery event.
    @Published private(set) var reconnectSignal: Int = 0

    private let pathMonitor = NWPathMonitor()
    private let monitorQueue = DispatchQueue(label: "com.kameronpence.AronnaxIDE.pathmonitor")
    private var wakeObservation: NSObjectProtocol?
    /// Identity of the last network path we saw, to detect real route changes.
    private var lastPathSignature: String?

    init() {
        wakeObservation = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // Already on the main queue (queue: .main), but hop through the actor
            // so the published mutation is isolation-correct.
            Task { @MainActor in self?.bump() }
        }

        pathMonitor.pathUpdateHandler = { [weak self] path in
            let signature = WakeObserver.signature(for: path)
            Task { @MainActor in self?.handlePath(signature: signature) }
        }
        pathMonitor.start(queue: monitorQueue)
    }

    deinit {
        pathMonitor.cancel()
        if let wakeObservation {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObservation)
        }
    }

    /// A stable description of the path's route identity. Two satisfied paths over
    /// different interfaces/gateways (Wi-Fi↔Ethernet, VPN up/down) produce
    /// different signatures; an unsatisfied path is a single sentinel.
    nonisolated static func signature(for path: NWPath) -> String {
        guard path.status == .satisfied else { return "unsatisfied" }
        let interfaces = path.availableInterfaces
            .map { "\($0.name):\($0.type)" }
            .sorted()
            .joined(separator: ",")
        let gateways = path.gateways
            .map { "\($0)" }
            .sorted()
            .joined(separator: ",")
        return "satisfied|\(interfaces)|\(gateways)"
    }

    /// Bump when the route actually changes to a usable path — covers down→up
    /// recovery *and* satisfied→satisfied route handoffs — but skip the initial
    /// baseline callback and pure teardowns so we don't reconnect spuriously.
    private func handlePath(signature: String) {
        defer { lastPathSignature = signature }
        guard let last = lastPathSignature else { return }   // first callback: baseline
        if signature != last && signature != "unsatisfied" {
            bump()
        }
    }

    /// Manually request a reconnect — e.g. the status bar's Reconnect button.
    /// Drives the same path as a wake / network-recovery event, so panes re-attach
    /// their existing tmux sessions rather than restarting any work.
    func triggerReconnect() {
        bump()
    }

    private func bump() {
        reconnectSignal &+= 1
    }
}
