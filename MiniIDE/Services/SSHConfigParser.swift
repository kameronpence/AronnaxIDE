import Foundation

/// Minimal parser for `~/.ssh/config` — enough to discover hosts the app can
/// connect to (alias, HostName, User, ProxyJump). It intentionally ignores
/// wildcard patterns, `Match` blocks, and `Include` directives; explicit per-host
/// blocks cover the fleet (kepler, EC2, Lightsail). Unknown keywords are skipped.
///
/// Keywords are case-insensitive and accept both `Key value` and `Key=value`.
enum SSHConfigParser {

    /// Parses ssh-config `text` into hosts. The host whose alias matches
    /// `hubAlias` (case-insensitively) is flagged `isHub`.
    static func parse(_ text: String, hubAlias: String) -> [Host] {
        var hosts: [Host] = []
        var current: [Builder] = []

        func flush() {
            for builder in current {
                hosts.append(builder.build(hubAlias: hubAlias))
            }
            current = []
        }

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard let (key, value) = keyValue(line) else { continue }

            switch key.lowercased() {
            case "host":
                flush()
                // A `Host` directive can list several aliases; each concrete
                // (non-wildcard) one is a connectable host sharing this block.
                current = value.split(whereSeparator: { $0 == " " || $0 == "\t" })
                    .map(String.init)
                    .filter { !$0.contains("*") && !$0.contains("?") }
                    .map { Builder(alias: $0) }
            case "match":
                flush()                      // Match blocks aren't modeled
            case "hostname":  for i in current.indices { current[i].hostName = value }
            case "user":      for i in current.indices { current[i].user = value }
            case "proxyjump": for i in current.indices { current[i].proxyJump = value }
            default: break
            }
        }
        flush()
        return hosts
    }

    /// Loads and parses `~/.ssh/config`; returns `[]` if it can't be read.
    static func loadHosts(hubAlias: String,
                          path: String = NSHomeDirectory() + "/.ssh/config") -> [Host] {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        return parse(text, hubAlias: hubAlias)
    }

    /// Splits a config line into (keyword, value): the keyword ends at the first
    /// `=` or whitespace; the value is the remainder, with separators and any
    /// surrounding quotes stripped.
    private static func keyValue(_ line: String) -> (key: String, value: String)? {
        guard let sep = line.firstIndex(where: { $0 == "=" || $0 == " " || $0 == "\t" })
        else { return nil }
        let key = String(line[..<sep])
        var rest = String(line[line.index(after: sep)...])
        // Drop an inline comment: a `#` preceded by whitespace starts one.
        if let comment = rest.range(of: #"\s#"#, options: .regularExpression) {
            rest = String(rest[..<comment.lowerBound])
        }
        let value = rest.trimmingCharacters(in: CharacterSet(charactersIn: "= \t\""))
        guard !key.isEmpty, !value.isEmpty else { return nil }
        return (key, value)
    }

    private struct Builder {
        let alias: String
        var hostName: String?
        var user: String?
        var proxyJump: String?

        func build(hubAlias: String) -> Host {
            let reach: HostReach
            if let proxyJump, !proxyJump.isEmpty {
                reach = .proxyJump(via: proxyJump)
            } else {
                reach = .direct
            }
            return Host(
                id: alias,
                displayName: hostName.map { "\(alias) (\($0))" } ?? alias,
                sshAlias: alias,
                user: user,
                reach: reach,
                isHub: alias.caseInsensitiveCompare(hubAlias) == .orderedSame
            )
        }
    }
}
