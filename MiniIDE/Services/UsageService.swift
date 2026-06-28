import Foundation
import SwiftUI

/// Parsed usage for one agent: % *used* (normalized) and reset times for the
/// rolling session window and the weekly window.
struct AgentUsage: Equatable {
    var sessionUsedPercent: Int?
    var sessionResets: String?
    var weeklyUsedPercent: Int?
    var weeklyResets: String?

    var hasAny: Bool {
        sessionUsedPercent != nil || weeklyUsedPercent != nil
    }
}

/// Polls Claude/Codex subscription usage by driving a throwaway tmux session on the
/// hub: launch the CLI, clear any startup prompt, run its status view (`/usage` for
/// Claude, `/status` for Codex — never Codex `/usage`, which *consumes* a reset),
/// capture the rendered pane, parse it, and kill the session. Both views are
/// read-only and cost no tokens, so polling is free.
@MainActor
final class UsageService: ObservableObject {
    @Published var claude: AgentUsage?
    @Published var claudeUpdated: Date?
    @Published var codex: AgentUsage?
    @Published var codexUpdated: Date?
    @Published var isRefreshing = false

    private var host: Host?
    private var workdir = ""
    private var started = false
    private var autoTask: Task<Void, Never>?

    func start(host: Host?, workdir: String) {
        guard !started else { return }
        started = true
        self.host = host
        self.workdir = workdir
        refresh()
        autoTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 600_000_000_000)   // 10 min
                if Task.isCancelled { break }
                self?.refresh()
            }
        }
    }

    deinit { autoTask?.cancel() }

    func refresh() {
        guard let host, !isRefreshing else { return }
        isRefreshing = true
        let workdir = self.workdir
        Task {
            async let c = Self.capture(host: host, agent: .claude, workdir: workdir)
            async let x = Self.capture(host: host, agent: .codex, workdir: workdir)
            let (cu, xu) = await (c, x)
            // Per-agent timestamps: a failed probe keeps the other agent's data and
            // only the agent that actually refreshed gets a new "updated" time, so
            // stale data is never shown as freshly updated.
            if let cu { self.claude = cu; self.claudeUpdated = Date() }
            if let xu { self.codex = xu; self.codexUpdated = Date() }
            self.isRefreshing = false
        }
    }

    // MARK: - Capture

    private enum ProbeAgent { case claude, codex }

    private static func capture(host: Host, agent: ProbeAgent, workdir: String) async -> AgentUsage? {
        let (cli, command) = agent == .claude ? ("claude", "/usage") : ("codex", "/status")
        // Unique per probe so concurrent refreshes / multiple windows never kill each
        // other's throwaway session.
        let session = "miniide-usage-\(cli)-\(UUID().uuidString.prefix(8))"
        let cmd = captureCommand(cli: cli, command: command, workdir: workdir,
                                 session: session, repeatCommand: agent == .codex)
        return await withTimeout(seconds: 45) {
            guard let result = try? await SSHManager.shared.runShell(cmd, on: host) else { return nil }
            let text = result.stdout
            guard !text.isEmpty else { return nil }
            let parsed = agent == .claude ? parseClaude(text) : parseCodex(text)
            return parsed.hasAny ? parsed : nil
        }
    }

    /// Runs `op`, returning nil if it doesn't finish within `seconds`, so a hung
    /// probe can't leave the UI stuck refreshing forever.
    private static func withTimeout(seconds: Double,
                                    _ op: @escaping () async -> AgentUsage?) async -> AgentUsage? {
        await withTaskGroup(of: AgentUsage?.self) { group in
            group.addTask { await op() }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    /// The remote shell pipeline that opens the CLI, clears any startup prompt,
    /// runs the status command, and captures the rendered panel.
    private static func captureCommand(cli: String, command: String, workdir: String,
                                       session: String, repeatCommand: Bool) -> String {
        let wd = SSHManager.shellEscaped(workdir)
        // Codex's first /status can show stale limits ("run /status again shortly"),
        // so run it a second time for fresh numbers (shorter wait on the first pass).
        let firstWait = repeatCommand ? 4 : 6
        let secondRun = repeatCommand ? """
        tmux send-keys -t $SES \(command)
        sleep 2
        tmux send-keys -t $SES Enter
        sleep 6
        """ : ""
        return """
        export PATH="$HOME/.local/bin:/opt/homebrew/bin:$PATH"
        cd \(wd) 2>/dev/null || true
        now=$(date +%s)
        tmux ls -F '#{session_name} #{session_created}' 2>/dev/null | while read -r n c; do
          case "$n" in miniide-usage-*) [ $((now - c)) -gt 120 ] && tmux kill-session -t "$n" 2>/dev/null || true ;; esac
        done
        SES=\(session)
        tmux kill-session -t $SES 2>/dev/null || true
        tmux new-session -d -s $SES -x 220 -y 60
        tmux send-keys -t $SES \(cli) Enter
        sleep 10
        tmux send-keys -t $SES Escape
        sleep 1
        tmux send-keys -t $SES \(command)
        sleep 2
        tmux send-keys -t $SES Enter
        sleep \(firstWait)
        \(secondRun)tmux capture-pane -t $SES -p -S -200
        tmux kill-session -t $SES 2>/dev/null || true
        """
    }

    // MARK: - Parsing

    static func parseClaude(_ text: String) -> AgentUsage {
        var u = AgentUsage()
        u.sessionUsedPercent = match(#"Current session.*?(\d+)% used"#, text).flatMap { Int($0) }
        u.sessionResets = match(#"Current session.*?Resets ([^\n]+)"#, text)?
            .trimmingCharacters(in: .whitespaces)
        u.weeklyUsedPercent = match(#"Current week \(all models\).*?(\d+)% used"#, text).flatMap { Int($0) }
        u.weeklyResets = match(#"Current week \(all models\).*?Resets ([^\n]+)"#, text)?
            .trimmingCharacters(in: .whitespaces)
        return u
    }

    static func parseCodex(_ text: String) -> AgentUsage {
        var u = AgentUsage()
        // Codex reports % *left* → normalize to % used. We run /status twice (the first
        // can be stale), so both renders are in the capture — read the LAST one.
        if let left = match(#"5h limit:.*?(\d+)% left"#, text, last: true).flatMap({ Int($0) }) {
            u.sessionUsedPercent = 100 - left
        }
        u.sessionResets = match(#"5h limit:.*?resets ([^)\n]+)"#, text, last: true)?
            .trimmingCharacters(in: .whitespaces)
        if let left = match(#"Weekly limit:.*?(\d+)% left"#, text, last: true).flatMap({ Int($0) }) {
            u.weeklyUsedPercent = 100 - left
        }
        u.weeklyResets = match(#"Weekly limit:.*?resets ([^)\n]+)"#, text, last: true)?
            .trimmingCharacters(in: .whitespaces)
        return u
    }

    private static func match(_ pattern: String, _ text: String, group: Int = 1, last: Bool = false) -> String? {
        guard let re = try? NSRegularExpression(
            pattern: pattern, options: [.dotMatchesLineSeparators, .caseInsensitive]) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        let all = re.matches(in: text, range: range)
        guard let m = (last ? all.last : all.first), m.numberOfRanges > group,
              let r = Range(m.range(at: group), in: text) else { return nil }
        return String(text[r])
    }
}

// MARK: - Sidebar footer

/// Compact usage gauges pinned to the bottom of the sidebar.
struct SidebarUsageFooter: View {
    @ObservedObject var usage: UsageService

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Usage")
                    .font(.headline)
                    .foregroundStyle(.primary)
                Spacer()
                if usage.isRefreshing {
                    ProgressView().controlSize(.small)
                } else {
                    Button { usage.refresh() } label: {
                        Image(systemName: "arrow.clockwise").font(.body)
                    }
                    .buttonStyle(.borderless)
                    .help("Refresh usage")
                }
            }

            agentBlock("Claude", usage.claude, usage.claudeUpdated)
            agentBlock("Codex", usage.codex, usage.codexUpdated)
        }
        .padding(12)
    }

    @ViewBuilder
    private func agentBlock(_ name: String, _ u: AgentUsage?, _ updated: Date?) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(name)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.primary)
                Spacer()
                if let updated {
                    Text(updated.formatted(date: .omitted, time: .shortened))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if let u, u.hasAny {
                gauge("5h", u.sessionUsedPercent, u.sessionResets)
                gauge("Week", u.weeklyUsedPercent, u.weeklyResets)
            } else {
                Text(usage.isRefreshing ? "checking…" : "unavailable")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func gauge(_ label: String, _ usedPercent: Int?, _ resets: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                Spacer()
                Text(usedPercent.map { "\($0)% used" } ?? "—")
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.primary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.25))
                    Capsule()
                        .fill(barColor(usedPercent))
                        .frame(width: max(0, geo.size.width * CGFloat(usedPercent ?? 0) / 100))
                }
            }
            .frame(height: 9)
            if let resets {
                Text("resets \(resets)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private func barColor(_ usedPercent: Int?) -> Color {
        switch usedPercent ?? 0 {
        case ..<70:   return .green
        case 70..<90: return .yellow
        default:      return .red
        }
    }
}
