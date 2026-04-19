import Foundation
import Observation

// ── Substates ─────────────────────────────────────────────────────────────
//
// One lifetime-owned AppState (Codex-approved) but split internally into
// focused @Observable children so each view can bind to the narrowest surface
// it needs. New features (forward, reply-all, attachments, drafts, settings)
// plug into the substate they belong to without touching the others.

@MainActor
@Observable
final class SessionState {
    var accounts: [Account] = []
    var currentAccount: Account?
    var cliPath: String?
}

@MainActor
@Observable
final class InboxState {
    enum Folder: String, Hashable, CaseIterable {
        case inbox = "Inbox"
        case sent = "Sent"
        case drafts = "Drafts"
        case archived = "Archived"
    }

    var messages: [Message] = []
    var currentFolder: Folder = .inbox
    var searchQuery: String = ""
    var focusedRowIndex: Int = -1
    var totalUnread: Int = 0
    var syncState: AppState.SyncState = .idle
    var error: String?
    var lastPullAt: Date?

    func visible() -> [Message] {
        let base: [Message]
        switch currentFolder {
        case .inbox:
            base = messages.filter { $0.direction == "received" && !$0.isArchived }
        case .sent:
            base = messages.filter { $0.direction == "sent" }
        case .drafts:
            base = [] // wired in v0.2 via draft list
        case .archived:
            base = messages.filter { $0.isArchived }
        }
        let q = searchQuery.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return base }
        return base.filter { msg in
            (msg.subject ?? "").lowercased().contains(q) ||
            msg.from_addr.lowercased().contains(q)
        }
    }
}

@MainActor
@Observable
final class ReaderState {
    var loaded: Message?
    var error: String?
    var isLoading: Bool = false
    /// Task owning the currently-running fetch so we can cancel on navigation.
    var inflight: Task<Void, Never>?
}

@MainActor
@Observable
final class ComposeState {
    var to: String = ""
    var cc: String = ""
    var bcc: String = ""
    var subject: String = ""
    var body: String = ""
    var replyToID: Int64?
    var forwardingID: Int64?
    var replyAll: Bool = false
    var isSending: Bool = false
    var error: String?

    func clear() {
        to = ""; cc = ""; bcc = ""; subject = ""; body = ""
        replyToID = nil; forwardingID = nil; replyAll = false; error = nil
    }
}

@MainActor
@Observable
final class RouterState {
    enum View: Hashable {
        case inbox
        case reader(Int64)
        case compose(Int64?)
        case accountSwitcher
        case settings
        case needsInstall
    }
    var currentView: View = .inbox
}

// ── Root app state ────────────────────────────────────────────────────────

@MainActor
@Observable
final class AppState {
    enum SyncState: Equatable {
        case idle
        case syncing
        case error(String)
    }

    let session = SessionState()
    let inbox = InboxState()
    let reader = ReaderState()
    let compose = ComposeState()
    let router = RouterState()

    // Convenience at the root for things that cross concerns.
    var totalUnread: Int { inbox.totalUnread }

    private let cli = EmailCLI.shared

    // ── Lifecycle ─────────────────────────────────────────────────────────

    func bootstrap() async {
        if await cli.locate() == nil {
            router.currentView = .needsInstall
            return
        }
        session.cliPath = await cli.locate()
        await refreshAccounts()
        await refreshInbox(pull: false)
    }

    func refreshAccounts() async {
        do {
            let loaded = try await cli.listAccounts()
            session.accounts = loaded
            if session.currentAccount == nil {
                session.currentAccount = loaded.first(where: { $0.is_default == true }) ?? loaded.first
            }
        } catch {
            inbox.error = error.localizedDescription
        }
    }

    /// `pull: true` hits Resend first for new mail, then re-reads the local DB.
    /// `pull: false` is a local-only re-render (after mark-read, archive, send).
    func refreshInbox(pull: Bool = true) async {
        guard !session.accounts.isEmpty else { return }
        inbox.syncState = .syncing
        defer { inbox.syncState = .idle }

        do {
            let email = session.currentAccount?.email
            if pull {
                try await cli.sync(account: email)
                inbox.lastPullAt = Date()
            }
            async let listA = cli.listInbox(account: email, archived: false, limit: 100)
            async let listB = cli.listInbox(account: email, archived: true, limit: 100)
            let (a, b) = try await (listA, listB)
            var seen = Set<Int64>()
            inbox.messages = (a + b).filter { seen.insert($0.id).inserted }
            let stats = try? await cli.stats(account: email)
            inbox.totalUnread = stats?.unread ?? inbox.messages.filter(\.isUnread).count
            inbox.error = nil
        } catch {
            inbox.error = error.localizedDescription
            inbox.syncState = .error(error.localizedDescription)
        }
    }

    // ── Selection / navigation ────────────────────────────────────────────

    func open(message: Message) {
        reader.loaded = message     // show cached list-row version immediately
        reader.error = nil
        router.currentView = .reader(message.id)
        loadFullMessage(id: message.id)

        if message.isUnread {
            Task { [id = message.id] in
                try? await cli.markRead(ids: [id])
                await self.refreshInbox(pull: false)
            }
        }
    }

    private func loadFullMessage(id: Int64) {
        reader.inflight?.cancel()
        reader.isLoading = true
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                let detail = try await self.cli.readMessage(id: id, markRead: false)
                if !Task.isCancelled {
                    self.reader.loaded = detail
                    self.reader.error = nil
                }
            } catch {
                if !Task.isCancelled {
                    self.reader.error = error.localizedDescription
                }
            }
            if !Task.isCancelled {
                self.reader.isLoading = false
            }
        }
        reader.inflight = task
    }

    func back() {
        reader.inflight?.cancel()
        router.currentView = .inbox
    }

    func openAccountSwitcher() {
        router.currentView = .accountSwitcher
    }

    // ── Message actions ───────────────────────────────────────────────────

    func archive(message: Message) async {
        do {
            try await cli.archive(ids: [message.id])
            router.currentView = .inbox
            await refreshInbox(pull: false)
        } catch {
            inbox.error = error.localizedDescription
        }
    }

    func markAllRead() async {
        let ids = inbox.messages.filter(\.isUnread).map(\.id)
        guard !ids.isEmpty else { return }
        do {
            try await cli.markRead(ids: ids)
            await refreshInbox(pull: false)
        } catch {
            inbox.error = error.localizedDescription
        }
    }

    // ── Compose ──────────────────────────────────────────────────────────

    func startCompose(replyTo: Message? = nil, replyAll: Bool = false) {
        compose.clear()
        compose.replyToID = replyTo?.id
        compose.replyAll = replyAll
        if let msg = replyTo {
            compose.to = msg.from_addr
            let sub = msg.subject ?? ""
            compose.subject = sub.lowercased().hasPrefix("re:") ? sub : "Re: \(sub)"
        }
        router.currentView = .compose(replyTo?.id)
    }

    func startForward(of message: Message) {
        compose.clear()
        compose.forwardingID = message.id
        let sub = message.subject ?? ""
        compose.subject = sub.lowercased().hasPrefix("fwd:") ? sub : "Fwd: \(sub)"
        compose.body = "\n\n-------- Forwarded message --------\nFrom: \(message.from_addr)\nSubject: \(sub)\n\n\(message.text_body ?? "")"
        router.currentView = .compose(nil)
    }

    func send() async -> Bool {
        compose.error = nil
        let to = splitAddresses(compose.to)
        let cc = splitAddresses(compose.cc)
        let bcc = splitAddresses(compose.bcc)
        guard !to.isEmpty else {
            compose.error = "Add at least one recipient"
            return false
        }
        compose.isSending = true
        defer { compose.isSending = false }

        do {
            try await cli.send(
                from: session.currentAccount?.email,
                to: to,
                cc: cc,
                bcc: bcc,
                subject: compose.subject,
                text: compose.body.isEmpty ? nil : compose.body,
                html: nil,
                replyToMessageID: compose.replyToID
            )
            compose.clear()
            router.currentView = .inbox
            await refreshInbox(pull: false)
            return true
        } catch {
            compose.error = error.localizedDescription
            return false
        }
    }

    private func splitAddresses(_ raw: String) -> [String] {
        raw
            .split(whereSeparator: { ",; \n\t".contains($0) })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}

extension String {
    var looksLikeEmail: Bool {
        let pattern = #"^[A-Z0-9a-z._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}$"#
        return self.range(of: pattern, options: .regularExpression) != nil
    }
}
