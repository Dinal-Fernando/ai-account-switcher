import SwiftUI
import SwitcherCore

/// Shows exactly which executable, profile and identity each CLI will use, plus compatibility warnings.
struct DiagnosticsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button {
                    Task { await model.runDoctor() }
                } label: {
                    if model.isRunningDoctor { ProgressView().controlSize(.small) } else { Label("Run diagnostics", systemImage: "stethoscope") }
                }
                .disabled(model.isRunningDoctor)
                Spacer()
                if let report = model.doctorReport {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(report.text, forType: .string)
                    } label: { Label("Copy report", systemImage: "doc.on.doc") }
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([model.runtime.paths.logFile])
                    } label: { Label("Show log", systemImage: "doc.text.magnifyingglass") }
                }
            }
            if let report = model.doctorReport {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(report.items) { item in
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: icon(item.level)).foregroundStyle(color(item.level))
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(item.title).font(.callout).textSelection(.enabled)
                                    if !item.detail.isEmpty { Text(item.detail).font(.caption).foregroundStyle(.secondary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                Text("Runs the same checks as aiswitch doctor: state directory, wrappers, recorded executables, login-shell PATH resolution, selected profiles, a wrapper dry-run, environment overrides, Keychain item names, CLI versions, compatibility, and a live sign-in check per active account.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
        }
        .padding()
    }

    private func icon(_ level: DoctorItem.Level) -> String {
        switch level {
        case .ok: return "checkmark.circle.fill"
        case .info: return "info.circle"
        case .warning: return "exclamationmark.triangle.fill"
        case .failure: return "xmark.octagon.fill"
        }
    }

    private func color(_ level: DoctorItem.Level) -> Color {
        switch level {
        case .ok: return .green
        case .info: return .secondary
        case .warning: return .orange
        case .failure: return .red
        }
    }
}
