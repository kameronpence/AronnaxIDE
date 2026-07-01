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
                .textSelection(.enabled)   // let text be highlighted/copied everywhere
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
                .textSelection(.enabled)
                .preferredColorScheme(.light)   // keep Settings light too
        }

        // The Add-Server wizard is its own window, not a sheet — a sheet is clamped
        // to the tiny Settings window's width and clips the wizard on both sides.
        Window("Add Server", id: AddServerWizard.windowID) {
            AddServerWizardWindow()
                .environmentObject(settings)
                .textSelection(.enabled)
                .preferredColorScheme(.light)
        }
        .windowResizability(.contentSize)
    }
}
