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

    var body: some View {
        surface
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(   // a thin frame so pane content (incl. the tmux status bar) reads as inset, not flush
                Rectangle()
                    .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
            )
            .padding(10)   // breathing room around each pane
    }

    @ViewBuilder
    private var surface: some View {
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
    @State private var leftTab: WorkspaceTab = .terminal
    /// `nil` = single pane; non-nil = a second pane (right or bottom).
    @State private var rightTab: WorkspaceTab?
    @State private var splitAxis: SplitAxis = .horizontal

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 340)
        } detail: {
            VStack(spacing: 0) {
                WorkspaceTabBar(selection: $leftTab,
                                isSplit: rightTab != nil,
                                splitAxis: splitAxis,
                                onToggleSplit: toggleSplit)
                Divider()
                workspace
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                StatusBar()
            }
        }
        .navigationTitle("MiniIDE")
        .preferredColorScheme(.light)   // keep the whole app light regardless of system appearance
    }

    private var workspace: some View {
        // Pure-SwiftUI split (see SplitContainer) — no NSSplitView, so closing the
        // split no longer freezes. The left surface is always the primary pane and
        // keeps its live session whether or not the split is open.
        SplitContainer(
            axis: splitAxis,
            showsSecondary: rightTab != nil,
            primary: { WorkspaceSurface(tab: leftTab) },
            secondary: {
                if let right = Binding($rightTab) {
                    SecondaryPane(tab: right, onClose: { rightTab = nil })
                }
            }
        )
    }

    /// Toggle the second pane in the given orientation. Clicking the same orientation
    /// again closes the split; clicking the other orientation switches it.
    private func toggleSplit(_ axis: SplitAxis) {
        if rightTab != nil && splitAxis == axis {
            rightTab = nil
        } else {
            splitAxis = axis
            if rightTab == nil {
                rightTab = (leftTab == .terminal) ? .coding : .terminal
            }
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
    let splitAxis: SplitAxis
    let onToggleSplit: (SplitAxis) -> Void

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
            splitButton(.horizontal, icon: "rectangle.split.2x1", label: "Split right")
            splitButton(.vertical, icon: "rectangle.split.1x2", label: "Split bottom")
        }
        .font(.callout)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    private func splitButton(_ axis: SplitAxis, icon: String, label: String) -> some View {
        let active = isSplit && splitAxis == axis
        return Button(action: { onToggleSplit(axis) }) {
            Image(systemName: icon)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
        }
        .buttonStyle(.plain)
        .foregroundStyle(active ? Color.accentColor : .secondary)
        .help(active ? "Close split" : label)
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
