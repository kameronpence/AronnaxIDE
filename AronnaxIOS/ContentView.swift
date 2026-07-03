import SwiftUI

/// Milestone 0 — a live kepler terminal on the phone. Connects on appear and shows the
/// SSH shell. Once this works, the Coding pane + key-accessory bar build on top.
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
            .padding(.vertical, 8)
            Divider()
            TerminalSurface(session: session)
        }
        .onAppear { session.start() }
    }
}
