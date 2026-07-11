import SwiftUI

/// M3 shell: a status header over the recursive split-pane workspace. Leaves are placeholders
/// for now; M4 binds each leaf to a real terminal session and M5 adds the project sidebar.
struct RootView: View {
    @StateObject private var connection: SSHConnection
    @StateObject private var manager: PaneSessionManager
    @StateObject private var workspace = WorkspaceModel()

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
            WorkspaceView(model: workspace)
        }
        .onAppear { connection.start() }
        .preferredColorScheme(.light)
    }
}
