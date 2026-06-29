import Foundation

enum RemoteFSError: Error, LocalizedError {
    case command(String)

    var errorDescription: String? {
        switch self {
        case .command(let why):
            let trimmed = why.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "Remote file operation failed." : trimmed
        }
    }
}

/// File access to a host's vault over the shared SSH connection (`ssh` + `find` /
/// `cat`). Writes are atomic: content is streamed to a temp file in the same
/// directory and then renamed over the target, so an agent reading the file never
/// sees a half-written version.
struct RemoteFS {
    let host: Host

    /// Absolute paths of every `*.md` file under `vaultPath` (excluding the `Projects/`
    /// subtree, which is project code, not vault memory), sorted.
    func listMarkdown(in vaultPath: String) async throws -> [String] {
        // `-prune` skips descending into the Projects subtree entirely (it can hold
        // thousands of code .md files); a plain `-not -path` would still walk it.
        // `-path` matches a glob, so escape any glob metacharacters in the literal
        // directory path (backslash first) or the prune won't match that path.
        let projects = (vaultPath as NSString).appendingPathComponent("Projects")
        let projectsGlob = projects
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "*", with: "\\*")
            .replacingOccurrences(of: "?", with: "\\?")
            .replacingOccurrences(of: "[", with: "\\[")
        let result = try await SSHManager.shared.run(
            ["find", vaultPath, "-path", projectsGlob, "-prune", "-o",
             "-type", "f", "-name", "*.md", "-print"], on: host)
        guard result.ok else { throw RemoteFSError.command(result.stderr) }
        return result.stdout
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
            .sorted()
    }

    /// MD5 of the file's bytes (hex), or nil if it can't be read. Used to detect
    /// remote edits by content rather than mtime — so same-second edits aren't missed
    /// and there's no clock-resolution race. `md5 -q` is macOS; `md5sum` is the Linux
    /// fallback for hosts reached via the hub.
    func contentHash(of path: String) async -> String? {
        let p = SSHManager.shellEscaped(path)
        let cmd = "md5 -q \(p) 2>/dev/null || md5sum \(p) 2>/dev/null | cut -d' ' -f1"
        guard let result = try? await SSHManager.shared.runShell(cmd, on: host),
              result.ok else { return nil }
        let hash = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return hash.isEmpty ? nil : hash
    }

    /// Reads the file at `path`.
    func read(_ path: String) async throws -> String {
        let result = try await SSHManager.shared.run(["cat", path], on: host)
        guard result.ok else { throw RemoteFSError.command(result.stderr) }
        return result.stdout
    }

    /// Atomically writes `content` to `path`: write a sibling temp file, then `mv`
    /// it over the target (a rename within one directory is atomic).
    func write(_ content: String, to path: String) async throws {
        // Unique temp name so concurrent/overlapping saves can't clobber each other.
        let tmp = path + ".miniide-\(UUID().uuidString).tmp"
        let cmd = "cat > \(SSHManager.shellEscaped(tmp))"
            + " && mv -f \(SSHManager.shellEscaped(tmp)) \(SSHManager.shellEscaped(path))"
        let result = try await SSHManager.shared.runShell(cmd, input: content, on: host)
        guard result.ok else { throw RemoteFSError.command(result.stderr) }
    }
}
