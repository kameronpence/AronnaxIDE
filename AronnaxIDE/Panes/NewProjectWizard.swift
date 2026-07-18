import SwiftUI

/// The "New Project" wizard: name a project, and the app wires it end to end on the hub —
/// GitHub repo, beads + Dolt remote, and vault memory — by running the vault's tested
/// `new-project.sh`. Mirrors `AddServerWizard`, but there is only one machine involved (the
/// hub) and one script call, so it's a single form + live status pane rather than a step rail.
///
/// Reads the app-wide settings from the environment and hands them to the model's
/// `@StateObject` — needed because the wizard lives in its own `Window` scene.
struct NewProjectWizardWindow: View {
    @EnvironmentObject private var settings: AppSettings
    var body: some View { NewProjectWizard(settings: settings) }
}

struct NewProjectWizard: View {
    static let windowID = "new-project"
    @Environment(\.dismissWindow) private var dismissWindow
    @StateObject private var model: NewProjectOnboarding
    @State private var pendingWrite: WriteRequest?

    init(settings: AppSettings) {
        _model = StateObject(wrappedValue: NewProjectOnboarding(settings: settings))
    }

    /// Creating a project writes to the hub, so honor the same guardrails as the panes:
    /// block on a read-only hub, confirm when "Confirm before every write" is on, else run.
    private func requestCreate() {
        guard model.nameValid, !model.hubIsReadOnly else { return }
        if model.confirmWrites {
            pendingWrite = WriteRequest(title: "Create project “\(model.name)” on kepler — "
                                        + "GitHub repo, beads + Dolt remote, and vault memory.") {
                model.start()
            }
        } else {
            model.start()
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "folder.badge.plus").imageScale(.large)
                Text("New Project").font(.headline)
                Spacer()
                Button("Close") { closeWizard(reset: true) }
            }
            .padding(12)
            Divider()
            ScrollView { detail.padding(16) }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 620, idealWidth: 680, minHeight: 460, idealHeight: 540)
        .writeConfirm($pendingWrite)
        .onDisappear { model.cancel() }   // closing the wizard cancels an in-flight create
    }

    @ViewBuilder private var detail: some View {
        switch model.phase {
        case .form:            formStep
        case .running:         runningStep
        case .done:            doneStep
        case .failed:          failedStep
        }
    }

    // MARK: - Form
    private var formStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Create a local project").font(.title3.weight(.semibold))
            Text("Names a folder under the vault's Projects/, creates its GitHub repo, sets up "
                 + "beads with a Dolt remote, and seeds vault memory — all on kepler.")
                .font(.callout).foregroundStyle(.secondary)

            Form {
                TextField("Name (e.g. relayptc-tools)", text: $model.name)
                Toggle("Public repo", isOn: $model.isPublic)
            }
            .formStyle(.columns)

            if !model.name.isEmpty && !model.nameValid {
                Label("Use only letters, numbers, and . _ - — and don't start with a dot.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
            }

            if model.hubIsReadOnly {
                Label("kepler is marked read-only in Settings — creating a project is blocked. "
                      + "Turn off read-only for kepler to create projects.",
                      systemImage: "lock.fill")
                    .font(.caption).foregroundStyle(.orange)
            } else {
                Label("Runs on kepler (the vault host). New projects always land there, whatever "
                      + "host is active.", systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Spacer()
            HStack {
                Spacer()
                Button("Create") { requestCreate() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.nameValid || model.hubIsReadOnly)
            }
        }
    }

    // MARK: - Running
    private var runningStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Wiring “\(model.name)” on kepler…").font(.callout)
            }
            logView
            Spacer()
        }
    }

    // MARK: - Done
    private var doneStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Done", systemImage: "checkmark.seal.fill")
                .font(.title2.weight(.semibold)).foregroundStyle(.green)
            Text("“\(model.createdProjectName)” is wired: GitHub repo, beads + Dolt remote, and "
                 + "vault memory. It'll appear in the sidebar; servers pick it up on their next sync.")
                .font(.callout)
            if !model.resultLine.isEmpty {
                Text(model.resultLine)
                    .font(.caption.monospaced()).foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            logView
            Spacer()
            HStack { Spacer(); Button("Done") { closeWizard(reset: true) }.keyboardShortcut(.defaultAction) }
        }
    }

    // MARK: - Failed
    private var failedStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Couldn't finish", systemImage: "exclamationmark.triangle.fill")
                .font(.title3.weight(.semibold)).foregroundStyle(.red)
            if !model.resultLine.isEmpty {
                Text(model.resultLine)
                    .font(.callout).foregroundStyle(.red)
                    .textSelection(.enabled)
            }
            Text("The script is safe to re-run — it repairs what's missing and skips what's done.")
                .font(.caption).foregroundStyle(.secondary)
            logView
            Spacer()
            HStack {
                Button("Back") { model.phase = .form }
                Spacer()
                Button("Retry") { requestCreate() }.keyboardShortcut(.defaultAction)
            }
        }
    }

    @ViewBuilder private var logView: some View {
        if !model.log.isEmpty {
            ScrollView {
                Text(model.log)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 200)
            .padding(8)
            .background(Color.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 6))
        }
    }

    private func closeWizard(reset: Bool = false) {
        if reset { model.reset() }
        // Close ONLY this wizard's window by id, so finishing it can't close the main IDE
        // window (see the same note in AddServerWizard).
        dismissWindow(id: NewProjectWizard.windowID)
    }
}
