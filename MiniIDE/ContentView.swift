import SwiftUI

/// The surfaces available in the main workspace.
enum WorkspaceTab: String, CaseIterable, Identifiable {
    case terminal = "Terminal"
    case chat = "Chat"
    case browser = "Browser"
    case vault = "Vault"
    case beads = "Beads"
    case logs = "Logs"
    case git = "Git / Deploy"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .terminal: return "terminal"
        case .chat:     return "bubble.left.and.bubble.right"
        case .browser:  return "globe"
        case .vault:    return "doc.text"
        case .beads:    return "point.3.connected.trianglepath.dotted"
        case .logs:     return "list.bullet.rectangle"
        case .git:      return "arrow.triangle.branch"
        }
    }
}

struct ContentView: View {
    @EnvironmentObject private var settings: AppSettings
    @State private var selectedTab: WorkspaceTab = .terminal

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 340)
        } detail: {
            VStack(spacing: 0) {
                WorkspaceTabBar(selection: $selectedTab)
                Divider()
                workspaceContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                StatusBar()
            }
        }
        .navigationTitle("MiniIDE")
    }

    @ViewBuilder
    private var workspaceContent: some View {
        switch selectedTab {
        case .terminal: TerminalPane()
        case .chat:     ChatPane()
        case .browser:  BrowserPane()
        case .vault:    VaultPane()
        case .beads:    BeadsPanel()
        case .logs:     LogViewer()
        case .git:      GitDeployPanel()
        }
    }
}

private struct WorkspaceTabBar: View {
    @Binding var selection: WorkspaceTab

    var body: some View {
        HStack(spacing: 4) {
            ForEach(WorkspaceTab.allCases) { tab in
                Button {
                    selection = tab
                } label: {
                    Label(tab.rawValue, systemImage: tab.systemImage)
                        .labelStyle(.titleAndIcon)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            selection == tab
                                ? Color.accentColor.opacity(0.18)
                                : Color.clear,
                            in: RoundedRectangle(cornerRadius: 6)
                        )
                }
                .buttonStyle(.plain)
                .foregroundStyle(selection == tab ? Color.accentColor : .secondary)
            }
            Spacer()
        }
        .font(.callout)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }
}

private struct SidebarView: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        List {
            Section("Hosts") {
                ForEach(settings.hosts) { host in
                    Label(host.displayName,
                          systemImage: host.isHub ? "server.rack" : "cloud")
                }
            }
            Section("Projects") {
                if settings.projects.isEmpty {
                    Text("No projects yet")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                } else {
                    ForEach(settings.projects) { project in
                        Label(project.name, systemImage: "folder")
                    }
                }
            }
        }
        .listStyle(.sidebar)
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
