import SwiftUI

/// The iPad shell: a project sidebar beside the recursive split-pane workspace. Selecting a
/// project reattaches the agent panes to that project's tmux session (a plain terminal keeps
/// running). Single host = kepler.
struct RootView: View {
    @StateObject private var connection: SSHConnection
    @StateObject private var manager: PaneSessionManager
    @StateObject private var workspace = WorkspaceModel()
    @State private var selectedProject: String? = SSHConnection.keplerRootLabel

    init() {
        let conn = SSHConnection()
        _connection = StateObject(wrappedValue: conn)
        _manager = StateObject(wrappedValue: PaneSessionManager(connection: conn))
    }

    var body: some View {
        NavigationSplitView {
            ProjectSidebar(connection: connection, selected: $selectedProject)
        } detail: {
            let project = selectedProject ?? SSHConnection.keplerRootLabel
            WorkspaceView(model: workspace, manager: manager,
                          workdir: connection.workdir(for: project))
                .navigationTitle(project)
                .navigationBarTitleDisplayMode(.inline)
        }
        .onAppear { connection.start() }
        .preferredColorScheme(.light)
    }
}
