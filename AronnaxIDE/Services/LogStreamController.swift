import Foundation
import Combine

/// Streams a long-lived remote command (a `tail -F`, `pm2 logs`, `docker logs -f`,
/// `log stream`, …) over SSH and exposes its output line-by-line for the Logs pane.
///
/// Reads happen on a background readability handler; lines are parsed on a serial
/// queue (so chunks stay in order) and the parsed lines are appended on the main
/// thread, where the `@Published` buffer drives SwiftUI. The buffer is capped so a
/// chatty source can't grow memory without bound.
final class LogStreamController: ObservableObject {
    struct LogLine: Identifiable {
        let id: Int
        let text: String
        let isError: Bool
    }

    @Published private(set) var lines: [LogLine] = []
    @Published private(set) var isRunning = false
    @Published private(set) var status: String?
    /// While paused, incoming lines are held (not shown) so the visible scrollback
    /// stays put for inspection and isn't dropped by the line cap. Resume flushes them.
    @Published private(set) var isPaused = false
    private var pending: [LogLine] = []   // held while paused (main thread)

    private let maxLines = 5000
    private let parseQueue = DispatchQueue(label: "com.kameronpence.AronnaxIDE.logstream")

    private var process: Process?
    private var outHandle: FileHandle?
    private var errHandle: FileHandle?
    private var outResidual = Data()   // parseQueue only
    private var errResidual = Data()   // parseQueue only
    private var nextID = 0
    private var generation = 0              // bumped on every start/stop (main thread)
    private var parseActiveGeneration = -1  // parseQueue only

    var isEmpty: Bool { lines.isEmpty }

    /// Builds the remote command for a source and starts streaming it on `host`.
    func start(host: Host?, source: LogSource, target: String) {
        guard let host else { status = "No host configured."; return }
        let trimmed = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            status = source == .file ? "Enter a file path to tail." : "Enter a command to run."
            return
        }
        let command: String
        switch source {
        case .file:    command = "tail -n 200 -F \(SSHManager.shellEscaped(trimmed))"
        case .command: command = trimmed
        }
        startRaw(host: host, command: command)
    }

    private func startRaw(host: Host, command: String) {
        stop()                       // tear down any prior stream (bumps generation)
        let gen = generation
        lines.removeAll()
        pending.removeAll()
        nextID = 0
        status = nil
        isPaused = false

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: SSHManager.shared.sshExecutable)
        proc.arguments = SSHManager.shared.streamArguments(for: host, running: command)

        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self else { return }
            if data.isEmpty {   // EOF — stop reading and flush this pipe's final fragment
                handle.readabilityHandler = nil
                self.parseQueue.async { self.flushResidual(isError: false, generation: gen) }
                return
            }
            self.parseQueue.async { self.parse(data, isError: false, generation: gen) }
        }
        errPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self else { return }
            if data.isEmpty {
                handle.readabilityHandler = nil
                self.parseQueue.async { self.flushResidual(isError: true, generation: gen) }
                return
            }
            self.parseQueue.async { self.parse(data, isError: true, generation: gen) }
        }
        proc.terminationHandler = { [weak self] p in
            let code = p.terminationStatus
            DispatchQueue.main.async { self?.handleTermination(code: code, generation: gen) }
        }

        do {
            try proc.run()
            process = proc
            outHandle = outPipe.fileHandleForReading
            errHandle = errPipe.fileHandleForReading
            isRunning = true
        } catch {
            status = "Couldn't start stream: \(error.localizedDescription)"
        }
    }

    func stop() {
        generation &+= 1   // invalidate any callbacks queued from the prior stream
        outHandle?.readabilityHandler = nil
        errHandle?.readabilityHandler = nil
        process?.terminationHandler = nil
        if process?.isRunning == true { process?.terminate() }
        process = nil
        outHandle = nil
        errHandle = nil
        isRunning = false
    }

    func clear() {
        lines.removeAll()
        pending.removeAll()
    }

    /// Pause holds incoming lines; resume flushes everything held since.
    func togglePause() {
        if isPaused {
            isPaused = false
            guard !pending.isEmpty else { return }
            lines.append(contentsOf: pending)
            pending.removeAll()
            if lines.count > maxLines { lines.removeFirst(lines.count - maxLines) }
        } else {
            isPaused = true
        }
    }

    // MARK: - Parsing (parseQueue)

    private func parse(_ data: Data, isError: Bool, generation: Int) {
        // The two pipes' readability handlers run on separate queues, so a stale
        // chunk can land here after a newer stream started. Generation is monotonic:
        // ignore anything older, and reset buffers only when a newer stream begins.
        if generation < parseActiveGeneration { return }
        if generation > parseActiveGeneration {
            parseActiveGeneration = generation
            outResidual.removeAll()
            errResidual.removeAll()
        }
        if isError { errResidual.append(data) } else { outResidual.append(data) }

        var emitted: [String] = []
        let extract: () -> Void = {
            while true {
                let buffer = isError ? self.errResidual : self.outResidual
                guard let nl = buffer.firstIndex(of: 0x0A) else { break }
                let lineData = buffer.subdata(in: buffer.startIndex..<nl)
                let text = String(decoding: lineData, as: UTF8.self)
                    .replacingOccurrences(of: "\r", with: "")
                emitted.append(text)
                if isError {
                    self.errResidual.removeSubrange(self.errResidual.startIndex...nl)
                } else {
                    self.outResidual.removeSubrange(self.outResidual.startIndex...nl)
                }
            }
        }
        extract()

        guard !emitted.isEmpty else { return }
        DispatchQueue.main.async {
            guard generation == self.generation else { return }   // superseded stream — drop
            for text in emitted { self.append(text, isError: isError) }
        }
    }

    // MARK: - Buffer (main thread)

    private func append(_ text: String, isError: Bool) {
        let line = LogLine(id: nextID, text: text, isError: isError)
        nextID += 1
        if isPaused {
            pending.append(line)
            if pending.count > maxLines { pending.removeFirst(pending.count - maxLines) }
        } else {
            lines.append(line)
            if lines.count > maxLines { lines.removeFirst(lines.count - maxLines) }
        }
    }

    private func handleTermination(code: Int32, generation: Int) {
        guard generation == self.generation else { return }   // superseded stream — ignore
        isRunning = false
        // SIGTERM (15) is us calling stop(); a clean tail/stream doesn't normally end.
        if code != 0 && code != 15 {
            status = "Stream ended (exit \(code)). Press Start to reconnect."
        }
    }

    /// Emit a pipe's leftover bytes (a final line with no trailing newline) at EOF so
    /// the last log line isn't dropped. Runs on parseQueue, enqueued after that pipe's
    /// data, and honors pause via `append` so held output flushes on resume.
    private func flushResidual(isError: Bool, generation: Int) {
        guard generation == parseActiveGeneration else { return }
        let residual = isError ? errResidual : outResidual
        guard !residual.isEmpty else { return }
        let text = String(decoding: residual, as: UTF8.self).replacingOccurrences(of: "\r", with: "")
        if isError { errResidual.removeAll() } else { outResidual.removeAll() }
        guard !text.isEmpty else { return }
        DispatchQueue.main.async {
            guard generation == self.generation else { return }
            self.append(text, isError: isError)
        }
    }
}

/// Where a log line comes from.
enum LogSource: String, CaseIterable, Identifiable {
    case file
    case command

    var id: String { rawValue }
    var label: String {
        switch self {
        case .file:    return "Tail file"
        case .command: return "Command"
        }
    }
    var prompt: String {
        switch self {
        case .file:    return "/var/log/… or a project log path"
        case .command: return "pm2 logs · docker logs -f web · log stream"
        }
    }
}
