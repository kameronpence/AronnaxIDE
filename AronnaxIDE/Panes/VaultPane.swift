import SwiftUI
import CryptoKit

/// The Obsidian vault pane: a list of the vault's markdown files on the hub, a
/// markdown editor for the selected note (loaded/saved over SSH via `RemoteFS`),
/// and a live preview. The vault lives on the mini, so edits here land in the same
/// files the agents read.
struct VaultPane: View {
    @EnvironmentObject private var settings: AppSettings
    @StateObject private var model = VaultModel()
    @State private var showPreview = true
    @State private var search = ""
    @State private var pendingWrite: WriteRequest?

    private var hubReadOnly: Bool { settings.isReadOnly(settings.activeHost) }
    private func requestWrite(_ title: String, _ perform: @escaping () -> Void) {
        if settings.confirmWrites { pendingWrite = WriteRequest(title: title, perform: perform) }
        else { perform() }
    }

    /// Files whose name matches the search box (used to show a flat list while searching).
    private var matchingFiles: [String] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return [] }
        return model.files.filter { ($0 as NSString).lastPathComponent.lowercased().contains(q) }
    }

    var body: some View {
        HSplitView {
            fileList
                .frame(minWidth: 200, idealWidth: 240, maxWidth: 360)
            editorArea
                .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            // The Vault shows the active host's vault clone — the CTX/notes plus each
            // project's docs. On a server it's that box's GitHub-synced clone (what the
            // agent there uses as memory); on the hub it's the canonical vault.
            model.readOnly = hubReadOnly
            model.confirmWrites = settings.confirmWrites
            Task { await model.switchVault(host: settings.activeHost, to: settings.activeVaultPath) }
            model.startWatching()
        }
        .onDisappear { model.stopWatching() }
        .onChange(of: settings.activeVaultPath) { _, new in
            // Active host (or its vault path) changed — re-root the Vault at the new
            // host's clone. If unsaved edits block the switch, the model stays put and
            // its status tells the user to save first.
            Task { _ = await model.switchVault(host: settings.activeHost, to: new) }
        }
        .onChange(of: hubReadOnly) { _, ro in model.readOnly = ro }
        .onChange(of: settings.confirmWrites) { _, c in model.confirmWrites = c }
        .writeConfirm($pendingWrite)
    }

    private var fileList: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Vault").font(.headline)
                Spacer()
                Button { model.refresh() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .help("Reload file list")
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            TextField("Search notes", text: $search)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 8).padding(.bottom, 6)
            Divider()
            if search.trimmingCharacters(in: .whitespaces).isEmpty {
                List(model.tree, children: \.children, selection: Binding(
                    get: { model.selected },
                    set: { id in
                        // Folder ids are prefixed "dir:"; only file nodes open a note.
                        if let id, !id.hasPrefix("dir:") { model.select(id) }
                    }
                )) { node in
                    Label(node.name, systemImage: node.filePath != nil ? "doc.text" : "folder")
                        .font(.body)
                        .lineLimit(1)
                        .tag(node.id)
                }
                .listStyle(.sidebar)
            } else if matchingFiles.isEmpty {
                Text("No notes match “\(search)”")
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(matchingFiles, id: \.self, selection: Binding(
                    get: { model.selected },
                    set: { if let p = $0 { model.select(p) } }
                )) { path in
                    Label(displayName(path), systemImage: "doc.text")
                        .font(.body)
                        .lineLimit(1)
                        .tag(path)
                }
                .listStyle(.sidebar)
            }
        }
    }

    /// The note's path relative to the vault, for the search results.
    private func displayName(_ path: String) -> String {
        model.displayName(path)
    }

    private var editorArea: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(model.selected.map(model.displayName) ?? "No note selected")
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                if model.isDirty { Text("• edited").font(.caption).foregroundStyle(.orange) }
                Spacer()
                Toggle("Preview", isOn: $showPreview)
                    .toggleStyle(.button)
                    .controlSize(.small)
                if hubReadOnly {
                    Label("read-only", systemImage: "lock.fill")
                        .font(.callout).foregroundStyle(.orange)
                }
                Button("Save") { requestWrite("Save this note?") { model.save() } }
                    .disabled(!model.isDirty || model.externalChange || hubReadOnly)
                    .keyboardShortcut("s", modifiers: .command)
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            if let status = model.status {
                Text(status).font(.caption).foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8).padding(.bottom, 4)
            }
            if model.externalChange {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text("An agent changed this note on the hub, and you have unsaved edits.")
                        .font(.caption)
                    Spacer()
                    Button("Reload") { model.reloadExternal() }
                    // Overwriting the agent's version is a write — gate it like Save.
                    Button("Keep mine") {
                        requestWrite("Overwrite the agent's version with yours?") { model.keepMine() }
                    }
                    .disabled(hubReadOnly)
                }
                .controlSize(.small)
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(Color.orange.opacity(0.12))
            }
            Divider()

            if model.selected == nil {
                ContentUnavailableView("Select a note", systemImage: "doc.text")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if showPreview {
                HSplitView {
                    editor
                    MarkdownPreview(text: model.content) { name in
                        model.openWikilink(name)
                    }
                    .frame(minWidth: 280, maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                editor
            }
        }
    }

    private var editor: some View {
        TextEditor(text: $model.content)
            .font(.system(.body, design: .monospaced))
            .disabled(model.isLoading || hubReadOnly)   // locked while loading, or host read-only
            .frame(minWidth: 280, maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A node in the vault file tree: a folder (has `children`) or a markdown file
/// (has `filePath`). `id` is the file path for files, `"dir:<rel path>"` for folders.
struct VaultNode: Identifiable {
    let id: String
    let name: String
    let filePath: String?
    let children: [VaultNode]?
}

/// Loads/saves vault notes over `RemoteFS` and tracks the dirty state.
@MainActor
final class VaultModel: ObservableObject {
    @Published var files: [String] = []
    @Published var tree: [VaultNode] = []
    @Published var selected: String?
    @Published var content: String = ""
    @Published var status: String?
    @Published var isLoading = false
    /// Set when the open note changed on the hub (an agent edited it) while the
    /// editor has unsaved local edits — a conflict the user must resolve.
    @Published private(set) var externalChange = false

    private var host: Host?
    private var vault: String = ""
    private var loadedContent: String = ""
    private var loadedHash: String?          // MD5 of the open note as last loaded/saved
    private var pendingSave: Task<Void, Never>?   // serializes back-to-back saves
    /// Host is read-only: never write; on switch, abandon any (edge-case) dirty edits.
    var readOnly = false
    /// "Confirm every write" is on: block a switch while there are unsaved edits so the
    /// user saves explicitly (guarded) rather than the silent autosave bypassing it.
    var confirmWrites = false
    private var selectionToken = 0
    private var vaultSwitchToken = 0
    private var writeChain: Task<String?, Never>?
    private var watchTimer: Timer?
    private var watchPolls = 0
    private let watchInterval: TimeInterval = 5

    /// True when the editor differs from what was last loaded/saved.
    var isDirty: Bool { selected != nil && content != loadedContent }

    /// Re-points the vault at a new root (the user changed the workdir in Settings).
    /// Preserves the open note's unsaved edits: it saves them first, and if it can't
    /// (a pending conflict, a save failure, or a write guard) it stays put and returns
    /// `false` so the caller can revert the workdir setting — no edits lost, no stale root.
    @discardableResult
    func switchVault(host: Host?, to vault: String) async -> Bool {
        self.host = host
        guard self.vault != vault else { return true }   // already here — no-op
        guard !externalChange else {
            status = "Resolve this note's conflict first — Reload or Keep mine."
            return false
        }
        vaultSwitchToken += 1
        let token = vaultSwitchToken
        // Snapshot + lock the editor synchronously so nothing typed between now and
        // the async save below can be lost.
        let dirtyPath = selected
        let dirtyContent = content
        let wasDirty = isDirty
        let dirtyHash = loadedHash
        isLoading = true
        // Under a write guard, don't silently autosave or discard — block so the caller
        // reverts the workdir (nothing diverges, no edits lost). The user saves under
        // confirm-writes, or disables read-only, before changing the workdir.
        if let dirtyPath, wasDirty, confirmWrites || readOnly {
            status = readOnly
                ? "Host is read-only — can't save \(displayName(dirtyPath)). Disable read-only before changing the workdir."
                : "Unsaved edits in \(displayName(dirtyPath)) — Save (⌘S) before changing the workdir."
            isLoading = false
            return false
        }
        // Save the open note before re-rooting; on conflict/failure stay put (caller reverts).
        if let host, let dirtyPath, wasDirty {
            let outcome = await conflictAwareWrite(dirtyContent, to: dirtyPath,
                                                   baseline: dirtyHash, host: host)
            guard token == vaultSwitchToken else { return false }
            switch outcome {
            case .written:
                break
            case .conflict:
                externalChange = true
                isLoading = false
                return false
            case .failed(let e):
                status = "Couldn't save \(displayName(dirtyPath)): \(e) — staying."
                isLoading = false
                return false
            }
        }
        guard token == vaultSwitchToken else { return false }   // superseded by a newer switch
        self.vault = vault
        // Reset for the new project's vault.
        selectionToken += 1   // invalidate any in-flight note load from the old vault
        selected = nil
        content = ""
        loadedContent = ""
        loadedHash = nil
        externalChange = false
        files = []
        tree = []
        isLoading = false
        refresh()
        return true
    }

    func refresh() {
        guard let host else { status = "No hub host configured."; return }
        let vault = self.vault
        Task {
            do {
                let listed = try await RemoteFS(host: host).listMarkdown(in: vault)
                guard vault == self.vault else { return }   // project switched — drop stale
                files = listed
                tree = Self.buildTree(from: listed, vault: vault)
                status = nil
            } catch {
                guard vault == self.vault else { return }
                status = "Couldn't list vault: \(error.localizedDescription)"
            }
        }
    }

    /// Builds a folder/file tree from the flat list of absolute file paths.
    private static func buildTree(from files: [String], vault: String) -> [VaultNode] {
        let prefix = vault.hasSuffix("/") ? vault : vault + "/"

        final class Builder {
            var children: [String: Builder] = [:]
            var filePath: String?
        }
        let root = Builder()
        for file in files {
            let rel = file.hasPrefix(prefix) ? String(file.dropFirst(prefix.count)) : file
            let parts = rel.split(separator: "/").map(String.init)
            guard !parts.isEmpty else { continue }
            var node = root
            for (i, part) in parts.enumerated() {
                let child = node.children[part] ?? Builder()
                node.children[part] = child
                if i == parts.count - 1 { child.filePath = file }
                node = child
            }
        }

        func convert(name: String, builder: Builder, relPath: String) -> VaultNode {
            if let path = builder.filePath, builder.children.isEmpty {
                return VaultNode(id: path, name: name, filePath: path, children: nil)
            }
            let kids = builder.children
                .map { convert(name: $0.key, builder: $0.value, relPath: relPath + "/" + $0.key) }
                .sorted(by: nodeOrder)
            return VaultNode(id: "dir:" + relPath, name: name, filePath: nil, children: kids)
        }
        return root.children
            .map { convert(name: $0.key, builder: $0.value, relPath: $0.key) }
            .sorted(by: nodeOrder)
    }

    /// Folders before files, alphabetical within each.
    private static func nodeOrder(_ lhs: VaultNode, _ rhs: VaultNode) -> Bool {
        let lFolder = lhs.children != nil, rFolder = rhs.children != nil
        if lFolder != rFolder { return lFolder }
        return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
    }

    func select(_ path: String) {
        guard let host, path != selected else { return }
        // A pending conflict must be resolved (Reload / Keep mine) before leaving the
        // note — otherwise navigating would either lose the local edits or clobber the
        // agent's version. Blocking keeps both intact until the user chooses.
        guard !externalChange else {
            status = "Resolve this note's conflict first — Reload or Keep mine."
            return
        }
        selectionToken += 1
        let token = selectionToken
        let previous = selected
        let previousContent = content
        let previousDirty = isDirty
        let previousHash = loadedHash
        isLoading = true   // lock the editor so edits can't be lost during the switch
        Task {
            // Write guards take precedence over the autosave so nothing is written
            // unconfirmed and no edits are silently lost. Block the switch and keep the
            // user on the note: under confirm-writes they save explicitly; under
            // read-only they can't save here, so they disable it (or discard) first.
            if let previous, previousDirty, confirmWrites || readOnly {
                status = readOnly
                    ? "Host is read-only — can't save \(displayName(previous)). Disable read-only to save before switching."
                    : "Unsaved edits in \(displayName(previous)) — Save (⌘S) before switching."
                isLoading = false
                return
            }
            // Auto-save the current note's unsaved edits before switching (Obsidian
            // style); stay put if it fails, and surface a conflict instead of clobbering
            // an agent edit that landed since the last poll.
            if let previous, previousDirty {
                let outcome = await conflictAwareWrite(previousContent, to: previous,
                                                       baseline: previousHash, host: host)
                guard token == selectionToken else { return }
                switch outcome {
                case .written:
                    break
                case .conflict:
                    externalChange = true
                    isLoading = false
                    return
                case .failed(let e):
                    status = "Couldn't save \(displayName(previous)): \(e) — staying on it."
                    isLoading = false
                    return
                }
            }
            guard token == selectionToken else { return }   // superseded by a newer pick
            do {
                let text = try await RemoteFS(host: host).read(path)
                guard token == selectionToken else { return }
                selected = path
                content = text
                loadedContent = text
                status = nil
                externalChange = false
                loadedHash = Self.md5Hex(text)
            } catch {
                guard token == selectionToken else { return }
                // Leave the user on the previous note rather than showing its content
                // under the failed note's name.
                status = "Couldn't open \(displayName(path)): \(error.localizedDescription)"
            }
            if token == selectionToken { isLoading = false }
        }
    }

    func save() {
        // While a conflict is pending, resolution must go through the banner
        // (Reload / Keep mine) so the remote version isn't silently overwritten.
        guard let host, let path = selected, isDirty, !externalChange else { return }
        let toSave = content
        let prior = pendingSave
        pendingSave = Task { [weak self] in
            // Wait for any in-flight save to finish so this one reads a fresh baseline —
            // otherwise our own prior write looks like an external conflict.
            await prior?.value
            guard let self, self.selected == path else { return }
            let baseline = self.loadedHash
            let outcome = await self.conflictAwareWrite(toSave, to: path, baseline: baseline, host: host)
            guard self.selected == path else { return }
            switch outcome {
            case .written:       self.externalChange = false; self.status = nil
            case .conflict:      self.externalChange = true   // an agent edited it since the last poll
            case .failed(let e): self.status = "Save failed: \(e)"
            }
        }
    }

    /// Writes `text` and, on success, makes it the new baseline (content + hash).
    /// Returns an error message on failure, leaving conflict/dirty state to the caller.
    private func performWrite(_ text: String, to path: String, host: Host) async -> String? {
        let err = await serializedWrite(text, to: path, host: host)
        if err == nil, selected == path {
            loadedContent = text
            loadedHash = Self.md5Hex(text)
        }
        return err
    }

    private enum WriteOutcome { case written, conflict, failed(String) }

    /// Writes `text` only if the remote still matches `baseline` (no agent edit since
    /// load); otherwise reports `.conflict` so the caller surfaces it instead of
    /// clobbering. A successful write refreshes the baseline.
    private func conflictAwareWrite(_ text: String, to path: String,
                                    baseline: String?, host: Host) async -> WriteOutcome {
        let remote = await RemoteFS(host: host).contentHash(of: path)
        if let remote, remote != baseline { return .conflict }
        if let err = await performWrite(text, to: path, host: host) { return .failed(err) }
        return .written
    }

    // MARK: - RemoteWatcher (detect agent edits to the shared vault)

    /// Begin polling the open note's mtime (and periodically re-listing the vault) so
    /// edits the agents make to the same files show up without a manual refresh.
    func startWatching() {
        guard watchTimer == nil else { return }
        watchTimer = Timer.scheduledTimer(withTimeInterval: watchInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
    }

    func stopWatching() {
        watchTimer?.invalidate()
        watchTimer = nil
    }

    private func poll() {
        guard let host else { return }
        // Re-list every ~4th poll so notes the agents create appear in the tree
        // (selection is by path, so a rebuild keeps the open note selected).
        watchPolls += 1
        if watchPolls % 4 == 0 { refresh() }

        guard let path = selected, loadedHash != nil, !isLoading else { return }
        let selToken = selectionToken
        Task {
            guard let remote = await RemoteFS(host: host).contentHash(of: path),
                  selToken == selectionToken,   // a selection started meanwhile — let it win
                  selected == path,
                  let baseline = loadedHash,    // re-read the current baseline (a save/reload may have moved it)
                  remote != baseline else { return }
            if isDirty {
                externalChange = true            // conflict — let the user choose
            } else {
                reloadCurrent(expectedPath: path, force: false)  // no local edits — show theirs
            }
        }
    }

    /// Re-read the open note from the hub (an agent changed it). Used both for the
    /// no-edits auto-refresh and the conflict banner's "Reload (use theirs)".
    private func reloadCurrent(expectedPath: String, force: Bool) {
        guard let host, selected == expectedPath else { return }
        selectionToken += 1
        let token = selectionToken
        isLoading = true   // lock the editor so nothing typed during the read is lost
        Task {
            defer { if token == selectionToken { isLoading = false } }
            guard let text = try? await RemoteFS(host: host).read(expectedPath),
                  token == selectionToken, selected == expectedPath else { return }
            // The user may have started typing before the lock — don't clobber their
            // edits unless this is an explicit "use theirs".
            if !force && isDirty {
                externalChange = true
                return
            }
            content = text
            loadedContent = text
            loadedHash = Self.md5Hex(text)
            externalChange = false
        }
    }

    /// Conflict banner — "Reload": take the hub version, dropping local edits. The
    /// conflict flag is cleared by reloadCurrent only once the read succeeds, so a
    /// failed reload leaves the banner up.
    func reloadExternal() {
        guard let path = selected else { return }
        reloadCurrent(expectedPath: path, force: true)
    }

    /// Conflict banner — "Keep mine": write the local edits over the agent's version.
    /// The conflict is cleared only once the write lands (a failed write keeps it up).
    func keepMine() {
        guard let host, let path = selected, isDirty else { externalChange = false; return }
        let toSave = content
        Task {
            if let err = await performWrite(toSave, to: path, host: host) {
                status = "Save failed: \(err)"   // keep the conflict banner up
            } else if selected == path {
                externalChange = false           // resolved only after the write lands
                status = nil
            }
        }
    }

    private static func md5Hex(_ s: String) -> String {
        Insecure.MD5.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Writes serialized behind any in-flight write so two saves never race on the
    /// same file (the latest enqueued content wins). Returns nil on success, or an
    /// error message.
    private func serializedWrite(_ content: String, to path: String, host: Host) async -> String? {
        let previous = writeChain
        let task = Task<String?, Never> {
            _ = await previous?.value
            do {
                try await RemoteFS(host: host).write(content, to: path)
                return nil
            } catch {
                return error.localizedDescription
            }
        }
        writeChain = task
        return await task.value
    }

    /// The note's path relative to the vault, for display.
    func displayName(_ path: String) -> String {
        let prefix = vault.hasSuffix("/") ? vault : vault + "/"
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path
    }

    /// Opens the note a `[[wikilink]]` points at by matching its base filename
    /// (case-insensitive, `.md` optional) against the vault's files.
    func openWikilink(_ name: String) {
        let clean = name.trimmingCharacters(in: .whitespaces)
        let key = (clean.lowercased().hasSuffix(".md") ? String(clean.dropLast(3)) : clean).lowercased()
        guard !key.isEmpty else { return }
        let match = files.first { path in
            let fn = (path as NSString).lastPathComponent.lowercased()
            let base = fn.hasSuffix(".md") ? String(fn.dropLast(3)) : fn
            return base == key
        }
        if let match {
            select(match)
        } else {
            status = "No note named “\(clean)” in this vault."
        }
    }
}

/// A lightweight live markdown preview: headings, bullets, inline styling, and
/// clickable Obsidian `[[wikilinks]]`.
struct MarkdownPreview: View {
    let text: String
    var onOpenWikilink: ((String) -> Void)? = nil

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(text.split(separator: "\n", omittingEmptySubsequences: false).enumerated()),
                        id: \.offset) { _, raw in
                    line(String(raw))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .textSelection(.enabled)
        }
        .environment(\.openURL, OpenURLAction { url in
            guard url.scheme == "wikilink" else { return .systemAction }
            onOpenWikilink?(url.lastPathComponent)   // already percent-decoded
            return .handled
        })
    }

    @ViewBuilder
    private func line(_ s: String) -> some View {
        if s.hasPrefix("# ") {
            Text(inline(String(s.dropFirst(2)))).font(.title).bold()
        } else if s.hasPrefix("## ") {
            Text(inline(String(s.dropFirst(3)))).font(.title2).bold()
        } else if s.hasPrefix("### ") {
            Text(inline(String(s.dropFirst(4)))).font(.title3).bold()
        } else if s.hasPrefix("- ") || s.hasPrefix("* ") {
            HStack(alignment: .top, spacing: 6) {
                Text("•")
                Text(inline(String(s.dropFirst(2))))
            }
        } else if s.trimmingCharacters(in: .whitespaces).isEmpty {
            Text(" ")
        } else {
            Text(inline(s))
        }
    }

    private func inline(_ s: String) -> AttributedString {
        let linked = Self.linkifyWikilinks(s)
        return (try? AttributedString(
            markdown: linked,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(s)
    }

    /// Rewrites Obsidian `[[Note Name]]` (and `[[Note|alias]]` / `[[Note#heading]]`)
    /// into a tappable markdown link with a `wikilink://` scheme, so the preview can
    /// open the target note. The link target ignores any alias/heading.
    static func linkifyWikilinks(_ s: String) -> String {
        guard s.contains("[["),
              let re = try? NSRegularExpression(pattern: #"\[\[([^\]\[]+)\]\]"#) else { return s }
        let full = NSRange(s.startIndex..., in: s)
        var out = ""
        var cursor = s.startIndex
        re.enumerateMatches(in: s, range: full) { match, _, _ in
            guard let match,
                  let mr = Range(match.range, in: s),
                  let nr = Range(match.range(at: 1), in: s) else { return }
            out += s[cursor..<mr.lowerBound]
            let inner = String(s[nr])
            let target = inner.split(whereSeparator: { $0 == "|" || $0 == "#" })
                .first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? inner
            let display = inner.contains("|")
                ? String(inner.split(separator: "|").last ?? Substring(target))
                : target
            let encoded = target.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? target
            out += "[\(display)](wikilink://open/\(encoded))"
            cursor = mr.upperBound
        }
        out += s[cursor...]
        return out
    }
}
