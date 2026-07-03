import Foundation
import SwiftTerm
import Citadel
import NIOCore
import NIOSSH
import Crypto

/// Milestone 0 spike: open an interactive PTY shell on kepler over Citadel (pure-Swift
/// SSH) and bridge it to a SwiftTerm `TerminalView` — output bytes feed the terminal,
/// keyboard bytes go back over the channel. Proves the hard part of the iOS app.
@MainActor
final class SSHTerminalSession: ObservableObject {
    @Published var status = "Idle"
    weak var terminalView: TerminalView?

    private var task: Task<Void, Never>?
    private var inputContinuation: AsyncStream<[UInt8]>.Continuation?

    func start() {
        guard task == nil else { return }
        status = "Connecting…"
        let (stream, cont) = AsyncStream<[UInt8]>.makeStream()
        inputContinuation = cont
        task = Task { [weak self] in await self?.run(input: stream) }
    }

    /// Keyboard input from the terminal view → queued for the writer task.
    func sendInput(_ bytes: [UInt8]) {
        inputContinuation?.yield(bytes)
    }

    private func feed(_ bytes: [UInt8]) {
        terminalView?.feed(byteArray: bytes[...])
    }

    private func initialSize() -> (cols: Int, rows: Int) {
        if let t = terminalView?.getTerminal() {
            return (max(t.cols, 20), max(t.rows, 10))
        }
        return (80, 24)
    }

    private func run(input: AsyncStream<[UInt8]>) async {
        do {
            let key = try Curve25519.Signing.PrivateKey(sshEd25519: aronnaxPrivateKey)
            let settings = SSHClientSettings(
                host: keplerHost,
                port: 22,
                authenticationMethod: { .ed25519(username: keplerUser, privateKey: key) },
                hostKeyValidator: .acceptAnything()
            )
            let client = try await SSHClient.connect(to: settings)
            status = "Connected"
            let size = initialSize()
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
                try await withThrowingTaskGroup(of: Void.self) { group in
                    // Remote output → terminal.
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
                    // Keyboard → remote stdin.
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
            status = "Session ended"
        } catch {
            status = "Error: \(error)"
        }
    }
}
