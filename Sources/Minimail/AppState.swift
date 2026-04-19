import Foundation
import Observation

@MainActor
@Observable
final class AppState {
    enum CurrentView: Hashable {
        case inbox
        case reader(Int64)
        case compose(Int64?) // optional reply-to message id
        case accountSwitcher
        case needsInstall
    }

    enum SyncState: Equatable {
        case idle
        case syncing
        case error(String)
    }

    enum Folder: String, Hashable, CaseIterable {
        case inbox = "Inbox"
        case sent = "Sent"
        case archived = "Archived"
    }

    // ── Navigation (persisted across popover show/hide) ────────────────────
    var currentView: CurrentView = .inbox
    var currentFolder: Folder = .inbox

    // ── Identity ──────────────────────────────────────────────────────────
    var accounts: [Account] = []
    var currentAccount: Account?

    // ── Data ──────────────────────────────────────────────────────────────
    var messages: [Message] = []
    var selectedMessage: Message?
    var totalUnread: Int = 0
    var searchQuery: String = ""
    var focusedRowIndex: Int = -1

    // ── UX state ──────────────────────────────────────────────────────────
    var syncState: SyncState = .idle
    var inboxError: String?   // scoped to inbox view
    var composeError: String? // scoped to compose view

    // Draft in-progress for the composer. Stays alive across popover shows.
    var composeTo: String = ""
    var composeCc: String = ""
    var composeSubject: String = ""
    var composeBody: String = ""
    var composeReplyTo: Int64?

    // Visible messages = messages filtered by folder + search.
    var visibleMessages: [Message] {
        let base: [Message]
        switch currentFolder {
        case .inbox:
            base = messages.filter { $0.direction == "received" && !$0.isArchived }
        case .sent:
            base = messages.filter { $0.direction == "sent" }
        case .archived:
            base = messages.filter { $0.isArchived }
        }
        guard !searchQuery.trimmingCharacters(in: .whitespaces).isEmpty else { return base }
        let q = searchQuery.lowercased()
        return base.filter { msg in
            (msg.subject ?? "").lowercased().contains(q) ||
            msg.from_addr.lowercased().contains(q)
        }
    }

    private let cli = EmailCLI.shared

    /// Called once at app launch.
    func bootstrap() async {
        if await cli.locate() == nil {
            currentView = .needsInstall
            return
        }
        await refreshAccounts()
        await refreshInbox()
    }

    func refreshAccounts() async {
        do {
            let loaded = try await cli.listAccounts()
            accounts = loaded
            if currentAccount == nil {
                currentAccount = loaded.first(where: { $0.is_default == true }) ?? loaded.first
            }
        } catch {
            inboxError = error.localizedDescription
        }
    }

    /// Refresh the inbox. Set `pull: true` to hit Resend first (fetch new mail),
    /// which is what the user expects when clicking the refresh button.
    /// Cheap re-renders (e.g. after mark-read) pass `pull: false`.
    func refreshInbox(pull: Bool = true) async {
        guard !accounts.isEmpty else { return }
        syncState = .syncing
        defer { syncState = .idle }
        do {
            let email = currentAccount?.email
            if pull {
                try await cli.sync(account: email)
            }
            async let inbox = cli.listInbox(account: email, archived: false, limit: 100)
            async let arch = cli.listInbox(account: email, archived: true, limit: 100)
            let (listA, listB) = try await (inbox, arch)
            // Dedup by id in case both lists include an item.
            var seen = Set<Int64>()
            messages = (listA + listB).filter { seen.insert($0.id).inserted }
            let stats = try? await cli.stats(account: email)
            totalUnread = stats?.unread ?? messages.filter { $0.isUnread }.count
            inboxError = nil
        } catch {
            inboxError = error.localizedDescription
            syncState = .error(error.localizedDescription)
        }
    }

    func archive(message: Message) async {
        do {
            try await cli.archive(ids: [message.id])
            currentView = .inbox
            selectedMessage = nil
            await refreshInbox(pull: false)
        } catch {
            inboxError = error.localizedDescription
        }
    }

    func markAllRead() async {
        let ids = messages.filter { $0.isUnread }.map(\.id)
        guard !ids.isEmpty else { return }
        do {
            try await cli.markRead(ids: ids)
            await refreshInbox(pull: false)
        } catch {
            inboxError = error.localizedDescription
        }
    }

    func open(message: Message) async {
        selectedMessage = message
        currentView = .reader(message.id)
        // Fire-and-forget mark-as-read (local DB only; no need to re-pull).
        if message.isUnread {
            Task { [id = message.id] in
                try? await cli.markRead(ids: [id])
                await refreshInbox(pull: false)
            }
        }
    }

    func back() {
        currentView = .inbox
    }

    func startCompose(replyTo: Message? = nil) {
        composeReplyTo = replyTo?.id
        composeTo = replyTo?.from_addr ?? ""
        composeCc = ""
        composeSubject = replyTo.flatMap { msg in
            let subject = msg.subject ?? ""
            return subject.lowercased().hasPrefix("re:") ? subject : "Re: \(subject)"
        } ?? ""
        composeBody = ""
        currentView = .compose(replyTo?.id)
    }

    func clearCompose() {
        composeTo = ""
        composeCc = ""
        composeSubject = ""
        composeBody = ""
        composeReplyTo = nil
    }

    func send() async -> Bool {
        composeError = nil
        let to = composeTo
            .split(whereSeparator: { ",; ".contains($0) })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let cc = composeCc
            .split(whereSeparator: { ",; ".contains($0) })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !to.isEmpty else {
            composeError = "Add at least one recipient"
            return false
        }
        do {
            try await cli.send(
                from: currentAccount?.email,
                to: to,
                cc: cc,
                bcc: [],
                subject: composeSubject,
                text: composeBody.isEmpty ? nil : composeBody,
                html: nil
            )
            clearCompose()
            currentView = .inbox
            await refreshInbox(pull: false)
            return true
        } catch {
            composeError = error.localizedDescription
            return false
        }
    }
}

// A simple RFC-5322-ish email validator. Good enough for chip recognition.
extension String {
    var looksLikeEmail: Bool {
        let pattern = #"^[A-Z0-9a-z._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}$"#
        return self.range(of: pattern, options: .regularExpression) != nil
    }
}
