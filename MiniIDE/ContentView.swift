import SwiftUI

/// The surfaces available in the main workspace.
enum WorkspaceTab: String, CaseIterable, Identifiable {
    case terminal = "Terminal"
    case coding = "Coding"
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
        case .coding:   return "chevron.left.forwardslash.chevron.right"
        case .chat:     return "bubble.left.and.bubble.right"
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
        case .chat:     WebChatPane()
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
    @State private var leftTab: WorkspaceTab = .terminal
    /// `nil` = single pane; non-nil = a second pane shown to the right.
    @State private var rightTab: WorkspaceTab?

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 340)
        } detail: {
            VStack(spacing: 0) {
                WorkspaceTabBar(selection: $leftTab,
                                isSplit: rightTab != nil,
                                onToggleSplit: toggleSplit)
                Divider()
                workspace
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                StatusBar()
            }
        }
        .navigationTitle("MiniIDE")
    }

    private var workspace: some View {
        // The left surface is the unconditional first child of one persistent
        // HSplitView, so toggling the split keeps the live left session (only the
        // right pane is added/removed). The close is deferred to the next runloop so
        // the right pane isn't torn down mid-click — removing it synchronously inside
        // the button action was freezing the split.
        HSplitView {
            WorkspaceSurface(tab: leftTab)
                .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
            if let right = Binding($rightTab) {
                SecondaryPane(tab: right, onClose: { DispatchQueue.main.async { rightTab = nil } })
                    .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    /// Open the right pane (defaulting to a surface different from the left) or
    /// close it if already open.
    private func toggleSplit() {
        if rightTab == nil {
            rightTab = (leftTab == .terminal) ? .coding : .terminal
        } else {
            rightTab = nil
        }
    }
}

/// The right column of a split workspace: its own surface picker + a close button
/// above the surface.
private struct SecondaryPane: View {
    @Binding var tab: WorkspaceTab
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Menu {
                    ForEach(WorkspaceTab.allCases) { t in
                        Button {
                            tab = t
                        } label: {
                            Label(t.rawValue, systemImage: t.systemImage)
                        }
                    }
                } label: {
                    Label(tab.rawValue, systemImage: tab.systemImage)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()

                Spacer()

                Button(action: onClose) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Close this pane")
            }
            .font(.callout)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)

            Divider()

            WorkspaceSurface(tab: tab)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct WorkspaceTabBar: View {
    @Binding var selection: WorkspaceTab
    let isSplit: Bool
    let onToggleSplit: () -> Void

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
            Button(action: onToggleSplit) {
                Image(systemName: isSplit ? "rectangle" : "rectangle.split.2x1")
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
            }
            .buttonStyle(.plain)
            .foregroundStyle(isSplit ? Color.accentColor : .secondary)
            .help(isSplit ? "Close split view" : "Split view (open a second pane)")
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
