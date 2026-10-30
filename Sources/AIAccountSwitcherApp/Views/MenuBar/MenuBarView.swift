import SwiftUI
import SwitcherCore

/// Menu bar popover: active account per provider with 5-hour / weekly usage and a real account switcher.
@MainActor struct MenuBarView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Provider.allCases) { provider in
                section(provider)
                if provider != Provider.allCases.last { Divider() }
            }
            Divider()
            HStack {
                Button { openWindow(id: "dashboard"); NSApp.activate(ignoringOtherApps: true) } label: { Label("Dashboard", systemImage: "rectangle.grid.2x2") }
                Button { Task { await model.manualRefresh() } } label: {
                    if model.isRefreshing { ProgressView().controlSize(.small) } else { Label("Refresh", systemImage: "arrow.clockwise") }
                }
                Button { openSettings(); NSApp.activate(ignoringOtherApps: true) } label: { Label("Settings", systemImage: "gearshape") }
                Spacer()
                Button { NSApp.terminate(nil) } label: { Label("Quit", systemImage: "power") }
            }
            .controlSize(.small)
            .labelStyle(.titleAndIcon)
        }
        .padding(14)
        .frame(width: 340)
        .onAppear { Task { await model.menuBarOpened() } }
    }

    @ViewBuilder private func section(_ provider: Provider) -> some View {
        let active = model.activeAccount(for: provider)
        let snap = active.flatMap { model.usageState($0).effectiveSnapshot }
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("\(provider.displayName) — Active").font(.subheadline.weight(.semibold))
                Spacer()
                Menu {
                    ForEach(model.accounts(for: provider)) { account in
                        Button {
                            Task { await model.setActive(account) }
                        } label: {
                            let pct = model.menuBarPercent(model.usageState(account).effectiveSnapshot).map { " · \(Int($0.rounded()))%" } ?? ""
                            if model.activeIds[provider] == account.id {
                                Label("\(account.name)\(pct)", systemImage: "checkmark")
                            } else {
                                Text("\(account.name)\(pct)")
                            }
                        }
                    }
                } label: {
                    Label("Switch account", systemImage: "arrow.triangle.swap")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            if let active {
                HStack(spacing: 12) {
                    if model.settings.menuBarWindow == .weekly {
                        UsageRingView(percent: snap?.weekly?.usedPercent, label: "Weekly", size: 56, lineWidth: 6, showRemaining: model.settings.showRemaining)
                        UsageRingView(percent: snap?.fiveHour?.usedPercent, label: "5-hour", size: 56, lineWidth: 6, showRemaining: model.settings.showRemaining)
                    } else {
                        UsageRingView(percent: snap?.fiveHour?.usedPercent, label: "5-hour", size: 56, lineWidth: 6, showRemaining: model.settings.showRemaining)
                        UsageRingView(percent: snap?.weekly?.usedPercent, label: "Weekly", size: 56, lineWidth: 6, showRemaining: model.settings.showRemaining)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(active.name).font(.headline).lineLimit(1)
                        if let id = active.identity?.email { Text(id).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
                        if let five = snap?.fiveHour { Text("5h: \(UsageFormat.countdown(five, now: model.now))").font(.caption2).monospacedDigit() }
                        if let week = snap?.weekly { Text("Week: \(UsageFormat.countdown(week, now: model.now))").font(.caption2).monospacedDigit() }
                        switch model.activeState(active) {
                        case .active: Label("Verified", systemImage: "checkmark.circle.fill").font(.caption2).foregroundStyle(.green)
                        case .selectedNeedsLogin: Label("Not signed in", systemImage: "exclamationmark.triangle.fill").font(.caption2).foregroundStyle(.orange)
                        case .selectedWrapperInactive: Label("Wrapper inactive", systemImage: "exclamationmark.triangle.fill").font(.caption2).foregroundStyle(.orange)
                        default: Text(model.usageState(active).status.shortLabel).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 0)
                }
            } else {
                Text("No account").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
