import SwiftUI

@main
struct MiniIDEApp: App {
    @StateObject private var settings = AppSettings()
    @StateObject private var wakeObserver = WakeObserver()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(settings)
                .environmentObject(wakeObserver)
                .frame(minWidth: 1100, minHeight: 700)
                .onAppear {
                    // Re-establish port-forwards on the same reconnect signal the
                    // panes use (wake / network change / manual Reconnect).
                    PortForwardManager.shared.bind(to: wakeObserver)
                }
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)

        Settings {
            SettingsView()
                .environmentObject(settings)
                .preferredColorScheme(.light)   // keep Settings light too
        }
    }
}
