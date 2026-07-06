import SwiftUI

/// One terminal surface with a Terminal / Claude / Codex switcher (one at a time — no
/// split) and a project picker for which kepler project the agents attach to.
struct ContentView: View {
    @StateObject private var session = SSHTerminalSession()

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
                // Claude/Codex run in tmux; a one-finger drag can't reliably scroll their
                // history (SwiftTerm's scroll view eats the gesture), so give agents
                // explicit scroll buttons that drive tmux copy-mode via wheel events.
                .overlay(alignment: .bottomTrailing) {
                    if session.target != .terminal {
                        VStack(spacing: 10) {
                            ScrollRepeatButton(systemName: "chevron.up") { session.scrollAgent(up: true) }
                            ScrollRepeatButton(systemName: "chevron.down") { session.scrollAgent(up: false) }
                        }
                        .padding(.trailing, 20)
                        .padding(.bottom, 16)
                    }
                }
        }
        .onAppear { session.start() }
        .preferredColorScheme(.light)
    }
}

/// A translucent round scroll control. A tap scrolls one notch; press-and-hold repeats so
/// you can fling through long history without tapping dozens of times.
private struct ScrollRepeatButton: View {
    let systemName: String
    let action: () -> Void
    @State private var timer: Timer?

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 20, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 44, height: 44)
            .background(.blue.opacity(0.8), in: Circle())
            .shadow(radius: 2, y: 1)
            .contentShape(Circle())
            // minimumDistance 0 → onChanged fires on touch-down, onEnded on release, giving
            // us press/hold/release without a separate tap gesture to arbitrate.
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in if timer == nil { startRepeating() } }
                    .onEnded { _ in stopRepeating() }
            )
    }

    private func startRepeating() {
        action()   // fire once immediately so a quick tap scrolls
        // .common mode so it keeps firing while the touch is tracking.
        let t = Timer(timeInterval: 0.1, repeats: true) { _ in action() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func stopRepeating() {
        timer?.invalidate()
        timer = nil
    }
}
