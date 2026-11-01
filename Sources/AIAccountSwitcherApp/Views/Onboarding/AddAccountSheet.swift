import SwiftUI
import SwitcherCore

/// Create an isolated profile, then run the vendor's own browser login inside it.
@MainActor struct AddAccountSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State var provider: Provider
    @State private var name = ""
    @State private var copySettings = true
    @State private var usageEnabled = true
    @State private var deviceAuth = false
    @State private var created: Account?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(created == nil ? "Add \(provider.displayName) account" : "Sign in to '\(created!.name)'").font(.title3.weight(.semibold))
            if let created {
                signInStep(created)
            } else {
                form
            }
        }
        .padding(22)
        .frame(width: 460)
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Provider", selection: $provider) {
                ForEach(Provider.allCases) { Text($0.displayName).tag($0) }
            }
            .pickerStyle(.segmented)
            TextField("Friendly name (e.g. Claude Work)", text: $name).textFieldStyle(.roundedBorder)
            Toggle(provider == .claude ? "Copy settings.json, CLAUDE.md, commands, agents and skills from ~/.claude" : "Copy ~/.codex/config.toml (never auth.json)", isOn: $copySettings)
            Toggle("Monitor usage using this profile's own login (read-only)", isOn: $usageEnabled)
            if provider == .codex { Toggle("Use device-code login (headless/SSO friendly)", isOn: $deviceAuth) }
            Text("Creates an isolated \(provider.configDirEnvVar) directory under ~/.aiswitch/profiles. The login itself happens in the \(provider.displayName) tool, in a Terminal window; the app never sees your password.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Create & Sign in") { create() }
                    .buttonStyle(.borderedProminent)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private func create() {
        do {
            let account = try model.addAccount(provider: provider, name: name, copySettings: copySettings, usageEnabled: usageEnabled)
            created = account
            model.startLogin(account, deviceAuth: deviceAuth)
        } catch {
            self.error = error.localizedDescription
        }
    }

    @ViewBuilder private func signInStep(_ account: Account) -> some View {
        let live = model.accounts.first { $0.key == account.key } ?? account
        VStack(alignment: .leading, spacing: 10) {
            if live.lastAuth?.isAuthenticated == true {
                Label("Signed in\(live.identity?.email.map { " as \($0)" } ?? "")", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                Text("You can now click Set Active on its card to route \(provider.executableName) to this account.").font(.caption).foregroundStyle(.secondary)
                HStack { Spacer(); Button("Done") { dismiss() }.buttonStyle(.borderedProminent) }
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("A Terminal window is signing this profile in with the \(provider.displayName) login flow. Complete the browser login; this sheet updates automatically.")
                        .font(.callout).fixedSize(horizontal: false, vertical: true)
                }
                Text("Profile directory: \(model.profilePath(live))").font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
                HStack {
                    Button("Open login window again") { model.startLogin(live, deviceAuth: deviceAuth) }
                    Spacer()
                    Button("Close (keep account)") { model.cancelLoginWait(live); dismiss() }
                }
            }
        }
    }
}
