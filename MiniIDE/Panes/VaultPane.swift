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
        .onAppear { model.start(host: settings.hub, vault: settings.agentWorkdir) }
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
                    MarkdownPreview(text: model.content)
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
    private var writeChain: Task<String?, Never>?

    /// True when the editor differs from what was last loaded/saved.
    var isDirty: Bool { selected != nil && content != loadedContent }

    func start(host: Host?, vault: String) {
        self.host = host
        self.vault = vault
        guard files.isEmpty else { return }   // don't reload on every re-appear
        refresh()
    }

    func refresh() {
        guard let host else { status = "No hub host configured."; return }
        let vault = self.vault
        Task {
            do {
                let listed = try await RemoteFS(host: host).listMarkdown(in: vault)
                files = listed
                tree = Self.buildTree(from: listed, vault: vault)
                status = nil
            } catch {
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
}

/// A lightweight live markdown preview: headings, bullets, and inline styling.
/// (Wikilinks become clickable in a later task.)
struct MarkdownPreview: View {
    let text: String

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
        (try? AttributedString(
            markdown: s,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(s)
    }
}
