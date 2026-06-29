import SwiftUI

/// Streams a remote log source on the hub (tail a file, or run a streaming command
/// like `pm2 logs` / `docker logs -f`) into a live, filterable, monospaced view.
struct LogViewer: View {
    @EnvironmentObject private var settings: AppSettings
    @StateObject private var stream = LogStreamController()

    @State private var source: LogSource = .file
    @State private var target = ""
    @State private var filter = ""

    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()
            content
        }
        .onDisappear { stream.stop() }
    }

    private var controls: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Picker("Source", selection: $source) {
                    ForEach(LogSource.allCases) { Text($0.label).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .fixedSize()

                TextField(source.prompt, text: $target)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .onSubmit(startIfPossible)

                if stream.isRunning {
                    Button(role: .destructive) { stream.stop() } label: {
                        Label("Stop", systemImage: "stop.fill")
                    }
                } else {
                    Button(action: startIfPossible) {
                        Label("Start", systemImage: "play.fill")
                    }
                    .disabled(target.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }

            HStack(spacing: 8) {
                Image(systemName: "line.3.horizontal.decrease.circle")
                    .foregroundStyle(.secondary)
                TextField("Filter…", text: $filter)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))

                Button { stream.togglePause() } label: {
                    Label(stream.isPaused ? "Resume" : "Pause",
                          systemImage: stream.isPaused ? "play.fill" : "pause.fill")
                }
                // Still allow Resume when paused after the stream ended, to flush held lines.
                .disabled(!stream.isRunning && !stream.isPaused)

                Button { stream.clear() } label: { Label("Clear", systemImage: "trash") }
                    .disabled(stream.isEmpty)

                Text("\(filteredLines.count) lines")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(minWidth: 70, alignment: .trailing)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    @ViewBuilder private var content: some View {
        if stream.isEmpty {
            if let status = stream.status {
                message(status, system: "exclamationmark.triangle")
            } else {
                message(stream.isRunning ? "Waiting for output…"
                                         : "Pick a source and press Start to stream logs from \(settings.hub?.displayName ?? "the hub").",
                        system: "list.bullet.rectangle")
            }
        } else {
            VStack(spacing: 0) {
                if let status = stream.status {
                    statusBanner(status)   // surface a dead/ended stream even with stale output above
                    Divider()
                }
                logList
            }
        }
    }

    private func statusBanner(_ text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(text).font(.callout)
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.orange.opacity(0.12))
    }

    private var logList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(filteredLines) { line in
                        Text(line.text.isEmpty ? " " : line.text)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(line.isError ? Color.red : Color.primary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 1)
                            .id(line.id)
                    }
                    Color.clear.frame(height: 1).id(bottomID)
                }
            }
            .onChange(of: stream.lines.last?.id) { _, _ in
                // Track the newest line's id, not the count — once the buffer caps,
                // count stays flat while new lines keep arriving. Frozen while paused.
                guard !stream.isPaused else { return }
                withAnimation(.none) { proxy.scrollTo(bottomID, anchor: .bottom) }
            }
        }
    }

    private let bottomID = "log-bottom"

    /// Client-side, case-insensitive substring filter.
    private var filteredLines: [LogStreamController.LogLine] {
        let needle = filter.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return stream.lines }
        return stream.lines.filter { $0.text.range(of: needle, options: .caseInsensitive) != nil }
    }

    private func startIfPossible() {
        guard !target.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        stream.start(host: settings.hub, source: source, target: target)
    }

    private func message(_ text: String, system: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: system)
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(.secondary)
            Text(text)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}
