import AppKit
import Foundation
import Observation
import os

/// Typed os.Logger categories. Use these instead of `NSLog` / `print` so
/// logs show up in Console.app grouped by subsystem and survive release
/// builds where `print` is stripped. Add a new category here when you need
/// to instrument a new subsystem — keep the list small.
enum Log {
    static let send = Logger(subsystem: "ai.paperfoot.minimail", category: "send")
    static let cli = Logger(subsystem: "ai.paperfoot.minimail", category: "cli")
}

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
    var error: ActionableError?
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
    /// Pre-computed "3 of 24" label shown in the reader footer. Populated by
    /// `AppState.open(message:)` once per navigation so the footer doesn't
    /// need to call `inbox.visible()` (filter+sort over 100+ messages) on
    /// every re-render of the reader.
    var positionLabel: String?
    /// Pre-computed count of blocked remote images in the current message's
    /// HTML body. Populated once per navigation; avoids compiling an
    /// `NSRegularExpression` on every render of the reader footer.
    var trackerCount: Int = 0
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
    /// Per-compose "Send from" override. nil = use `AppState.composeFromAccount`
    /// (which falls back to default account or first account). Set when the
    /// user picks a different identity in the compose From-dropdown — does
    /// NOT change the inbox view (so picking a sender while reading the
    /// unified inbox doesn't filter the inbox down to that account).
    var fromOverride: Account?
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
        fromOverride = nil
        replyToID = nil; forwardingID = nil; replyAll = false; error = nil
        editingDraftID = nil; lastAutosaveAt = nil
    }

    /// Anything worth persisting? Attachments count: "dropped a file, closed
    /// the popover" is a common flow where the user hasn't typed anything yet
    /// but absolutely expects the draft to survive. Without the attachments
    /// clause the autosave scheduler short-circuits and the file is lost.
    var hasContent: Bool {
        !to.trimmingCharacters(in: .whitespaces).isEmpty
        || !subject.trimmingCharacters(in: .whitespaces).isEmpty
        || !body.trimmingCharacters(in: .whitespaces).isEmpty
        || !attachments.isEmpty
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

    /// Last send that failed after the undo window expired. Kept in memory so
    /// the UI can render a recovery banner with Retry + Edit buttons. Cleared
    /// on successful retry or when the user explicitly edits. The payload is
    /// also persisted in the Rust outbox table under `status = 'failed'` —
    /// `lastFailedSend` is the in-memory mirror that survives as long as the
    /// popover stays open.
    var lastFailedSend: PendingSend?
    /// Cached view of the outbox after a send failure — avoids a CLI round
    /// trip every time the banner re-renders.
    var lastOutboxSnapshot: [OutboxEntry] = []

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
        // If the current message dropped out of the visible list (archived,
        // filtered out by a folder switch, snoozed in the background), land
        // on the first row rather than computing next-after-(-1) — the old
        // fallback used Swift's `index(after:)` on a -1 sentinel and then
        // subscripted the result, which trap-crashed on the next access.
        // Keeping the "first row" fallback matches what the user sees if
        // they just opened the inbox cold.
        guard let idx = list.firstIndex(where: { $0.id == currentID }) else {
            inbox.focusedRowIndex = 0
            open(message: list[0])
            return
        }
        let next = idx + 1
        guard next < list.count else { return }
        inbox.focusedRowIndex = next
        open(message: list[next])
    }

    func openPrevious() {
        let list = inbox.visible()
        guard !list.isEmpty else { return }
        let currentID = reader.loaded?.id
        // Symmetrical guard — if the current message isn't in the visible
        // list, previous-from-nothing is undefined so open the first row
        // (same behaviour as cold-open). Without this the old fallback
        // `idx = list.count` combined with `prev = idx - 1` happened to
        // land on the last row, which was a surprise teleport for anyone
        // whose message got archived from under them.
        guard let idx = list.firstIndex(where: { $0.id == currentID }) else {
            inbox.focusedRowIndex = 0
            open(message: list[0])
            return
        }
        let prev = idx - 1
        guard prev >= 0 else { return }
        inbox.focusedRowIndex = prev
        open(message: list[prev])
    }

    /// Persisted across launches so unified vs single-account choice survives.
    /// Stores either the email of the current account or the literal "all".
    private static let preferredAccountKey = "minimail.preferredAccount"
    private static let unifiedSentinel = "__all__"

    func refreshAccounts() async {
        do {
            let loaded = try await cli.listAccounts()
            session.accounts = loaded
            if session.currentAccount == nil {
                // Restore the user's last choice from UserDefaults. Falls
                // back to the default account on first launch.
                let saved = UserDefaults.standard.string(forKey: Self.preferredAccountKey)
                if saved == Self.unifiedSentinel {
                    session.currentAccount = nil   // unified
                } else if let email = saved, let match = loaded.first(where: { $0.email == email }) {
                    session.currentAccount = match
                } else {
                    session.currentAccount = loaded.first(where: { $0.is_default == true }) ?? loaded.first
                }
            }
        } catch {
            inbox.error = ActionableError.classify(error)
        }
    }

    /// Persist the user's account-view preference so a relaunch returns
    /// to the same view (unified vs a specific account).
    private func persistPreferredAccount() {
        let value = session.currentAccount?.email ?? Self.unifiedSentinel
        UserDefaults.standard.set(value, forKey: Self.preferredAccountKey)
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
            // Eager attachment cache — Resend's signed URLs expire (seen as
            // CloudFront 403s at click time) and sometimes arrive as null in
            // the webhook. Prefetch keeps the bytes on disk so attachments
            // stay openable regardless. Fire-and-forget; the user doesn't
            // need to wait for it.
            if pull {
                Task { [weak self, account = email] in
                    try? await self?.cli.prefetchAttachments(account: account)
                }
            }
        } catch {
            let actionable = ActionableError.classify(error)
            inbox.error = actionable
            inbox.syncState = .error(actionable.message)
        }
    }

    // ── Selection / navigation ────────────────────────────────────────────

    /// Static regex for tracking-pixel counting — was compiled inside the
    /// reader's footer on every render. Matches `<img ... src="http://">`
    /// or `https://` which is what our WKContentRuleList blocks.
    private static let trackingRegex = try! NSRegularExpression(
        pattern: "<img[^>]+src=\"https?://",
        options: [.caseInsensitive]
    )

    func open(message: Message) {
        // Seed immediately with the cached list-row version so the reader
        // has a body to render before the full-detail fetch returns. All of
        // these writes are synchronous so SwiftUI coalesces them into a
        // single re-render (per Donny Wals: body re-evaluations in the same
        // render loop collapse to one redraw).
        reader.loaded = message
        if reader.error != nil { reader.error = nil }   // guard no-op write
        router.currentView = .reader(message.id)
        updateReaderDerived(for: message)
        loadFullMessage(id: message.id)

        // Mark-read path: mutate the message in-place instead of re-fetching
        // the whole inbox via refreshInbox. The old refresh ran listInbox x3
        // + rebuildContactIndex DURING the spring transition — ~25ms of
        // unrelated work that starved the animation. In-place flip is O(1).
        if message.isUnread {
            Task { [weak self, id = message.id] in
                try? await self?.cli.markRead(ids: [id])
                guard let self else { return }
                if let idx = self.inbox.messages.firstIndex(where: { $0.id == id }) {
                    self.inbox.messages[idx].is_read = true
                }
                self.inbox.totalUnread = max(0, self.inbox.totalUnread - 1)
            }
        }
    }

    /// Open a message by id — used by notification click-through. Prefers the
    /// in-memory list row (synchronous, avoids a round-trip for common case)
    /// but falls through to a raw reader-route + lazy body fetch when the
    /// message isn't currently loaded. The second branch used to just flip
    /// the route and leave `reader.loaded == nil`, producing a blank reader
    /// shell until the user navigated back and forward. Now it seeds reader
    /// state correctly, triggers `loadFullMessage` to pull the body, and
    /// mirrors the in-place mark-read mutation from `open(message:)` (commit
    /// 69585db) so the unread badge updates without a full refresh.
    func openMessage(id: Int64) {
        if let msg = inbox.messages.first(where: { $0.id == id }) {
            open(message: msg)
            return
        }
        reader.loaded = nil
        if reader.error != nil { reader.error = nil }
        router.currentView = .reader(id)
        loadFullMessage(id: id)
        // Mark read. The message may or may not be in our currently-loaded
        // inbox slice (e.g. notification click for a different account or a
        // message older than our 100-row pull window). Only flip the local
        // `is_read` + decrement the badge when we actually observe the
        // previously-unread state in-memory. For the out-of-view case, ask
        // the CLI for fresh stats instead of blindly decrementing — the old
        // "always --" path undercounted the badge on cross-account
        // notifications.
        Task { [weak self, id] in
            try? await self?.cli.markRead(ids: [id])
            guard let self else { return }
            if let idx = self.inbox.messages.firstIndex(where: { $0.id == id }) {
                let wasUnread = self.inbox.messages[idx].isUnread
                self.inbox.messages[idx].is_read = true
                if wasUnread {
                    self.inbox.totalUnread = max(0, self.inbox.totalUnread - 1)
                }
                return
            }
            // Message not in current view — reconcile via stats for the
            // currently-displayed account (nil = unified).
            let account = self.session.currentAccount?.email
            if let stats = try? await self.cli.stats(account: account),
               let unread = stats.unread {
                self.inbox.totalUnread = unread
            }
        }
    }

    /// Refresh cached reader-footer values when navigating to a message.
    /// Called once per `open()` — avoids per-render `inbox.visible()` filter
    /// and per-render `NSRegularExpression` compile in the footer.
    private func updateReaderDerived(for message: Message) {
        let list = inbox.visible()
        if let idx = list.firstIndex(where: { $0.id == message.id }) {
            reader.positionLabel = "\(idx + 1) of \(list.count)"
        } else {
            reader.positionLabel = nil
        }
        if let html = message.html_body, !html.isEmpty {
            let range = NSRange(html.startIndex..., in: html)
            reader.trackerCount = Self.trackingRegex.numberOfMatches(in: html, range: range)
        } else {
            reader.trackerCount = 0
        }
    }

    private func loadFullMessage(id: Int64) {
        reader.inflight?.cancel()
        // Batch the synchronous reset writes — all in one tick, one redraw.
        reader.isLoading = true
        reader.attachments = []
        reader.thread = []
        reader.expandedThreadIDs = [id]

        let task = Task { [weak self] in
            guard let self else { return }

            // Phase 1 — fetch the detail body (the user-visible work).
            // Writing loaded + error + isLoading here is three properties in
            // the same tick → SwiftUI coalesces into one render.
            do {
                let detail = try await self.cli.readMessage(id: id, markRead: false)
                if Task.isCancelled { return }
                self.reader.loaded = detail
                if self.reader.error != nil { self.reader.error = nil }
                self.reader.isLoading = false
                self.updateReaderDerived(for: detail)
            } catch {
                if Task.isCancelled { return }
                self.reader.error = error.localizedDescription
                self.reader.isLoading = false
                return
            }

            // Phase 2 — deferred: wait for the open-spring to settle, then
            // fetch attachments + thread in parallel. Doing this after the
            // transition means the extra CLI work doesn't compete with
            // animation frames, and writing both results in a single tick
            // (one redraw) instead of two sequential awaits (two redraws).
            try? await Task.sleep(nanoseconds: 350_000_000) // 350ms ≈ spring settle
            if Task.isCancelled { return }

            async let attachmentsTask = self.cli.listAttachments(messageID: id)
            async let threadTask = self.cli.readThread(id: id)
            let attachments = (try? await attachmentsTask) ?? []
            let thread = (try? await threadTask) ?? []
            if Task.isCancelled { return }

            self.reader.attachments = attachments
            if thread.count > 1 {
                // Splice the full-body message back at its position — the
                // thread endpoint returns lightweight summaries without
                // text_body / html_body, and we'd render "(no body)" for
                // the seed without this hydration.
                var hydrated = thread
                if let loaded = self.reader.loaded,
                   let idx = hydrated.firstIndex(where: { $0.id == loaded.id }) {
                    hydrated[idx] = loaded
                }
                self.reader.thread = hydrated
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
            inbox.error = ActionableError.classify(error)
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
            inbox.error = ActionableError.classify(error)
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
            inbox.error = ActionableError.classify(error)
        }
    }

    func snooze(_ message: Message, until: String) async {
        do {
            try await cli.snooze(ids: [message.id], until: until)
            if case .reader = router.currentView { router.currentView = .inbox }
            await refreshInbox(pull: false)
            flashStatus(.info("Snoozed"))
        } catch {
            inbox.error = ActionableError.classify(error)
        }
    }

    func unsnooze(_ message: Message) async {
        do {
            try await cli.unsnooze(ids: [message.id])
            await refreshInbox(pull: false)
            flashStatus(.info("Back in inbox"))
        } catch {
            inbox.error = ActionableError.classify(error)
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
            inbox.error = ActionableError.classify(error)
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
            inbox.error = ActionableError.classify(error)
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
            inbox.error = ActionableError.classify(error)
        }
    }

    // ── Account quick-switcher ────────────────────────────────────────────

    /// Activate the nth account (1-indexed). Hooked to ⌘1…⌘9 via RootView.
    /// No-op if there's no account at that index.
    func selectAccount(at index: Int) async {
        guard index >= 1, index <= session.accounts.count else { return }
        let acct = session.accounts[index - 1]
        session.currentAccount = acct
        persistPreferredAccount()
        try? await cli.setDefaultAccount(acct.email)
        await refreshInbox(pull: false)
    }

    /// Switch to unified "All Accounts" mode. `currentAccount = nil` is the
    /// sentinel; `refreshInbox` then queries the CLI without an --account
    /// filter so messages from every mailbox stream into one list. Compose
    /// falls back to the default account (see `composeFromAccount`).
    func selectUnifiedInbox() async {
        session.currentAccount = nil
        persistPreferredAccount()
        await refreshInbox(pull: false)
    }

    /// Account to send from when composing. Mirrors `currentAccount` when
    /// it's set; otherwise picks the user's marked default; otherwise the
    /// first account we know about. Used by `send()` and the From dropdown.
    var composeFromAccount: Account? {
        session.currentAccount
            ?? session.accounts.first(where: { $0.is_default == true })
            ?? session.accounts.first
    }

    func markAllRead() async {
        let ids = inbox.messages.filter(\.isUnread).map(\.id)
        guard !ids.isEmpty else { return }
        do {
            try await cli.markRead(ids: ids)
            await refreshInbox(pull: false)
        } catch {
            inbox.error = ActionableError.classify(error)
        }
    }

    func markUnread(message: Message) async {
        do {
            try await cli.markUnread(ids: [message.id])
            await refreshInbox(pull: false)
        } catch {
            inbox.error = ActionableError.classify(error)
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
            inbox.error = ActionableError.classify(error)
        }
    }

    func unarchive(message: Message) async {
        do {
            try await cli.unarchive(ids: [message.id])
            await refreshInbox(pull: false)
        } catch {
            inbox.error = ActionableError.classify(error)
        }
    }

    func delete(message: Message) async {
        do {
            try await cli.delete(ids: [message.id])
            router.currentView = .inbox
            reader.loaded = nil
            await refreshInbox(pull: false)
        } catch {
            inbox.error = ActionableError.classify(error)
        }
    }

    // ── Attachments ───────────────────────────────────────────────────────

    func downloadAttachment(_ attachment: Attachment, messageID: Int64, to destination: URL) async {
        do {
            try await cli.downloadAttachment(messageID: messageID, attachmentID: attachment.id, to: destination)
            NSWorkspace.shared.activateFileViewerSelecting([destination])
        } catch {
            inbox.error = .other("Attachment download failed: \(error.localizedDescription)")
        }
    }

    // ── Drafts ───────────────────────────────────────────────────────────

    func refreshDrafts() async {
        do {
            inbox.drafts = try await cli.listDrafts(account: session.currentAccount?.email)
        } catch {
            inbox.error = ActionableError.classify(error)
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
        // Restore the draft's originating sender so reopening a draft in
        // unified-inbox mode doesn't quietly switch identities on the user.
        // The draft row is the ground truth — `composeFromAccount` would
        // fall back to the default account otherwise. Missing / deleted
        // account is a no-op (compose then falls back to default — there's
        // no safer choice and the user will see it in the From row).
        if let account = draft.account_email {
            compose.fromOverride = session.accounts.first { $0.email == account }
        }
        // Rehydrate attachments from the snapshot paths the Rust backend
        // persisted. Files may have moved/been deleted since the draft was
        // saved — skip missing ones silently rather than surface a noisy
        // error, since the draft body is still salvageable.
        if let paths = draft.attachment_paths, !paths.isEmpty {
            let fm = FileManager.default
            compose.attachments = paths
                .map { URL(fileURLWithPath: $0) }
                .filter { fm.fileExists(atPath: $0.path) }
        }
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
        let attachments = compose.attachments
        // Resolve the draft's owning account in the same priority order as
        // send(): explicit fromOverride wins, then composeFromAccount (which
        // already handles default-account + first-account fallbacks), then
        // currentAccount. This matters in unified-inbox mode (currentAccount
        // == nil) where the old `session.currentAccount?.email` produced a
        // nil account_email and the CLI fell back to the default — silently
        // storing the draft under the wrong identity and later sending it
        // from a different address than the user picked.
        let accountEmail = compose.fromOverride?.email
            ?? composeFromAccount?.email
            ?? session.currentAccount?.email

        do {
            if let id = compose.editingDraftID {
                try await cli.editDraft(
                    id: id, to: toList, cc: ccList, bcc: bccList,
                    subject: subject, text: body, html: html,
                    attachments: attachments
                )
            } else {
                let draft = try await cli.createDraft(
                    account: accountEmail,
                    to: toList, cc: ccList, bcc: bccList,
                    subject: subject, text: body, html: html,
                    attachments: attachments,
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

    // ── Attachment mutations (centralised) ───────────────────────────────
    //
    // Every add/remove site routes through these two helpers so autosave runs
    // without the view layer having to remember. Without central routing the
    // bug was: drag in a file, close the popover → `compose.attachments` is
    // non-empty but `scheduleAutosave()` was never called, so the draft row
    // was never written and the user lost their file. GPT-5.4 Pro Recipe #4.

    /// Add an attachment URL to the current compose draft, dedup-by-URL,
    /// and schedule an autosave. Safe on the main actor.
    func addAttachment(_ url: URL) {
        guard !compose.attachments.contains(url) else { return }
        compose.attachments.append(url)
        scheduleAutosave()
    }

    /// Append multiple attachments (e.g. NSOpenPanel selection) in one go.
    /// Single scheduleAutosave call at the end — the debounce coalesces.
    func addAttachments(_ urls: [URL]) {
        var changed = false
        for url in urls where !compose.attachments.contains(url) {
            compose.attachments.append(url)
            changed = true
        }
        if changed { scheduleAutosave() }
    }

    /// Remove an attachment URL from the compose draft + schedule autosave.
    /// When the last attachment is removed from a previously attach-only
    /// draft we force an immediate flush so the Rust side clears its stored
    /// list now rather than after the 1.5s debounce — matters if the user
    /// then closes the popover before the debounce fires.
    func removeAttachment(_ url: URL) {
        compose.attachments.removeAll { $0 == url }
        scheduleAutosave()
    }

    // ── Compose ──────────────────────────────────────────────────────────

    func startCompose(replyTo: Message? = nil, replyAll: Bool = false) {
        compose.clear()
        compose.replyToID = replyTo?.id
        compose.replyAll = replyAll
        if let msg = replyTo {
            // Always reply FROM the account the original was addressed to —
            // this matters in unified inbox mode where currentAccount is
            // nil and the default-account fallback would send from the
            // wrong identity. Single-account mode is unaffected.
            compose.fromOverride = session.accounts.first(where: { $0.email == msg.account_email })
            compose.to = msg.from_addr
            let sub = msg.subject ?? ""
            compose.subject = sub.lowercased().hasPrefix("re:") ? sub : "Re: \(sub)"
            // Reply All: pull every original recipient (to + cc) into Cc,
            // minus the user's own address (would self-reply) and minus the
            // person we're already replying to in `to`.
            if replyAll {
                let me = session.currentAccount?.email.lowercased() ?? ""
                let primary = msg.fromParts.email.lowercased()
                let pool = (msg.to ?? []) + (msg.cc ?? [])
                let cc = pool
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { addr in
                        let lower = addr.lowercased()
                        if lower.isEmpty { return false }
                        if lower == me { return false }
                        // Compare by parsed email part too — handles "Name <a@x.com>".
                        let parsed = Self.emailPart(of: addr).lowercased()
                        return parsed != me && parsed != primary
                    }
                if !cc.isEmpty {
                    compose.cc = cc.joined(separator: ", ")
                }
            }
            // Prepend an attribution + quoted body so the reply has context.
            // Apple Mail format: "On <date> at <time>, <Name> wrote:" then
            // each original line prefixed with "> ".
            compose.body = Self.buildReplyQuote(for: msg)
        }
        router.currentView = .compose(replyTo?.id)
    }

    func startForward(of message: Message) {
        compose.clear()
        compose.forwardingID = message.id
        // Forward FROM the account the message was originally sent to / from.
        // Same reasoning as Reply (above) — unified-mode forwards must use
        // the right identity, not the global default.
        compose.fromOverride = session.accounts.first(where: { $0.email == message.account_email })
        let sub = message.subject ?? ""
        let lowered = sub.lowercased()
        let alreadyForwarded = lowered.hasPrefix("fwd:") || lowered.hasPrefix("fw:")
        compose.subject = alreadyForwarded ? sub : "Fwd: \(sub)"
        compose.body = Self.buildForwardBody(for: message)
        router.currentView = .compose(nil)
        // Re-attach the original's attachments. Fire-and-forget — the user
        // sees the compose window open immediately and the chips slide in
        // as each file downloads. Fails silently per-file (manifests as a
        // missing attachment in the chip row).
        Task { [weak self] in await self?.reattachOriginalAttachments(for: message.id) }
    }

    /// Download every attachment on the source message into a temp directory
    /// and append the file URLs to `compose.attachments`. Mirrors what Apple
    /// Mail / Gmail do when you Forward — the user expects the original
    /// files to ride along.
    private func reattachOriginalAttachments(for messageID: Int64) async {
        guard let list = try? await cli.listAttachments(messageID: messageID),
              !list.isEmpty else { return }
        let tempBase = FileManager.default.temporaryDirectory
            .appendingPathComponent("minimail-fwd-\(messageID)-\(Int(Date().timeIntervalSince1970))",
                                    isDirectory: true)
        try? FileManager.default.createDirectory(at: tempBase, withIntermediateDirectories: true)
        for attachment in list {
            let filename = attachment.filename ?? "attachment-\(attachment.id)"
            let dest = tempBase.appendingPathComponent(filename)
            do {
                try await cli.downloadAttachment(messageID: messageID,
                                                 attachmentID: attachment.id,
                                                 to: dest)
                if !compose.attachments.contains(dest) {
                    compose.attachments.append(dest)
                }
            } catch {
                Log.cli.error("forward re-attach failed for \(filename, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// Email-part of "Display Name <addr@host>"; falls back to the raw value.
    private static func emailPart(of raw: String) -> String {
        if let open = raw.firstIndex(of: "<"),
           let close = raw.firstIndex(of: ">"),
           open < close {
            return String(raw[raw.index(after: open)..<close])
        }
        return raw
    }

    /// Apple-Mail-style attribution + quoted original body. Quote uses the
    /// plain text_body when available, else strips tags from html_body.
    private static func buildReplyQuote(for msg: Message) -> String {
        let dateBlock: String
        if let raw = msg.created_at, let date = Dates.parse(raw) {
            let f = DateFormatter()
            f.dateStyle = .medium
            f.timeStyle = .short
            dateBlock = f.string(from: date)
        } else {
            dateBlock = ""
        }
        let sender = msg.fromParts.name ?? msg.fromParts.email
        let header: String
        if dateBlock.isEmpty {
            header = "On \(sender) wrote:"
        } else {
            header = "On \(dateBlock), \(sender) wrote:"
        }
        let raw = msg.text_body
            ?? msg.html_body.map(stripHTML)
            ?? msg.text_preview
            ?? ""
        let quoted = raw
            .split(whereSeparator: { $0.isNewline })
            .map { "> \($0)" }
            .joined(separator: "\n")
        return "\n\n\(header)\n\(quoted)"
    }

    /// Forward preamble + body. Falls back to stripped HTML for HTML-only
    /// messages so the forwarded body isn't blank.
    private static func buildForwardBody(for msg: Message) -> String {
        let dateBlock: String
        if let raw = msg.created_at, let date = Dates.parse(raw) {
            let f = DateFormatter()
            f.dateStyle = .medium
            f.timeStyle = .short
            dateBlock = f.string(from: date)
        } else {
            dateBlock = ""
        }
        let body = msg.text_body
            ?? msg.html_body.map(stripHTML)
            ?? msg.text_preview
            ?? ""
        var preamble = "\n\n-------- Forwarded message --------\n"
        preamble += "From: \(msg.from_addr)\n"
        if !dateBlock.isEmpty { preamble += "Date: \(dateBlock)\n" }
        preamble += "Subject: \(msg.subject ?? "")\n"
        if let to = msg.to, !to.isEmpty {
            preamble += "To: \(to.joined(separator: ", "))\n"
        }
        return preamble + "\n" + body
    }

    /// Minimal HTML → plain-text. Strips tags + collapses whitespace. Good
    /// enough for the quoted-body / forward preamble use case where we just
    /// want readable text, not perfect fidelity.
    private static func stripHTML(_ html: String) -> String {
        var out = ""
        var inTag = false
        for ch in html {
            switch ch {
            case "<": inTag = true
            case ">": inTag = false
            default:
                if !inTag { out.append(ch) }
            }
        }
        // Collapse runs of whitespace, preserve paragraph breaks.
        let lines = out.split(whereSeparator: { $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return lines.joined(separator: "\n")
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
        // Resolve send identity in priority order:
        //   1. compose.fromOverride (user picked it explicitly in the dropdown)
        //   2. composeFromAccount (currentAccount, or default, or first)
        let fromAccount = compose.fromOverride?.email ?? composeFromAccount?.email
        let snapshot = PendingSend(
            from: fromAccount,
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
            // Successful send clears any stale failure affordance from a
            // previous attempt — the banner was about that attempt, not this
            // one.
            lastFailedSend = nil
            lastOutboxSnapshot = []
            flashStatus(.sent)
            await refreshInbox(pull: false)
            if inbox.currentFolder == .drafts { await refreshDrafts() }
        } catch {
            // Keep the snapshot accessible via `lastFailedSend` so the
            // outboxBanner in RootView can offer Retry / Edit. The old
            // implementation nilled `pendingSend` and flashed an error that
            // disappeared — the message felt "lost" even though email-cli
            // had persisted it in the outbox table. (ritalin O-022)
            pendingSendTask = nil
            pendingSend = nil
            lastFailedSend = snap
            // Snapshot the outbox so the banner can show the matching failed
            // row (status + attempts + last_error). Best-effort: a failure to
            // list the outbox isn't itself surface-worthy — the banner still
            // works off `lastFailedSend`.
            lastOutboxSnapshot = (try? await cli.outboxList(account: snap.from)) ?? []
            let classified = ActionableError.classify(error)
            if case .other = classified {
                inbox.error = .other(Self.describeSendError(error))
            } else {
                inbox.error = classified
            }
            Log.send.error("send failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Re-queue the last failed send as a fresh pendingSend and fire it
    /// immediately. Matches "Retry" on the recovery banner.
    func retryLastFailedSend() async {
        guard let snap = lastFailedSend else { return }
        lastFailedSend = nil
        lastOutboxSnapshot = []
        // Keep the deadline in the past so firePendingSend runs right away
        // rather than re-arming the 10s undo window (the user already
        // explicitly chose to retry).
        let requeued = PendingSend(
            from: snap.from, to: snap.to, cc: snap.cc, bcc: snap.bcc,
            subject: snap.subject, text: snap.text, html: snap.html,
            attachments: snap.attachments,
            replyToMessageID: snap.replyToMessageID,
            originalDraftID: snap.originalDraftID,
            queuedAt: Date(),
            deadline: Date()
        )
        pendingSend = requeued
        await firePendingSend()
    }

    /// Restore the failed snapshot back into the compose view so the user can
    /// edit before retrying (fix the bad address, reword, etc.). Matches
    /// "Edit" on the recovery banner.
    func editLastFailedSend() {
        guard let snap = lastFailedSend else { return }
        lastFailedSend = nil
        lastOutboxSnapshot = []
        compose.clear()
        compose.to = snap.to.joined(separator: ", ")
        compose.cc = snap.cc.joined(separator: ", ")
        compose.bcc = snap.bcc.joined(separator: ", ")
        compose.subject = snap.subject
        // Prefer HTML round-trip when the snapshot has it so bold/italic/links
        // survive the recovery path — matches undoPendingSend's rich-text
        // restore. Falls back to plain text.
        if let html = snap.html, let data = html.data(using: .utf8),
           let attr = try? NSAttributedString(
               data: data,
               options: [.documentType: NSAttributedString.DocumentType.html,
                         .characterEncoding: String.Encoding.utf8.rawValue],
               documentAttributes: nil
           ) {
            compose.bodyAttributed = attr
        } else {
            compose.body = snap.text ?? ""
        }
        compose.attachments = snap.attachments
        compose.replyToID = snap.replyToMessageID
        compose.editingDraftID = snap.originalDraftID
        if let fromEmail = snap.from {
            compose.fromOverride = session.accounts.first { $0.email == fromEmail }
        }
        router.currentView = .compose(snap.replyToMessageID)
    }

    /// User dismissed the banner without choosing. Drops the in-memory
    /// snapshot; the Rust outbox row is still there and `outbox retry` via a
    /// future Settings-side UI can surface it again.
    func dismissLastFailedSend() {
        lastFailedSend = nil
        lastOutboxSnapshot = []
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
        // Rich-text undo: snapshot captures both the plain-text body and the
        // HTML serialisation; the previous undo path dropped snap.html on the
        // floor, so Bold/Italic/Underline/links vanished on Undo even though
        // the send was still queued. Rehydrating from HTML when it's present
        // preserves every formatting run. Falls back to plain text for
        // messages the user sent without any formatting (bodyHTML is nil in
        // that case — see ComposeState.bodyContainsFormatting). (O-023)
        if let html = snap.html, let data = html.data(using: .utf8),
           let attr = try? NSAttributedString(
               data: data,
               options: [.documentType: NSAttributedString.DocumentType.html,
                         .characterEncoding: String.Encoding.utf8.rawValue],
               documentAttributes: nil
           ) {
            compose.bodyAttributed = attr
        } else {
            compose.body = snap.text ?? ""
        }
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
