import Foundation
import Citadel
import NIOCore
import NIOSSH
import Crypto

/// One SSH connection to kepler, shared by every pane. Unlike the phone's
/// `SSHTerminalSession` (which owns a single PTY), this owns only the `SSHClient` and the
/// connect/retry logic; each pane opens its OWN PTY channel over this one client (Citadel
/// multiplexes many channels per client). Panes call `await client()` to get the connected
/// client once it's up.
@MainActor
final class SSHConnection: ObservableObject {
    @Published var status = "Idle"
    @Published var projects: [String] = [SSHConnection.keplerRootLabel]

    /// The "kepler root" pseudo-project — top of the picker and the default. Agents run at
    /// the machine root (`/Users/kepler`) instead of inside a project folder. Mirrors macOS.
    static let keplerRootLabel = "kepler root"
    let keplerHome = "/Users/kepler"
    let projectsRoot = "/Users/kepler/Documents/AI_OS/Projects"
    /// The Obsidian vault root (parent of `projectsRoot`) — what the Vault pane browses.
    let vaultRoot = "/Users/kepler/Documents/AI_OS"

    private var connection: SSHClient?
    private var connectTask: Task<Void, Never>?
    private var didFail = false
    private var readyWaiters: [CheckedContinuation<SSHClient?, Never>] = []
    /// Bumped on every start()/stop(). A connect() attempt captures the value at launch and
    /// only touches shared state (the client, status, waiters) while it still matches — so a
    /// canceled attempt that wakes from an await after a background→foreground cycle can't
    /// resolve the NEW attempt's waiters with nil and strand its panes.
    private var generation = 0

    func start() { ensureConnecting() }

    /// Start a connect attempt if one isn't already running. `connect()` clears `connectTask`
    /// when it finishes (see its `defer`), so this can also *re*connect after the transport
    /// dropped while foregrounded — not only on first launch.
    private func ensureConnecting() {
        guard connectTask == nil else { return }
        didFail = false
        generation += 1
        let gen = generation
        if connection == nil { status = "Connecting…" }
        connectTask = Task { [weak self] in await self?.connect(generation: gen) }
    }

    /// Tear the connection down when the app is backgrounded: cancel the connect loop, drop
    /// the client, and release any pane awaiting `client()` so they don't hang. The remote
    /// work keeps running in tmux on kepler, so a later `start()` + `reattach` is lossless.
    func stop() {
        generation += 1        // invalidate any in-flight attempt
        connectTask?.cancel()
        connectTask = nil
        let live = connection
        connection = nil
        status = "Disconnected"
        resolveWaiters(nil)
        if let live { Task { try? await live.close() } }
    }

    /// Suspends until the client is connected; returns nil if the connection has failed
    /// fatally (bad key/auth) or the connection was torn down. Panes await this before
    /// opening their PTY channel.
    ///
    /// Health-aware: if the cached client's channel has gone inactive (the shared transport
    /// dropped while the app stayed foregrounded — a Wi-Fi blip, kepler restart), we discard it
    /// and kick off a fresh connect, then wait for the replacement. That's what lets a pane's
    /// tap-to-reconnect actually recover instead of reusing a dead client forever.
    func client() async -> SSHClient? {
        if let c = connection {
            if c.isConnected { return c }
            connection = nil          // stale, closed transport — drop it and reconnect
            status = "Reconnecting…"
        }
        if didFail { return nil }
        ensureConnecting()
        return await withCheckedContinuation { readyWaiters.append($0) }
    }

    private func resolveWaiters(_ c: SSHClient?) {
        let waiters = readyWaiters
        readyWaiters = []
        for w in waiters { w.resume(returning: c) }
    }

    /// One-off command (project scan, etc.) — non-PTY exec channel returning captured output.
    func executeCommand(_ command: String) async throws -> ByteBuffer {
        guard let c = await client() else { throw CancellationError() }
        return try await c.executeCommand(command)
    }

    private func connect(generation gen: Int) async {
        // Let a future ensureConnecting() spin up a fresh attempt once this one settles (success,
        // fatal failure, or supersede). Guarded so a superseded attempt can't clear the task the
        // newer attempt owns.
        defer { if gen == generation { connectTask = nil } }
        // Build the SSH key once — a bad key is fatal, not worth retrying.
        let key: Curve25519.Signing.PrivateKey
        do {
            key = try Curve25519.Signing.PrivateKey(sshEd25519: aronnaxPrivateKey)
        } catch {
            guard gen == generation else { return }
            status = "Bad SSH key"
            didFail = true
            resolveWaiters(nil)
            return
        }
        // Keep retrying until we connect (or the view goes away). On Wi-Fi Tailscale goes
        // direct and the first try lands; on cellular (carrier CGNAT) the early tries warm
        // up the DERP relay and a later one succeeds. (Same logic as the phone app.)
        var attempt = 0
        while !Task.isCancelled {
            guard gen == generation else { return }   // superseded by a newer start()/stop()
            attempt += 1
            status = attempt == 1 ? "Connecting…" : "Connecting… (\(attempt))"
            do {
                var settings = SSHClientSettings(
                    host: keplerHost,
                    port: 22,
                    authenticationMethod: { .ed25519(username: keplerUser, privateKey: key) },
                    hostKeyValidator: .acceptAnything()
                )
                settings.connectTimeout = .seconds(12)
                let c = try await SSHClient.connect(to: settings)
                // If we were superseded (or canceled) while connecting, this client is stale:
                // close it and leave the current attempt's state/waiters untouched.
                guard gen == generation, !Task.isCancelled else {
                    try? await c.close()
                    return
                }
                connection = c
                status = "Connected"
                resolveWaiters(c)
                // Connect is done the moment the client is live — release the task now so that
                // if the transport drops during the (non-critical) project fetch below, a pane's
                // client() can start a fresh attempt instead of blocking on this finished task.
                connectTask = nil
                await fetchProjects()
                return
            } catch {
                guard gen == generation, !Task.isCancelled else { return }
                // Auth/config failures can't be fixed by retrying — surface and stop. Only
                // transient network failures (a cold cellular path) are worth retrying.
                if Self.isFatalConnectError(error) {
                    status = "Auth failed — check SSH key / user"
                    didFail = true
                    resolveWaiters(nil)
                    return
                }
                status = "Reconnecting…"
                try? await Task.sleep(nanoseconds: 1_500_000_000)   // brief backoff, then retry
            }
        }
        guard gen == generation else { return }
        resolveWaiters(nil)
    }

    /// True for connect errors where retrying can't help: rejected credentials, an
    /// unauthorized session, or an unsupported/failed auth method. Network timeouts and
    /// connection refusals — the cellular case the retry loop exists for — are NOT fatal.
    private static func isFatalConnectError(_ error: Error) -> Bool {
        if error is AuthenticationFailed { return true }
        if let e = error as? SSHClientError {
            switch e {
            case .allAuthenticationOptionsFailed,
                 .unsupportedPasswordAuthentication,
                 .unsupportedPrivateKeyAuthentication,
                 .unsupportedHostBasedAuthentication:
                return true
            case .channelCreationFailed:
                return false   // post-connect channel hiccup — transient, worth a retry
            }
        }
        if let e = error as? CitadelError, case .unauthorized = e { return true }
        return false
    }

    /// The absolute workdir for a project name (or the machine root for "kepler root").
    func workdir(for project: String) -> String {
        if project == Self.keplerRootLabel || project.isEmpty { return keplerHome }
        return projectsRoot + "/" + project
    }

    func fetchProjects() async {
        do {
            let out = try await executeCommand("ls -1 \(projectsRoot)")
            let list = String(buffer: out)
                .split(separator: "\n")
                .map { String($0).trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            projects = [Self.keplerRootLabel] + list
        } catch {
            // Terminals still work even if the project list can't be fetched.
        }
    }
}
