import SwiftUI

/// The Obsidian vault pane: a list of the vault's markdown files on the hub, a
/// markdown editor for the selected note (loaded/saved over SSH via `RemoteFS`),
/// and a live preview. The vault lives on the mini, so edits here land in the same
/// files the agents read.
struct VaultPane: View {
    @EnvironmentObject private var settings: AppSettings
    @StateObject private var model = VaultModel()
    @State private var showPreview = true

    var body: some View {
        HSplitView {
            fileList
                .frame(minWidth: 200, idealWidth: 240, maxWidth: 360)
            editorArea
                .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            Task { await model.switchVault(host: settings.hub, to: settings.activePath) }
        }
        .onChange(of: settings.selectedProjectPath) { oldValue, newValue in
            let target = newValue ?? settings.agentWorkdir
            Task {
                // If the previous note couldn't be saved, the vault stays put — revert
                // the sidebar so the selection and the vault don't diverge. Only revert
                // when this is still the active selection, so a newer switch isn't undone.
                let ok = await model.switchVault(host: settings.hub, to: target)
                if !ok && settings.selectedProjectPath == newValue {
                    settings.selectedProjectPath = oldValue
                }
            }
        }
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
            Divider()
            List(model.tree, children: \.children, selection: Binding(
                get: { model.selected },
                set: { id in
                    // Folder ids are prefixed "dir:"; only file nodes open a note.
                    if let id, !id.hasPrefix("dir:") { model.select(id) }
                }
            )) { node in
                Label(node.name, systemImage: node.filePath != nil ? "doc.text" : "folder")
                    .font(.callout)
                    .lineLimit(1)
                    .tag(node.id)
            }
            .listStyle(.sidebar)
        }
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
                Button("Save") { model.save() }
                    .disabled(!model.isDirty)
                    .keyboardShortcut("s", modifiers: .command)
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            if let status = model.status {
                Text(status).font(.caption).foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8).padding(.bottom, 4)
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
            .disabled(model.isLoading)   // locked briefly while a note loads
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

    private var host: Host?
    private var vault: String = ""
    private var loadedContent: String = ""
    private var selectionToken = 0
    private var vaultSwitchToken = 0
    private var writeChain: Task<String?, Never>?

    /// True when the editor differs from what was last loaded/saved.
    var isDirty: Bool { selected != nil && content != loadedContent }

    /// Points the vault at a new project root. Saves the current note's unsaved edits
    /// first (locking the editor so nothing is typed or lost mid-switch); if that save
    /// fails it stays put and returns `false`, so the caller can keep the sidebar
    /// selection in sync with the vault. Returns `true` on success or a no-op.
    @discardableResult
    func switchVault(host: Host?, to vault: String) async -> Bool {
        self.host = host
        guard self.vault != vault else { return true }   // already here — no-op
        vaultSwitchToken += 1
        let token = vaultSwitchToken
        // Snapshot + lock the editor synchronously so nothing typed between now and
        // the async save below can be lost.
        let dirtyPath = selected
        let dirtyContent = content
        let wasDirty = isDirty
        isLoading = true
        // Save the previous project's unsaved edits first. If the save fails, stay on
        // the current vault so the edits aren't lost.
        if let host, let dirtyPath, wasDirty {
            if let err = await serializedWrite(dirtyContent, to: dirtyPath, host: host) {
                guard token == vaultSwitchToken else { return false }
                status = "Couldn't save \(displayName(dirtyPath)): \(err) — staying on this project."
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
        selectionToken += 1
        let token = selectionToken
        let previous = selected
        let previousContent = content
        let previousDirty = isDirty
        isLoading = true   // lock the editor so edits can't be lost during the switch
        Task {
            // Auto-save the current note's unsaved edits before switching (Obsidian
            // style), serialized with any other save; stay put if it fails.
            if let previous, previousDirty {
                let err = await serializedWrite(previousContent, to: previous, host: host)
                guard token == selectionToken else { return }
                if let err {
                    status = "Couldn't save \(displayName(previous)): \(err) — staying on it."
                    isLoading = false
                    return
                }
                loadedContent = previousContent
            }
            guard token == selectionToken else { return }   // superseded by a newer pick
            do {
                let text = try await RemoteFS(host: host).read(path)
                guard token == selectionToken else { return }
                selected = path
                content = text
                loadedContent = text
                status = nil
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
        guard let host, let path = selected, isDirty else { return }
        let toSave = content
        Task {
            if let err = await serializedWrite(toSave, to: path, host: host) {
                status = "Save failed: \(err)"
            } else {
                if selected == path { loadedContent = toSave }
                status = nil
            }
        }
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
