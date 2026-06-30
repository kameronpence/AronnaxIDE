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

    var body: some View {
        VStack(spacing: 0) {
            List {
                Section("Working on") {
                    Picker("Host", selection: $settings.activeHostID) {
                        ForEach(settings.hosts) { host in
                            Label(host.displayName,
                                  systemImage: host.isHub ? "server.rack" : "cloud").tag(host.id)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }
                Section {
                    if projects.projects.isEmpty {
                        Text(projects.isLoading ? "Scanning…" : "No projects found")
                            .foregroundStyle(.secondary)
                            .font(.callout)
                    } else {
                        ForEach(projects.projects) { project in
                            Button {
                                settings.selectedProjectPath = project.path
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 1) {
                                        Label(project.name, systemImage: "folder")
                                        if let branch = project.branch {
                                            Text(branch + (project.owner.map { " · \($0)" } ?? ""))
                                                .font(.callout)
                                                .foregroundStyle(.secondary)
                                                .padding(.leading, 24)
                                        }
                                    }
                                    Spacer()
                                    if settings.selectedProjectPath == project.path {
                                        Image(systemName: "checkmark")
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(.tint)
                                    }
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                } header: {
                    HStack {
                        Text("Projects")
                        Spacer()
                        if projects.isLoading {
                            ProgressView().controlSize(.mini)
                        } else {
                            Button { projects.refresh() } label: { Image(systemName: "arrow.clockwise") }
                                .buttonStyle(.borderless)
                                .controlSize(.small)
                                .help("Rescan projects")
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
            projects.start(host: settings.activeHost, root: settings.activeProjectsRoot)
        }
        .onChange(of: projects.projects) { _, list in
            // Auto-select the first project (and recover if the selection vanished).
            if settings.selectedProjectPath == nil
                || !list.contains(where: { $0.path == settings.selectedProjectPath }) {
                settings.selectedProjectPath = list.first?.path
            }
        }
        .onChange(of: settings.activeProjectsRoot) { _, _ in
            // Active host (or its projects root / the hub workdir) changed — re-scan
            // there. The projects.onChange auto-selects the first of the new list, so a
            // stale selection from the previous host clears itself.
            projects.setRoot(host: settings.activeHost, root: settings.activeProjectsRoot)
        }
    }
}


#Preview {
    ContentView()
        .environmentObject(AppSettings())
        .environmentObject(WakeObserver())
}
