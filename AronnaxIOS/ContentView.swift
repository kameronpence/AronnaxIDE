import SwiftUI

/// One terminal surface with a Terminal / Claude / Codex switcher (one at a time — no
/// split). Connects to kepler on appear.
struct ContentView: View {
    @StateObject private var session = SSHTerminalSession(projectDir: defaultProjectDir)

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
            .padding(.vertical, 6)

            Divider()
            TerminalSurface(session: session)
        }
        .onAppear { session.start() }
        .preferredColorScheme(.light)
    }
}
