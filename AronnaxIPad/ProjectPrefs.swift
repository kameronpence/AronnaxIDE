import Foundation
import SwiftUI

/// Persisted sidebar preferences — currently which projects the user has hidden. Mirrors the
/// macOS app's hide/show behavior; hidden projects drop out of the list until revealed. Keyed by
/// project name (the sidebar's identifier); "kepler root" can never be hidden.
@MainActor
final class ProjectPrefs: ObservableObject {
    @Published private(set) var hidden: Set<String> = []

    private static let key = "ipad.hiddenProjects"

    init() {
        if let names = UserDefaults.standard.array(forKey: Self.key) as? [String] {
            hidden = Set(names)
        }
    }

    func isHidden(_ project: String) -> Bool { hidden.contains(project) }

    func setHidden(_ project: String, _ value: Bool) {
        // The machine root is always visible — it's the default target, not a real project.
        guard project != SSHConnection.keplerRootLabel else { return }
        if value { hidden.insert(project) } else { hidden.remove(project) }
        UserDefaults.standard.set(Array(hidden), forKey: Self.key)
    }
}
