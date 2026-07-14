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
    /// True once the PTY has exited on its own (agent quit, channel dropped) rather than being
    /// intentionally torn down — drives a tap-to-reconnect affordance on the pane.
    @Published private(set) var ended = false
    private(set) var workdir: String
    weak var terminalView: AronnaxTerminalView?

    private unowned let connection: SSHConnection
    private var ptyTask: Task<Void, Never>?
    private var inputContinuation: AsyncStream<[UInt8]>.Continuation?
    private var sizeContinuation: AsyncStream<(cols: Int, rows: Int)>.Continuation?
    /// The last size we told the PTY, so a reopen starts at the pane's real size and we don't
    /// spam identical SIGWINCHes as SwiftTerm reports sub-cell layout passes.
    private var lastSize: (cols: Int, rows: Int)?

    init(id: UUID, target: AgentTarget, workdir: String, connection: SSHConnection) {
        self.id = id
        self.target = target
        self.workdir = workdir
        self.connection = connection
    }

    /// Keyboard input → the active PTY's stdin.
    func sendInput(_ bytes: [UInt8]) { inputContinuation?.yield(bytes) }

    /// A resize (divider drag, rotation, Split View / Stage Manager) → SIGWINCH on the remote
    /// PTY, so tmux and the agents re-lay-out to the pane's real size. Deduped against the last
    /// size sent; the reopen path picks up `lastSize` so a fresh channel starts correctly sized.
    func changeSize(cols: Int, rows: Int) {
        guard cols > 0, rows > 0 else { return }
        guard lastSize?.cols != cols || lastSize?.rows != rows else { return }
        lastSize = (cols, rows)
        sizeContinuation?.yield((cols, rows))
    }

    /// Open (or reopen) the PTY for the current target/workdir.
    func attach() {
        ptyTask?.cancel()
        ended = false
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
        sizeContinuation = nil
    }

    private func feed(_ bytes: [UInt8]) { terminalView?.feed(byteArray: bytes[...]) }

    private func initialSize() -> (cols: Int, rows: Int) {
        // A reopen (surface/project switch) should start at the pane's real current size.
        if let s = lastSize { return s }
        if let t = terminalView?.getTerminal() { return (max(t.cols, 20), max(t.rows, 10)) }
        return (80, 24)
    }

    private func runPTY() async {
        // client() returns nil only when the connection failed fatally (bad key/auth) or was torn
        // down — surface that as an ended pane (with a reconnect affordance) rather than a silent
        // blank, unless we were intentionally cancelled.
        guard let client = await connection.client() else {
            if !Task.isCancelled { status = "\(target.label) unavailable"; ended = true }
            return
        }
        // The connect wait can outlive this task (surface switch / teardown cancels it while
        // still waiting). Bail before opening a channel so a stale task can't leave a stray PTY.
        if Task.isCancelled { return }
        let (input, cont) = AsyncStream<[UInt8]>.makeStream()
        inputContinuation = cont
        let (sizes, sizeCont) = AsyncStream<(cols: Int, rows: Int)>.makeStream()
        sizeContinuation = sizeCont
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
                    group.addTask {
                        // Live resize: each reported size becomes a WindowChangeRequest (SIGWINCH).
                        for await size in sizes {
                            try await writer.changeSize(cols: size.cols, rows: size.rows,
                                                        pixelWidth: 0, pixelHeight: 0)
                        }
                    }
                    try await group.next()
                    group.cancelAll()
                }
            }
            // withPTY returned WITHOUT throwing = the remote command/shell exited on its own
            // (agent quit, `exit` typed). This is the common end case and does NOT hit `catch`,
            // so surface the reconnect affordance here too (unless we were torn down).
            if !Task.isCancelled {
                status = "\(target.label) exited"
                ended = true
            }
        } catch {
            if !Task.isCancelled {
                status = "\(target.label) ended"
                ended = true
            }
        }
    }
}
