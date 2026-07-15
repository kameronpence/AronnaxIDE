import SwiftUI

/// The "Add Server" wizard. The app runs every step it can over SSH and pauses with
/// instructions at the steps only Kameron can do. Chunk 1 covers details → foothold
/// key → connection test; provisioning (deploy key, clone, tools) lands next.
/// Reads the app-wide settings from the environment and hands them to the wizard's
/// `@StateObject`. Needed because the wizard lives in its own `Window` scene.
struct AddServerWizardWindow: View {
    @EnvironmentObject private var settings: AppSettings
    var body: some View { AddServerWizard(settings: settings) }
}

struct AddServerWizard: View {
    static let windowID = "add-server"
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model: ServerOnboarding

    init(settings: AppSettings) {
        _model = StateObject(wrappedValue: ServerOnboarding(settings: settings))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "plus.rectangle.on.folder").imageScale(.large)
                Text("Add Server").font(.headline)
                Spacer()
                Button("Close") { closeWizard(reset: true) }
            }
            .padding(12)
            Divider()
            HStack(spacing: 0) {
                stepList.frame(width: 250)
                Divider()
                ScrollView { detail.padding(16) }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 860, idealWidth: 900, minHeight: 620, idealHeight: 660)
        .onDisappear { model.cancel() }   // closing the wizard cancels in-flight provisioning
    }

    // MARK: - Step list (left rail)
    private var stepList: some View {
        List {
            ForEach(model.steps) { step in
                HStack(spacing: 10) {
                    icon(step.phase)
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(step.title)
                            .font(.callout)
                            .fontWeight(step.id == model.current ? .semibold : .regular)
                        Text(step.role == .app ? "the app does this" : "you do this")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.vertical, 2)
                .listRowBackground(step.id == model.current ? Color.accentColor.opacity(0.10) : Color.clear)
            }
        }
        .listStyle(.inset)
    }

    @ViewBuilder private func icon(_ phase: ServerOnboarding.Phase) -> some View {
        switch phase {
        case .idle:        Image(systemName: "circle").foregroundStyle(.tertiary)
        case .running:     ProgressView().controlSize(.small)
        case .waitingOnYou:Image(systemName: "hand.point.up.left.fill").foregroundStyle(.orange)
        case .done:        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed:      Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
        }
    }

    // MARK: - Detail (right pane), switches on the active step
    @ViewBuilder private var detail: some View {
        if model.finished {
            doneStep
        } else {
            switch model.current {
            case 0: detailsForm
            case 1: footholdStep
            case 4: githubStep
            default: provisioningStatus   // 2, 3, 5, 6, 7, 8 — app working
            }
        }
    }

    private var detailsForm: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Server details").font(.title3.weight(.semibold))
            Text("Where the box lives and how the app reaches it.")
                .font(.callout).foregroundStyle(.secondary)
            Form {
                TextField("Name (e.g. relayptc-prod)", text: $model.name)
                TextField("IP or hostname", text: $model.address)
                TextField("User", text: $model.user)
                TextField("Project directory on the box (e.g. /var/www/html/gatsa_rewrite)", text: $model.projectDir)
                Toggle("Reach it through kepler (ProxyJump)", isOn: $model.viaHub)
            }
            .formStyle(.columns)
            Spacer()
            HStack {
                Spacer()
                Button("Continue") {
                    model.current = 1
                    Task { await model.prepareFoothold() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!model.formValid)
            }
        }
    }

    private var footholdStep: some View {
        let step = model.steps[1]
        return VStack(alignment: .leading, spacing: 14) {
            Text("Give the app a foothold").font(.title3.weight(.semibold))
            Text("A brand-new AWS/Lightsail box only trusts the key it launched with. Add this "
                 + "Mac's key so the app can take over — step by step:")
                .font(.callout).foregroundStyle(.secondary)

            if model.bootstrapKey.isEmpty {
                ProgressView("Fetching the key…")
            } else {
                Text("**1.** Copy this Mac's public key (button on the right):")
                    .font(.callout)
                keyBox(model.bootstrapKey)
                Text("**2.** In a terminal window (not within this app), ssh into your server. If you're using AWS EC2 or Lightsail, just use the **Connect using SSH** option.")
                    .font(.callout)
                Text("**3.** Add the key to the box — either option works:")
                    .font(.callout)
                Text("• Open the file with `nano ~/.ssh/authorized_keys`, paste your key from step 1 on a new line, then save (Ctrl+O, Enter, Ctrl+X).")
                    .font(.callout)
                Text("• Or just copy and paste this one command at the command prompt to add it automatically (replace `PASTE_KEY` with the key from step 1):")
                    .font(.callout)
                keyBox("mkdir -p ~/.ssh && chmod 700 ~/.ssh && echo 'PASTE_KEY' >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys")
                Text("**4.** Come back here and click **I've added it — connect** below.")
                    .font(.callout)
            }

            if !step.detail.isEmpty {
                Label(step.detail, systemImage: step.phase == .failed
                      ? "exclamationmark.triangle.fill" : "info.circle")
                    .font(.caption)
                    .foregroundStyle(step.phase == .failed ? .red : .secondary)
            }

            Spacer()
            HStack {
                Button("Back") { model.current = 0 }
                Spacer()
                Button(model.steps[2].phase == .running ? "Connecting…" : "I've added it — connect") {
                    model.startConnect()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(model.bootstrapKey.isEmpty || model.steps[2].phase == .running)
            }
        }
    }

    private var githubStep: some View {
        let step = model.steps[4]
        return VStack(alignment: .leading, spacing: 14) {
            Text("Add the deploy key to GitHub").font(.title3.weight(.semibold))
            Label("This goes on your **personal** GitHub (kameronpence) — the `ai-os-vault` repo lives there, NOT under the GATSA org.",
                  systemImage: "person.crop.circle.badge.exclamationmark")
                .font(.callout.weight(.medium))
                .foregroundStyle(.orange)
            Text("On **personal GitHub** → the **ai-os-vault** repo → Settings → Deploy keys → "
                 + "Add deploy key. Title it \"\(model.host.displayName)\" and check **Allow write access**.")
                .font(.callout).foregroundStyle(.secondary)
            if model.deployKey.isEmpty { ProgressView() }
            else {
                keyBox(model.deployKey)
                if !model.deployKeyFingerprint.isEmpty {
                    Text("Fingerprint: \(model.deployKeyFingerprint)")
                        .font(.caption.monospaced()).foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Text("Already set this server up before? If GitHub says **\"Key is already in use\"**, it's already added — match the fingerprint above to the repo's Deploy keys list; if it's there, just click **continue** and the app verifies it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !step.detail.isEmpty {
                Label(step.detail, systemImage: step.phase == .failed
                      ? "exclamationmark.triangle.fill" : "info.circle")
                    .font(.caption).foregroundStyle(step.phase == .failed ? .red : .secondary)
            }
            Spacer()
            HStack {
                Spacer()
                Button(step.phase == .running ? "Checking…" : "I've added it — continue") {
                    model.startVerify()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(model.deployKey.isEmpty || step.phase == .running)
            }
        }
    }

    private var provisioningStatus: some View {
        let step = model.steps[min(model.current, model.steps.count - 1)]
        return VStack(alignment: .leading, spacing: 14) {
            Text("Setting up \(model.host.displayName)").font(.title3.weight(.semibold))
            HStack(spacing: 10) {
                if step.phase == .running {
                    ProgressView().controlSize(.small)
                } else if step.phase == .failed {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                }
                Text(step.detail.isEmpty ? step.title : step.detail).font(.callout)
            }
            if step.phase == .failed {
                Button("Retry") { model.startRetry() }
            }
            Spacer()
        }
    }

    private var doneStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Done", systemImage: "checkmark.seal.fill")
                .font(.title2.weight(.semibold)).foregroundStyle(.green)
            Text("\(model.host.displayName) is set up — vault synced, memory rules + Obsidian "
                 + "second memory in place, and it's now in your host list.")
                .font(.callout)
            if !model.steps[6].detail.isEmpty {
                Text(model.steps[6].detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            HStack { Spacer(); Button("Done") { closeWizard(reset: true) }.keyboardShortcut(.defaultAction) }
        }
    }

    private func closeWizard(reset: Bool = false) {
        if reset { model.reset() }
        dismiss()
        NSApp.keyWindow?.close()
    }

    private func keyBox(_ key: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(key)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(Color.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 6))
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(key, forType: .string)
            } label: { Image(systemName: "doc.on.doc") }
            .buttonStyle(.borderless)
            .help("Copy")
        }
    }
}
