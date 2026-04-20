import AppKit
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
        case starred = "Starred"
        case snoozed = "Snoozed"
        case sent = "Sent"
        case drafts = "Drafts"
        case archived = "Archived"
    }

    var messages: [Message] = []
    var snoozedMessages: [Message] = []
    var drafts: [Draft] = []
    var currentFolder: Folder = .inbox
    var searchQuery: String = ""
    var focusedRowIndex: Int = -1
    var totalUnread: Int = 0
    var syncState: AppState.SyncState = .idle
    var error: String?
    var lastPullAt: Date?
    /// Multi-select (Shift- or ⌘-click to toggle). Non-empty selection
    /// surfaces the bulk-action bar at the top of the list.
    var selection: Set<Int64> = []

    func visible() -> [Message] {
        let base: [Message]
        switch currentFolder {
        case .inbox:
            // Hide currently-snoozed messages from the main inbox.
            base = messages.filter {
                $0.direction == "received" && !$0.isArchived && !$0.isSnoozed
            }
        case .starred:
            base = messages.filter { $0.isStarred && !$0.isArchived }
        case .snoozed:
            base = snoozedMessages.filter { $0.isSnoozed }
        case .sent:
            base = messages.filter { $0.direction == "sent" }
        case .drafts:
            base = []
        case .archived:
            base = messages.filter { $0.isArchived }
        }
        let q = searchQuery.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return base }
        return base.filter { msg in
            (msg.subject ?? "").lowercased().contains(q) ||
            msg.from_addr.lowercased().contains(q) ||
            (msg.text_preview ?? "").lowercased().contains(q)
        }
    }

    func visibleDrafts() -> [Draft] {
        let q = searchQuery.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return drafts }
        return drafts.filter { d in
            (d.subject ?? "").lowercased().contains(q) ||
            (d.to ?? []).joined(separator: " ").lowercased().contains(q)
        }
    }

    func clearSelection() { selection.removeAll() }
    func toggle(_ id: Int64) {
        if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
    }
}

@MainActor
@Observable
final class ReaderState {
    var loaded: Message?
    var error: String?
    var isLoading: Bool = false
    var attachments: [Attachment] = []
    /// Task owning the currently-running fetch so we can cancel on navigation.
    var inflight: Task<Void, Never>?
    /// All messages in the current thread, oldest → newest. Contains at least
    /// the currently-loaded message; >1 when the CLI finds related headers.
    var thread: [Message] = []
    /// IDs of thread messages the user has manually expanded in the reader.
    /// The currently-loaded message is always treated as expanded.
    var expandedThreadIDs: Set<Int64> = []
    /// Non-nil = delete confirmation dialog is up for this message id.
    var pendingDeleteConfirm: Int64?
}

@MainActor
@Observable
final class ComposeState {
    var to: String = ""
    var cc: String = ""
    var bcc: String = ""
    var subject: String = ""
    /// Rich-text backing store for the body editor. Plain-text getters below
    /// read through `.string` for autosave / contact parsing; `bodyHTML`
    /// turns it into sendable HTML at send time.
    var bodyAttributed: NSAttributedString = NSAttributedString()
    /// Plain-text passthrough. Writing replaces the attributed string with a
    /// plain run so callers that only deal in strings (Forward / Reply
    /// seeding) still work.
    var body: String {
        get { bodyAttributed.string }
        set {
            bodyAttributed = NSAttributedString(string: newValue, attributes: [
                .font: NSFont.systemFont(ofSize: 13),
                .foregroundColor: NSColor.labelColor,
            ])
        }
    }
    /// HTML serialization of the attributed body. Nil when the body has no
    /// formatting beyond the default run (so the CLI sends text only).
    var bodyHTML: String? {
        guard bodyAttributed.length > 0, bodyContainsFormatting else { return nil }
        let range = NSRange(location: 0, length: bodyAttributed.length)
        let attrs: [NSAttributedString.DocumentAttributeKey: Any] = [
            .documentType: NSAttributedString.DocumentType.html,
            .characterEncoding: String.Encoding.utf8.rawValue,
        ]
        guard let data = try? bodyAttributed.data(from: range, documentAttributes: attrs),
              let html = String(data: data, encoding: .utf8) else {
            return nil
        }
        return html
    }
    /// True when at least one run has bold / italic / underline / link /
    /// non-default colour — worth emitting HTML for. Avoids wrapping pure
    /// plain-text messages in gnarly HTML boilerplate.
    private var bodyContainsFormatting: Bool {
        var found = false
        let full = NSRange(location: 0, length: bodyAttributed.length)
        bodyAttributed.enumerateAttributes(in: full, options: []) { attrs, _, stop in
            if attrs[.link] != nil { found = true; stop.pointee = true; return }
            if attrs[.underlineStyle] != nil { found = true; stop.pointee = true; return }
            if let font = attrs[.font] as? NSFont {
                let traits = NSFontManager.shared.traits(of: font)
                if traits.contains(.boldFontMask) || traits.contains(.italicFontMask) {
                    found = true; stop.pointee = true; return
                }
            }
        }
        return found
    }
    var attachments: [URL] = []
    var replyToID: Int64?
    var forwardingID: Int64?
    var replyAll: Bool = false
    var isSending: Bool = false
    var error: String?

    /// The backing draft row we're editing — created lazily on first autosave,
    /// or populated when the user taps a row in the Drafts folder. On send
    /// or explicit discard we delete it.
    var editingDraftID: String?
    var lastAutosaveAt: Date?
    var autosaveTask: Task<Void, Never>?
    /// Guard against concurrent autosave runs that would double-create drafts.
    var isAutosaving: Bool = false

    func clear() {
        autosaveTask?.cancel()
        autosaveTask = nil
        to = ""; cc = ""; bcc = ""; subject = ""
        bodyAttributed = NSAttributedString()
        attachments = []
        replyToID = nil; forwardingID = nil; replyAll = false; error = nil
        editingDraftID = nil; lastAutosaveAt = nil
    }

    /// Anything worth persisting?
    var hasContent: Bool {
        !to.trimmingCharacters(in: .whitespaces).isEmpty
        || !subject.trimmingCharacters(in: .whitespaces).isEmpty
        || !body.trimmingCharacters(in: .whitespaces).isEmpty
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
        case onboarding
    }
    var currentView: View = .inbox
}

// ── Root app state ────────────────────────────────────────────────────────

/// A send that has been queued to run after a short delay so the user has a
/// chance to hit Undo (Gmail/Superhuman pattern). Captures the full payload
/// plus the metadata needed to restore the compose view on undo.
struct PendingSend: Sendable {
    let from: String?
    let to: [String]
    let cc: [String]
    let bcc: [String]
    let subject: String
    let text: String?
    let html: String?
    let attachments: [URL]
    let replyToMessageID: Int64?
    let originalDraftID: String?
    let queuedAt: Date
    let deadline: Date
}

/// Transient status flash shown briefly after a send / archive / delete / etc.
enum TransientStatus: Equatable {
    case sent
    /// Messages archived — user can undo within the 10s window. IDs let us
    /// restore them.
    case archived(ids: [Int64], deadline: Date)
    /// Messages deleted — undo within window restores via the `trashed_ids`
    /// remembered by the delete call (we fake the undo by re-inserting
    /// nothing and relying on the user to re-sync; for now we just let the
    /// user know it happened).
    case deleted(count: Int)
    /// One-off confirmation banner for miscellaneous actions (star, snooze).
    case info(String)
}

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

    /// Queue snapshot for the in-flight undoable send. View layer watches this
    /// to render the countdown toast; nil = no pending send.
    var pendingSend: PendingSend?
    private var pendingSendTask: Task<Void, Never>?
    /// Brief "Sent" flash after a queued send completes successfully.
    var transientStatus: TransientStatus?
    private var transientClearTask: Task<Void, Never>?

    /// Undo window (seconds). Matches Gmail's max.
    static let undoSendWindow: TimeInterval = 10

    /// Keyboard-help sheet visibility — `?` anywhere opens it.
    var showKeyboardHelp: Bool = false

    /// Cache of every address Minimail has seen in `from`, `to`, `cc`, `bcc`
    /// across stored messages. Rebuilt from `inbox.messages` on each refresh.
    /// Used by EmailTokenField for recipient autocomplete.
    var contactIndex: [String] = []

    /// Last archived IDs, for the "Undo" action on the archive toast.
    private var lastArchivedIDs: [Int64] = []

    private let cli = EmailCLI.shared

    // ── Lifecycle ─────────────────────────────────────────────────────────

    func bootstrap() async {
        if await cli.locate() == nil {
            router.currentView = .needsInstall
            return
        }
        session.cliPath = await cli.locate()
        await refreshAccounts()
        if session.accounts.isEmpty {
            router.currentView = .onboarding
            return
        }
        await refreshInbox(pull: false)
        // Prefetch drafts so the Drafts tab doesn't flash empty-state when tapped.
        await refreshDrafts()
    }

    // ── Reader navigation within the list ─────────────────────────────────

    func openNext() {
        let list = inbox.visible()
        guard !list.isEmpty else { return }
        let currentID = reader.loaded?.id
        let idx = list.firstIndex { $0.id == currentID } ?? -1
        let next = list.index(after: idx)
        guard next < list.count else { return }
        inbox.focusedRowIndex = next
        open(message: list[next])
    }

    func openPrevious() {
        let list = inbox.visible()
        guard !list.isEmpty else { return }
        let currentID = reader.loaded?.id
        let idx = list.firstIndex { $0.id == currentID } ?? list.count
        let prev = idx - 1
        guard prev >= 0 else { return }
        inbox.focusedRowIndex = prev
        open(message: list[prev])
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
            async let snoozedList = cli.listInbox(account: email, snoozed: true, limit: 100)
            let (a, b, c) = try await (listA, listB, snoozedList)
            var seen = Set<Int64>()
            inbox.messages = (a + b).filter { seen.insert($0.id).inserted }
            inbox.snoozedMessages = c
            let stats = try? await cli.stats(account: email)
            inbox.totalUnread = stats?.unread ?? inbox.messages.filter(\.isUnread).count
            inbox.error = nil
            rebuildContactIndex()
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
        reader.attachments = []
        reader.thread = []
        reader.expandedThreadIDs = [id]
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
            // Attachments: best-effort, non-blocking for the body render.
            if !Task.isCancelled,
               let list = try? await self.cli.listAttachments(messageID: id),
               !Task.isCancelled {
                self.reader.attachments = list
            }
            // Thread relatives: also best-effort. The CLI returns [seed] when
            // there are no related headers, so we only swap in real multi-
            // message threads to avoid noisy "1 of 1" chrome.
            if !Task.isCancelled,
               let thread = try? await self.cli.readThread(id: id),
               !Task.isCancelled,
               thread.count > 1 {
                self.reader.thread = thread
            }
        }
        reader.inflight = task
    }

    /// Load the full body for a thread sibling (user tapped a collapsed row).
    func expandThreadMessage(_ id: Int64) async {
        guard !reader.expandedThreadIDs.contains(id) else { return }
        reader.expandedThreadIDs.insert(id)
        // If the summary version is already in `thread`, just fetch the body
        // and splice it in so the view updates.
        guard let idx = reader.thread.firstIndex(where: { $0.id == id }) else { return }
        if let full = try? await cli.readMessage(id: id, markRead: false) {
            reader.thread[idx] = full
        }
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
        await archive(ids: [message.id], navigateBack: true)
    }

    /// Archive any list of messages. Captures the IDs so an Undo toast can
    /// unarchive within the next 10s. Reusable for single-row archive (from
    /// reader) and bulk archive (from the selection bar).
    func archive(ids: [Int64], navigateBack: Bool = false) async {
        guard !ids.isEmpty else { return }
        do {
            try await cli.archive(ids: ids)
            lastArchivedIDs = ids
            if navigateBack, case .reader = router.currentView {
                router.currentView = .inbox
            }
            inbox.clearSelection()
            await refreshInbox(pull: false)
            flashStatus(.archived(ids: ids, deadline: Date().addingTimeInterval(Self.undoSendWindow)))
        } catch {
            inbox.error = error.localizedDescription
        }
    }

    /// Undo for the archive toast — fires a one-shot unarchive for the last
    /// captured IDs.
    func undoLastArchive() async {
        guard !lastArchivedIDs.isEmpty else { return }
        let ids = lastArchivedIDs
        lastArchivedIDs = []
        transientStatus = nil
        do {
            try await cli.unarchive(ids: ids)
            await refreshInbox(pull: false)
        } catch {
            inbox.error = error.localizedDescription
        }
    }

    // ── Star / Snooze / Unsubscribe ───────────────────────────────────────

    func toggleStar(_ message: Message) async {
        do {
            if message.isStarred {
                try await cli.unstar(ids: [message.id])
            } else {
                try await cli.star(ids: [message.id])
            }
            await refreshInbox(pull: false)
        } catch {
            inbox.error = error.localizedDescription
        }
    }

    func snooze(_ message: Message, until: String) async {
        do {
            try await cli.snooze(ids: [message.id], until: until)
            if case .reader = router.currentView { router.currentView = .inbox }
            await refreshInbox(pull: false)
            flashStatus(.info("Snoozed"))
        } catch {
            inbox.error = error.localizedDescription
        }
    }

    func unsnooze(_ message: Message) async {
        do {
            try await cli.unsnooze(ids: [message.id])
            await refreshInbox(pull: false)
            flashStatus(.info("Back in inbox"))
        } catch {
            inbox.error = error.localizedDescription
        }
    }

    /// Resolve a List-Unsubscribe link via the CLI and open it in the browser.
    /// Returns the URL so the UI can also show it in a confirmation dialog
    /// before opening.
    @discardableResult
    func unsubscribeFrom(_ message: Message) async -> String? {
        do {
            let urlString = try await cli.unsubscribeURL(messageID: message.id)
            if let url = URL(string: urlString) {
                NSWorkspace.shared.open(url)
            }
            flashStatus(.info("Unsubscribe link opened"))
            return urlString
        } catch {
            inbox.error = error.localizedDescription
            return nil
        }
    }

    // ── Bulk actions ──────────────────────────────────────────────────────

    func bulkArchive() async {
        let ids = Array(inbox.selection)
        await archive(ids: ids)
    }

    func bulkMarkRead() async {
        let ids = Array(inbox.selection)
        guard !ids.isEmpty else { return }
        do {
            try await cli.markRead(ids: ids)
            inbox.clearSelection()
            await refreshInbox(pull: false)
        } catch {
            inbox.error = error.localizedDescription
        }
    }

    func bulkDelete() async {
        let ids = Array(inbox.selection)
        guard !ids.isEmpty else { return }
        do {
            try await cli.delete(ids: ids)
            inbox.clearSelection()
            await refreshInbox(pull: false)
            flashStatus(.deleted(count: ids.count))
        } catch {
            inbox.error = error.localizedDescription
        }
    }

    // ── Account quick-switcher ────────────────────────────────────────────

    /// Activate the nth account (1-indexed). Hooked to ⌘1…⌘9 via RootView.
    /// No-op if there's no account at that index.
    func selectAccount(at index: Int) async {
        guard index >= 1, index <= session.accounts.count else { return }
        let acct = session.accounts[index - 1]
        session.currentAccount = acct
        try? await cli.setDefaultAccount(acct.email)
        await refreshInbox(pull: false)
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

    func markUnread(message: Message) async {
        do {
            try await cli.markUnread(ids: [message.id])
            await refreshInbox(pull: false)
        } catch {
            inbox.error = error.localizedDescription
        }
    }

    /// Mark a single message as read. Wraps the CLI so views don't need to
    /// know about the transport — they talk to AppState, AppState talks to
    /// the CLI. Kept alongside markUnread/archive for shape consistency.
    func markRead(message: Message) async {
        do {
            try await cli.markRead(ids: [message.id])
            await refreshInbox(pull: false)
        } catch {
            inbox.error = error.localizedDescription
        }
    }

    func unarchive(message: Message) async {
        do {
            try await cli.unarchive(ids: [message.id])
            await refreshInbox(pull: false)
        } catch {
            inbox.error = error.localizedDescription
        }
    }

    func delete(message: Message) async {
        do {
            try await cli.delete(ids: [message.id])
            router.currentView = .inbox
            reader.loaded = nil
            await refreshInbox(pull: false)
        } catch {
            inbox.error = error.localizedDescription
        }
    }

    // ── Attachments ───────────────────────────────────────────────────────

    func downloadAttachment(_ attachment: Attachment, messageID: Int64, to destination: URL) async {
        do {
            try await cli.downloadAttachment(messageID: messageID, attachmentID: attachment.id, to: destination)
            NSWorkspace.shared.activateFileViewerSelecting([destination])
        } catch {
            inbox.error = "Attachment download failed: \(error.localizedDescription)"
        }
    }

    // ── Drafts ───────────────────────────────────────────────────────────

    func refreshDrafts() async {
        do {
            inbox.drafts = try await cli.listDrafts(account: session.currentAccount?.email)
        } catch {
            inbox.error = error.localizedDescription
        }
    }

    func edit(draft: Draft) {
        compose.clear()
        compose.editingDraftID = draft.id
        compose.to = (draft.to ?? []).joined(separator: ", ")
        compose.cc = (draft.cc ?? []).joined(separator: ", ")
        compose.bcc = (draft.bcc ?? []).joined(separator: ", ")
        compose.subject = draft.subject ?? ""
        // Prefer HTML body if the draft has one so rich-text formatting
        // survives a save-and-reopen round-trip. Falls back to plain text.
        if let html = draft.html_body, !html.isEmpty,
           let data = html.data(using: .utf8),
           let attr = try? NSAttributedString(
               data: data,
               options: [
                   .documentType: NSAttributedString.DocumentType.html,
                   .characterEncoding: String.Encoding.utf8.rawValue,
               ],
               documentAttributes: nil
           ) {
            compose.bodyAttributed = attr
        } else {
            compose.body = draft.text_body ?? ""
        }
        compose.replyToID = draft.reply_to_message_id
        router.currentView = .compose(nil)
    }

    // ── Draft autosave ───────────────────────────────────────────────────

    /// Debounced: call every time a compose field changes. Waits 1.5s of
    /// inactivity, then creates/updates the backing draft row.
    func scheduleAutosave() {
        compose.autosaveTask?.cancel()
        compose.autosaveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            if Task.isCancelled { return }
            await self?.performAutosave()
        }
    }

    private func performAutosave() async {
        // Reentrancy guard: if a save is in flight, skip this call — the next
        // keystroke will reschedule. Prevents a fast typist from storming
        // createDraft with concurrent tasks (each picks up editingDraftID=nil).
        guard !compose.isAutosaving, compose.hasContent else { return }
        compose.isAutosaving = true
        defer { compose.isAutosaving = false }

        let toList = splitAddresses(compose.to)
        let ccList = splitAddresses(compose.cc)
        let bccList = splitAddresses(compose.bcc)
        let subject = compose.subject
        let body = compose.body.isEmpty ? nil : compose.body
        let html = compose.bodyHTML

        do {
            if let id = compose.editingDraftID {
                try await cli.editDraft(
                    id: id, to: toList, cc: ccList, bcc: bccList,
                    subject: subject, text: body, html: html
                )
            } else {
                let draft = try await cli.createDraft(
                    account: session.currentAccount?.email,
                    to: toList, cc: ccList, bcc: bccList,
                    subject: subject, text: body, html: html,
                    replyToMessageID: compose.replyToID
                )
                compose.editingDraftID = draft.id
            }
            compose.lastAutosaveAt = Date()
        } catch {
            // Autosave failures are silent — we'll try again on the next edit.
        }
    }

    /// Explicit "Discard" — deletes the backing draft and clears compose state.
    func discardDraft() async {
        if let id = compose.editingDraftID {
            try? await cli.deleteDraft(id: id)
        }
        compose.clear()
        router.currentView = .inbox
        await refreshDrafts()
    }

    /// Called on popover close / app quit — flush any pending debounce.
    func flushAutosave() async {
        compose.autosaveTask?.cancel()
        compose.autosaveTask = nil
        await performAutosave()
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

    /// User-initiated send. Validates, captures a snapshot, returns the user
    /// to the inbox, and queues the transmission behind a short undo window.
    /// The old `cli.send` call is now invoked from `firePendingSend()` after
    /// the delay expires.
    func send() async -> Bool {
        compose.error = nil
        let to = splitAddresses(compose.to)
        let cc = splitAddresses(compose.cc)
        let bcc = splitAddresses(compose.bcc)
        guard !to.isEmpty else {
            compose.error = "Add at least one recipient"
            return false
        }
        // If a previous queued send is still pending, fire it immediately so
        // its payload doesn't sit behind the new one.
        if pendingSend != nil {
            await flushPendingSendNow()
        }

        let now = Date()
        let plainText = compose.body.isEmpty ? nil : compose.body
        let html = compose.bodyHTML
        let snapshot = PendingSend(
            from: session.currentAccount?.email,
            to: to,
            cc: cc,
            bcc: bcc,
            subject: compose.subject,
            text: plainText,
            html: html,
            attachments: compose.attachments,
            replyToMessageID: compose.replyToID,
            originalDraftID: compose.editingDraftID,
            queuedAt: now,
            deadline: now.addingTimeInterval(Self.undoSendWindow)
        )

        compose.clear()
        router.currentView = .inbox
        pendingSend = snapshot

        pendingSendTask?.cancel()
        pendingSendTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.undoSendWindow))
            if Task.isCancelled { return }
            await self?.firePendingSend()
        }
        return true
    }

    /// Actually run the CLI send for the queued snapshot. Safe to call even
    /// if `pendingSend` was already cleared (idempotent).
    private func firePendingSend() async {
        guard let snap = pendingSend else { return }
        do {
            try await cli.send(
                from: snap.from,
                to: snap.to,
                cc: snap.cc,
                bcc: snap.bcc,
                subject: snap.subject,
                text: snap.text,
                html: snap.html,
                attachments: snap.attachments,
                replyToMessageID: snap.replyToMessageID
            )
            if let draftID = snap.originalDraftID {
                try? await cli.deleteDraft(id: draftID)
            }
            pendingSend = nil
            pendingSendTask = nil
            flashStatus(.sent)
            await refreshInbox(pull: false)
            if inbox.currentFolder == .drafts { await refreshDrafts() }
        } catch {
            pendingSend = nil
            pendingSendTask = nil
            // Surface the typed CLIError payloads verbatim. The CLI encodes
            // semantic failures (bad input, rate limit, missing config) in
            // exit codes — making those distinguishable in the UI is better
            // than a generic "Send failed" string.
            inbox.error = Self.describeSendError(error)
            NSLog("Minimail send failed: %@", "\(error)")
        }
    }

    /// Map EmailCLI errors to user-facing copy that mentions what went wrong
    /// and hints at what to fix. Unknown errors fall back to localizedDescription.
    static func describeSendError(_ error: Error) -> String {
        guard let cliError = error as? EmailCLI.CLIError else {
            return "Send failed: \(error.localizedDescription)"
        }
        switch cliError {
        case .configError(let stderr):
            return "Send failed — configuration: \(stderr.prefix(240))"
        case .badInput(let stderr):
            return "Send failed — invalid input: \(stderr.prefix(240))"
        case .rateLimited(let stderr):
            return "Send failed — Resend rate limit: \(stderr.prefix(180))"
        case .nonZeroExit(let code, let stderr):
            return "Send failed (exit \(code)): \(stderr.prefix(240))"
        case .notFound:
            return "Send failed — email-cli helper not found in bundle."
        case .decode(let err):
            return "Send succeeded but response couldn't be decoded: \(err.localizedDescription)"
        case .envelopeError(let msg):
            return "Send failed: \(msg)"
        case .cancelled:
            return "Send cancelled."
        }
    }

    /// Cancel the pending send and restore the compose view with every field
    /// exactly as the user left it. Called when the user hits Undo on the toast.
    func undoPendingSend() {
        guard let snap = pendingSend else { return }
        pendingSendTask?.cancel()
        pendingSendTask = nil
        pendingSend = nil

        compose.clear()
        compose.to = snap.to.joined(separator: ", ")
        compose.cc = snap.cc.joined(separator: ", ")
        compose.bcc = snap.bcc.joined(separator: ", ")
        compose.subject = snap.subject
        compose.body = snap.text ?? ""
        compose.attachments = snap.attachments
        compose.replyToID = snap.replyToMessageID
        compose.editingDraftID = snap.originalDraftID
        router.currentView = .compose(snap.replyToMessageID)
    }

    /// Fire any in-flight pending send immediately. Called on popover close
    /// / app quit so we don't lose the user's message.
    func flushPendingSendNow() async {
        pendingSendTask?.cancel()
        pendingSendTask = nil
        if pendingSend != nil {
            await firePendingSend()
        }
    }

    private func flashStatus(_ status: TransientStatus) {
        transientStatus = status
        transientClearTask?.cancel()
        // Archive gets the full undo window; other flashes fade quickly.
        let lifetime: TimeInterval
        switch status {
        case .archived: lifetime = Self.undoSendWindow
        default: lifetime = 2.5
        }
        transientClearTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(lifetime))
            if Task.isCancelled { return }
            self?.transientStatus = nil
        }
    }

    // ── Contacts index ────────────────────────────────────────────────────

    /// Rebuild the autocomplete-friendly address list from messages currently
    /// loaded into memory. Cheap; called after every inbox refresh.
    func rebuildContactIndex() {
        var seen: Set<String> = []
        var ordered: [String] = []
        // Most recent messages first so the most-used addresses bubble to the top.
        for msg in inbox.messages.sorted(by: { ($0.created_at ?? "") > ($1.created_at ?? "") }) {
            collect(&ordered, &seen, msg.from_addr)
            for field in [msg.to, msg.cc, msg.bcc, msg.reply_to] {
                for addr in field ?? [] { collect(&ordered, &seen, addr) }
            }
        }
        contactIndex = ordered
    }

    private func collect(_ ordered: inout [String], _ seen: inout Set<String>, _ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        let key = trimmed.lowercased()
        if seen.insert(key).inserted {
            ordered.append(trimmed)
        }
    }

    private func splitAddresses(_ raw: String) -> [String] {
        raw.splitAddressTokens()
    }
}

extension String {
    var looksLikeEmail: Bool {
        let pattern = #"^[A-Z0-9a-z._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}$"#
        return self.range(of: pattern, options: .regularExpression) != nil
    }

    /// Split a raw address list into individual tokens. Splits on commas /
    /// semicolons / newlines / tabs — NOT whitespace, so display names like
    /// "Alice Example <alice@x.com>" survive intact. Trims each result.
    func splitAddressTokens() -> [String] {
        self.split(whereSeparator: { ",;\n\t".contains($0) })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}
