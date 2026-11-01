import SwiftUI
import SwitcherCore

@MainActor struct DashboardView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings
    @State private var addProvider: Provider?

    var body: some View {
        @Bindable var model = model
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                banners
                ForEach(Provider.allCases) { provider in
                    ProviderSection(provider: provider, addAccount: { addProvider = provider })
                }
                footerNote
            }
            .padding(24)
        }
        .frame(minWidth: 760, minHeight: 540)
        .background(Color(nsColor: .windowBackgroundColor))
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { Task { await model.manualRefresh() } } label: {
                    if model.isRefreshing { ProgressView().controlSize(.small) } else { Label("Refresh", systemImage: "arrow.clockwise") }
                }
                .help("Refresh usage for every account (⌘R)")
                Menu {
                    Button("Add Claude Code account…") { addProvider = .claude }
                    Button("Add Codex account…") { addProvider = .codex }
                } label: { Label("Add Account", systemImage: "plus") }
                Button { openSettings() } label: { Label("Settings", systemImage: "gearshape") }
            }
        }
        .sheet(item: $addProvider) { provider in
            AddAccountSheet(provider: provider).environment(model)
        }
        .sheet(isPresented: $model.showOnboarding) {
            OnboardingView().environment(model)
        }
        .navigationTitle("AI Account Switcher")
    }

    @ViewBuilder private var banners: some View {
        @Bindable var model = model
        if model.shellStatus.loginShellProbed && !model.shellIntegrationActive {
            let wrappersPresent = Provider.allCases.allSatisfy { model.shellStatus.wrapperInstalled[$0] == true }
            let details = Provider.allCases.filter { !model.shellIntegrationActive($0) }.map { model.shellStatus.detail($0, paths: model.runtime.paths) }.joined(separator: " ")
            Banner(style: .warning, icon: "terminal",
                   title: wrappersPresent ? "Shell integration is not in effect" : "Shell integration is not installed",
                   message: wrappersPresent
                       ? details
                       : "Terminal still runs the plain claude/codex, so Set Active has no effect on new commands yet. Install it (reversible, backs up ~/.zshrc).",
                   actionTitle: wrappersPresent ? "Repair" : "Install shell integration",
                   action: { Task { await model.installShellIntegration(addPathBlock: true) } },
                   secondaryTitle: wrappersPresent ? "Re-check" : nil,
                   secondaryAction: { Task { await model.probeShell() } })
        }
        if let msg = model.errorMessage {
            Banner(style: .error, icon: "xmark.octagon", title: "Something went wrong", message: msg, actionTitle: "Dismiss") { model.errorMessage = nil }
        }
        if let msg = model.infoMessage {
            Banner(style: .info, icon: "info.circle", title: "", message: msg, actionTitle: "OK") { model.infoMessage = nil }
        }
        ForEach(Provider.allCases) { p in
            if let rec = model.recommendations[p] {
                Banner(style: .info, icon: "arrow.triangle.swap", title: "\(p.displayName): \(rec.toName) has more capacity",
                       message: rec.reason, actionTitle: "Switch to \(rec.toName)") { Task { await model.applyRecommendation(rec) } }
            }
        }
        if model.isOffline {
            Banner(style: .warning, icon: "wifi.slash", title: "Offline", message: "Showing cached readings; switching still works.", actionTitle: nil, action: nil)
        }
    }

    private var footerNote: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("How switching works").font(.caption.weight(.semibold))
            Text("Set Active writes the selection atomically to ~/.aiswitch/state; the claude/codex wrappers read it on every launch and export only CLAUDE_CONFIG_DIR / CODEX_HOME. Sessions already running keep their account. Usage numbers come from undocumented vendor endpoints (see docs/ENDPOINTS.md) and may lag or be rate-limited.")
                .font(.caption).foregroundStyle(.secondary)
            if let last = model.lastRefresh { Text("Last refresh \(UsageFormat.age(last, now: model.now))").font(.caption2).foregroundStyle(.secondary) }
        }
        .padding(.top, 8)
    }
}

struct ProviderSection: View {
    @Environment(AppModel.self) private var model
    let provider: Provider
    let addAccount: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(provider.displayName).font(.title2.weight(.semibold))
                if let active = model.activeAccount(for: provider) {
                    Text("Active: \(active.name)").font(.subheadline).foregroundStyle(.secondary)
                }
                if let v = model.versions[provider] { Text(v).font(.caption2).foregroundStyle(.tertiary) }
                Spacer()
                Text(model.shellIntegrationActive(provider) ? "wrapper active" : (model.shellStatus.loginShellProbed ? "wrapper inactive" : "checking shell…"))
                    .font(.caption).foregroundStyle(model.shellIntegrationActive(provider) ? .green : .orange)
                    .help(model.shellStatus.detail(provider, paths: model.runtime.paths))
                Button(action: addAccount) { Label("Add", systemImage: "plus") }.controlSize(.small)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 340, maximum: 600), spacing: 16, alignment: .top)], alignment: .leading, spacing: 16) {
                ForEach(model.accounts(for: provider)) { account in
                    AccountCardView(account: account)
                }
            }
        }
    }
}

struct Banner: View {
    enum Style { case info, warning, error }
    let style: Style
    let icon: String
    let title: String
    let message: String
    let actionTitle: String?
    let action: (() -> Void)?
    var secondaryTitle: String? = nil
    var secondaryAction: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).foregroundStyle(color)
            VStack(alignment: .leading, spacing: 2) {
                if !title.isEmpty { Text(title).font(.subheadline.weight(.semibold)) }
                Text(message).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if let secondaryTitle, let secondaryAction { Button(secondaryTitle, action: secondaryAction).controlSize(.small) }
            if let actionTitle, let action { Button(actionTitle, action: action).controlSize(.small).buttonStyle(.borderedProminent) }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(color.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(color.opacity(0.3)))
    }

    private var color: Color {
        switch style {
        case .info: return .accentColor
        case .warning: return .orange
        case .error: return .red
        }
    }
}
