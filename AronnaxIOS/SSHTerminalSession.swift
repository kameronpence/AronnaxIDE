import Foundation
import SwiftTerm
import Citadel
import NIOCore
import NIOSSH
import Crypto

/// One SSH connection to kepler; a single PTY at a time bound to the selected target
/// (Terminal / Claude / Codex). Switching tears down the current PTY channel and opens
/// a fresh one — no split, one surface at a time. Output feeds SwiftTerm; keystrokes go
/// back over the active channel.
@MainActor
final class SSHTerminalSession: ObservableObject {
    @Published var status = "Idle"
    @Published var target: AgentTarget = .terminal
    @Published var projects: [String] = [SSHTerminalSession.keplerRootLabel]
    @Published var selectedProject = SSHTerminalSession.keplerRootLabel
    weak var terminalView: AronnaxTerminalView?

    /// The "kepler root" pseudo-project — top of the picker and the default on launch. The
    /// agents run at the machine root (`/Users/kepler`) instead of inside a project folder.
    /// Mirrors the macOS app's "kepler root" row.
    static let keplerRootLabel = "kepler root"
    private let keplerHome = "/Users/kepler"

    private let projectsRoot = "/Users/kepler/Documents/AI_OS/Projects"
    private var projectDir: String {
        if selectedProject == Self.keplerRootLabel || selectedProject.isEmpty { return keplerHome }
        return projectsRoot + "/" + selectedProject
    }

    private var client: SSHClient?
    private var connectTask: Task<Void, Never>?
    private var ptyTask: Task<Void, Never>?
    private var inputContinuation: AsyncStream<[UInt8]>.Continuation?

    func start() {
        guard connectTask == nil else { return }
        status = "Connecting…"
        connectTask = Task { [weak self] in await self?.connect() }
    }

    /// Keyboard input → the active PTY's stdin.
    func sendInput(_ bytes: [UInt8]) { inputContinuation?.yield(bytes) }

    /// Scroll the agent's tmux scrollback by emitting SGR mouse-wheel events straight to
    /// the PTY — the same input path as keystrokes. tmux (mouse on) enters copy-mode and
    /// scrolls its history on these. Only meaningful for tmux-backed targets; the plain
    /// shell uses the native scroll view. Driven by the on-screen scroll buttons because
    /// touch-gesture arbitration against SwiftTerm's own scroll view proved unreliable.
    func scrollAgent(up: Bool, lines: Int = 3) {
        guard target != .terminal else { return }
        let button = up ? 64 : 65   // SGR wheel-up / wheel-down
        let seq = Array("\u{1b}[<\(button);1;1M".utf8)
        for _ in 0..<max(1, lines) { sendInput(seq) }
    }

    /// Switch which surface the terminal shows.
    func select(_ newTarget: AgentTarget) {
        guard newTarget != target else { return }
        target = newTarget
        restartPTY()
    }

    private func feed(_ bytes: [UInt8]) { terminalView?.feed(byteArray: bytes[...]) }

    private func initialSize() -> (cols: Int, rows: Int) {
        if let t = terminalView?.getTerminal() { return (max(t.cols, 20), max(t.rows, 10)) }
        return (80, 24)
    }

    private func connect() async {
        // Build the SSH key once — a bad key is fatal, not worth retrying.
        let key: Curve25519.Signing.PrivateKey
        do {
            key = try Curve25519.Signing.PrivateKey(sshEd25519: aronnaxPrivateKey)
        } catch {
            status = "Bad SSH key"
            return
        }
        // Keep retrying until we connect (or the view goes away). On Wi-Fi Tailscale goes
        // direct and the first try lands; on cellular (carrier CGNAT) there's no direct
        // path, so the early tries warm up the DERP relay and a later one succeeds. A
        // single attempt would just time out, which is the bug this fixes.
        var attempt = 0
        while !Task.isCancelled {
            attempt += 1
            status = attempt == 1 ? "Connecting…" : "Connecting… (\(attempt))"
            do {
                var settings = SSHClientSettings(
                    host: keplerHost,
                    port: 22,
                    authenticationMethod: { .ed25519(username: keplerUser, privateKey: key) },
                    hostKeyValidator: .acceptAnything()
                )
                // Shorter per-try timeout so a cold path fails fast and we retry, instead
                // of hanging the whole 30s on one doomed attempt.
                settings.connectTimeout = .seconds(12)
                let c = try await SSHClient.connect(to: settings)
                guard !Task.isCancelled else { return }
                client = c
                status = "Connected"
                restartPTY()
                await fetchProjects()
                return
            } catch {
                if Task.isCancelled { return }
                // Auth/config failures (bad key, wrong user, rejected credentials) can't be
                // fixed by retrying — surface the real error and stop instead of hammering
                // the server every 1.5s forever behind a "Reconnecting…" label. Only
                // transient network failures (a cold cellular path) are worth retrying to
                // warm up the Tailscale DERP relay.
                if Self.isFatalConnectError(error) {
                    status = "Auth failed — check SSH key / user"
                    return
                }
                status = "Reconnecting…"
                try? await Task.sleep(nanoseconds: 1_500_000_000)   // brief backoff, then retry
            }
        }
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

    /// Switch which kepler project the Claude/Codex sessions attach to.
    func selectProject(_ name: String) {
        guard name != selectedProject else { return }
        selectedProject = name
        if target != .terminal { restartPTY() }
    }

    private func fetchProjects() async {
        guard let client else { return }
        do {
            let out = try await client.executeCommand("ls -1 \(projectsRoot)")
            let list = String(buffer: out)
                .split(separator: "\n")
                .map { String($0).trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            // "kepler root" always sits at the top of the list and is the default.
            projects = [Self.keplerRootLabel] + list
            if selectedProject.isEmpty { selectedProject = Self.keplerRootLabel }
        } catch {
            // Terminal still works even if the project list can't be fetched.
        }
    }

    private func restartPTY() {
        ptyTask?.cancel()
        guard client != nil else { return }
        // Clear the screen so the previous surface doesn't linger under the new one.
        feed(Array("\u{1b}c".utf8))
        let t = target
        ptyTask = Task { [weak self] in await self?.runPTY(target: t) }
    }

    private func runPTY(target: AgentTarget) async {
        guard let client else { return }
        let (input, cont) = AsyncStream<[UInt8]>.makeStream()
        inputContinuation = cont
        let size = initialSize()
        let command = AgentCommands.attachCommand(target: target, workdir: projectDir)
        do {
            try await client.withPTY(
                SSHChannelRequestEvent.PseudoTerminalRequest(
                    wantReply: true,
                    term: "xterm-256color",
                    terminalCharacterWidth: size.cols,
                    terminalRowHeight: size.rows,
                    terminalPixelWidth: 0,
                    terminalPixelHeight: 0,
                    terminalModes: .init([.ECHO: 1])
                )
            ) { output, writer in
                // Terminal = plain login shell (nil). Claude/Codex = attach to tmux.
                if let command {
                    var cmd = ByteBuffer()
                    cmd.writeString(command + "\n")
                    try await writer.write(cmd)
                }
                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask {
                        for try await chunk in output {
                            let bytes: [UInt8]
                            switch chunk {
                            case .stdout(let bb): bytes = Array(bb.readableBytesView)
                            case .stderr(let bb): bytes = Array(bb.readableBytesView)
                            }
                            await self.feed(bytes)
                        }
                    }
                    group.addTask {
                        for await data in input {
                            var buf = ByteBuffer()
                            buf.writeBytes(data)
                            try await writer.write(buf)
                        }
                    }
                    try await group.next()
                    group.cancelAll()
                }
            }
        } catch {
            // Cancellation (a surface switch) is expected; only surface real errors.
            if !Task.isCancelled {
                status = "\(target.label) ended"
            }
        }
    }
}
