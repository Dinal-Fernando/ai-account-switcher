import AppKit
import SwiftUI
import SwitcherCore

/// Conversations stored by one account, with "Resume here", "Duplicate to another account" and "Resume by ID".
/// A duplicate is an independent copy of the transcript; nothing is shared between profiles.
@MainActor
struct SessionsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let account: Account

    @State private var sessions: [CLISession] = []
    @State private var loading = true
    @State private var query = ""
    @State private var resumeId = ""
    @State private var pendingResume: PendingResume?
    @State private var message: String?

    struct PendingResume: Identifiable {
        let id = UUID()
        let session: CLISession
        let target: Account
    }

    private var filtered: [CLISession] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return sessions }
        return sessions.filter { $0.title.lowercased().contains(q) || $0.cwd.lowercased().contains(q) || $0.id.lowercased().hasPrefix(q) }
    }

    private var otherAccounts: [Account] { model.accounts(for: account.provider).filter { $0.key != account.key } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Sessions · \(account.name)").font(.title3.weight(.semibold))
                    Text("Transcripts in \(model.profilePath(account))").font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
                }
                Spacer()
                Button { load() } label: { Label("Reload", systemImage: "arrow.clockwise") }.controlSize(.small)
                Button("Close") { dismiss() }
            }
            TextField("Filter by title, folder or session id", text: $query).textFieldStyle(.roundedBorder)
            if loading {
                HStack { ProgressView().controlSize(.small); Text("Reading transcripts…").font(.caption) }
            } else if filtered.isEmpty {
                Text(sessions.isEmpty ? "No conversations recorded for this account yet." : "No match.").font(.caption).foregroundStyle(.secondary)
            }
            List(filtered) { session in
                row(session)
            }
            .frame(minHeight: 260)
            Divider()
            HStack {
                TextField("Resume by session id (from /status or another account)", text: $resumeId).textFieldStyle(.roundedBorder)
                Button("Find & resume") { resumeById() }.disabled(resumeId.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if let message { Text(message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
            Text("Resume opens a Terminal bound to the chosen account in the conversation's original folder and resumes the conversation there. Duplicating copies only that one transcript; the resumed chat runs with the target profile's settings and tools, and re-sending the context uses that account's quota.")
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .frame(width: 720, height: 560)
        .onAppear { load() }
        .alert("Transcript copied", isPresented: Binding(get: { pendingResume != nil }, set: { if !$0 { pendingResume = nil } }), presenting: pendingResume) { pending in
            Button("Resume in \(pending.target.name)") { model.resumeSession(pending.session, in: pending.target); pendingResume = nil }
            Button("Later", role: .cancel) { pendingResume = nil }
        } message: { pending in
            Text("Session \(pending.session.id) is now available in '\(pending.target.name)'. Resume it there now? The window will be bound to that account.")
        }
    }

    private func row(_ session: CLISession) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(session.title).font(.callout).lineLimit(2)
                HStack(spacing: 8) {
                    Label(session.folderName, systemImage: "folder").help(session.cwd)
                    Text(UsageFormat.age(session.modifiedAt, now: model.now))
                    Text("\(session.messageCount) msgs")
                    Text(ByteCountFormatter.string(fromByteCount: Int64(session.sizeBytes), countStyle: .file))
                    Text(String(session.id.prefix(8)) + "…").monospaced()
                }
                .font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Resume here") { model.resumeSession(session, in: account) }.controlSize(.small)
            Menu {
                Button("Copy session id") { copy(session.id) }
                Button("Reveal transcript in Finder") { NSWorkspace.shared.activateFileViewerSelecting([session.fileURL]) }
                if !otherAccounts.isEmpty {
                    Divider()
                    ForEach(otherAccounts) { target in
                        Button("Duplicate to \(target.name)…") { duplicate(session, to: target) }
                    }
                }
            } label: { Image(systemName: "ellipsis.circle") }
            .menuStyle(.borderlessButton).frame(width: 28)
        }
        .padding(.vertical, 2)
    }

    private func load() {
        loading = true
        let acct = account
        Task {
            let list = await model.sessions(acct)
            sessions = list
            loading = false
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        message = "Copied \(text)"
    }

    private func duplicate(_ session: CLISession, to target: Account) {
        Task {
            if let copy = await model.duplicateSession(session, to: target) {
                pendingResume = PendingResume(session: copy, target: target)
            }
        }
    }

    private func resumeById() {
        let id = resumeId.trimmingCharacters(in: .whitespaces)
        Task {
            if let here = sessions.first(where: { $0.id.lowercased() == id.lowercased() }) {
                model.resumeSession(here, in: account)
                return
            }
            if let elsewhere = await model.findSession(id: id, provider: account.provider) {
                let owner = model.accounts.first { $0.key == elsewhere.key }?.name ?? elsewhere.accountId
                message = "Found in '\(owner)'. Copying it into '\(account.name)'…"
                if let copy = await model.duplicateSession(elsewhere, to: account) {
                    pendingResume = PendingResume(session: copy, target: account)
                    load()
                }
            } else {
                message = "No transcript with id \(id) in any \(account.provider.displayName) profile."
            }
        }
    }
}
