import Darwin
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

    /// Cached Tailscale-IP resolution per host id (value may be nil = "no Tailscale address").
    /// Short-lived so a home↔away network change is picked up without restarting the app.
    private struct TSResolution { let ip: String?; let at: Date }
    private var tailscaleCache: [String: TSResolution] = [:]
    private var tailscaleRefreshing: Set<String> = []
    private let tailscaleLock = NSLock()

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
        var opts = [
            "-o", "ControlMaster=auto",
            "-o", "ControlPath=\(controlPath(for: host))",
            "-o", "ControlPersist=300",
            // Auto-trust a *new* host's key on first connect (so a freshly added server
            // probes without a prompt that BatchMode can't answer), but still reject a
            // *changed* key — MITM/reassign protection is preserved.
            "-o", "StrictHostKeyChecking=accept-new",
            // Fail a stalled TCP/auth connect in ~10s instead of hanging on ssh's
            // long default — so a down hub surfaces as "Disconnected" promptly.
            "-o", "ConnectTimeout=10",
            "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=3",
        ]
        // Reach the hub over Tailscale from ANY network: its ~/.ssh/config HostName is a LAN
        // IP that only works at home (and drifts via DHCP), which is why the app connected on
        // the home LAN but failed at work while the iOS app (which uses the Tailscale IP) kept
        // working. A command-line `-o HostName=` overrides the config; Tailscale routes over
        // the LAN directly when home, so this is strictly better. Falls back to the config
        // HostName when Tailscale isn't running (resolution returns nil).
        if let ts = tailscaleHostName(for: host) {
            opts += ["-o", "HostName=\(ts)"]
        }
        return opts
    }

    /// The hub's Tailscale IPv4 as seen by THIS Mac's Tailscale client, or nil to fall back to
    /// the ssh-config HostName. Hub-only (other hosts are public IPs / ProxyJump — no LAN
    /// problem). NEVER blocks: it returns the cached value immediately (nil on the very first
    /// call) and, when the cache is missing/stale, kicks off a background refresh via the CLI.
    /// This is called synchronously while building ssh args on the main thread, so it must not
    /// run the subprocess inline. `prewarmTailscale(for:)` warms it before the first connect.
    private func tailscaleHostName(for host: Host) -> String? {
        guard host.isHub else { return nil }
        tailscaleLock.lock(); defer { tailscaleLock.unlock() }
        let cached = tailscaleCache[host.id]
        let fresh = cached.map { Date().timeIntervalSince($0.at) < 15 } ?? false
        if !fresh { scheduleTailscaleRefresh(host) }   // background; returns immediately
        return cached?.ip
    }

    /// Kicks a one-at-a-time background probe of the hub's Tailscale IP. Must be called with
    /// `tailscaleLock` held (reads/writes `tailscaleRefreshing`). The probe itself runs off the
    /// lock and off the calling thread, so connection setup is never blocked by the CLI.
    private func scheduleTailscaleRefresh(_ host: Host) {
        guard !tailscaleRefreshing.contains(host.id) else { return }
        tailscaleRefreshing.insert(host.id)
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let ip = Self.resolveTailscaleIP(matching: host.sshAlias)
            guard let self else { return }
            self.tailscaleLock.lock()
            self.tailscaleCache[host.id] = TSResolution(ip: ip, at: Date())
            self.tailscaleRefreshing.remove(host.id)
            self.tailscaleLock.unlock()
        }
    }

    /// Warm the hub's Tailscale address before the first connection, so the app reaches it over
    /// Tailscale on the very first attempt (rather than after a LAN attempt times out at work).
    /// Fire-and-forget; safe to call repeatedly (deduped). Call once the hub host is known.
    func prewarmTailscale(for host: Host) {
        _ = tailscaleHostName(for: host)
    }

    /// Guarantees the hub's Tailscale address is resolved (or definitively absent) before ssh
    /// args are built, so the FIRST connection targets Tailscale rather than the unreachable
    /// LAN IP when away from home. Async + bounded (the probe self-limits to ~3s) — it awaits
    /// off the main thread, so it never freezes the UI the way an inline sync probe would.
    /// The async command paths await this; the sync terminal spawn relies on `prewarmTailscale`.
    func ensureTailscaleResolved(for host: Host) async {
        guard host.isHub else { return }
        tailscaleLock.lock()
        let fresh = tailscaleCache[host.id].map { Date().timeIntervalSince($0.at) < 15 } ?? false
        tailscaleLock.unlock()
        guard !fresh else { return }
        let ip = await Task.detached(priority: .userInitiated) {
            Self.resolveTailscaleIP(matching: host.sshAlias)
        }.value
        tailscaleLock.lock()
        tailscaleCache[host.id] = TSResolution(ip: ip, at: Date())
        tailscaleLock.unlock()
    }

    /// Finds the Tailscale **peer** whose DNS name or hostname corresponds to `alias`
    /// (e.g. `kepler` → `keplers-mac-mini`) and returns its 100.x IPv4, or nil. Deliberately
    /// ignores `Self`: the app runs on the MacBook and the hub is always a remote peer, so a
    /// fuzzy match on this Mac's own name must never redirect hub traffic back to localhost.
    private static func resolveTailscaleIP(matching alias: String) -> String? {
        guard let data = runTailscaleStatusJSON(),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        let needle = alias.lowercased()
        let nodes: [[String: Any]] = (root["Peer"] as? [String: Any])?
            .values.compactMap { $0 as? [String: Any] } ?? []
        for node in nodes {
            let host = (node["HostName"] as? String ?? "").lowercased()
            let firstLabel = (node["DNSName"] as? String ?? "").lowercased()
                .split(separator: ".").first.map(String.init) ?? ""
            let matches = host.contains(needle)
                || (!firstLabel.isEmpty && (firstLabel.contains(needle) || needle.contains(firstLabel)))
            guard matches else { continue }
            if let ips = node["TailscaleIPs"] as? [String],
               let v4 = ips.first(where: { $0.contains(".") && !$0.contains(":") }) {
                return v4
            }
        }
        return nil
    }

    /// Runs the Mac's Tailscale CLI (`tailscale status --json`) from the standard install
    /// locations. Returns nil if Tailscale isn't installed/running.
    private static func runTailscaleStatusJSON() -> Data? {
        let candidates = [
            "/usr/local/bin/tailscale",
            "/opt/homebrew/bin/tailscale",
            "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: path)
            proc.arguments = ["status", "--json"]
            let out = Pipe()
            proc.standardOutput = out
            proc.standardError = FileHandle.nullDevice
            guard (try? proc.run()) != nil else { continue }
            // Bound the WHOLE probe (read + process lifetime): if tailscaled/the CLI wedges —
            // even by closing stdout but never exiting — terminate after 3s and fall back to
            // the ssh-config HostName rather than blocking. Runs on a background thread, so a
            // slow probe never affects connection setup.
            let box = DataBox()
            let done = DispatchGroup()
            done.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                box.data = out.fileHandleForReading.readDataToEndOfFile()
                done.leave()
            }
            let timedOut = done.wait(timeout: .now() + 3) == .timedOut
            if proc.isRunning { proc.terminate() }   // bounds process exit too, not just the read
            if timedOut { continue }
            // Validate by parsing (not exit status): the caller requires a real peer match, so
            // partial/garbage output simply resolves to nil.
            if let data = box.data, !data.isEmpty { return data }
        }
        return nil
    }

    /// Reference box so the background reader can hand data back without a captured `var`.
    private final class DataBox { var data: Data? }

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
        await ensureTailscaleResolved(for: host)   // first attempt targets Tailscale, not the LAN
        let remote = remoteCommand.isEmpty
            ? nil
            : [remoteCommand.map(Self.shellEscaped).joined(separator: " ")]
        return try await launchHealingStaleMaster(for: host) {
            self.sshArguments(for: host, interactive: false, remoteCommand: remote)
        }
    }

    /// Runs an ssh invocation and, on either of two failure modes, drops the shared master and
    /// retries **once** on a fresh connection. This is the self-heal the interactive panes
    /// already do on reconnect; without it a one-shot command (project scan, vault list, git
    /// status, a wizard step) rides the dead tunnel and — with no retry — leaves the UI blank
    /// or spinning until the whole app is restarted.
    ///
    ///  - **exit 255** — ssh itself failed (a stale/dead shared ControlMaster after a network
    ///    change, a jump-host round-trip, etc.). ssh never ran the remote command, so re-running
    ///    is safe even for writes.
    ///  - **exit 124** — our timeout fired, i.e. the command *hung*. The usual cause is a
    ///    black-holed ControlMaster after a network change (e.g. a Tailscale blip): the master's
    ///    TCP is dead but not yet detected, so a mux client attaches and hangs with no
    ///    ConnectTimeout of its own. Healing 255 alone isn't enough here — the hung client never
    ///    reaches 255, so without this every retry re-attaches to the same dead master and hangs
    ///    again (the "wizard stuck after a network drop, Retry does nothing" bug). Tearing the
    ///    master down forces the retry through a fresh TCP connect bounded by ConnectTimeout=10,
    ///    so it either succeeds or fails cleanly in ~10s instead of hanging forever. A command
    ///    that hangs on a healthy link never happened (it didn't complete), so re-running it is
    ///    likewise safe; a genuinely slow-but-alive command simply times out again and is
    ///    returned as-is.
    ///
    /// Any other exit code (a real remote-command result) is returned as-is.
    private func launchHealingStaleMaster(for host: Host, input: String? = nil,
                                          timeoutSeconds: TimeInterval? = nil,
                                          buildArgs: () -> [String]) async throws -> CommandResult {
        let first = try await launch(arguments: buildArgs(), input: input, timeoutSeconds: timeoutSeconds)
        guard first.exitCode == 255 || first.exitCode == 124 else { return first }
        closeMaster(for: host)   // tear down the dead tunnel so ControlMaster=auto rebuilds it
        return try await launch(arguments: buildArgs(), input: input, timeoutSeconds: timeoutSeconds)
    }

    /// Runs a raw shell command string on `host` (pipes, globs, redirection are
    /// honored). The caller owns quoting — use `run(_:on:)` for untrusted args.
    /// `input`, if given, is written to the command's stdin and then closed — e.g.
    /// for `cat > file` atomic writes.
    @discardableResult
    func runShell(_ command: String, input: String? = nil, on host: Host, timeoutSeconds: TimeInterval? = nil) async throws -> CommandResult {
        await ensureTailscaleResolved(for: host)   // first attempt targets Tailscale, not the LAN
        return try await launchHealingStaleMaster(for: host, input: input, timeoutSeconds: timeoutSeconds) {
            self.sshArguments(for: host, interactive: false, remoteCommand: [command])
        }
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
    func loginShellArguments(for host: Host, running command: String,
                             execProcess: Bool = true) -> [String] {
        // COLORTERM=truecolor makes tmux on ANY host detect 24-bit colour and stop
        // downgrading truecolour (e.g. codex's near-white input box rendered dark) —
        // a universal fix that needs no per-server ~/.tmux.conf. The inner `exec` keeps
        // the target process as ssh's direct child so its exit still drives
        // processTerminated. Pass execProcess:false for a *multi-statement* command
        // (e.g. set a tmux option, THEN attach) — `exec` would replace the shell on the
        // first statement and swallow the rest; the outer `exec zsh` still makes ssh's
        // child the login shell, whose exit (when the final blocking cmd ends) still fires.
        let inner = execProcess ? "exec \(command)" : command
        let withColor = "export COLORTERM=truecolor; \(inner)"
        let remote = "exec zsh -lc \(Self.shellEscaped(withColor))"
        return sshArguments(for: host, interactive: true, remoteCommand: [remote])
    }

    /// Argument vector for a long-lived **streaming** command (e.g. `tail -F`,
    /// `pm2 logs`, `docker logs -f`). Runs under a login shell so PATH resolves
    /// pm2/docker/etc., with no PTY (`BatchMode`) so tools emit plain, un-coloured
    /// lines. Spawn with `sshExecutable` and terminate the process to stop the
    /// stream; it reuses the shared ControlMaster and any ProxyJump.
    func streamArguments(for host: Host, running command: String) -> [String] {
        let remote = "exec zsh -lc \(Self.shellEscaped(command))"
        let args = sshArguments(for: host, interactive: false, remoteCommand: [remote])
        // Ride the shared master if one exists, but never *become* it: a stream that
        // owned the master would drop the terminal/other panes when it's stopped.
        // NOTE: ControlMaster=no still multiplexes over an existing master (verified:
        // ssh logs `mux_client_request_session`); it only prevents *creating* one. It
        // does NOT disable sharing. ssh uses the first value given for an option, so
        // this wins over the ControlMaster=auto that sshArguments adds.
        return ["-o", "ControlMaster=no"] + args
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

    private func launch(arguments: [String], input: String? = nil, timeoutSeconds: TimeInterval? = nil) async throws -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: sshPath)
        process.arguments = arguments

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        let inPipe: Pipe? = input != nil ? Pipe() : nil
        if let inPipe { process.standardInput = inPipe }

        do {
            try process.run()
        } catch {
            throw SSHError.launchFailed(error.localizedDescription)
        }

        var timedOut = false
        let timeoutTimer: DispatchSourceTimer?
        if let timeoutSeconds {
            let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .userInitiated))
            timer.schedule(deadline: .now() + timeoutSeconds)
            timer.setEventHandler { [process] in
                guard process.isRunning else { return }
                timedOut = true
                process.terminate()
                DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 2) {
                    if process.isRunning {
                        Darwin.kill(process.processIdentifier, SIGKILL)
                    }
                }
            }
            timer.resume()
            timeoutTimer = timer
        } else {
            timeoutTimer = nil
        }

        // Feed stdin (if any) off the calling thread, then close so the remote
        // command sees EOF. stdout/stderr are drained concurrently below, so a large
        // write can't deadlock against unread output.
        if let inPipe, let input {
            let handle = inPipe.fileHandleForWriting
            DispatchQueue.global(qos: .userInitiated).async {
                // `write(contentsOf:)` throws rather than raising an ObjC exception on
                // a broken pipe (e.g. the remote command exits before reading stdin).
                if !input.isEmpty { try? handle.write(contentsOf: Data(input.utf8)) }
                try? handle.close()
            }
        }

        return try await withTaskCancellationHandler {
            // Drain both pipes concurrently, so a child writing more than the pipe
            // buffer (~64 KB) can't deadlock against us while the command runs.
            let progress = ByteProgress()
            async let outData = Self.readToEnd(outPipe.fileHandleForReading, progress: progress)
            async let errData = Self.readToEnd(errPipe.fileHandleForReading, progress: progress)

            // Gate on the PROCESS exiting, never on the pipes reaching EOF. With
            // ControlPersist, ssh forks a background master that INHERITS these stdout/stderr
            // write ends and keeps them open after our command is long gone — so `readToEnd`
            // would block on an EOF that never arrives, and the timeout timer above (which only
            // terminates the ssh *process*) could never unblock it. That is the "Add Server
            // wizard hangs forever at Clone the vault, always" bug: step 5 is the first
            // reconnect after the human deploy-key step, by which time the 300s master has
            // expired, so step 5's ssh re-establishes the master and inherits the clone's pipes.
            await Self.waitForExit(process)
            timeoutTimer?.cancel()

            // The process is gone, so no new bytes can be produced — anything left is just the
            // pipe buffer, which drains in milliseconds. Normally both pipes then reach EOF and
            // the drains return on their own, and this closer is cancelled before it acts, so a
            // normal command pays no extra latency. Only when a ControlPersist master still holds
            // the write ends do the drains wedge with NO further progress; detect that by
            // inactivity (not a fixed deadline, which could truncate a large stream still being
            // read) and force the read ends closed — the incremental drains then return
            // everything they accumulated.
            let closer = Task {
                var last = -1
                while !Task.isCancelled {
                    let now = progress.snapshot()
                    if now == last { break }   // a full interval with no new bytes → wedged
                    last = now
                    try? await Task.sleep(nanoseconds: 300_000_000)
                }
                guard !Task.isCancelled else { return }
                try? outPipe.fileHandleForReading.close()
                try? errPipe.fileHandleForReading.close()
            }
            let (out, err) = await (outData, errData)
            closer.cancel()
            try Task.checkCancellation()

            return CommandResult(
                stdout: String(decoding: out, as: UTF8.self),
                stderr: String(decoding: err, as: UTF8.self),
                exitCode: timedOut ? 124 : process.terminationStatus
            )
        } onCancel: {
            // Don't leave a stuck remote command running in the background.
            process.terminate()
        }
    }

    /// Awaits `process` exiting off the calling task. Lets `launch` bound on the process
    /// instead of on the pipes reaching EOF — a ControlPersist master can inherit and hold the
    /// command's stdout/stderr write ends open past the command's own exit, so waiting for pipe
    /// EOF can hang forever.
    private static func waitForExit(_ process: Process) async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                process.waitUntilExit()
                continuation.resume()
            }
        }
    }

    /// Thread-safe running total of bytes drained across both pipes, so `launch` can tell a
    /// still-draining read (progress advancing) apart from one wedged on a ControlPersist master
    /// holding the write end open (progress frozen).
    private final class ByteProgress: @unchecked Sendable {
        private let lock = NSLock()
        private var total = 0
        func add(_ n: Int) { lock.lock(); total += n; lock.unlock() }
        func snapshot() -> Int { lock.lock(); defer { lock.unlock() }; return total }
    }

    /// Reads a file handle to EOF off the main actor. Returns whatever was read,
    /// treating read errors as end-of-stream rather than failing the command.
    ///
    /// Reads INCREMENTALLY, accumulating as it goes and reporting progress: if the handle is
    /// force-closed to break a ControlPersist master that's holding the write end open (see
    /// `launch`), this still returns every byte read so far. `handle.readToEnd()` would instead
    /// throw and discard the whole buffer — silently emptying a command's stdout in that scenario.
    private static func readToEnd(_ handle: FileHandle, progress: ByteProgress) async -> Data {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var buffer = Data()
                while true {
                    let chunk: Data?
                    do { chunk = try handle.read(upToCount: 1 << 16) }
                    catch { break }   // closed / error — stop, keep what we've read
                    guard let chunk, !chunk.isEmpty else { break }   // EOF
                    buffer.append(chunk)
                    progress.add(chunk.count)
                }
                continuation.resume(returning: buffer)
            }
        }
    }
}
