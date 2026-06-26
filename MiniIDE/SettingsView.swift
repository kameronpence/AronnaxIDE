import SwiftUI

/// M0 placeholder. Full settings (hosts, GitHub accounts, projects, log sources,
/// port-forwards, ~/.ssh/config import) arrive in M12.
struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        Form {
            Section("Hub") {
                ForEach(settings.hosts) { host in
                    LabeledContent(host.displayName, value: host.sshAlias)
                }
                LabeledContent("Primary tmux session", value: settings.primaryTmuxSession)
            }
            Section("GitHub accounts") {
                ForEach(settings.accounts) { account in
                    LabeledContent(account.displayName, value: account.email)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 320)
    }
}

#Preview {
    SettingsView().environmentObject(AppSettings())
}
