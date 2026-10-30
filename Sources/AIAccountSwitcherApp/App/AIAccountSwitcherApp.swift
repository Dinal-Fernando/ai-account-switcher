import SwiftUI
import SwitcherCore
import SwitcherMac

/// Lives in its own View so `@Observable` tracking re-renders the icon when usage changes.
struct MenuBarLabel: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        HStack(spacing: 4) {
            Image(nsImage: model.menuBarIcon)
            if let text = model.menuBarText { Text(text) }
        }
    }
}

@main
struct AIAccountSwitcherApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model: AppModel

    init() {
        let runtime = SwitcherRuntime(captureLoginShell: true)
        let model = AppModel(runtime: runtime)
        _model = State(initialValue: model)
        AppDelegate.sharedModel = model
    }

    var body: some Scene {
        Window("AI Account Switcher", id: "dashboard") {
            DashboardView()
                .environment(model)
                .onAppear { model.start() }
        }
        .defaultSize(width: 980, height: 680)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .toolbar) {
                Button("Refresh Usage") { Task { await model.manualRefresh() } }.keyboardShortcut("r", modifiers: .command)
            }
        }

        MenuBarExtra {
            MenuBarView()
                .environment(model)
                .onAppear { model.start() }
        } label: {
            MenuBarLabel().environment(model)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}
