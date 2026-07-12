import SwiftUI

/// The iPad shell: a project sidebar beside the recursive split-pane workspace. Selecting a
/// project reattaches the agent panes to that project's tmux session (a plain terminal keeps
/// running). Single host = kepler.
struct RootView: View {
    @StateObject private var connection: SSHConnection
    @StateObject private var manager: PaneSessionManager
    @StateObject private var workspace = WorkspaceModel()
    @State private var selectedProject: String? = SSHConnection.keplerRootLabel
    @Environment(\.scenePhase) private var scenePhase
    /// Only reconnect on foreground if we actually tore down on background — a brief
    /// `.inactive` (control center, notification) must not trigger a needless reconnect.
    @State private var didBackground = false

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
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background:
                connection.stop()
                didBackground = true
            case .active where didBackground:
                didBackground = false
                connection.start()        // reconnect…
                manager.reattachAll()     // …and reattach every pane to its tmux session
            default:
                break
            }
        }
        .preferredColorScheme(.light)
    }
}
