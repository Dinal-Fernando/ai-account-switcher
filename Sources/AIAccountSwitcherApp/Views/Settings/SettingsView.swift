import SwiftUI
import SwitcherCore
import SwitcherMac

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        TabView {
            GeneralSettingsView().tabItem { Label("General", systemImage: "gearshape") }
            RefreshSettingsView().tabItem { Label("Refresh", systemImage: "arrow.clockwise") }
            NotificationSettingsView().tabItem { Label("Notifications", systemImage: "bell") }
            ShellIntegrationSettingsView().tabItem { Label("Shell", systemImage: "terminal") }
            DiagnosticsView().tabItem { Label("Diagnostics", systemImage: "stethoscope") }
        }
        .frame(width: 560, height: 440)
        .environment(model)
    }
}

struct GeneralSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var launchError: String?

    var body: some View {
        @Bindable var model = model
        Form {
            Toggle("Show icon in the Dock", isOn: $model.settings.showDockIcon)
            Section("Menu bar") {
                Picker("Show", selection: $model.settings.menuBarMode) {
                    ForEach(MenuBarMode.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                Picker("Number", selection: $model.settings.menuBarWindow) {
                    ForEach(MenuBarWindow.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                if model.settings.menuBarMode == .allAccounts {
                    Toggle("Compact (no rings, no % sign)", isOn: $model.settings.menuBarCompact)
                    Toggle("Mini ring per account", isOn: $model.settings.menuBarShowRings).disabled(model.settings.menuBarCompact)
                    Text("Each account appears as a short label with its usage; a dot marks the active account of each provider. Labels default to the initials of the account name — change them with Rename… on a card.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Toggle("Show percentage next to the icon", isOn: $model.settings.menuBarShowsPercent)
                }
            }
            Toggle("Launch at login", isOn: $launchAtLogin)
                .disabled(!LaunchAtLogin.isAvailable)
                .onChange(of: launchAtLogin) { _, v in
                    guard v != LaunchAtLogin.isEnabled else { return }
                    do { try LaunchAtLogin.setEnabled(v); launchError = nil } catch {
                        launchError = error.localizedDescription
                        launchAtLogin = LaunchAtLogin.isEnabled
                    }
                }
            if let launchError { Text(launchError).font(.caption).foregroundStyle(.red) }
            Picker("Usage graphs", selection: $model.settings.graphStyle) {
                ForEach(GraphStyle.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            Toggle("Rings show remaining instead of used", isOn: $model.settings.showRemaining)
            TextField("Terminal app for logins and “Open Terminal” (Terminal, iTerm, Ghostty, …)", text: $model.settings.terminalApp)
            Button("Show onboarding again") { model.showOnboarding = true }
        }
        .formStyle(.grouped)
        .padding()
    }
}

struct RefreshSettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Picker("Mode", selection: $model.settings.refresh.mode) {
                ForEach(RefreshMode.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            if model.settings.refresh.mode == .fixed {
                Picker("Interval", selection: $model.settings.refresh.fixedInterval) {
                    ForEach(RefreshSettings.fixedChoices, id: \.self) { Text(label($0)).tag($0) }
                }
            }
            if model.settings.refresh.mode == .smart {
                Text("Smart mode polls every 60 s while numbers change and backs off to 3, 5 and 10 minutes when nothing moves. Opening the menu bar or pressing Refresh returns to 60 s.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("Each account is refreshed independently; a failing account never blocks the others. Rate limits (HTTP 429) trigger exponential backoff from 1 to 30 minutes and honour Retry-After. Readings are cached and marked stale when they cannot be refreshed. The Anthropic usage endpoint is never polled faster than once per minute per account.")
                .font(.caption).foregroundStyle(.secondary)
            if let last = model.lastRefresh { Text("Last refresh: \(last.formatted(date: .omitted, time: .standard))").font(.caption) }
        }
        .formStyle(.grouped)
        .padding()
    }

    private func label(_ secs: TimeInterval) -> String { secs < 3600 ? "\(Int(secs / 60)) min" : "\(Int(secs / 3600)) h" }
}

struct NotificationSettingsView: View {
    @Environment(AppModel.self) private var model
    private let choices = Array(stride(from: 50, through: 100, by: 5))

    var body: some View {
        @Bindable var model = model
        Form {
            Toggle("Usage notifications", isOn: $model.settings.notificationsEnabled)
                .onChange(of: model.settings.notificationsEnabled) { _, on in if on { model.notifications.requestAuthorization() } }
            thresholdPicker("5-hour window", values: $model.settings.thresholds.fiveHour)
            thresholdPicker("Weekly window", values: $model.settings.thresholds.weekly)
            thresholdPicker("Per-model weekly", values: $model.settings.thresholds.modelWeekly)
            Section("Account recommendations") {
                Text("When the active account crosses a threshold, the notification offers “Switch account” to the signed-in account with the most capacity left. Clicking it changes the account future `claude`/`codex` launches use.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Automatic switching (opt-in)") {
                ForEach(Provider.allCases) { p in
                    Toggle("Automatically switch \(p.displayName) when the active account reaches \(Int(model.settings.autoSwitchThreshold))%",
                           isOn: Binding(get: { model.settings.autoSwitchEnabled(p) },
                                         set: { model.settings.autoSwitch[p.rawValue] = $0 }))
                }
                Slider(value: $model.settings.autoSwitchThreshold, in: 80...100, step: 5) { Text("Threshold") }
                Text("Only the selection for *future* launches changes and you get a notification. Running sessions are never redirected and work is never split across accounts.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private func thresholdPicker(_ title: String, values: Binding<[Int]>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 54), spacing: 4)], alignment: .leading, spacing: 4) {
            ForEach(choices, id: \.self) { v in
                Toggle("\(v)%", isOn: Binding(get: { values.wrappedValue.contains(v) },
                                                set: { on in
                                                    var set = Set(values.wrappedValue)
                                                    if on { set.insert(v) } else { set.remove(v) }
                                                    values.wrappedValue = set.sorted()
                                                }))
                .toggleStyle(.button).controlSize(.mini)
            }
            }
        }
    }
}

struct ShellIntegrationSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var confirmUninstall = false

    var body: some View {
        Form {
            Section("Status") {
                ForEach(Provider.allCases) { p in
                    let s = model.shellStatus
                    LabeledContent(p.executableName) {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(s.wrapperInstalled[p] == true ? "wrapper installed (v\(s.wrapperVersion[p] ?? 0))" : "wrapper not installed")
                            Text("real: \(s.realExecutable[p] ?? "—")").font(.caption2).foregroundStyle(.secondary)
                            Text("login shell → \(s.loginShellResolution[p] ?? (s.loginShellProbed ? "not found" : "…"))").font(.caption2)
                                .foregroundStyle(model.shellIntegrationActive(p) ? Color.green : Color.orange)
                        }
                        .textSelection(.enabled)
                    }
                }
                LabeledContent("rc files with PATH block") { Text(model.shellStatus.rcFilesWithBlock.isEmpty ? "none" : model.shellStatus.rcFilesWithBlock.joined(separator: ", ")).font(.caption) }
                LabeledContent("State directory") { Text(model.runtime.paths.root.path).font(.caption).textSelection(.enabled) }
            }
            Section {
                HStack {
                    Button("Install / repair") { Task { await model.installShellIntegration(addPathBlock: true) } }
                    Button("Re-check login shell") { Task { await model.probeShell() } }
                    Spacer()
                    Button("Uninstall…", role: .destructive) { confirmUninstall = true }
                }
                Text("Install writes the wrappers, records the real executables, and appends a marked block to \(model.runtime.shell.defaultRCFiles().map(\.path).joined(separator: ", ")) after backing it up to ~/.aiswitch/backups. Uninstall removes the block and the wrappers; your profiles and logins stay.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
        .confirmationDialog("Uninstall shell integration?", isPresented: $confirmUninstall, titleVisibility: .visible) {
            Button("Remove PATH block and wrappers") { Task { await model.uninstallShellIntegration(restoreBackups: false) } }
            Button("Restore rc files from install-time backup", role: .destructive) { Task { await model.uninstallShellIntegration(restoreBackups: true) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("New terminals will run the plain claude/codex again (using ~/.claude and ~/.codex). Restoring from backup discards edits made to your rc file after installation.")
        }
    }
}
