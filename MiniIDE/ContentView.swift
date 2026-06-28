import SwiftUI

/// The surfaces available in the main workspace.
enum WorkspaceTab: String, CaseIterable, Identifiable {
    case terminal = "Terminal"
    case coding = "Coding"
    case browser = "Browser"
    case vault = "Vault"
    case beads = "Beads"
    case logs = "Logs"
    case git = "Git / Deploy"

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
                WorkspaceTabBar(workspace: workspace)
                Divider()
                WorkspaceView(model: workspace)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                StatusBar()
            }
        }
        .navigationTitle("AronnaxIDE")
        .preferredColorScheme(.light)   // keep the whole app light regardless of system appearance
    }
}

/// The surface switcher. Each pane has its own content dropdown + split/close
/// controls; this bar is a convenience that retargets the *focused* pane (the one
/// outlined in the accent color when more than one pane is open).
private struct WorkspaceTabBar: View {
    @ObservedObject var workspace: WorkspaceModel

    var body: some View {
        HStack(spacing: 4) {
            ForEach(WorkspaceTab.allCases) { tab in
                Button {
                    workspace.setFocusedTab(tab)
                } label: {
                    Label(tab.rawValue, systemImage: tab.systemImage)
                        .labelStyle(.titleAndIcon)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            workspace.focusedTab == tab
                                ? Color.accentColor.opacity(0.18)
                                : Color.clear,
                            in: RoundedRectangle(cornerRadius: 6)
                        )
                }
                .buttonStyle(.plain)
                .foregroundStyle(workspace.focusedTab == tab ? Color.accentColor : .secondary)
            }
            Spacer()
            if workspace.paneCount > 1 {
                Text("→ focused pane")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .help("These tabs change the highlighted pane. Each pane also has its own content dropdown and split buttons.")
            }
        }
        .font(.callout)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }
}

private struct SidebarView: View {
    @EnvironmentObject private var settings: AppSettings
    @ObservedObject var usage: UsageService
    @ObservedObject var projects: ProjectService

    var body: some View {
        VStack(spacing: 0) {
            List {
                Section("Hosts") {
                    ForEach(settings.hosts) { host in
                        Label(host.displayName,
                              systemImage: host.isHub ? "server.rack" : "cloud")
                    }
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
                                                .font(.caption)
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

            Divider()
            SidebarUsageFooter(usage: usage)
        }
        .onAppear {
            usage.start(host: settings.hub, workdir: settings.agentWorkdir)
            projects.start(host: settings.hub, root: settings.agentWorkdir)
        }
        .onChange(of: projects.projects) { _, list in
            // Auto-select the first project (and recover if the selection vanished).
            if settings.selectedProjectPath == nil
                || !list.contains(where: { $0.path == settings.selectedProjectPath }) {
                settings.selectedProjectPath = list.first?.path
            }
        }
    }
}

private struct StatusBar: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var wakeObserver: WakeObserver
    @StateObject private var monitor = ConnectionMonitor()

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(dotColor)
                .frame(width: 8, height: 8)
            Text(statusText)
                .foregroundStyle(.secondary)
            Button("Reconnect", action: reconnect)
                .buttonStyle(.link)
                .font(.caption)
            Spacer()
            if let hub = settings.hub {
                Text("hub: \(hub.sshAlias)")
                    .foregroundStyle(.tertiary)
            }
        }
        .font(.caption)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
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
        // Drop the (possibly stale) hub master directly so Reconnect works even on
        // a tab with no reconnect-aware pane mounted to do it. resetMasterOnce is
        // idempotent per signal, so this coordinates with any active pane rather
        // than double-closing.
        if let hub = settings.hub {
            SSHManager.shared.resetMasterOnce(for: hub,
                                              generation: wakeObserver.reconnectSignal)
        }
        monitor.recheck(host: settings.hub)
    }
}

#Preview {
    ContentView()
        .environmentObject(AppSettings())
        .environmentObject(WakeObserver())
}
