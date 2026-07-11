import SwiftUI

/// M2 checkpoint shell: one connection, TWO concurrent panes (Terminal + Claude) to prove
/// multiple PTY channels multiplex over a single `SSHConnection`. The recursive split-pane
/// workspace + sidebar replace this in M3–M5.
struct RootView: View {
    @StateObject private var connection: SSHConnection
    @StateObject private var manager: PaneSessionManager
    // @State so the pane keys survive RootView reconstruction (a plain `let` would
    // regenerate and leak the prior sessions' PTY channels). M3's WorkspaceModel owns leaf
    // ids persistently; this is just the interim two-pane checkpoint.
    @State private var leftID = UUID()
    @State private var rightID = UUID()

    init() {
        let conn = SSHConnection()
        _connection = StateObject(wrappedValue: conn)
        _manager = StateObject(wrappedValue: PaneSessionManager(connection: conn))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "terminal.fill").foregroundStyle(.tint)
                Text("kepler").font(.headline)
                Spacer()
                Text(connection.status)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()
            HStack(spacing: 0) {
                TerminalSurface(session: manager.session(for: leftID, target: .terminal,
                                                         workdir: connection.keplerHome))
                    .id(leftID)
                Divider()
                TerminalSurface(session: manager.session(for: rightID, target: .claude,
                                                         workdir: connection.keplerHome))
                    .id(rightID)
            }
        }
        .onAppear { connection.start() }
        .preferredColorScheme(.light)
    }
}
