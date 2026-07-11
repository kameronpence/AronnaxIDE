import Foundation
import SwiftTerm
import Citadel
import NIOCore
import NIOSSH

/// One PTY channel, bound to one pane leaf. Opens its own channel over the shared
/// `SSHConnection` (Citadel multiplexes channels per client), feeds output to its SwiftTerm
/// view, and pumps keystrokes back. Switching the surface (Terminal/Claude/Codex) or the
/// project tears down this channel and opens a fresh one — the leaf (and its view) persist.
///
/// NOTE: live PTY resize (SIGWINCH on divider/Split-View drags) is wired in a later milestone;
/// for now the channel opens at the pane's current size and re-sizes on reattach.
@MainActor
final class PaneSession: ObservableObject, Identifiable {
    let id: UUID
    @Published private(set) var target: AgentTarget
    @Published private(set) var status = "…"
    private(set) var workdir: String
    weak var terminalView: AronnaxTerminalView?

    private unowned let connection: SSHConnection
    private var ptyTask: Task<Void, Never>?
    private var inputContinuation: AsyncStream<[UInt8]>.Continuation?

    init(id: UUID, target: AgentTarget, workdir: String, connection: SSHConnection) {
        self.id = id
        self.target = target
        self.workdir = workdir
        self.connection = connection
    }

    /// Keyboard input → the active PTY's stdin.
    func sendInput(_ bytes: [UInt8]) { inputContinuation?.yield(bytes) }

    /// Open (or reopen) the PTY for the current target/workdir.
    func attach() {
        ptyTask?.cancel()
        // Agents run in tmux → a one-finger drag scrolls history via wheel events; the plain
        // shell uses SwiftTerm's native scrollback, so leave agent scroll off.
        terminalView?.agentScrollEnabled = (target != .terminal)
        feed(Array("\u{1b}c".utf8))   // clear so the previous surface doesn't linger
        ptyTask = Task { [weak self] in await self?.runPTY() }
    }

    /// Switch this pane's surface and/or project, reopening its single channel.
    func restart(target: AgentTarget, workdir: String) {
        self.target = target
        self.workdir = workdir
        attach()
    }

    /// Remember a new workdir without reopening the channel — used for a plain terminal on a
    /// project switch (it keeps running; only the dir a *future* reopen would use changes).
    func updateWorkdir(_ workdir: String) {
        self.workdir = workdir
    }

    func teardown() {
        ptyTask?.cancel()
        ptyTask = nil
        inputContinuation = nil
    }

    private func feed(_ bytes: [UInt8]) { terminalView?.feed(byteArray: bytes[...]) }

    private func initialSize() -> (cols: Int, rows: Int) {
        if let t = terminalView?.getTerminal() { return (max(t.cols, 20), max(t.rows, 10)) }
        return (80, 24)
    }

    private func runPTY() async {
        guard let client = await connection.client() else { return }
        // The connect wait can outlive this task (surface switch / teardown cancels it while
        // still waiting). Bail before opening a channel so a stale task can't leave a stray PTY.
        if Task.isCancelled { return }
        let (input, cont) = AsyncStream<[UInt8]>.makeStream()
        inputContinuation = cont
        let size = initialSize()
        let command = AgentCommands.attachCommand(target: target, workdir: workdir)
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
            if !Task.isCancelled {
                status = "\(target.label) ended"
            }
        }
    }
}
