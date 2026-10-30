import SwiftUI
import SwitcherCore

/// One account: identity, quota gauges, sync state, and the primary action — Set Active.
@MainActor struct AccountCardView: View {
    @Environment(AppModel.self) private var model
    let account: Account
    @State private var showRename = false
    @State private var newName = ""
    @State private var newShortLabel = ""
    @State private var confirmRemove = false
    @State private var showHistory = false

    private var state: AccountUsageState { model.usageState(account) }
    private var snapshot: UsageSnapshot? { state.effectiveSnapshot }
    private var activeState: ActiveState { model.activeState(account) }
    private var isSelected: Bool { activeState != .notActive }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            identityRow
            usageSection
            footer
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(isSelected ? Color.accentColor : Color.secondary.opacity(0.15), lineWidth: isSelected ? 2 : 1))
        .sheet(isPresented: $showRename) { renameSheet }
        .confirmationDialog("Remove '\(account.name)'?", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Remove and delete its login directory", role: .destructive) { Task { await model.remove(account, deleteDirectory: true) } }
            Button("Remove but keep the directory") { Task { await model.remove(account, deleteDirectory: false) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Deleting the directory signs this profile out of \(account.provider.displayName) on this Mac. Run `\(account.provider.executableName) auth logout` style logout first if you want the vendor session revoked.")
        }
    }

    // MARK: pieces

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(account.name).font(.headline).lineLimit(1)
                    if account.isDefault {
                        Text("default dir").font(.caption2).padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Capsule().fill(Color.secondary.opacity(0.15)))
                    }
                }
                Text(account.provider.displayName).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            activeBadge
        }
    }

    @ViewBuilder private var activeBadge: some View {
        switch activeState {
        case .active:
            Label("ACTIVE", systemImage: "checkmark.circle.fill")
                .font(.caption.weight(.bold)).foregroundStyle(.white)
                .padding(.horizontal, 8).padding(.vertical, 4).background(Capsule().fill(Color.green))
                .help("New `\(account.provider.executableName)` launches use this account (verified signed in).")
        case .selectedUnverified:
            Label("SELECTED", systemImage: "clock").font(.caption.weight(.bold)).foregroundStyle(.secondary)
                .padding(.horizontal, 8).padding(.vertical, 4).background(Capsule().fill(Color.secondary.opacity(0.2)))
                .help("Selected; sign-in check pending.")
        case .selectedNeedsLogin:
            Label("SELECTED · SIGN IN", systemImage: "exclamationmark.triangle.fill").font(.caption.weight(.bold)).foregroundStyle(.white)
                .padding(.horizontal, 8).padding(.vertical, 4).background(Capsule().fill(Color.orange))
                .help("Selected, but not signed in: `\(account.provider.executableName)` will ask you to log in.")
        case .selectedWrapperInactive:
            Label("SELECTED · WRAPPER OFF", systemImage: "exclamationmark.triangle.fill").font(.caption.weight(.bold)).foregroundStyle(.white)
                .padding(.horizontal, 8).padding(.vertical, 4).background(Capsule().fill(Color.orange))
                .help("Selected, but the shell wrapper is not active, so Terminal ignores it. Install shell integration in Settings.")
        case .notActive:
            Button {
                Task { await model.setActive(account) }
            } label: {
                if model.isBusy(account) { ProgressView().controlSize(.small) } else { Text("Set Active") }
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.isBusy(account))
            .help("Make this the account that new `\(account.provider.executableName)` commands use.")
        }
    }

    private var identityRow: some View {
        HStack(spacing: 8) {
            if let auth = account.lastAuth {
                Image(systemName: auth.isAuthenticated ? "person.crop.circle.badge.checkmark" : "person.crop.circle.badge.xmark")
                    .foregroundStyle(auth.isAuthenticated ? Color.green : Color.orange)
            } else {
                Image(systemName: "person.crop.circle.badge.questionmark").foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 1) {
                if let id = account.identity, !id.summary.isEmpty {
                    Text(id.summary).font(.subheadline).lineLimit(1)
                } else {
                    Text(account.lastAuth?.displayLabel ?? "Not verified yet").font(.subheadline).foregroundStyle(.secondary)
                }
                if let auth = account.lastAuth {
                    Text(auth.isAuthenticated ? "Signed in · checked \(UsageFormat.age(auth.checkedAt, now: model.now))" : (auth.message ?? auth.displayLabel))
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                ForEach(account.lastAuth?.warnings ?? [], id: \.self) { w in
                    Label(w, systemImage: "exclamationmark.triangle").font(.caption2).foregroundStyle(.orange).lineLimit(2)
                }
            }
            Spacer()
            if model.loginWaiting.contains(account.key) {
                HStack(spacing: 4) {
                    ProgressView().controlSize(.small)
                    Text("Waiting for sign-in…").font(.caption).foregroundStyle(.secondary)
                    Button("Cancel") { model.cancelLoginWait(account) }.controlSize(.small)
                }
            } else if account.lastAuth?.isAuthenticated != true {
                Button("Sign in") { model.startLogin(account) }.controlSize(.small)
            }
        }
    }

    @ViewBuilder private var usageSection: some View {
        if account.usageSource == .disabled {
            Text("Usage monitoring disabled for this account.").font(.caption).foregroundStyle(.secondary)
        } else if let snap = snapshot {
            if model.settings.graphStyle == .pace {
                PaceGraphView(windows: snap.allWindows, now: model.now)
            } else {
                HStack(alignment: .top, spacing: 18) {
                    UsageRingView(percent: snap.fiveHour?.usedPercent, label: "5-hour",
                                  sublabel: snap.fiveHour.map { UsageFormat.countdown($0, now: model.now) },
                                  showRemaining: model.settings.showRemaining)
                    UsageRingView(percent: snap.weekly?.usedPercent, label: "Weekly",
                                  sublabel: snap.weekly.map { UsageFormat.countdown($0, now: model.now) },
                                  showRemaining: model.settings.showRemaining)
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(snap.modelWindows) { w in
                            UsageBarView(label: w.label, percent: w.usedPercent, trailing: UsageFormat.countdown(w, now: model.now))
                        }
                        if let extra = snap.extraUsage, extra.enabled {
                            UsageBarView(label: "Extra usage", percent: extra.usedPercent ?? 0,
                                         trailing: "\(UsageFormat.money(extra.usedCredits, currency: extra.currency)) / \(UsageFormat.money(extra.monthlyLimit, currency: extra.currency))")
                        }
                        if let credits = snap.credits {
                            HStack {
                                Text("Credits").font(.caption)
                                Spacer()
                                Text(credits.unlimited ? "unlimited" : (credits.balance.map { String(format: "%.2f", $0) } ?? (credits.hasCredits ? "available" : "none")))
                                    .font(.caption).monospacedDigit()
                            }
                        }
                        if let plan = snap.plan { Text("Plan: \(plan.capitalized)").font(.caption2).foregroundStyle(.secondary) }
                        if let next = snap.nextReset {
                            Text("Next reset \(UsageFormat.resetTime(UsageWindow(kind: .other, label: "", usedPercent: 0, resetsAt: next)) ?? "")").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if showHistory { UsageHistoryView(points: model.history(account)) }
        } else {
            HStack(spacing: 18) {
                UsageRingView(percent: nil, label: "5-hour")
                UsageRingView(percent: nil, label: "Weekly")
                VStack(alignment: .leading) {
                    Text(placeholderText).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
        }
    }

    private var placeholderText: String {
        switch state.status {
        case .never: return "No reading yet."
        case .refreshing: return "Fetching usage…"
        default: return state.status.detail ?? state.status.shortLabel
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            StatusDot(status: state.status)
            VStack(alignment: .leading, spacing: 0) {
                Text(syncText).font(.caption).lineLimit(1)
                if let detail = state.status.detail, state.status.isProblem {
                    Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                }
                if let snap = snapshot, snap.source == "statusline-beacon" {
                    Text("Values observed by Claude Code (status-line beacon)").font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button { model.openTerminal(account) } label: { Label("Open Terminal", systemImage: "terminal") }
                .controlSize(.small)
                .help("Opens a terminal whose `\(account.provider.executableName)` uses this account, without changing the global selection.")
            Menu {
                Group {
                    Button("Verify sign-in") { Task { await model.verify(account) } }
                    Button("Re-authenticate…") { model.startLogin(account) }
                    if account.provider == .codex { Button("Sign in with device code…") { model.startLogin(account, deviceAuth: true) } }
                    Divider()
                    Button("Rename…") { newName = account.name; newShortLabel = account.shortLabel ?? ""; showRename = true }
                    Button(showHistory ? "Hide history" : "Show history") { showHistory.toggle() }
                }
                Menu("Usage source") {
                    ForEach(UsageSource.allCases, id: \.self) { s in
                        Button { Task { await model.setUsageSource(account, s) } } label: {
                            if s == account.usageSource { Label(s.displayName, systemImage: "checkmark") } else { Text(s.displayName) }
                        }
                    }
                }
                Button("Reveal profile folder in Finder") { model.revealProfile(account) }
                Button("Copy profile path") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(model.profilePath(account), forType: .string)
                }
                if !account.isDefault {
                    Divider()
                    Button("Remove…", role: .destructive) { confirmRemove = true }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .frame(width: 28)
        }
    }

    private var syncText: String {
        switch state.status {
        case .fresh(let at): return "Updated \(UsageFormat.age(at, now: model.now))"
        case .stale(let at, _): return "Stale · as of \(UsageFormat.age(at, now: model.now))"
        case .rateLimited(let until): return "Rate limited · retry \(UsageFormat.age(until, now: model.now).replacingOccurrences(of: " ago", with: ""))"
        case .offline(let last): return "Offline" + (last.map { " · last \(UsageFormat.age($0, now: model.now))" } ?? "")
        default: return state.status.shortLabel
        }
    }

    private var renameSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Rename account").font(.headline)
            TextField("Name", text: $newName).textFieldStyle(.roundedBorder).frame(width: 280)
            TextField("Menu bar label (blank = \(Account.initials(of: newName, provider: account.provider)))", text: $newShortLabel)
                .textFieldStyle(.roundedBorder).frame(width: 280)
                .onChange(of: newShortLabel) { _, v in if v.count > 4 { newShortLabel = String(v.prefix(4)) } }
            Text("Up to 4 characters, shown next to this account's usage in the menu bar.").font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { showRename = false }
                Button("Save") { model.update(account, name: newName, shortLabel: newShortLabel); showRename = false }
                    .buttonStyle(.borderedProminent).disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
    }
}
