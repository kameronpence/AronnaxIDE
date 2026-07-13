import Foundation

/// One markdown note in the vault.
struct VaultNote: Identifiable {
    let path: String          // absolute path on kepler
    let relativePath: String  // path under the vault root, for display
    var id: String { path }
    var name: String { (relativePath as NSString).lastPathComponent }
    var folder: String {
        let f = (relativePath as NSString).deletingLastPathComponent
        return f.isEmpty ? "" : f
    }
}

/// Browses kepler's Obsidian vault over the shared SSH connection: lists markdown notes
/// (recent-first) and fetches a note's raw content on demand. Same data-pane pattern as the
/// others (login shell, marker-guarded errors, generation-token). Read-only for v1.
@MainActor
final class VaultService: ObservableObject {
    enum Phase: Equatable {
        case idle, loading, loaded, empty
        case failed(String)
    }

    @Published private(set) var notes: [VaultNote] = []
    @Published private(set) var phase: Phase = .idle

    private let connection: SSHConnection
    private var loadGeneration = 0

    /// Cap: the vault has thousands of notes; show the most recently-edited ones.
    private let noteLimit = 200
    /// Cap a single note's fetched size so an accidental huge file can't stall the pane.
    private let contentByteLimit = 500_000

    init(connection: SSHConnection) { self.connection = connection }

    /// List notes, most-recently-modified first. BSD `find`+`stat` (kepler is macOS): emits
    /// `<mtime>\t<abspath>` lines. Always exits 0; a real failure emits only __ERR__.
    func loadNotes() async {
        loadGeneration += 1
        let gen = loadGeneration
        phase = .loading
        let root = connection.vaultRoot
        let escRoot = AgentCommands.shellEscaped(root)
        let find = "find \(escRoot) -type f -name '*.md' -not -path '*/.*' "
            + "-not -path '*/node_modules/*' -exec stat -f '%m%t%N' {} +"
        // Capture find's status BEFORE the pipe — otherwise zsh reports head's (always-0) status
        // and a find failure (missing/unreadable vault) would masquerade as an empty vault. On
        // failure we emit ONLY __ERR__ and discard any partial output.
        let inner = "out=$(\(find) 2>/dev/null) || { echo __ERR__; exit 0; }; "
            + "printf '%s\\n' \"$out\" | sort -rn | head -\(noteLimit)"
        let command = "zsh -lc \(AgentCommands.shellEscaped(inner))"
        do {
            let out = try await connection.executeCommand(command)
            guard gen == loadGeneration else { return }
            let text = String(decoding: Data(buffer: out), as: UTF8.self)
            if text.trimmingCharacters(in: .whitespacesAndNewlines) == "__ERR__" {
                phase = .failed("Couldn't read vault"); return
            }
            notes = Self.parse(text, root: root)
            phase = notes.isEmpty ? .empty : .loaded
        } catch is CancellationError {
            guard gen == loadGeneration else { return }
            phase = .failed("Not connected")
        } catch {
            guard gen == loadGeneration else { return }
            phase = .failed("Couldn't read vault")
        }
    }

    /// Fetch one note's raw content (capped). Returns nil on failure.
    func content(for note: VaultNote) async -> String? {
        let inner = "head -c \(contentByteLimit) \(AgentCommands.shellEscaped(note.path)) 2>/dev/null"
        let command = "zsh -lc \(AgentCommands.shellEscaped(inner))"
        guard let out = try? await connection.executeCommand(command) else { return nil }
        return String(decoding: Data(buffer: out), as: UTF8.self)
    }

    static func parse(_ text: String, root: String) -> [VaultNote] {
        let prefix = root.hasSuffix("/") ? root : root + "/"
        return text.split(separator: "\n").compactMap { raw -> VaultNote? in
            let line = String(raw)
            guard let tab = line.firstIndex(of: "\t") else { return nil }
            let path = String(line[line.index(after: tab)...])
            guard !path.isEmpty else { return nil }
            let rel = path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path
            return VaultNote(path: path, relativePath: rel)
        }
    }
}
