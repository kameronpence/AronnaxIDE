import SwiftUI

/// One terminal surface with a Terminal / Claude / Codex switcher (one at a time — no
/// split) and a project picker for which kepler project the agents attach to.
struct ContentView: View {
    @StateObject private var session = SSHTerminalSession()
    @Environment(\.scenePhase) private var scenePhase
    /// Only reconnect on foreground if we actually backgrounded — a brief `.inactive`
    /// (notification banner, Control Center) must not trigger a needless reconnect.
    @State private var didBackground = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "terminal.fill").foregroundStyle(.tint)
                Text("kepler").font(.headline)
                Spacer()
                Text(session.status)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .padding(.top, 6)

            Picker("Surface", selection: Binding(
                get: { session.target },
                set: { session.select($0) }
            )) {
                ForEach(AgentTarget.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 12)
            .padding(.top, 6)

            // Project picker — which kepler project Claude/Codex attach to.
            HStack(spacing: 6) {
                Image(systemName: "folder").font(.caption).foregroundStyle(.secondary)
                Menu {
                    ForEach(session.projects, id: \.self) { project in
                        Button {
                            session.selectProject(project)
                        } label: {
                            if project == session.selectedProject {
                                Label(project, systemImage: "checkmark")
                            } else {
                                Text(project)
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 3) {
                        Text(session.selectedProject.isEmpty ? "Loading projects…" : session.selectedProject)
                        Image(systemName: "chevron.up.chevron.down").font(.caption2)
                    }
                    .font(.callout)
                }
                .disabled(session.projects.isEmpty)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

            Divider()
            TerminalSurface(session: session)
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .padding(.bottom, 4)
        }
        .onAppear { session.start() }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background:
                didBackground = true
            case .active where didBackground:
                didBackground = false
                session.reconnect()   // socket died while suspended → reconnect + reattach
            default:
                break
            }
        }
        .preferredColorScheme(.light)
    }
}
