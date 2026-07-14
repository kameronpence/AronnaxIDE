import SwiftUI

/// The sidebar: which kepler project the workspace's agent panes attach to. Single host
/// (kepler) for v1 — a project list (pinned "kepler root") + the connection status. Projects can
/// be hidden (long-press → Hide); a toolbar toggle reveals hidden ones so they can be restored.
struct ProjectSidebar: View {
    @ObservedObject var connection: SSHConnection
    @Binding var selected: String?
    @StateObject private var prefs = ProjectPrefs()
    @State private var showHidden = false

    /// "kepler root" always shows; other projects only when not hidden (or when revealing).
    private var visibleProjects: [String] {
        connection.projects.filter {
            $0 == SSHConnection.keplerRootLabel || showHidden || !prefs.isHidden($0)
        }
    }

    private var hiddenCount: Int {
        connection.projects.filter { prefs.isHidden($0) }.count
    }

    var body: some View {
        List(selection: $selected) {
            Section {
                ForEach(visibleProjects, id: \.self) { project in
                    let isRoot = project == SSHConnection.keplerRootLabel
                    let hidden = prefs.isHidden(project)
                    Label(project, systemImage: isRoot ? "house" : (hidden ? "eye.slash" : "folder"))
                        .tag(project)
                        .opacity(hidden ? 0.5 : 1)
                        .contextMenu {
                            if !isRoot {
                                Button {
                                    setHidden(project, !hidden)
                                } label: {
                                    Label(hidden ? "Show in List" : "Hide from List",
                                          systemImage: hidden ? "eye" : "eye.slash")
                                }
                            }
                        }
                }
            } header: {
                HStack {
                    Text("Project")
                    Spacer()
                    if hiddenCount > 0 {
                        Button { showHidden.toggle() } label: {
                            Image(systemName: showHidden ? "eye" : "eye.slash")
                        }
                        .buttonStyle(.borderless)
                    }
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

    /// Hide/show a project; when hiding the selected one, move the selection back to "kepler root"
    /// so the panes don't keep pointing at a now-hidden project.
    private func setHidden(_ project: String, _ hidden: Bool) {
        prefs.setHidden(project, hidden)
        if hidden, selected == project {
            selected = SSHConnection.keplerRootLabel
        }
    }
}
