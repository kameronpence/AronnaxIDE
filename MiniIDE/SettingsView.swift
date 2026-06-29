import SwiftUI

/// App settings: the agent workdir + tmux session (persisted to UserDefaults), the
/// hosts discovered from `~/.ssh/config` (read-only), and the GitHub accounts used
/// for per-project push identity (editable + persisted).
struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings

    @State private var newName = ""
    @State private var newAlias = ""
    @State private var newEmail = ""

    @State private var newHostName = ""
    @State private var newHostAddr = ""
    @State private var newHostUser = "root"
    @State private var newHostViaHub = true

    var body: some View {
        Form {
            Section("General") {
                TextField("Agent workdir", text: $settings.agentWorkdir)
                    .textFieldStyle(.roundedBorder)
                TextField("Primary tmux session", text: $settings.primaryTmuxSession)
                    .textFieldStyle(.roundedBorder)
                Text("The agent workdir is the fallback directory when no project is selected.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Hosts") {
                ForEach(settings.hosts) { host in
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(host.displayName).fontWeight(.medium)
                            Text("\(host.sshAlias)\(host.user.map { " · \($0)" } ?? "") · \(reachLabel(host))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if settings.isCustomHost(host.id) {
                            Button(role: .destructive) { settings.removeHost(id: host.id) } label: {
                                Image(systemName: "minus.circle.fill")
                            }
                            .buttonStyle(.plain).foregroundStyle(.secondary)
                            .help("Remove host")
                        } else {
                            Text(host.isHub ? "hub" : "ssh config")
                                .font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                }

                VStack(spacing: 6) {
                    TextField("Name (e.g. GATSA staging)", text: $newHostName)
                    TextField("Hostname or IP", text: $newHostAddr)
                    TextField("User (e.g. root)", text: $newHostUser)
                    Toggle("Reach via the hub (ProxyJump)", isOn: $newHostViaHub)
                    HStack {
                        Spacer()
                        Button("Add host", action: addHost)
                            .disabled(newHostName.trimmingCharacters(in: .whitespaces).isEmpty
                                      || newHostAddr.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                .textFieldStyle(.roundedBorder)
            }

            Section("GitHub accounts") {
                if settings.accounts.isEmpty {
                    Text("No accounts configured.").foregroundStyle(.secondary)
                }
                ForEach(settings.accounts) { account in
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(account.displayName).fontWeight(.medium)
                            Text("\(account.sshHostAlias) · \(account.email)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(role: .destructive) { remove(account) } label: {
                            Image(systemName: "minus.circle.fill")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("Remove account")
                    }
                }

                VStack(spacing: 6) {
                    TextField("Name (e.g. Work)", text: $newName)
                    TextField("SSH host alias (e.g. github.com-work)", text: $newAlias)
                    TextField("Email", text: $newEmail)
                    HStack {
                        Spacer()
                        Button("Add account", action: addAccount)
                            .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                .textFieldStyle(.roundedBorder)
            }
        }
        .formStyle(.grouped)
        .frame(width: 500, height: 560)
    }

    private func reachLabel(_ host: Host) -> String {
        switch host.reach {
        case .direct:             return host.isHub ? "hub · direct" : "direct"
        case .proxyJump(let via): return "via \(via)"
        }
    }

    private func addHost() {
        let name = newHostName.trimmingCharacters(in: .whitespaces)
        let addr = newHostAddr.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !addr.isEmpty else { return }
        let user = newHostUser.trimmingCharacters(in: .whitespaces)
        settings.addHost(Host(
            id: addr,            // the address is unique + stable; also the ssh target
            displayName: name,
            sshAlias: addr,      // connect straight to the address (not an ~/.ssh/config alias)
            user: user.isEmpty ? nil : user,
            reach: newHostViaHub ? .proxyJump(via: AppSettings.hubAlias) : .direct,
            isHub: false))
        newHostName = ""; newHostAddr = ""; newHostUser = "root"; newHostViaHub = true
    }

    private func addAccount() {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        settings.accounts.append(GitHubAccount(
            id: UUID().uuidString,
            displayName: name,
            sshHostAlias: newAlias.trimmingCharacters(in: .whitespaces),
            email: newEmail.trimmingCharacters(in: .whitespaces)))
        newName = ""; newAlias = ""; newEmail = ""
    }

    private func remove(_ account: GitHubAccount) {
        settings.accounts.removeAll { $0.id == account.id }
    }
}

#Preview {
    SettingsView().environmentObject(AppSettings())
}
