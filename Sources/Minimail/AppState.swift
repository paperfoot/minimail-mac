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
        case unread = "Unread"
        case starred = "Starred"
        case snoozed = "Snoozed"
        case sent = "Sent"
        case drafts = "Drafts"
        case archived = "Archived"
    }

    var messages: [Message] = []
    var inboxCursor: Int64?
    var archiveCursor: Int64?
    var snoozeCursor: Int64?
    var isLoadingMore = false
    var canLoadMore: Bool {
        switch currentFolder {
        case .drafts: false
        case .archived: archiveCursor != nil
        case .snoozed: snoozeCursor != nil
        case .starred: inboxCursor != nil || archiveCursor != nil || snoozeCursor != nil
        default: inboxCursor != nil
        }
    }
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

    // ── Search (FTS-backed via cli.search) ───────────────────────────────
    //
    // Free-text search that reaches across the entire mailbox via the
    // CLI's FTS5 index — not just the ~100 rows currently loaded in
    // `messages`. When `searchQuery` is non-empty and a search run has
    // completed, `visible()` returns `searchResults` instead of the
    // folder-filtered slice. The widget's scope is deliberately free-text
    // only; operator parsing (`from:`, `is:unread`, …) belongs in the
    // future full app (see product-split.md).
    var searchResults: [Message] = []
    var isSearching: Bool = false
    var searchError: ActionableError?

    func visible() -> [Message] {
        // When the user is searching, bypass the folder filter entirely and
        // render `searchResults`. The CLI's FTS5 index covers the whole
        // mailbox, not just the 100 rows we keep in `messages`, so a query
        // for "invoice from 2023" actually finds things. Empty query →
        // original folder-filtered list (the common glanceable case).
        let trimmedQuery = searchQuery.trimmingCharacters(in: .whitespaces)
        if !trimmedQuery.isEmpty {
            return searchResults
        }
        switch currentFolder {
        case .inbox:
            // Hide currently-snoozed messages from the main inbox.
            return messages.filter {
                $0.direction == "received" && !$0.isArchived && !$0.isSnoozed
            }
        case .unread:
            // Unread, not archived, not snoozed. Matches the "Unread"
            // folder tab so the user can one-click-focus unread messages
            // without hunting for the blue dots. `isUnread` is the typed
            // accessor on Message (= direction == "received" && !is_read).
            return messages.filter {
                $0.isUnread && !$0.isArchived && !$0.isSnoozed
            }
        case .starred:
            return AppState.mergeMessages(messages + snoozedMessages).filter { $0.isStarred }
        case .snoozed:
            return snoozedMessages.filter { $0.isSnoozed }
        case .sent:
            return messages.filter { $0.direction == "sent" }
        case .drafts:
            return []
        case .archived:
            return messages.filter { $0.isArchived }
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
    var attachmentsByMessageID: [Int64: [Attachment]] = [:]
    var attachmentErrors: [Int64: String] = [:]
    var attachmentDownloads: Set<String> = []
    var inlineImages: [Int64: [String: String]] = [:]
    var inlineImageErrors: [Int64: String] = [:]
    var contentGeneration = UUID()
    var remoteContentCountsByMessageID: [Int64: Int] = [:]
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
    func attachments(for messageID: Int64) -> [Attachment] {
        attachmentsByMessageID[messageID] ?? []
    }

    func remoteContentCount(for messageID: Int64) -> Int {
        remoteContentCountsByMessageID[messageID] ?? 0
    }
}

@MainActor
@Observable
final class ComposeState {
    var generation = UUID()
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
        let export = NSMutableAttributedString(attributedString: bodyAttributed)
        export.enumerateAttribute(.foregroundColor, in: range) { value, run, _ in
            if let color = value as? NSColor, color == .labelColor || color == .textColor {
                export.addAttribute(.foregroundColor, value: NSColor.black, range: run)
            }
        }
        guard let data = try? export.data(from: range, documentAttributes: attrs),
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
            let plainKeys: Set<NSAttributedString.Key> = [.font, .foregroundColor, .paragraphStyle]
            let extraKeys = Set(attrs.keys).subtracting(plainKeys)
            if !extraKeys.isEmpty { found = true }
            if let font = attrs[.font] as? NSFont, font != NSFont.systemFont(ofSize: 13) { found = true }
            if let color = attrs[.foregroundColor] as? NSColor, color != .labelColor, color != .textColor {
                found = true
            }
            if let paragraph = attrs[.paragraphStyle] as? NSParagraphStyle,
               !paragraph.isEqual(NSParagraphStyle.default) { found = true }
            if found { stop.pointee = true }
        }
        return found
    }
    var usesRichText: Bool { bodyContainsFormatting }
    var attachments: [URL] = []
    var isLoadingAttachments = false
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
    /// Optional Reply-To header override. When non-empty, the outgoing
    /// email's RFC-5322 Reply-To carries these addresses, so recipient
    /// clients route Reply somewhere other than the From account.
    /// Same comma/semicolon/newline-separated format as `to` / `cc` /
    /// `bcc` so it can flow through the same token field.
    var replyTo: String = ""
    /// Optional Resend `scheduled_at`. When set, the CLI passes this to
    /// Resend which holds the email server-side until the wake moment.
    /// Preserved in drafts and restored by Undo Send.
    var scheduledAt: Date?

    /// The backing draft row we're editing — created lazily on first autosave,
    /// or populated when the user taps a row in the Drafts folder. On send
    /// or explicit discard we delete it.
    var editingDraftID: String?
    var lastAutosaveAt: Date?
    var autosaveTask: Task<Void, Never>?
    /// Guard against concurrent autosave runs that would double-create drafts.
    var isAutosaving: Bool = false

    func clear() {
        generation = UUID()
        autosaveTask?.cancel()
        autosaveTask = nil
        to = ""; cc = ""; bcc = ""; subject = ""
        bodyAttributed = NSAttributedString()
        attachments = []
        isLoadingAttachments = false
        fromOverride = nil
        replyToID = nil; forwardingID = nil; replyAll = false; error = nil
        replyTo = ""
        scheduledAt = nil
        editingDraftID = nil; lastAutosaveAt = nil
    }

    /// Anything worth persisting? Attachments count: "dropped a file, closed
    /// the popover" is a common flow where the user hasn't typed anything yet
    /// but absolutely expects the draft to survive. Without the attachments
    /// clause the autosave scheduler short-circuits and the file is lost.
    var hasContent: Bool {
        !to.trimmingCharacters(in: .whitespaces).isEmpty
        || !cc.trimmingCharacters(in: .whitespaces).isEmpty
        || !bcc.trimmingCharacters(in: .whitespaces).isEmpty
        || !replyTo.trimmingCharacters(in: .whitespaces).isEmpty
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
    var isExpanded = false
    var settingsSection: String?
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
    /// Optional Reply-To header overrides. Empty Vec = inherit From identity.
    let replyTo: [String]
    let subject: String
    let text: String?
    let html: String?
    let attachments: [URL]
    let replyToMessageID: Int64?
    /// RFC-3339 string for Resend's `scheduled_at` — nil = send immediately.
    /// Stored as a string rather than a Date so the CLI flag passes
    /// through unchanged and the same value can be displayed in toasts.
    let scheduledAt: String?
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
    /// Permanent local deletion, with no undo claim.
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
    /// Non-nil after the undo window has closed and the CLI send is actively
    /// running. At this point Undo is no longer truthful, so the UI switches
    /// from the undo toast to a progress-only sending toast.
    var deliveringSend: PendingSend?
    private var deliveryWaiters: [CheckedContinuation<Void, Never>] = []
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

    /// RFC-3339 / ISO-8601 formatter for Resend's `scheduled_at` field.
    /// Resend documents both RFC-3339 timestamps and natural-language
    /// values ("in 1 min"); we always emit RFC-3339 for deterministic
    /// behavior. nonisolated(unsafe) so Sendable PendingSend snapshots
    /// can be built off the main actor.
    nonisolated(unsafe) static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// Keyboard-help sheet visibility — ⌘/ opens it.
    var showKeyboardHelp: Bool = false

    /// True while the one-time "Open Minimail at login?" nudge is showing.
    /// A menu-bar mail client only checks for new mail while it's running, so
    /// for most users launch-at-login is the difference between a working
    /// background client and one that's dead after the next reboot — yet it
    /// was previously opt-in, buried in Settings, and off by default (the
    /// reported "doesn't start automatically" symptom). We offer it once.
    var pendingLaunchAtLoginOffer: Bool = false
    private static let didOfferLaunchAtLoginKey = "minimail.didOfferLaunchAtLogin"

    /// Cache of every address Minimail has seen in `from`, `to`, `cc`, `bcc`
    /// across stored messages. Rebuilt from `inbox.messages` on each refresh.
    /// Used by EmailTokenField for recipient autocomplete.
    var contactIndex: [String] = []

    /// Last archived IDs, for the "Undo" action on the archive toast.
    private var lastArchivedIDs: [Int64] = []

    /// Debounced search: `scheduleSearch()` cancels the previous pending
    /// task and schedules a new one 300ms out. `performSearch()` runs the
    /// actual CLI round-trip. Task-cancellation through `searchDebounceTask`
    /// means a fast typist doesn't fan out one CLI process per keystroke.
    private var searchDebounceTask: Task<Void, Never>?

    let cli: EmailCLI
    private var refreshGeneration = UUID()
    private var searchGeneration = UUID()
    private var activeAutosave: Task<Void, Never>?
    private var isNavigating = false

    init(cli: EmailCLI = .shared) { self.cli = cli }

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
        if router.currentView == .onboarding || router.currentView == .needsInstall {
            router.currentView = .inbox
        }
        await refreshInbox(pull: false)
        // Prefetch drafts so the Drafts tab doesn't flash empty-state when tapped.
        await refreshDrafts()
        // Reconcile any send the previous session left mid-flight (crash/quit
        // during the undo window or delivery) before the user notices.
        await reconcileOutboxOnLaunch()
        // One-time launch-at-login nudge once at least one account exists.
        offerLaunchAtLoginIfNeeded()
    }

    // ── Launch-at-login first-run offer ───────────────────────────────────

    /// Decide whether to show the one-time launch-at-login nudge. Gated on a
    /// UserDefaults flag so we ask exactly once; skipped if it's already
    /// enabled. We never auto-register without consent — the user owns their
    /// Login Items list — so this only flips a flag the UI turns into a card.
    func offerLaunchAtLoginIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: Self.didOfferLaunchAtLoginKey) else { return }
        if LaunchAtLogin.isOn {
            // Already registered — record it so we never ask later.
            defaults.set(true, forKey: Self.didOfferLaunchAtLoginKey)
            return
        }
        pendingLaunchAtLoginOffer = true
    }

    /// Handle the user's choice on the launch-at-login card. Records that we
    /// asked (so the nudge never returns), and registers when they accept —
    /// surfacing the approval path when macOS lands in `.requiresApproval`.
    func respondToLaunchAtLoginOffer(enable: Bool) {
        UserDefaults.standard.set(true, forKey: Self.didOfferLaunchAtLoginKey)
        pendingLaunchAtLoginOffer = false
        guard enable else { return }
        do {
            let state = try LaunchAtLogin.set(true)
            if state == .requiresApproval {
                flashStatus(.info("Approve Minimail in System Settings ▸ Login Items to finish."))
                LaunchAtLogin.openSystemSettings()
            } else {
                flashStatus(.info("Minimail will open at login"))
            }
        } catch {
            inbox.error = ActionableError.classify(error)
        }
    }

    /// Called when the popover closes. The nudge card is dismissed simply by
    /// closing the popover (status-item click / Esc / click-away) without
    /// touching a button — so if it was on screen and unanswered, treat that
    /// as "not now": record that we asked (so it never returns on relaunch)
    /// and clear the in-memory flag (so reopening the popover this session
    /// doesn't show it again). Without this, the card re-appeared on every
    /// reopen and every launch until an explicit button press — the
    /// "asked twice" the user hit. Showing happens only while the popover is
    /// open, so this still guarantees the nudge is seen exactly once.
    func dismissLaunchAtLoginOfferIfShown() {
        guard pendingLaunchAtLoginOffer else { return }
        UserDefaults.standard.set(true, forKey: Self.didOfferLaunchAtLoginKey)
        pendingLaunchAtLoginOffer = false
    }

    /// Startup reports unfinished deliveries. Retry stays an explicit action
    /// because a very old request may outlive the provider's deduplication window.
    private func reconcileOutboxOnLaunch() async {
        if let entries = try? await cli.outboxList() {
            let unfinished = entries.filter { $0.isFailed || $0.isPending }.count
            if unfinished > 0 {
                flashStatus(.info("\(unfinished) message\(unfinished == 1 ? "" : "s") need attention in Outbox"))
            }
        }
    }

    func pollForNewMail() async -> [Message] {
        do {
            try await cli.sync(account: nil)
            await refreshInbox(pull: false)
            inbox.lastPullAt = Date()
            return try await cli.listInbox(account: nil, limit: 100).filter { $0.direction == "received" }
        } catch {
            inbox.error = ActionableError.classify(error)
            return []
        }
    }

    func replyFromNotification(id: Int64, text: String) async {
        guard await prepareToLeaveCompose() else { return }
        do {
            let message = try await cli.readMessage(id: id, markRead: false)
            startCompose(replyTo: message)
            if !text.isEmpty { compose.body = text + "\n\n" + compose.body }
            scheduleAutosave()
        } catch { inbox.error = ActionableError.classify(error) }
    }

    func markRead(ids: [Int64]) async {
        do {
            try await cli.markRead(ids: ids)
            for id in ids { markMessageReadLocally(id: id) }
        } catch { inbox.error = ActionableError.classify(error) }
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
    private var restoredAccountSelection = false

    func refreshAccounts() async {
        do {
            let loaded = try await cli.listAccounts()
            session.accounts = loaded
            if let current = session.currentAccount {
                session.currentAccount = loaded.first { $0.email == current.email }
            } else if !restoredAccountSelection {
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
            restoredAccountSelection = true
        } catch {
            inbox.error = ActionableError.classify(error)
        }
    }

    /// Persist the user's account-view preference so a relaunch returns
    /// to the same view (unified vs a specific account).
    func persistPreferredAccount() {
        let value = session.currentAccount?.email ?? Self.unifiedSentinel
        UserDefaults.standard.set(value, forKey: Self.preferredAccountKey)
    }

    /// `pull: true` hits Resend first for new mail, then re-reads the local DB.
    /// `pull: false` is a local-only re-render (after mark-read, archive, send).
    func refreshInbox(pull: Bool = true) async {
        guard !session.accounts.isEmpty else {
            refreshGeneration = UUID()
            inbox.messages = []; inbox.snoozedMessages = []; inbox.drafts = []
            inbox.searchResults = []; inbox.selection = []; inbox.totalUnread = 0
            inbox.inboxCursor = nil; inbox.archiveCursor = nil; inbox.snoozeCursor = nil
            inbox.syncState = .idle
            return
        }
        let generation = UUID()
        refreshGeneration = generation
        let account = session.currentAccount?.email
        inbox.syncState = .syncing
        defer {
            if refreshGeneration == generation, inbox.syncState == .syncing { inbox.syncState = .idle }
        }
        do {
            if pull { try await cli.sync(account: account) }
            // Keep the already-loaded depth when actions or background checks refresh.
            let limit = max(100, inbox.messages.filter { !$0.isArchived }.count)
            let archiveLimit = max(100, inbox.messages.filter(\.isArchived).count)
            async let listA = cli.listInboxPage(account: account, limit: limit)
            async let listB = cli.listInboxPage(account: account, archived: true, limit: archiveLimit)
            async let snoozedList = cli.listInboxPage(account: account, snoozed: true, limit: max(100, inbox.snoozedMessages.count))
            async let statsResult = cli.stats(account: account)
            let (a, b, c) = try await (listA, listB, snoozedList)
            let stats = try? await statsResult
            guard refreshGeneration == generation, session.currentAccount?.email == account else { return }
            inbox.messages = Self.mergeMessages((a.messages ?? []) + (b.messages ?? []))
            inbox.snoozedMessages = c.messages ?? []
            inbox.inboxCursor = a.has_more == true ? a.next_cursor : nil
            inbox.archiveCursor = b.has_more == true ? b.next_cursor : nil
            inbox.snoozeCursor = c.has_more == true ? c.next_cursor : nil
            inbox.totalUnread = stats?.unread ?? inbox.messages.filter(\.isUnread).count
            if pull { inbox.lastPullAt = Date() }
            inbox.error = nil
            rebuildContactIndex()
            if !inbox.searchQuery.isEmpty { scheduleSearch() }
            if pull {
                Task { [weak self] in try? await self?.cli.prefetchAttachments(account: account) }
            }
        } catch {
            guard refreshGeneration == generation else { return }
            let actionable = ActionableError.classify(error)
            inbox.error = actionable
            inbox.syncState = .error(actionable.message)
        }
    }

    static func mergeMessages(_ messages: [Message]) -> [Message] {
        var seen = Set<Int64>()
        return messages.filter { seen.insert($0.id).inserted }.sorted {
            let lhs = Dates.parse($0.created_at) ?? .distantPast
            let rhs = Dates.parse($1.created_at) ?? .distantPast
            return lhs == rhs ? $0.id > $1.id : lhs > rhs
        }
    }

    func loadMoreMessages() async {
        guard !inbox.isLoadingMore else { return }
        inbox.isLoadingMore = true
        defer { inbox.isLoadingMore = false }
        let generation = refreshGeneration
        let account = session.currentAccount?.email
        let folder = inbox.currentFolder
        do {
            for kind in 0...2 {
                if folder == .archived && kind != 1 { continue }
                if folder == .snoozed && kind != 2 { continue }
                if folder != .archived && folder != .snoozed && folder != .starred && kind != 0 { continue }
                let cursor = kind == 0 ? inbox.inboxCursor : (kind == 1 ? inbox.archiveCursor : inbox.snoozeCursor)
                guard let cursor else { continue }
                let page = try await cli.listInboxPage(account: account, archived: kind == 1, snoozed: kind == 2, limit: 100, after: cursor)
                guard refreshGeneration == generation, session.currentAccount?.email == account else { return }
                let next = page.has_more == true ? page.next_cursor : nil
                if kind == 2 {
                    inbox.snoozedMessages = Self.mergeMessages(inbox.snoozedMessages + (page.messages ?? []))
                    inbox.snoozeCursor = next
                } else {
                    inbox.messages = Self.mergeMessages(inbox.messages + (page.messages ?? []))
                    if kind == 0 { inbox.inboxCursor = next } else { inbox.archiveCursor = next }
                }
            }
        } catch { inbox.error = ActionableError.classify(error) }
    }

    func open(message: Message) {
        if router.isExpanded { inbox.selection = [message.id] }
        reader.loaded = message
        reader.error = nil
        router.currentView = .reader(message.id)
        updateReaderDerived(for: message)
        loadFullMessage(id: message.id)
        if message.isUnread { Task { await markRead(message: message) } }
    }

    func openMessage(id: Int64) {
        if let message = inbox.messages.first(where: { $0.id == id }) {
            open(message: message)
            return
        }
        reader.loaded = nil
        reader.error = nil
        router.currentView = .reader(id)
        loadFullMessage(id: id)
    }

    /// Refresh cached reader-footer values when navigating to a message.
    /// Called once per `open()` — avoids per-render `inbox.visible()` filter
    /// and per-render `NSRegularExpression` compile in the footer.
    private func updateReaderDerived(for message: Message) {
        let list = inbox.visible()
        reader.positionLabel = list.firstIndex(where: { $0.id == message.id }).map { "\($0 + 1) of \(list.count)" }
        reader.remoteContentCountsByMessageID[message.id] = EmailHTML.hasRemoteResources(message.html_body ?? "") ? 1 : 0
    }

    private func loadFullMessage(id: Int64) {
        reader.inflight?.cancel()
        // Batch the synchronous reset writes — all in one tick, one redraw.
        reader.isLoading = true
        reader.attachments = []
        reader.attachmentsByMessageID = [:]
        reader.attachmentErrors = [:]
        reader.inlineImages = [:]
        reader.inlineImageErrors = [:]
        reader.contentGeneration = UUID()
        reader.remoteContentCountsByMessageID = [:]
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
                if detail.isUnread { Task { await self.markRead(message: detail) } }
                if self.reader.error != nil { self.reader.error = nil }
                self.reader.isLoading = false
                self.updateReaderDerived(for: detail)
            } catch {
                if Task.isCancelled { return }
                // Route through ActionableError so the reader shows a
                // redacted, human-readable message (e.g. "Rate limited —
                // retry in 30s" instead of raw stderr with URLs + tokens).
                self.reader.error = ActionableError.classify(error).message
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
            let attachments: [Attachment]
            do { attachments = try await attachmentsTask }
            catch {
                if Task.isCancelled { return }
                attachments = []
                self.reader.attachmentErrors[id] = ActionableError.classify(error).message
            }
            let thread = (try? await threadTask) ?? []
            if Task.isCancelled { return }

            self.reader.attachments = attachments
            // Sibling files load when their message is expanded, so a long
            // conversation never delays this message's body or inline images.
            self.reader.attachmentsByMessageID = [id: attachments]
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
            if let detail = self.reader.loaded { await self.loadInlineImages(for: detail) }
        }
        reader.inflight = task
    }

    /// Load the full body for a thread sibling (user tapped a collapsed row).
    func expandThreadMessage(_ id: Int64) async {
        guard !reader.expandedThreadIDs.contains(id) else { return }
        let route = router.currentView
        let generation = reader.contentGeneration
        reader.expandedThreadIDs.insert(id)
        do {
            let full = try await cli.readMessage(id: id, markRead: false)
            guard router.currentView == route else { return }
            await reloadAttachments(messageID: id)
            guard router.currentView == route, reader.contentGeneration == generation,
                  let index = reader.thread.firstIndex(where: { $0.id == id }) else { return }
            reader.thread[index] = full
            reader.loaded = full
            updateReaderDerived(for: full)
            await loadInlineImages(for: full)
            if full.isUnread { await markRead(message: full) }
        } catch {
            guard router.currentView == route else { return }
            reader.expandedThreadIDs.remove(id)
            inbox.error = ActionableError.classify(error)
        }
    }

    func focusThreadMessage(_ id: Int64) {
        guard let message = reader.thread.first(where: { $0.id == id }) else { return }
        reader.loaded = message
        updateReaderDerived(for: message)
    }

    private func markMessageReadLocally(id: Int64) {
        if reader.loaded?.id == id { reader.loaded?.is_read = true }
        if let index = inbox.searchResults.firstIndex(where: { $0.id == id }) { inbox.searchResults[index].is_read = true }
        if let idx = inbox.messages.firstIndex(where: { $0.id == id }) {
            let wasUnread = inbox.messages[idx].isUnread
            inbox.messages[idx].is_read = true
            if wasUnread {
                inbox.totalUnread = max(0, inbox.totalUnread - 1)
            }
        }
        if let idx = reader.thread.firstIndex(where: { $0.id == id }) {
            reader.thread[idx].is_read = true
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
        // Search and Starred may mix archived and unarchived messages. Undo
        // must only restore messages this action actually moved.
        let known = inbox.messages + inbox.snoozedMessages + inbox.searchResults + reader.thread
        let archivedIDs = Set(known.filter(\.isArchived).map(\.id))
        let ids = ids.filter { !archivedIDs.contains($0) }
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
            mutateMessage(message.id) { $0.starred = !message.isStarred }
            await refreshInbox(pull: false)
        } catch {
            inbox.error = ActionableError.classify(error)
        }
    }

    private func mutateMessage(_ id: Int64, change: (inout Message) -> Void) {
        if reader.loaded?.id == id, var message = reader.loaded { change(&message); reader.loaded = message }
        if let i = reader.thread.firstIndex(where: { $0.id == id }) { change(&reader.thread[i]) }
        if let i = inbox.messages.firstIndex(where: { $0.id == id }) { change(&inbox.messages[i]) }
        if let i = inbox.snoozedMessages.firstIndex(where: { $0.id == id }) { change(&inbox.snoozedMessages[i]) }
        if let i = inbox.searchResults.firstIndex(where: { $0.id == id }) { change(&inbox.searchResults[i]) }
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
            // List-Unsubscribe is attacker-controlled mail content; gate the
            // scheme so a crafted `file://` / custom-scheme header can't drive
            // a one-click cross-app launch.
            guard let url = URL(string: urlString), ExternalLink.open(url) else {
                flashStatus(.info("Unsubscribe link blocked (unsupported link type)"))
                return nil
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
        guard !ids.isEmpty else { return }
        if inbox.currentFolder == .archived {
            do {
                try await cli.unarchive(ids: ids)
                inbox.clearSelection()
                await refreshInbox(pull: false)
                flashStatus(.info("Moved to Inbox"))
            } catch { inbox.error = ActionableError.classify(error) }
            return
        }
        await archive(ids: ids)
    }

    func bulkMarkUnread() async {
        let ids = Array(inbox.selection)
        guard !ids.isEmpty else { return }
        do {
            try await cli.markUnread(ids: ids)
            inbox.clearSelection()
            await refreshInbox(pull: false)
        } catch { inbox.error = ActionableError.classify(error) }
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
        await deleteMessages(ids: Array(inbox.selection))
    }

    // ── Account quick-switcher ────────────────────────────────────────────

    /// Activate the nth account (1-indexed). Hooked to ⌘1…⌘9 via RootView.
    /// No-op if there's no account at that index.
    func selectAccount(at index: Int) async {
        guard index >= 1, index <= session.accounts.count else { return }
        await switchAccount(session.accounts[index - 1])
    }

    func selectUnifiedInbox() async { await switchAccount(nil) }

    private func switchAccount(_ account: Account?) async {
        guard await prepareToLeaveCompose() else { return }
        session.currentAccount = account
        persistPreferredAccount()
        reader.inflight?.cancel()
        reader.loaded = nil
        inbox.messages = []
        inbox.snoozedMessages = []
        inbox.drafts = []
        inbox.selection = []
        inbox.searchResults = []
        inbox.searchError = nil
        inbox.totalUnread = 0
        searchDebounceTask?.cancel()
        searchGeneration = UUID()
        router.currentView = .inbox
        await refreshInbox(pull: false)
        await refreshDrafts()
    }

    func selectFolder(_ folder: InboxState.Folder) async {
        guard await prepareToLeaveCompose() else { return }
        inbox.currentFolder = folder
        inbox.searchQuery = ""
        scheduleSearch()
        inbox.focusedRowIndex = -1
        inbox.clearSelection()
        back()
        if folder == .drafts { await refreshDrafts() }
    }

    @discardableResult
    func prepareToLeaveCompose() async -> Bool {
        guard case .compose = router.currentView else { return true }
        guard !compose.isSending else { return false }
        guard !compose.isLoadingAttachments else {
            compose.error = "Wait for the original attachments to finish downloading."
            return false
        }
        NotificationCenter.default.post(name: .minimailCommitRecipients, object: nil)
        await flushAutosave()
        return compose.error == nil
    }

    func navigate(to destination: RouterState.View) async {
        guard await prepareToLeaveCompose() else { return }
        router.settingsSection = nil
        router.currentView = destination
    }

    func openOutbox() async { await openSettings(section: "outbox") }

    func openSettings(section: String) async {
        guard await prepareToLeaveCompose() else { return }
        router.settingsSection = section
        router.currentView = .settings
    }

    func saveComposeAndStartNew() async {
        guard !isNavigating else { return }
        isNavigating = true
        defer { isNavigating = false }
        guard await prepareToLeaveCompose() else { return }
        startCompose()
    }

    func composeReply(to message: Message, replyAll: Bool = false, forward: Bool = false) async {
        guard !isNavigating else { return }
        isNavigating = true
        defer { isNavigating = false }
        guard await prepareToLeaveCompose() else { return }
        do {
            let full = try await cli.readMessage(id: message.id, markRead: false)
            if forward { startForward(of: full) }
            else { startCompose(replyTo: full, replyAll: replyAll) }
        } catch { inbox.error = ActionableError.classify(error) }
    }

    // ── Search ────────────────────────────────────────────────────────────

    /// Debounced entry point: cancel any pending search task, schedule a new
    /// one 300ms out. Called from the inbox TextField's onChange handler so
    /// keystrokes fan-in into a single CLI round-trip rather than spawning
    /// one process per character. If the user clears the query, we short-
    /// circuit: cancel the in-flight search and fall back to the folder-
    /// filtered list via `InboxState.visible()`.
    func scheduleSearch() {
        searchDebounceTask?.cancel()
        searchGeneration = UUID()
        let trimmed = inbox.searchQuery.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            // Clear-query path — reset search state so visible() routes back
            // to the folder filter on the next render.
            inbox.isSearching = false
            inbox.searchError = nil
            inbox.searchResults = []
            return
        }
        inbox.isSearching = true
        inbox.searchResults = []
        searchDebounceTask = Task { [weak self] in
            // 300ms debounce is short enough that typists barely notice,
            // long enough that the CLI isn't hammered mid-word.
            try? await Task.sleep(nanoseconds: 300_000_000)
            if Task.isCancelled { return }
            await self?.performSearch()
        }
    }

    /// Run a free-text search through the CLI's FTS5 index. Respects the
    /// current account filter (nil = unified). Results drop straight into
    /// `inbox.searchResults`; the view picks them up via `visible()`.
    func performSearch() async {
        let query = inbox.searchQuery.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else {
            inbox.isSearching = false
            inbox.searchResults = []
            inbox.searchError = nil
            return
        }
        let generation = searchGeneration
        let account = session.currentAccount?.email
        inbox.isSearching = true
        inbox.searchError = nil
        defer { if searchGeneration == generation { inbox.isSearching = false } }
        do {
            let hits = try await cli.search(
                query: query,
                account: account,
                limit: 500
            )
            if Task.isCancelled { return }
            // Only commit results if the query we searched for is still the
            // user's current query — guards against a slow search run
            // finishing after the user has already moved on or cleared the
            // box. Without this you'd see stale hits flash in after clear.
            if searchGeneration == generation, session.currentAccount?.email == account,
               inbox.searchQuery.trimmingCharacters(in: .whitespaces) == query {
                inbox.searchResults = hits
            }
        } catch {
            if Task.isCancelled || searchGeneration != generation { return }
            inbox.searchError = ActionableError.classify(error)
            inbox.searchResults = []
        }
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
        let account = session.currentAccount?.email
        do {
            // Traverse the mailbox, not just the pages currently visible.
            for archived in [false, true] {
                for snoozed in [false, true] {
                    var cursor: Int64?
                    repeat {
                        let page = try await cli.listInboxPage(
                            account: account, archived: archived, snoozed: snoozed,
                            limit: 100, after: cursor
                        )
                        let ids = (page.messages ?? []).filter(\.isUnread).map(\.id)
                        if !ids.isEmpty { try await cli.markRead(ids: ids) }
                        let next = page.has_more == true ? page.next_cursor : nil
                        guard next != cursor || next == nil else { break }
                        cursor = next
                    } while cursor != nil
                }
            }
            await refreshInbox(pull: false)
        } catch {
            inbox.error = ActionableError.classify(error)
        }
    }

    func markUnread(message: Message) async {
        do {
            try await cli.markUnread(ids: [message.id])
            mutateMessage(message.id) { $0.is_read = false }
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
            markMessageReadLocally(id: message.id)
        } catch {
            inbox.error = ActionableError.classify(error)
        }
    }

    func unarchive(message: Message) async {
        do {
            try await cli.unarchive(ids: [message.id])
            mutateMessage(message.id) { $0.archived = false }
            await refreshInbox(pull: false)
        } catch {
            inbox.error = ActionableError.classify(error)
        }
    }

    func delete(message: Message) async { await deleteMessages(ids: [message.id]) }

    func deleteMessages(ids: [Int64]) async {
        do {
            try await cli.delete(ids: ids)
            if let current = reader.loaded, ids.contains(current.id) {
                router.currentView = .inbox
                reader.loaded = nil
            }
            inbox.selection.subtract(ids)
            await refreshInbox(pull: false)
            flashStatus(.deleted(count: ids.count))
        } catch {
            inbox.error = ActionableError.classify(error)
        }
    }

    // ── Attachments ───────────────────────────────────────────────────────

    func loadInlineImages(for message: Message) async {
        guard let html = message.html_body, html.range(of: "cid:", options: .caseInsensitive) != nil else { return }
        let generation = reader.contentGeneration
        let attachments = reader.attachments(for: message.id).filter { $0.content_id != nil }
        var images: [String: String] = [:]
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Minimail-Inline-\(UUID().uuidString)")
        let batch = beginAttachmentExportBatch()
        defer {
            endAttachmentExportBatch(batch)
            try? FileManager.default.removeItem(at: folder)
        }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var remainingBytes = 25 * 1024 * 1024
            for attachment in attachments {
                guard !Task.isCancelled, reader.contentGeneration == generation else { return }
                guard let cid = attachment.content_id,
                      let mime = attachment.content_type?.lowercased(),
                      EmailHTML.inlineImageTypes.contains(mime),
                      EmailHTML.referencesContentID(cid, in: html) else { continue }
                if let size = attachment.size, size > remainingBytes { continue }
                let file = folder.appendingPathComponent(UUID().uuidString)
                try await exportAttachment(attachment, messageID: message.id, to: file)
                let budget = remainingBytes
                let data = try await Task.detached {
                    let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                    guard size <= budget else { throw EmailCLI.CLIError.badInput("Embedded images exceed the 25 MB preview limit.") }
                    return try Data(contentsOf: file)
                }.value
                remainingBytes -= data.count
                images[EmailHTML.normalizedContentID(cid)] = "data:\(mime);base64,\(data.base64EncodedString())"
            }
            guard !Task.isCancelled, reader.contentGeneration == generation else { return }
            reader.inlineImages[message.id] = images
            reader.inlineImageErrors[message.id] = EmailHTML.unresolvedContentIDs(in: html, images: images).isEmpty
                ? nil : "Some embedded images are unavailable. You can still open the message's attachments."
        } catch {
            guard !Task.isCancelled, reader.contentGeneration == generation else { return }
            reader.inlineImages[message.id] = images
            reader.inlineImageErrors[message.id] = "Embedded images: " + ActionableError.classify(error).message
        }
    }

    func reloadAttachments(messageID: Int64) async {
        let route = router.currentView
        do {
            let attachments = try await cli.listAttachments(messageID: messageID)
            guard router.currentView == route else { return }
            reader.attachmentsByMessageID[messageID] = attachments
            reader.attachmentErrors[messageID] = nil
        } catch {
            guard router.currentView == route else { return }
            reader.attachmentErrors[messageID] = ActionableError.classify(error).message
        }
    }

    private var attachmentExportWaiters: [CheckedContinuation<Void, Never>] = []
    private var attachmentExportBatches: Set<UUID> = []

    func beginAttachmentExportBatch() -> UUID {
        let token = UUID()
        attachmentExportBatches.insert(token)
        return token
    }

    func endAttachmentExportBatch(_ token: UUID) {
        attachmentExportBatches.remove(token)
        resumeAttachmentExportWaiters()
    }

    private func resumeAttachmentExportWaiters() {
        guard reader.attachmentDownloads.isEmpty, attachmentExportBatches.isEmpty else { return }
        let waiters = attachmentExportWaiters
        attachmentExportWaiters = []
        for waiter in waiters { waiter.resume() }
    }

    func exportAttachment(_ attachment: Attachment, messageID: Int64, to destination: URL) async throws {
        let key = "\(messageID):\(attachment.id)"
        guard reader.attachmentDownloads.insert(key).inserted else {
            throw EmailCLI.CLIError.badInput("This attachment is already downloading.")
        }
        defer {
            reader.attachmentDownloads.remove(key)
            resumeAttachmentExportWaiters()
        }
        try await cli.downloadAttachment(messageID: messageID, attachmentID: attachment.id, to: destination)
    }

    // ── Drafts ───────────────────────────────────────────────────────────

    func refreshDrafts() async {
        let account = session.currentAccount?.email
        do {
            let drafts = try await cli.listDrafts(account: account)
            guard session.currentAccount?.email == account else { return }
            inbox.drafts = drafts
        } catch {
            inbox.error = ActionableError.classify(error)
        }
    }

    func openDraft(_ draft: Draft) async {
        if pendingSend?.originalDraftID == draft.id {
            await restorePendingSend()
            return
        }
        guard deliveringSend?.originalDraftID != draft.id else {
            flashStatus(.info("This draft is being sent"))
            return
        }
        guard await prepareToLeaveCompose() else { return }
        // The sidebar can still contain the version from before autosave.
        if compose.editingDraftID == draft.id {
            router.currentView = .compose(compose.replyToID)
            return
        }
        edit(draft: draft)
    }

    func deleteDraft(_ draft: Draft) async {
        guard pendingSend?.originalDraftID != draft.id,
              deliveringSend?.originalDraftID != draft.id else {
            flashStatus(.info("Undo the send before discarding this draft"))
            return
        }
        if compose.editingDraftID == draft.id {
            await discardDraft()
            return
        }
        do {
            try await cli.deleteDraft(id: draft.id)
            await refreshDrafts()
        } catch { inbox.error = ActionableError.classify(error) }
    }

    func edit(draft: Draft) {
        compose.clear()
        compose.editingDraftID = draft.id
        compose.to = (draft.to ?? []).joined(separator: ", ")
        compose.cc = (draft.cc ?? []).joined(separator: ", ")
        compose.bcc = (draft.bcc ?? []).joined(separator: ", ")
        compose.replyTo = (draft.reply_to ?? []).joined(separator: ", ")
        compose.scheduledAt = Dates.parse(draft.scheduled_at)
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
        // Keep missing attachments visible. Saving and sending explain how
        // to repair them instead of silently dropping a promised file.
        if let paths = draft.attachment_paths, !paths.isEmpty {
            compose.attachments = paths.map { URL(fileURLWithPath: $0) }
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
            guard let self else { return }
            // The debounce owns only its delay. A database write must finish
            // even when another keystroke starts the next debounce.
            self.compose.autosaveTask = nil
            await self.saveLatestDraft()
        }
    }

    private func saveLatestDraft() async {
        while let active = activeAutosave { await active.value; await Task.yield() }
        let task = Task { await self.performAutosave() }
        activeAutosave = task
        await task.value
        activeAutosave = nil
    }

    private func performAutosave() async {
        // Reentrancy guard: if a save is in flight, skip this call — the next
        // keystroke will reschedule. Prevents a fast typist from storming
        // createDraft with concurrent tasks (each picks up editingDraftID=nil).
        guard !compose.isAutosaving, (compose.hasContent || compose.editingDraftID != nil) else { return }
        compose.isAutosaving = true
        let generation = compose.generation
        defer { compose.isAutosaving = false }

        let toList = splitAddresses(compose.to)
        let ccList = splitAddresses(compose.cc)
        let bccList = splitAddresses(compose.bcc)
        let subject = compose.subject
        let body = compose.body
        let html = compose.bodyHTML
        // A missing attachment requires a visible repair action. Never
        // silently save or send a reduced attachment list.
        let allAttachments = compose.attachments
        let existingAttachments = allAttachments.filter {
            FileManager.default.fileExists(atPath: $0.path)
        }
        let droppedCount = allAttachments.count - existingAttachments.count
        if droppedCount > 0 {
            compose.error = "An attachment is missing. Remove it or attach it again to save this draft."
            return
        }

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
                // Pass account so sender changes on an existing draft persist
                // across reopen. Before this, editDraft ignored the account
                // and the Rust UPDATE didn't touch account_email — user
                // picks a new From, closes, reopens → sees original.
                let saved = try await cli.editDraft(
                    id: id, account: accountEmail,
                    to: toList, cc: ccList, bcc: bccList,
                    subject: subject, text: body, html: html,
                    attachments: existingAttachments,
                    replyTo: splitAddresses(compose.replyTo),
                    scheduledAt: compose.scheduledAt.map { Self.isoFormatter.string(from: $0) },
                    clearSchedule: compose.scheduledAt == nil,
                    clearHTML: html == nil
                )
                guard compose.generation == generation else { return }
                adoptDraftAttachments(saved, replacing: existingAttachments)
            } else {
                let draft = try await cli.createDraft(
                    account: accountEmail,
                    to: toList, cc: ccList, bcc: bccList,
                    subject: subject, text: body, html: html,
                    attachments: existingAttachments,
                    replyToMessageID: compose.replyToID,
                    replyTo: splitAddresses(compose.replyTo),
                    scheduledAt: compose.scheduledAt.map { Self.isoFormatter.string(from: $0) }
                )
                guard compose.generation == generation else { return }
                compose.editingDraftID = draft.id
                adoptDraftAttachments(draft, replacing: existingAttachments)
            }
            guard compose.generation == generation else { return }
            compose.error = nil
            compose.lastAutosaveAt = Date()
        } catch {
            // A cancelled CLI call (user kept typing → debounce superseded this
            // run, or navigated away) is not a failure — swallow it silently
            // rather than flashing a phantom "Draft autosave failed: exited
            // with 15" toast.
            if Task.isCancelled { return }
            if case EmailCLI.CLIError.cancelled = error { return }
            // Route through ActionableError so the user sees a human-readable
            // error when the CLI itself fails (not just a silent retry on
            // next keystroke). Silent swallow was masking real bugs — e.g.
            // the account not existing in any profile, or the draft id
            // going stale.
            let actionable = ActionableError.classify(error)
            compose.error = "Draft could not be saved: \(actionable.message)"
        }
    }

    private func adoptDraftAttachments(_ draft: Draft, replacing originals: [URL]) {
        guard let paths = draft.attachment_paths, paths.count == originals.count else { return }
        // Typing/removing/adding files can continue during the save. Replace
        // only URLs still present; do not resurrect a removed attachment.
        for (original, path) in zip(originals, paths) {
            if let index = compose.attachments.firstIndex(of: original) {
                compose.attachments[index] = URL(fileURLWithPath: path)
            }
        }
    }

    /// Explicit "Discard" — deletes the backing draft and clears compose state.
    func discardDraft() async {
        compose.autosaveTask?.cancel()
        compose.autosaveTask = nil
        if let active = activeAutosave { await active.value }
        do {
            if let id = compose.editingDraftID { try await cli.deleteDraft(id: id) }
            compose.clear()
            router.currentView = .inbox
            await refreshDrafts()
        } catch { compose.error = ActionableError.classify(error).message }
    }

    func flushAutosave() async {
        compose.autosaveTask?.cancel()
        compose.autosaveTask = nil
        await saveLatestDraft()
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
            let recipients = Self.replyRecipients(
                for: msg,
                selfEmail: compose.fromOverride?.email ?? msg.account_email,
                replyAll: replyAll
            )
            compose.to = recipients.to.joined(separator: ", ")
            let sub = msg.subject ?? ""
            compose.subject = sub.lowercased().hasPrefix("re:") ? sub : "Re: \(sub)"
            if replyAll {
                compose.cc = recipients.cc.joined(separator: ", ")
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
        let generation = compose.generation
        compose.isLoadingAttachments = true
        forwardAttachmentTask = Task { [weak self] in
            await self?.reattachOriginalAttachments(for: message.id, generation: generation)
        }
    }

    private var forwardAttachmentTask: Task<Void, Never>?

    func waitForAttachmentDownloads() async {
        await forwardAttachmentTask?.value
        if !reader.attachmentDownloads.isEmpty || !attachmentExportBatches.isEmpty {
            await withCheckedContinuation { attachmentExportWaiters.append($0) }
        }
    }

    /// Download every attachment on the source message into a temp directory
    /// and append the file URLs to `compose.attachments`. Mirrors what Apple
    /// Mail / Gmail do when you Forward — the user expects the original
    /// files to ride along.
    private func reattachOriginalAttachments(for messageID: Int64, generation: UUID) async {
        guard compose.generation == generation else { return }
        defer { if compose.generation == generation { compose.isLoadingAttachments = false } }
        let list: [Attachment]
        do { list = try await cli.listAttachments(messageID: messageID) }
        catch {
            guard compose.generation == generation else { return }
            // Persist a missing-file chip so closing/reopening the draft can
            // never turn a failed attachment lookup into a successful omission.
            addAttachment(FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("Original attachments could not be loaded"))
            compose.error = "Original attachments could not be loaded. Reattach them, or remove the missing-file chip to continue without them."
            return
        }
        guard compose.generation == generation, !list.isEmpty else { return }
        let tempBase = FileManager.default.temporaryDirectory
            .appendingPathComponent("minimail-fwd-\(messageID)-\(Int(Date().timeIntervalSince1970))",
                                    isDirectory: true)
        try? FileManager.default.createDirectory(at: tempBase, withIntermediateDirectories: true)
        for attachment in list {
            guard compose.generation == generation else { return }
            // The filename is server/sender-controlled. `appendingPathComponent`
            // does NOT strip `..`, so a name like "../../../../Library/..."
            // would let a malicious sender write attachment bytes to an
            // arbitrary user-writable path the instant the user hits Forward.
            // Reduce to a bare leaf, reject dotfiles/traversal, then assert the
            // resolved path stays inside the temp dir.
            let rawName = attachment.filename ?? ""
            var leaf = (rawName as NSString).lastPathComponent
            if leaf.isEmpty || leaf == "." || leaf == ".." || leaf.hasPrefix(".") {
                leaf = "attachment-\(attachment.id)"
            }
            let dest = tempBase.appendingPathComponent(UUID().uuidString + "-" + leaf)
            guard dest.standardizedFileURL.path
                .hasPrefix(tempBase.standardizedFileURL.path + "/") else {
                Log.cli.error("rejected forward attachment with traversal filename")
                continue
            }
            do {
                try await cli.downloadAttachment(messageID: messageID,
                                                 attachmentID: attachment.id,
                                                 to: dest)
                // Route through the centralised helper so the late-arriving
                // attachment schedules an autosave — direct append here used
                // to skip autosave, so forward-with-attachments drafts lost
                // the files if the user closed the popover before the
                // download finished.
                guard compose.generation == generation else { return }
                addAttachment(dest)
            } catch {
                Log.cli.error("forward re-attach failed for \(leaf, privacy: .public): \(String(describing: error), privacy: .public)")
                guard compose.generation == generation else { return }
                addAttachment(dest)
                compose.error = "An attachment could not be downloaded. Reattach it, or remove its missing-file chip to continue without it."
            }
        }
    }

    /// Email-part of "Display Name <addr@host>"; falls back to the raw value.
    private static func emailPart(of raw: String) -> String {
        raw.emailAddressPart
    }

    /// Mirrors email-cli's reply recipient rules so the compose preview and
    /// eventual `send --reply-to-msg` payload agree. Received mail replies to
    /// Reply-To when present; sent mail replies to the original recipients.
    /// Reply All adds original To/Cc minus self and anyone already in To.
    private static func replyRecipients(
        for message: Message,
        selfEmail: String,
        replyAll: Bool
    ) -> (to: [String], cc: [String]) {
        let selfAddress = emailPart(of: selfEmail).lowercased()
        let toRaw: [String]
        if message.direction == "sent" {
            toRaw = message.to ?? []
        } else if let replyTo = message.reply_to, !replyTo.isEmpty {
            toRaw = replyTo
        } else {
            toRaw = [message.from_addr]
        }

        let to = stableAddressDedup(toRaw, excluding: [selfAddress])
        guard replyAll else { return (to, []) }

        let seenTo = Set(to.map { emailPart(of: $0).lowercased() })
        let cc = stableAddressDedup(
            (message.to ?? []) + (message.cc ?? []),
            excluding: Set([selfAddress]).union(seenTo)
        )
        return (to, cc)
    }

    private static func stableAddressDedup(_ raw: [String], excluding excluded: Set<String>) -> [String] {
        var seen = excluded
        var out: [String] = []
        for value in raw {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = emailPart(of: trimmed).lowercased()
            guard !trimmed.isEmpty, !key.isEmpty, seen.insert(key).inserted else { continue }
            out.append(trimmed)
        }
        return out
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
        guard !compose.isSending, deliveringSend == nil else { return false }
        guard !compose.isLoadingAttachments else {
            compose.error = "Wait for the original attachments to finish downloading."
            return false
        }
        NotificationCenter.default.post(name: .minimailCommitRecipients, object: nil)
        compose.isSending = true
        defer { compose.isSending = false }
        compose.error = nil
        await flushAutosave()
        guard compose.error == nil else { return false }
        let to = splitAddresses(compose.to)
        let cc = splitAddresses(compose.cc)
        let bcc = splitAddresses(compose.bcc)
        let replyTo = splitAddresses(compose.replyTo)
        guard !to.isEmpty else {
            compose.error = "Add at least one recipient"
            return false
        }
        if let invalid = (to + cc + bcc + replyTo).first(where: { !$0.looksLikeEmail }) {
            compose.error = "Fix invalid address: \(invalid)"
            return false
        }
        // If a previous queued send is still pending, fire it immediately so
        // its payload doesn't sit behind the new one.
        if pendingSend != nil {
            await flushPendingSendNow()
        }

        let now = Date()
        let html = compose.bodyHTML
        // email-cli requires an explicit text/html body argument. Passing an
        // empty string is intentional for subject-only emails the user has
        // acknowledged in the composer warning.
        let plainText = html == nil ? compose.body : (compose.body.isEmpty ? nil : compose.body)
        // Resolve send identity in priority order:
        //   1. compose.fromOverride (user picked it explicitly in the dropdown)
        //   2. composeFromAccount (currentAccount, or default, or first)
        let fromAccount = compose.fromOverride?.email ?? composeFromAccount?.email
        // Missing files require repair; never silently send fewer attachments.
        let existingAttachments = compose.attachments.filter {
            FileManager.default.fileExists(atPath: $0.path)
        }
        let droppedAttachments = compose.attachments.count - existingAttachments.count
        if droppedAttachments > 0 {
            compose.error = "An attachment is missing. Remove it or attach the file again before sending."
            return false
        }
        if let scheduled = compose.scheduledAt, scheduled <= Date() {
            compose.error = "Choose a future send time."
            return false
        }
        // Scheduled sends bypass the local undo window — Resend holds them
        // server-side and the user picked a wake time minutes-to-days out, so
        // the local 10-second hold is meaningless (and the countdown toast
        // would falsely read "Sending in 10s"). Fire straight to the CLI when
        // scheduled_at is present.
        let scheduledISO: String? = compose.scheduledAt.map(Self.isoFormatter.string(from:))
        let snapshot = PendingSend(
            from: fromAccount,
            to: to,
            cc: cc,
            bcc: bcc,
            replyTo: replyTo,
            subject: compose.subject,
            text: plainText,
            html: html,
            attachments: existingAttachments,
            replyToMessageID: compose.replyToID,
            scheduledAt: scheduledISO,
            originalDraftID: compose.editingDraftID,
            queuedAt: now,
            deadline: now.addingTimeInterval(Self.undoSendWindow)
        )

        compose.clear()
        router.currentView = .inbox
        pendingSend = snapshot

        // Server-scheduled: skip the undo timer and hand off immediately.
        if scheduledISO != nil {
            await firePendingSend()
            return true
        }

        pendingSendTask?.cancel()
        pendingSendTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.undoSendWindow))
            if Task.isCancelled { return }
            self?.pendingSendTask = nil
            await self?.firePendingSend()
        }
        return true
    }

    /// Actually run the CLI send for the queued snapshot. Safe to call even
    /// if `pendingSend` was already cleared (idempotent).
    private func firePendingSend() async {
        guard let snap = pendingSend else { return }
        pendingSendTask?.cancel()
        pendingSendTask = nil
        pendingSend = nil
        deliveringSend = snap
        defer {
            deliveringSend = nil
            let waiters = deliveryWaiters
            deliveryWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
        }
        do {
            try await cli.send(
                from: snap.from,
                to: snap.to,
                cc: snap.cc,
                bcc: snap.bcc,
                replyTo: snap.replyTo,
                subject: snap.subject,
                text: snap.text,
                html: snap.html,
                attachments: snap.attachments,
                replyToMessageID: snap.replyToMessageID,
                scheduledAt: snap.scheduledAt
            )
            if let draftID = snap.originalDraftID {
                try? await cli.deleteDraft(id: draftID)
            }
            // Successful send clears any stale failure affordance from a
            // previous attempt — the banner was about that attempt, not this
            // one.
            lastFailedSend = nil
            lastOutboxSnapshot = []
            flashStatus(snap.scheduledAt == nil ? .sent : .info("Scheduled for delivery"))
            await refreshInbox(pull: false)
            if inbox.currentFolder == .drafts { await refreshDrafts() }
        } catch {
            // Keep the snapshot accessible via `lastFailedSend` so the
            // outboxBanner in RootView can offer Retry / Edit. The old
            // implementation nilled `pendingSend` and flashed an error that
            // disappeared — the message felt "lost" even though email-cli
            // had persisted it in the outbox table. (ritalin O-022)
            lastFailedSend = snap
            // Snapshot the outbox so the banner can show the matching failed
            // row (status + attempts + last_error). Best-effort: a failure to
            // list the outbox isn't itself surface-worthy — the banner still
            // works off `lastFailedSend`.
            lastOutboxSnapshot = (try? await cli.outboxList(account: snap.from)) ?? []
            let classified = ActionableError.classify(error)
            inbox.error = classified
            Log.send.error("send failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Re-queue the last failed send as a fresh pendingSend and fire it
    /// immediately. Matches "Retry" on the recovery banner.
    func retryLastFailedSend() async {
        // Retry the durable outbox row through Settings so its idempotency
        // key and attachment snapshot survive. A fresh send can duplicate mail.
        await openOutbox()
    }

    /// User dismissed the banner without choosing. Drops the in-memory
    /// snapshot; the Rust outbox row is still there and `outbox retry` via a
    /// future Settings-side UI can surface it again.
    func dismissLastFailedSend() {
        lastFailedSend = nil
        lastOutboxSnapshot = []
    }

    /// Map EmailCLI errors to user-facing copy that mentions what went wrong
    /// and hints at what to fix. Unknown errors fall back to the same
    /// ActionableError classifier the rest of the app uses, so nothing
    /// leaks raw stderr URLs / tokens to the banner.
    static func describeSendError(_ error: Error) -> String {
        guard let cliError = error as? EmailCLI.CLIError else {
            return "Send failed: \(ActionableError.classify(error).message)"
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
    func restorePendingSend() async {
        guard await prepareToLeaveCompose() else { return }
        undoPendingSend()
    }

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
        compose.replyTo = snap.replyTo.joined(separator: ", ")
        compose.scheduledAt = snap.scheduledAt.flatMap(Dates.parse)
        compose.fromOverride = session.accounts.first { $0.email == snap.from }
        router.currentView = .compose(snap.replyToMessageID)
    }

    /// Complete a queued send on explicit Send Now or app quit. Hiding the
    /// interface keeps the full Undo Send interval.
    func flushPendingSendNow() async {
        pendingSendTask?.cancel()
        pendingSendTask = nil
        if pendingSend != nil {
            await firePendingSend()
        }
    }

    /// Quit waits for the active send to settle, including its draft cleanup.
    func waitForDelivery() async {
        guard deliveringSend != nil else { return }
        await withCheckedContinuation { deliveryWaiters.append($0) }
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
    var emailAddressPart: String {
        let trimmed = self.trimmingCharacters(in: .whitespacesAndNewlines)
        if let open = trimmed.lastIndex(of: "<"),
           let close = trimmed[trimmed.index(after: open)...].firstIndex(of: ">"),
           open < close {
            return String(trimmed[trimmed.index(after: open)..<close])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
    }

    var looksLikeEmail: Bool {
        let pattern = #"^[A-Z0-9a-z._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}$"#
        return emailAddressPart.range(of: pattern, options: .regularExpression) != nil
    }

    /// Split a raw address list into individual tokens. Splits on commas /
    /// semicolons / newlines / tabs — NOT whitespace, so display names like
    /// "Alice Example <alice@x.com>" survive intact. Trims each result.
    func splitAddressTokens() -> [String] {
        var tokens: [String] = []
        var current = ""
        var inQuotes = false
        var angleDepth = 0

        func commit() {
            let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { tokens.append(trimmed) }
            current.removeAll(keepingCapacity: true)
        }

        for ch in self {
            switch ch {
            case "\"":
                inQuotes.toggle()
                current.append(ch)
            case "<":
                if !inQuotes { angleDepth += 1 }
                current.append(ch)
            case ">":
                if !inQuotes, angleDepth > 0 { angleDepth -= 1 }
                current.append(ch)
            case ",", ";", "\n", "\t":
                if inQuotes || angleDepth > 0 {
                    current.append(ch)
                } else {
                    commit()
                }
            default:
                current.append(ch)
            }
        }
        commit()
        return tokens
    }
}
