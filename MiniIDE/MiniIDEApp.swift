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
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)

        Settings {
            SettingsView()
                .environmentObject(settings)
        }
    }
}
