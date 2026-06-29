import Foundation
import Combine

/// Watches a per-project signal file (`<projectDir>/.miniide-preview`) on the hub so
/// the agents can push something into the Browser pane: when Claude/Codex finish a UI
/// (a dev server or page), they write its URL or port to that file, and the app picks
/// it up and loads it — the Claude-desktop-style "see what I built" preview.
@MainActor
final class PreviewWatcher: ObservableObject {
    /// The latest target the agent wrote — a bare port ("5173") or a URL — or nil.
    @Published private(set) var target: String?

    static let signalFileName = ".miniide-preview"

    private var host: Host?
    private var path: String?
    private var timer: Timer?
    private var lastContent = ""
    private let interval: TimeInterval = 3

    /// Point the watcher at a project's signal file. Re-points (and resets) when the
    /// directory changes; safe to call repeatedly.
    func start(host: Host?, dir: String) {
        self.host = host
        let p = (dir.hasSuffix("/") ? dir : dir + "/") + Self.signalFileName
        if p != path {
            path = p
            lastContent = ""
            target = nil
        }
        guard timer == nil else { return }
        poll()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func poll() {
        guard let host, let path else { return }
        let command = "cat \(SSHManager.shellEscaped(path)) 2>/dev/null"
        Task {
            guard let result = try? await SSHManager.shared.runShell(command, on: host),
                  path == self.path else { return }   // project switched mid-poll — drop
            let content = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            guard content != lastContent else { return }   // unchanged since last poll
            lastContent = content
            target = content.isEmpty ? nil : content
        }
    }
}
