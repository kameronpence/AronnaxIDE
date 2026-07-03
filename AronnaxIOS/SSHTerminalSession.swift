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
    @Published var projects: [String] = []
    @Published var selectedProject = ""
    weak var terminalView: TerminalView?

    private let projectsRoot = "/Users/kepler/Documents/AI_OS/Projects"
    private var projectDir: String {
        selectedProject.isEmpty ? projectsRoot : projectsRoot + "/" + selectedProject
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
        do {
            let key = try Curve25519.Signing.PrivateKey(sshEd25519: aronnaxPrivateKey)
            let settings = SSHClientSettings(
                host: keplerHost,
                port: 22,
                authenticationMethod: { .ed25519(username: keplerUser, privateKey: key) },
                hostKeyValidator: .acceptAnything()
            )
            client = try await SSHClient.connect(to: settings)
            status = "Connected"
            restartPTY()
            await fetchProjects()
        } catch {
            status = "Error: \(error)"
        }
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
            projects = list
            if selectedProject.isEmpty { selectedProject = list.first ?? "" }
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
