import SwiftUI

/// M1 placeholder shell: one connection, one terminal pane. The recursive split-pane
/// workspace + sidebar land in later milestones (M3–M5); this proves the target builds,
/// connects to kepler, and hosts a live terminal on iPad.
struct RootView: View {
    @StateObject private var connection: SSHConnection
    @StateObject private var session: PaneSession

    init() {
        let conn = SSHConnection()
        _connection = StateObject(wrappedValue: conn)
        _session = StateObject(wrappedValue: PaneSession(
            id: UUID(), target: .terminal, workdir: conn.keplerHome, connection: conn))
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
            TerminalSurface(session: session)
                .padding(8)
        }
        .onAppear { connection.start() }
        .preferredColorScheme(.light)
    }
}
