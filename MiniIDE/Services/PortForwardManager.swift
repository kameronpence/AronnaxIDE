import Foundation
import Combine
import AppKit
import Darwin

/// Manages local SSH port-forwards to the hub's localhost dev servers, so the
/// Browser pane can load `http://localhost:<localPort>` and reach a server bound to
/// the mini's localhost. Each forward is a backgrounded `ssh -N -L` process
/// (multiplexed over the shared ControlMaster); terminating it drops the forward.
///
/// App-wide singleton so forwards survive tab switches and are shared across panes.
/// Forwards are re-established after a sleep/wake reconnect, and all ssh children
/// are torn down on app quit.
@MainActor
final class PortForwardManager: ObservableObject {
    static let shared = PortForwardManager()

    struct Forward: Identifiable {
        let id = UUID()
        let localPort: Int
        let remotePort: Int
        let remoteHost: String
        let host: Host
        fileprivate let process: Process
    }

    @Published private(set) var forwards: [Forward] = []
    @Published var lastError: String?

    /// What the user asked to forward, keyed by local port — kept so forwards can be
    /// re-established after a wake reconnect (which resets the shared master and
    /// tears down the multiplexed `-L` channels) even if the ssh child already died.
    private struct Spec {
        let localPort: Int
        let remotePort: Int
        let remoteHost: String
        let host: Host
    }
    private var desired: [Int: Spec] = [:]

    /// ssh children that have launched but not yet confirmed ready — tracked so
    /// `closeAll()` can terminate them if the app quits during the readiness wait.
    private var pending: [Process] = []

    private init() {
        // Don't leave ssh -N -L children (and their bound local ports) running
        // after the app quits.
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.closeAll() }
        }
    }

    /// Subscribe to the app's central reconnect signal — sleep/wake, network-path
    /// changes, and the manual Reconnect button all bump it. Each bump resets the
    /// shared SSH master, which tears down the multiplexed forwards, so re-open
    /// whatever the user still wants. Call once at launch (idempotent).
    private var reconnectCancellable: AnyCancellable?
    func bind(to wakeObserver: WakeObserver) {
        guard reconnectCancellable == nil else { return }
        reconnectCancellable = wakeObserver.$reconnectSignal
            .dropFirst()
            .sink { [weak self] signal in
                Task { @MainActor in self?.reestablish(generation: signal) }
            }
    }

    /// Opens a forward: `localhost:localPort` (this Mac) → `remoteHost:remotePort`
    /// as seen from `host`. Polls the local port until the tunnel's listener is
    /// actually accepting connections (or ssh exits / times out) before reporting
    /// success. Returns the forward, or nil after setting `lastError`.
    @discardableResult
    func open(localPort: Int,
              remoteHost: String = "localhost",
              remotePort: Int,
              on host: Host) async -> Forward? {
        guard (1...65535).contains(localPort), (1...65535).contains(remotePort) else {
            lastError = "Ports must be between 1 and 65535."
            return nil
        }
        guard !forwards.contains(where: { $0.localPort == localPort }) else {
            lastError = "Local port \(localPort) is already forwarded."
            return nil
        }
        // If something already listens on the local port, the tunnel can't bind it —
        // and the readiness probe would otherwise mistake that pre-existing service
        // for a live forward.
        guard !Self.portAccepts(localPort) else {
            lastError = "Local port \(localPort) is already in use by another app."
            return nil
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: SSHManager.shared.sshExecutable)
        process.arguments = SSHManager.shared.portForwardArguments(
            for: host, localPort: localPort, remoteHost: remoteHost, remotePort: remotePort)
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        // If ssh later exits on its own (link drop, etc.), drop the forward so the UI
        // doesn't show a dead tunnel. A no-op before the forward is appended below.
        process.terminationHandler = { [weak self] finished in
            Task { @MainActor in
                self?.forwards.removeAll { $0.process === finished }
            }
        }

        do {
            try process.run()
        } catch {
            lastError = "Couldn't start forward: \(error.localizedDescription)"
            return nil
        }
        // Track the child during the readiness wait so quit cleanup can reach it.
        pending.append(process)
        defer { pending.removeAll { $0 === process } }

        // Wait until the local listener actually accepts connections (the real
        // readiness signal — `isRunning` alone can be true while ssh is still
        // connecting under ConnectTimeout, especially via ProxyJump). Bail if ssh
        // exits or we exceed a bounded timeout.
        var ready = false
        for _ in 0..<80 {                       // up to ~12s (80 × 150ms)
            if !process.isRunning { break }
            if Self.portAccepts(localPort) { ready = true; break }
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
        guard ready, process.isRunning else {
            if process.isRunning { process.terminate() }
            lastError = "Couldn't forward port \(localPort) — it may be in use, or the "
                + "mini isn't serving port \(remotePort)."
            return nil
        }

        let forward = Forward(localPort: localPort, remotePort: remotePort,
                              remoteHost: remoteHost, host: host, process: process)
        forwards.append(forward)
        desired[localPort] = Spec(localPort: localPort, remotePort: remotePort,
                                  remoteHost: remoteHost, host: host)
        lastError = nil
        return forward
    }

    /// Closes a single forward (terminates its ssh process) and stops wanting it.
    func close(_ forward: Forward) {
        desired[forward.localPort] = nil   // user closed it → don't recreate on wake
        if forward.process.isRunning {
            forward.process.terminate()
        }
        forwards.removeAll { $0.id == forward.id }
    }

    /// Closes every active forward (on quit, via the willTerminate observer).
    func closeAll() {
        desired.removeAll()
        for process in pending where process.isRunning {
            process.terminate()
        }
        pending.removeAll()
        for forward in forwards where forward.process.isRunning {
            forward.process.terminate()
        }
        forwards.removeAll()
    }

    /// A reconnect (wake / network change / manual) resets the shared master and
    /// tears down the multiplexed forwards. Drop the stale processes and re-open
    /// everything the user still wants.
    private func reestablish(generation: Int) {
        guard !desired.isEmpty else { return }
        for forward in forwards where forward.process.isRunning {
            forward.process.terminate()
        }
        forwards.removeAll()
        let specs = Array(desired.values)
        // Drop the stale master for each host once for this reconnect generation —
        // coordinates with panes (idempotent), and covers the Browser-only case
        // where no pane is mounted to do it. Otherwise open() would reuse the dead
        // ControlMaster and fail to recreate the tunnel.
        for spec in specs {
            SSHManager.shared.resetMasterOnce(for: spec.host, generation: generation)
        }
        Task {
            // Let the reset settle and the local ports free first.
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            for spec in specs {
                _ = await open(localPort: spec.localPort, remoteHost: spec.remoteHost,
                               remotePort: spec.remotePort, on: spec.host)
            }
        }
    }

    /// True if something is accepting TCP connections on `127.0.0.1:port` — i.e. the
    /// forward's local listener is up. A localhost connect resolves immediately
    /// (accept or refuse), so this doesn't block meaningfully.
    private static func portAccepts(_ port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { Darwin.close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(truncatingIfNeeded: port).bigEndian)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return connected == 0
    }
}
