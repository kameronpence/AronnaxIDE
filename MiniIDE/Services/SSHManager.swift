import Foundation

/// Result of running a remote command over SSH.
struct CommandResult {
    let stdout: String
    let stderr: String
    let exitCode: Int32
    var ok: Bool { exitCode == 0 }
}

enum SSHError: Error, LocalizedError {
    case launchFailed(String)

    var errorDescription: String? {
        switch self {
        case .launchFailed(let why): return "Failed to launch ssh: \(why)"
        }
    }
}

/// Centralizes how the app talks to hosts via the system `ssh` client.
///
/// All connections to a host share one authenticated **ControlMaster** socket, so
/// the terminal, file I/O, and command calls reuse a single TCP/auth session
/// instead of re-handshaking. EC2/Lightsail hosts hop through the mini via
/// `ProxyJump`. The app never reimplements SSH — it inherits `~/.ssh/config`,
/// keys, and ssh-agent from the system client.
final class SSHManager {
    static let shared = SSHManager()

    private let sshPath = "/usr/bin/ssh"

    /// Directory for ControlMaster sockets. Kept short to stay under ssh's
    /// ~104-char `ControlPath` limit (a long temp path can silently disable
    /// multiplexing).
    private let controlDir: URL

    /// Last reconnect "generation" the master was reset for, per host id, so that
    /// multiple panes reacting to one wake/network signal reset it only once
    /// (a later pane must not close the master an earlier pane just rebuilt).
    private var lastResetGeneration: [String: Int] = [:]
    private let resetLock = NSLock()

    init() {
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("miniide-cm", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        self.controlDir = base
    }

    // MARK: - Argument construction

    /// Short, stable socket filename derived from the host id via FNV-1a. A raw
    /// id (e.g. a long EC2 DNS alias) appended to the temp-dir prefix can exceed
    /// the ~104-byte `ControlPath` limit and make the connection *fail*, not just
    /// lose multiplexing. The hash must be deterministic across launches so the
    /// master socket is reused and `closeMaster` finds it.
    private func socketName(for host: Host) -> String {
        var hash: UInt64 = 0xcbf29ce484222325          // FNV-1a 64-bit offset basis
        for byte in host.id.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3                // FNV prime
        }
        return String(format: "%016llx.sock", hash)
    }

    private func controlPath(for host: Host) -> String {
        controlDir.appendingPathComponent(socketName(for: host)).path
    }

    /// Multiplexing + keepalive options shared by every connection to `host`.
    private func sharedOptions(for host: Host) -> [String] {
        [
            "-o", "ControlMaster=auto",
            "-o", "ControlPath=\(controlPath(for: host))",
            "-o", "ControlPersist=300",
            // Fail a stalled TCP/auth connect in ~10s instead of hanging on ssh's
            // long default — so a down hub surfaces as "Disconnected" promptly.
            "-o", "ConnectTimeout=10",
            "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=3",
        ]
    }

    /// POSIX single-quote escaping so a token survives a shell as one argument:
    /// wrap in single quotes and close/escape/reopen around any embedded single
    /// quote (`'` → `'\''`). `static` and public so panes that assemble remote
    /// command strings (e.g. a tmux session name) can quote arguments the same way.
    static func shellEscaped(_ token: String) -> String {
        "'" + token.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Builds the full `ssh` argument vector for a host.
    ///
    /// - interactive: request a PTY (`-tt`) for terminal sessions; otherwise run
    ///   in `BatchMode` so a missing key fails fast instead of prompting.
    /// - remoteCommand: the literal trailing words handed to `ssh`. `ssh` joins
    ///   them with spaces and the remote shell re-parses the result, so callers
    ///   that need argv boundaries must pre-quote (see `run`); callers that want
    ///   shell semantics pass a raw string (see `runShell`).
    func sshArguments(for host: Host,
                      interactive: Bool,
                      remoteCommand: [String]? = nil) -> [String] {
        var args = sharedOptions(for: host)

        if case let .proxyJump(via) = host.reach {
            args += ["-J", via]
        }

        if interactive {
            args.append("-tt")
        } else {
            args += ["-o", "BatchMode=yes"]
        }

        let target = host.user.map { "\($0)@\(host.sshAlias)" } ?? host.sshAlias
        args.append(target)

        if let remoteCommand, !remoteCommand.isEmpty {
            args += remoteCommand
        }
        return args
    }

    // MARK: - Running commands

    /// Runs an argv-style command on `host` non-interactively and captures output.
    ///
    /// Each element is shell-quoted so argument boundaries are preserved through
    /// the remote shell — `run(["mkdir", "My Project"], on:)` creates one
    /// directory named `My Project`, and metacharacters in arguments are inert.
    @discardableResult
    func run(_ remoteCommand: [String], on host: Host) async throws -> CommandResult {
        let remote = remoteCommand.isEmpty
            ? nil
            : [remoteCommand.map(Self.shellEscaped).joined(separator: " ")]
        let args = sshArguments(for: host, interactive: false, remoteCommand: remote)
        return try await launch(arguments: args)
    }

    /// Runs a raw shell command string on `host` (pipes, globs, redirection are
    /// honored). The caller owns quoting — use `run(_:on:)` for untrusted args.
    @discardableResult
    func runShell(_ command: String, on host: Host) async throws -> CommandResult {
        let args = sshArguments(for: host, interactive: false, remoteCommand: [command])
        return try await launch(arguments: args)
    }

    /// Lightweight reachability probe used by status/health views.
    func isReachable(_ host: Host) async -> Bool {
        (try? await run(["true"], on: host).ok) ?? false
    }

    // MARK: - Interactive sessions

    /// Argument vector to open an interactive PTY on `host` that runs `command`
    /// inside the remote **login** shell. The login shell matters because tmux,
    /// claude, and codex live in `~/.local/bin` / Homebrew, which a non-login SSH
    /// shell does not have on its PATH. `exec` replaces the wrapper so the target
    /// process is ssh's direct child (its exit drives `processTerminated`).
    /// Used by the terminal and agent panes with SwiftTerm's `startProcess`.
    func loginShellArguments(for host: Host, running command: String) -> [String] {
        let remote = "exec zsh -lc \(Self.shellEscaped(command))"
        return sshArguments(for: host, interactive: true, remoteCommand: [remote])
    }

    /// Path to the system ssh client, for callers that spawn it themselves
    /// (e.g. SwiftTerm's `LocalProcessTerminalView.startProcess`).
    var sshExecutable: String { sshPath }

    // MARK: - Port forwarding

    /// Argument vector for a backgrounded **local port-forward**: binds `localPort`
    /// on this Mac and tunnels it to `remoteHost:remotePort` as resolved from
    /// `host` — so `localhost:remotePort` is the *mini's* localhost. `-N` runs no
    /// remote command (forward only); the connection reuses the shared
    /// ControlMaster and any ProxyJump. Spawn with `sshExecutable`; terminate the
    /// process to drop the forward.
    func portForwardArguments(for host: Host,
                              localPort: Int,
                              remoteHost: String = "localhost",
                              remotePort: Int) -> [String] {
        var args = sharedOptions(for: host)
        if case let .proxyJump(via) = host.reach {
            args += ["-J", via]
        }
        args += [
            "-o", "BatchMode=yes",
            // Exit (rather than log-and-linger) if the local bind fails, so a failed
            // forward is detectable instead of masquerading as a live tunnel.
            "-o", "ExitOnForwardFailure=yes",
            "-N",
            // Bind the local listener to loopback explicitly so a `GatewayPorts yes`
            // in ~/.ssh/config can't expose the mini's dev server to the LAN.
            "-L", "127.0.0.1:\(localPort):\(remoteHost):\(remotePort)",
        ]
        let target = host.user.map { "\($0)@\(host.sshAlias)" } ?? host.sshAlias
        args.append(target)
        return args
    }

    // MARK: - Connection lifecycle

    /// Tears down the shared master connection for `host` (e.g. on quit or before
    /// a forced reconnect). No-op if no master is running.
    func closeMaster(for host: Host) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: sshPath)
        process.arguments = [
            "-o", "ControlPath=\(controlPath(for: host))",
            "-O", "exit",
            host.sshAlias,
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
    }

    /// Closes the shared master for `host` at most once per reconnect `generation`.
    /// Panes pass the `WakeObserver` signal as the generation, so the first pane to
    /// react drops the stale master and the rest reuse the one it rebuilds — no
    /// pane tears down another's fresh master. Returns whether it reset this call.
    @discardableResult
    func resetMasterOnce(for host: Host, generation: Int) -> Bool {
        resetLock.lock()
        let alreadyReset = lastResetGeneration[host.id] == generation
        if !alreadyReset { lastResetGeneration[host.id] = generation }
        resetLock.unlock()

        guard !alreadyReset else { return false }
        closeMaster(for: host)
        return true
    }

    // MARK: - Process plumbing

    private func launch(arguments: [String]) async throws -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: sshPath)
        process.arguments = arguments

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        do {
            try process.run()
        } catch {
            throw SSHError.launchFailed(error.localizedDescription)
        }

        return try await withTaskCancellationHandler {
            // Drain both pipes concurrently *before* waiting, so a child writing
            // more than the pipe buffer (~64 KB) can't deadlock against us. If the
            // task is cancelled, `onCancel` terminates ssh, the pipes hit EOF, and
            // these reads unblock.
            async let outData = Self.readToEnd(outPipe.fileHandleForReading)
            async let errData = Self.readToEnd(errPipe.fileHandleForReading)
            let (out, err) = await (outData, errData)

            process.waitUntilExit()
            try Task.checkCancellation()

            return CommandResult(
                stdout: String(decoding: out, as: UTF8.self),
                stderr: String(decoding: err, as: UTF8.self),
                exitCode: process.terminationStatus
            )
        } onCancel: {
            // Don't leave a stuck remote command running in the background.
            process.terminate()
        }
    }

    /// Reads a file handle to EOF off the main actor. Returns whatever was read,
    /// treating read errors as end-of-stream rather than failing the command.
    private static func readToEnd(_ handle: FileHandle) async -> Data {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let data = (try? handle.readToEnd()) ?? Data()
                continuation.resume(returning: data)
            }
        }
    }
}
