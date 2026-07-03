import SwiftUI

/// Aronnax — the iOS companion to the macOS AronnaxIDE. Terminal + Coding only,
/// connecting to kepler over Tailscale via Citadel (pure-Swift SSH), since iOS
/// can't shell out to the system ssh binary the way the Mac app does.
@main
struct AronnaxApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
