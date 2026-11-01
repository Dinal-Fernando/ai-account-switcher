import SwiftUI
import SwitcherCore

/// First-run flow: detect CLIs → install the wrapper + PATH block (with consent) → verify → accounts.
@MainActor struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    @State private var step = 0
    @State private var addPathBlock = true
    @State private var installing = false
    @State private var addProvider: Provider?

    private let titles = ["Welcome", "Detect CLIs", "Shell integration", "Verify", "Accounts"]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                ForEach(titles.indices, id: \.self) { i in
                    Text(titles[i]).font(.caption).fontWeight(i == step ? .bold : .regular)
                        .foregroundStyle(i == step ? Color.accentColor : .secondary)
                    if i < titles.count - 1 { Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary) }
                }
                Spacer()
            }
            Divider()
            Group {
                switch step {
                case 0: welcome
                case 1: detect
                case 2: integration
                case 3: verify
                default: accounts
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Spacer()
            HStack {
                Button("Skip setup") { model.completeOnboarding() }
                Spacer()
                if step > 0 { Button("Back") { step -= 1 } }
                if step < titles.count - 1 {
                    Button("Continue") { step += 1 }.buttonStyle(.borderedProminent)
                } else {
                    Button("Finish") { model.completeOnboarding() }.buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(24)
        .frame(width: 620, height: 460)
        .sheet(item: $addProvider) { AddAccountSheet(provider: $0).environment(model) }
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Switch the account your terminal's claude and codex use").font(.title2.weight(.semibold))
            Text("Each account gets its own isolated configuration directory (CLAUDE_CONFIG_DIR / CODEX_HOME), so logins never mix. A tiny shell wrapper reads your selection every time you run claude or codex. The app never touches vendor Keychain items or tokens; sign-ins run through the vendor CLIs in Terminal.")
                .fixedSize(horizontal: false, vertical: true)
            Text("Your existing logins in ~/.claude and ~/.codex keep working as the “default” accounts — no re-login needed.").font(.callout).foregroundStyle(.secondary)
        }
    }

    private var detect: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Installed command-line tools").font(.headline)
            ForEach(Provider.allCases) { p in
                let path = model.runtime.shell.effectiveExecutable(p, searchPath: model.runtime.loginEnvironment["PATH"])
                HStack {
                    Image(systemName: path == nil ? "xmark.circle" : "checkmark.circle.fill").foregroundStyle(path == nil ? Color.red : Color.green)
                    VStack(alignment: .leading) {
                        Text(p.displayName).font(.subheadline.weight(.medium))
                        Text(path ?? "not found in your login shell's PATH — install it, then come back").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        if let v = model.versions[p] { Text(v).font(.caption2).foregroundStyle(.tertiary) }
                    }
                }
            }
            Text("The real executables are recorded so the wrapper can never call itself; they are not modified.").font(.caption).foregroundStyle(.secondary)
        }
    }

    private var integration: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Install the account-aware wrappers").font(.headline)
            Text("This creates ~/.aiswitch/bin/claude and ~/.aiswitch/bin/codex (plain shell scripts you can read) and, with your permission, appends a marked block to ~/.zshrc that puts that directory first in PATH. A backup of ~/.zshrc is kept in ~/.aiswitch/backups and everything can be uninstalled from Settings.")
                .fixedSize(horizontal: false, vertical: true)
            Toggle("Add the PATH block to \(model.runtime.shell.defaultRCFiles().map(\.lastPathComponent).joined(separator: ", "))", isOn: $addPathBlock)
            if !addPathBlock {
                Text("Without the PATH block you must add export PATH=\"$HOME/.aiswitch/bin:$PATH\" to your shell yourself.").font(.caption).foregroundStyle(.orange)
            }
            HStack {
                Button {
                    installing = true
                    Task { await model.installShellIntegration(addPathBlock: addPathBlock); installing = false; step = 3 }
                } label: { installing ? AnyView(ProgressView().controlSize(.small)) : AnyView(Text("Install now")) }
                .buttonStyle(.borderedProminent).disabled(installing)
                if model.shellStatus.wrapperInstalled.values.contains(true) {
                    Label("Wrappers already installed", systemImage: "checkmark").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var verify: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Verification").font(.headline)
            Text("A fresh login shell was asked what claude and codex resolve to:").font(.callout)
            ForEach(Provider.allCases) { p in
                let active = model.shellIntegrationActive(p)
                HStack {
                    Image(systemName: active ? "checkmark.circle.fill" : "exclamationmark.triangle.fill").foregroundStyle(active ? Color.green : Color.orange)
                    VStack(alignment: .leading) {
                        Text("\(p.executableName) → \(model.shellStatus.loginShellResolution[p] ?? "not found")").font(.caption).textSelection(.enabled)
                        Text(active ? "wrapper is in effect for new terminals" : "not the wrapper yet: open a new terminal or check that nothing later in ~/.zshrc rewrites PATH").font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            Button("Re-check") { Task { await model.probeShell() } }
        }
    }

    private var accounts: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Accounts").font(.headline)
            Text("Your current ~/.claude and ~/.codex logins are already listed as the default accounts. Add a second account per provider to start switching.").fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Add Claude Code account…") { addProvider = .claude }
                Button("Add Codex account…") { addProvider = .codex }
            }
            Text("Then click Set Active on a card; the next claude / codex you type uses that account. Running sessions are never reassigned.").font(.caption).foregroundStyle(.secondary)
            Text("Command-line fans: Scripts/build-app.sh --link puts the aiswitch tool on your PATH (aiswitch use, which, usage, sessions, doctor).").font(.caption).foregroundStyle(.secondary)
        }
    }
}
