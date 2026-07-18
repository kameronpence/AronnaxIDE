import SwiftUI

/// The surfaces available in the main workspace.
enum WorkspaceTab: String, CaseIterable, Identifiable, Codable {
    case terminal = "Terminal"
    case coding = "Coding"
    case browser = "Browser"
    case vault = "Vault"
    case beads = "Beads"
    case logs = "Logs"
    case git = "Git / Deploy"
    case health = "Health"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .terminal: return "terminal"
        case .coding:   return "chevron.left.forwardslash.chevron.right"
        case .browser:  return "globe"
        case .vault:    return "doc.text"
        case .beads:    return "point.3.connected.trianglepath.dotted"
        case .logs:     return "list.bullet.rectangle"
        case .git:      return "arrow.triangle.branch"
        case .health:   return "waveform.path.ecg"
        }
    }
}

/// Renders the surface for a workspace tab. Shared by the single-pane view and each
/// column of a split, so a given tab always maps to the same pane.
struct WorkspaceSurface: View {
    let tab: WorkspaceTab

    @ViewBuilder
    var body: some View {
        switch tab {
        case .terminal: TerminalPane()
        case .coding:   CodingPane()
        case .browser:  BrowserPane()
        case .vault:    VaultPane()
        case .beads:    BeadsPanel()
        case .logs:     LogViewer()
        case .git:      GitDeployPanel()
        case .health:   HostHealthPanel()
        }
    }
}

struct ContentView: View {
    @EnvironmentObject private var settings: AppSettings
    @StateObject private var workspace = WorkspaceModel()
    @StateObject private var usage = UsageService()
    @StateObject private var projects = ProjectService()

    var body: some View {
        NavigationSplitView {
            SidebarView(usage: usage, projects: projects)
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 340)
        } detail: {
            VStack(spacing: 0) {
                WorkspaceTopBar(workspace: workspace)
                Divider()
                WorkspaceView(model: workspace)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("AronnaxIDE")
        .preferredColorScheme(.light)   // keep the whole app light regardless of system appearance
    }
}

/// The top bar: connection status + hub on the left, the surface tabs in the middle
/// (they retarget the focused pane), and the Settings gear on the right.
private struct WorkspaceTopBar: View {
    @ObservedObject var workspace: WorkspaceModel
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var wakeObserver: WakeObserver
    @StateObject private var monitor = ConnectionMonitor()

    var body: some View {
        HStack(spacing: 12) {
            // Connection status + hub (left)
            HStack(spacing: 7) {
                Circle().fill(dotColor).frame(width: 11, height: 11)
                Text(statusText).foregroundStyle(.secondary)
                Button("Reconnect", action: reconnect).buttonStyle(.link)
                if let hub = settings.hub {
                    Text("· \(hub.sshAlias)").foregroundStyle(.tertiary)
                }
            }
            .fixedSize()

            Spacer(minLength: 8)

            // Surface tabs — retarget the focused pane
            HStack(spacing: 4) {
                ForEach(WorkspaceTab.allCases) { tab in
                    Button { workspace.setFocusedTab(tab) } label: {
                        Label(tab.rawValue, systemImage: tab.systemImage)
                            .labelStyle(.titleAndIcon)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(
                                workspace.focusedTab == tab
                                    ? Color.accentColor.opacity(0.18) : Color.clear,
                                in: RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(workspace.focusedTab == tab ? Color.accentColor : .secondary)
                }
            }
            .fixedSize()

            Spacer(minLength: 8)

            // Settings (right)
            SettingsLink { Image(systemName: "gearshape.fill") }
                .buttonStyle(.borderless)
                .font(.title2)
                .help("Settings (⌘,) — hosts, GitHub accounts, workdir")
        }
        .font(.body)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .onAppear { monitor.start(host: settings.hub) }
        .onDisappear { monitor.stop() }
    }

    private var dotColor: Color {
        switch monitor.status {
        case .connected:    return .green
        case .disconnected: return .red
        case .checking:     return .yellow
        }
    }
    private var statusText: String {
        switch monitor.status {
        case .connected:    return "Connected"
        case .disconnected: return "Disconnected"
        case .checking:     return "Connecting…"
        }
    }
    private func reconnect() {
        wakeObserver.triggerReconnect()
        // Drop the (possibly stale) hub master so Reconnect works even with no
        // reconnect-aware pane mounted; idempotent per signal.
        if let hub = settings.hub {
            SSHManager.shared.resetMasterOnce(for: hub, generation: wakeObserver.reconnectSignal)
        }
        monitor.recheck(host: settings.hub)
    }
}

private struct SidebarView: View {
    @EnvironmentObject private var settings: AppSettings
    @ObservedObject var usage: UsageService
    @ObservedObject var projects: ProjectService

    /// When on, hidden projects are revealed in the list (dimmed, with an "unhide"
    /// action) so you can bring them back. Off by default — hidden means hidden.
    @State private var showHidden = false

    var body: some View {
        VStack(spacing: 0) {
            List {
                Section("Working on") {
                    ForEach(Array(settings.hosts.enumerated()), id: \.element.id) { index, host in
                        HStack {
                            Button { settings.activeHostID = host.id } label: {
                                HStack {
                                    Label(host.displayName, systemImage: host.isHub ? "server.rack" : "cloud")
                                    Spacer()
                                    if settings.activeHostID == host.id {
                                        Image(systemName: "checkmark")
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(.tint)
                                    }
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            moveButtons(
                                canMoveUp: index > 0,
                                canMoveDown: index < settings.hosts.count - 1,
                                moveUp: { settings.moveHosts(from: IndexSet(integer: index), to: index - 1) },
                                moveDown: { settings.moveHosts(from: IndexSet(integer: index), to: index + 2) }
                            )
                        }
                    }
                    .onMove { source, destination in
                        settings.moveHosts(from: source, to: destination)
                    }
                }
                Section {
                    if settings.activeHost?.isHub ?? true {
                        // "kepler root" — deselect any project so every pane operates in the
                        // host home (/Users/kepler) instead of a project dir. Lets you run
                        // the agents on the machine itself, no host-toggle hack.
                        projectRow(name: "kepler root", path: settings.hostHome,
                                   subtitle: "Host home — no project", icon: "house")
                        // Hub: the projects discovered under the vault's Projects/ folder,
                        // minus any the user has hidden (unless "show hidden" is on).
                        let visible = settings.orderedProjects(projects.projects).filter {
                            showHidden || !settings.isProjectHidden($0.path)
                        }
                        if visible.isEmpty {
                            Text(emptyProjectsText)
                                .foregroundStyle(.secondary).font(.callout)
                        } else {
                            ForEach(Array(visible.enumerated()), id: \.element.id) { index, project in
                                let hidden = settings.isProjectHidden(project.path)
                                projectRow(name: project.name, path: project.path,
                                           subtitle: project.branch.map { $0 + (project.owner.map { o in " · \(o)" } ?? "") },
                                           isHidden: hidden,
                                           moveUp: index > 0
                                                ? { settings.moveProjects(projects.projects, visibleProjects: visible, from: IndexSet(integer: index), to: index - 1) }
                                                : nil,
                                           moveDown: index < visible.count - 1
                                                ? { settings.moveProjects(projects.projects, visibleProjects: visible, from: IndexSet(integer: index), to: index + 2) }
                                                : nil)
                                    .contextMenu {
                                        Button(hidden ? "Show in List" : "Hide from List",
                                               systemImage: hidden ? "eye" : "eye.slash") {
                                            toggleHidden(project.path, to: !hidden)
                                        }
                                    }
                            }
                            .onMove { source, destination in
                                settings.moveProjects(projects.projects, visibleProjects: visible, from: source, to: destination)
                            }
                        }
                    } else if let path = settings.serverProjectPath {
                        // Server: its one project directory — not a folder to scan.
                        projectRow(name: (path as NSString).lastPathComponent, path: path, subtitle: path)
                    } else {
                        Text("No project directory set for this server — add it in Settings → Hosts.")
                            .foregroundStyle(.secondary).font(.callout)
                    }
                } header: {
                    HStack(spacing: 8) {
                        Text((settings.activeHost?.isHub ?? true) ? "Projects" : "Project")
                        Spacer()
                        if settings.activeHost?.isHub ?? true {
                            if hiddenCount > 0 {
                                Button { showHidden.toggle() } label: {
                                    Image(systemName: showHidden ? "eye" : "eye.slash")
                                }
                                .buttonStyle(.borderless).controlSize(.small)
                                .help(showHidden
                                      ? "Hide finished projects"
                                      : "Show \(hiddenCount) hidden project\(hiddenCount == 1 ? "" : "s")")
                            }
                            if projects.isLoading {
                                ProgressView().controlSize(.mini)
                            } else {
                                Button { projects.refresh() } label: { Image(systemName: "arrow.clockwise") }
                                    .buttonStyle(.borderless).controlSize(.small).help("Rescan projects")
                            }
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .font(.body)

            Divider()
            SidebarUsageFooter(usage: usage)
        }
        .onAppear {
            usage.start(host: settings.hub, workdir: settings.agentWorkdir)
            if settings.activeHost?.isHub ?? true {
                projects.start(host: settings.hub, root: settings.projectsRoot)
            } else {
                settings.selectedProjectPath = settings.serverProjectPath
            }
        }
        .onChange(of: projects.projects) { _, list in
            // Hub only: auto-select the first *visible* project (and recover if it vanished).
            guard settings.activeHost?.isHub ?? true else { return }
            // "kepler root" is a deliberate selection that isn't in the scanned list — leave
            // it pinned so a rescan doesn't snap the panes back to a project.
            if settings.selectedProjectPath == settings.hostHome { return }
            if settings.selectedProjectPath == nil
                || !list.contains(where: { $0.path == settings.selectedProjectPath }) {
                settings.selectedProjectPath = settings.orderedProjects(list)
                    .first { !settings.isProjectHidden($0.path) }?.path
            }
        }
        .onChange(of: settings.activeHostID) { _, _ in
            // Switched host: the hub re-scans its Projects/ folder; a server pins to its
            // one configured project directory (no scan).
            if settings.activeHost?.isHub ?? true {
                projects.setRoot(host: settings.hub, root: settings.projectsRoot)
            } else {
                settings.selectedProjectPath = settings.serverProjectPath
            }
        }
        .onChange(of: settings.agentWorkdir) { _, _ in
            if settings.activeHost?.isHub ?? true {
                projects.setRoot(host: settings.hub, root: settings.projectsRoot)
            }
        }
        .onChange(of: settings.projectsRefreshToken) { _, _ in
            // The New Project wizard just wired a project on the hub — rescan so it shows up.
            // No isHub guard: `projects` is always pointed at the hub's Projects/ (a server
            // active in the sidebar doesn't re-point it), so if we're on a server when the
            // create finishes, refresh still updates the hub list in the background and the
            // project is already there when the user switches back — where setRoot would
            // otherwise early-return on the unchanged hub root and never rescan.
            projects.refresh(force: true)
        }
    }

    /// One selectable project row (used for both hub-discovered projects + the server's
    /// project). `isHidden` only applies to hub projects revealed via "show hidden" —
    /// the row is dimmed and marked so it reads as hidden.
    @ViewBuilder
    private func projectRow(
        name: String,
        path: String,
        subtitle: String?,
        isHidden: Bool = false,
        icon: String = "folder",
        moveUp: (() -> Void)? = nil,
        moveDown: (() -> Void)? = nil
    ) -> some View {
        HStack {
            Button { settings.selectedProjectPath = path } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Label(name, systemImage: isHidden ? "eye.slash" : icon)
                        if let subtitle {
                            Text(subtitle).font(.callout).foregroundStyle(.secondary).padding(.leading, 24)
                        }
                    }
                    Spacer()
                    if settings.selectedProjectPath == path {
                        Image(systemName: "checkmark").font(.caption.weight(.semibold)).foregroundStyle(.tint)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            moveButtons(
                canMoveUp: moveUp != nil,
                canMoveDown: moveDown != nil,
                moveUp: moveUp ?? {},
                moveDown: moveDown ?? {}
            )
        }
        .opacity(isHidden ? 0.5 : 1)
    }

    private func moveButtons(
        canMoveUp: Bool,
        canMoveDown: Bool,
        moveUp: @escaping () -> Void,
        moveDown: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 2) {
            Button(action: moveUp) { Image(systemName: "chevron.up") }
                .disabled(!canMoveUp)
                .help("Move up")
            Button(action: moveDown) { Image(systemName: "chevron.down") }
                .disabled(!canMoveDown)
                .help("Move down")
        }
        .buttonStyle(.borderless)
        .controlSize(.mini)
    }

    /// Count of discovered projects the user has hidden (hub only).
    private var hiddenCount: Int {
        projects.projects.reduce(0) { $0 + (settings.isProjectHidden($1.path) ? 1 : 0) }
    }

    /// Sidebar text when nothing is shown — distinguishes "none exist" from "all hidden".
    private var emptyProjectsText: String {
        if projects.isLoading { return "Scanning…" }
        if !projects.projects.isEmpty && hiddenCount == projects.projects.count {
            return "All projects hidden"
        }
        return "No projects found"
    }

    /// Hide/show a project. When hiding the currently-selected one, move the selection
    /// to the first still-visible project so the panes don't point at a hidden folder.
    private func toggleHidden(_ path: String, to hidden: Bool) {
        settings.setProjectHidden(path, hidden)
        if hidden, settings.selectedProjectPath == path {
            settings.selectedProjectPath = settings.orderedProjects(projects.projects)
                .first { !settings.isProjectHidden($0.path) }?.path
        }
    }
}


#Preview {
    ContentView()
        .environmentObject(AppSettings())
        .environmentObject(WakeObserver())
}
