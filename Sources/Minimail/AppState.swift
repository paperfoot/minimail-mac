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

    // ── Navigation (persisted across popover show/hide) ────────────────────
    var currentView: CurrentView = .inbox

    // ── Identity ──────────────────────────────────────────────────────────
    var accounts: [Account] = []
    var currentAccount: Account?

    // ── Data ──────────────────────────────────────────────────────────────
    var messages: [Message] = []
    var selectedMessage: Message?
    var totalUnread: Int = 0

    // ── UX state ──────────────────────────────────────────────────────────
    var syncState: SyncState = .idle
    var errorBanner: String?

    // Draft in-progress for the composer. Stays alive across popover shows.
    var composeTo: String = ""
    var composeCc: String = ""
    var composeSubject: String = ""
    var composeBody: String = ""
    var composeReplyTo: Int64?

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
            errorBanner = error.localizedDescription
        }
    }

    func refreshInbox() async {
        guard !accounts.isEmpty else { return }
        syncState = .syncing
        defer { syncState = .idle }
        do {
            let email = currentAccount?.email
            let loaded = try await cli.listInbox(account: email, limit: 50)
            messages = loaded
            let stats = try? await cli.stats(account: email)
            totalUnread = stats?.unread ?? loaded.filter { $0.isUnread }.count
            errorBanner = nil
        } catch {
            errorBanner = error.localizedDescription
            syncState = .error(error.localizedDescription)
        }
    }

    func open(message: Message) async {
        selectedMessage = message
        currentView = .reader(message.id)
        // Fire-and-forget mark-as-read.
        if message.isUnread {
            Task { [id = message.id] in
                try? await cli.markRead(ids: [id])
                await refreshInbox()
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
        guard !composeTo.trimmingCharacters(in: .whitespaces).isEmpty else {
            errorBanner = "Recipient required"
            return false
        }
        let to = composeTo.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        let cc = composeCc.isEmpty ? [] : composeCc.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
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
            await refreshInbox()
            return true
        } catch {
            errorBanner = error.localizedDescription
            return false
        }
    }
}
