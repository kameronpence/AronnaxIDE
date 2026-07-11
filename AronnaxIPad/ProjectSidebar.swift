import SwiftUI

/// The sidebar: which kepler project the workspace's agent panes attach to. Single host
/// (kepler) for v1 — a project list (pinned "kepler root") + the connection status.
struct ProjectSidebar: View {
    @ObservedObject var connection: SSHConnection
    @Binding var selected: String?

    var body: some View {
        List(selection: $selected) {
            Section("Project") {
                ForEach(connection.projects, id: \.self) { project in
                    Label(project,
                          systemImage: project == SSHConnection.keplerRootLabel ? "house" : "folder")
                        .tag(project)
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("kepler")
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 6) {
                Circle()
                    .fill(connection.status == "Connected" ? Color.green : Color.secondary)
                    .frame(width: 8, height: 8)
                Text(connection.status)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(.bar)
        }
    }
}
