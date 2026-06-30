import SwiftUI

/// App settings: the agent workdir + tmux session (persisted to UserDefaults), the
/// hosts discovered from `~/.ssh/config` (read-only), and the GitHub accounts used
/// for per-project push identity (editable + persisted).
struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings

    @State private var newHostName = ""
    @State private var newHostAddr = ""
    @State private var newHostUser = "root"
    @State private var newHostViaHub = true
    @State private var showingWizard = false

    var body: some View {
        Form {
            Section("General") {
                TextField("Agent workdir", text: $settings.agentWorkdir)
                    .textFieldStyle(.roundedBorder)
                TextField("Primary tmux session", text: $settings.primaryTmuxSession)
                    .textFieldStyle(.roundedBorder)
                Text("The agent workdir is the fallback directory when no project is selected.")
                    .font(.callout).foregroundStyle(.secondary)
                Toggle("Confirm before every write (Save · Commit · Push · Beads changes)",
                       isOn: $settings.confirmWrites)
            }

            Section("Hosts") {
                ForEach(settings.hosts) { host in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(host.displayName).fontWeight(.medium)
                                Text("\(host.sshAlias)\(host.user.map { " · \($0)" } ?? "") · \(reachLabel(host))")
                                    .font(.callout).foregroundStyle(.secondary)
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
                        HStack(spacing: 18) {
                            Toggle("Protected", isOn: Binding(
                                get: { settings.isProtected(host) },
                                set: { settings.setProtected(host.id, $0) }))
                                .help("Warn + confirm before the Terminal connects to this host")
                            Toggle("Read-only", isOn: Binding(
                                get: { settings.isReadOnly(host) },
                                set: { settings.setReadOnly(host.id, $0) }))
                                .help("Block the app's own writes (save, git, beads) to this host")
                        }
                        .toggleStyle(.checkbox)
                        .font(.callout)
                        .foregroundStyle(.secondary)

                        if !host.isHub {
                            TextField("Vault clone path (e.g. /root/AI_OS)", text: Binding(
                                get: { settings.hostVaultPaths[host.id] ?? "" },
                                set: { settings.hostVaultPaths[host.id] = $0.isEmpty ? nil : $0 }))
                                .textFieldStyle(.roundedBorder)
                                .font(.callout)
                            TextField("Projects root (optional; defaults to <vault>/Projects)", text: Binding(
                                get: { settings.hostProjectsRoots[host.id] ?? "" },
                                set: { settings.hostProjectsRoots[host.id] = $0.isEmpty ? nil : $0 }))
                                .textFieldStyle(.roundedBorder)
                                .font(.callout)
                        }
                    }
                    .padding(.vertical, 2)
                }

                Button {
                    showingWizard = true
                } label: {
                    Label("Add Server…", systemImage: "wand.and.stars")
                }
                .help("Guided setup: connect, vault deploy key, clone, and tools")

                DisclosureGroup("Add manually (host list only)") {
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
            }

            Section("GitHub") {
                Text("Git auth is handled on the hosts: each repo's origin URL embeds "
                     + "its account and gh is the credential helper, so push/pull use the "
                     + "right account automatically. Nothing to configure here.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 500, height: 470)
        .sheet(isPresented: $showingWizard) {
            AddServerWizard(settings: settings)
        }
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

}

#Preview {
    SettingsView().environmentObject(AppSettings())
}
