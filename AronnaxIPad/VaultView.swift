import SwiftUI

/// A data pane browsing kepler's Obsidian vault: a recent-first list of markdown notes; tap one
/// to read its raw content. Host-level, read-only for v1.
struct VaultView: View {
    @StateObject private var service: VaultService

    init(connection: SSHConnection) {
        _service = StateObject(wrappedValue: VaultService(connection: connection))
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Vault")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { Task { await service.loadNotes() } } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                }
        }
        .task { await service.loadNotes() }
    }

    @ViewBuilder private var content: some View {
        switch service.phase {
        case .idle, .loading:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        case .empty:
            VStack(spacing: 6) {
                Image(systemName: "doc.text").font(.largeTitle).foregroundStyle(.secondary)
                Text("No notes found").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            VStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle").font(.largeTitle).foregroundStyle(.orange)
                Text(message).foregroundStyle(.secondary)
                Button("Retry") { Task { await service.loadNotes() } }.buttonStyle(.bordered)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loaded:
            List(service.notes) { note in
                NavigationLink(value: note) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(note.name).font(.callout).lineLimit(1)
                        if !note.folder.isEmpty {
                            Text(note.folder).font(.caption2).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.head)
                        }
                    }
                }
            }
            .listStyle(.plain)
            .navigationDestination(for: VaultNote.self) { note in
                NoteDetailView(service: service, note: note)
            }
        }
    }
}

/// Loads and shows one note's raw markdown content.
private struct NoteDetailView: View {
    let service: VaultService
    let note: VaultNote
    @State private var content: String?
    @State private var failed = false

    var body: some View {
        Group {
            if failed {
                VStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle").font(.largeTitle).foregroundStyle(.orange)
                    Text("Couldn't open note").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let content {
                ScrollView {
                    Text(content.isEmpty ? "(empty note)" : content)
                        .font(.system(.footnote, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(note.name)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if let c = await service.content(for: note) { content = c } else { failed = true }
        }
    }
}

extension VaultNote: Hashable {
    static func == (lhs: VaultNote, rhs: VaultNote) -> Bool { lhs.path == rhs.path }
    func hash(into hasher: inout Hasher) { hasher.combine(path) }
}
