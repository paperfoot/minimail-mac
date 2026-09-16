import AppKit
import UserNotifications

/// Owns the `UNUserNotificationCenter` lifecycle for Minimail. Registers on
/// launch, fires a local notification when new received mail arrives, and
/// routes a notification tap back to the popover + message reader.
@MainActor
final class MinimailNotifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = MinimailNotifier()
    private var seenIDs: Set<Int64> = []
    private var granted = false
    private let startedAt = Date()
    /// Set by AppDelegate so the notifier can route taps.
    weak var popoverOpener: AppDelegate?

    static let replyActionID = "minimail.reply"
    static let markReadActionID = "minimail.markRead"
    static let archiveActionID = "minimail.archive"
    static let categoryID = "minimail.newMessage"

    func register() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self

        // Registering category + actions lets banners surface Reply /
        // Mark-Read / Archive buttons inline (hold-to-reveal on macOS).
        let reply = UNNotificationAction(
            identifier: Self.replyActionID,
            title: "Reply",
            options: [.foreground, .authenticationRequired]
        )
        let markRead = UNNotificationAction(
            identifier: Self.markReadActionID,
            title: "Mark as Read",
            options: []
        )
        let archive = UNNotificationAction(
            identifier: Self.archiveActionID,
            title: "Archive",
            options: []
        )
        let category = UNNotificationCategory(
            identifier: Self.categoryID,
            actions: [reply, markRead, archive],
            intentIdentifiers: [],
            options: [.customDismissAction]
        )
        center.setNotificationCategories([category])

        center.requestAuthorization(options: [.alert, .sound, .badge]) { [weak self] ok, _ in
            Task { @MainActor in self?.granted = ok }
        }
    }

    /// Seed the "already seen" set at launch so we don't spam notifications
    /// for every old message on the first refresh.
    func seed(_ ids: [Int64]) {
        seenIDs = Set(ids)
    }

    /// Call after each refresh. Fires a notification for every received
    /// message whose id isn't in the seen set, then absorbs it.
    func notifyNewMessages(_ messages: [Message]) {
        guard granted else {
            // Still seed the set so we don't backfill once permission lands.
            for msg in messages { seenIDs.insert(msg.id) }
            return
        }
        let newOnes = messages.filter { msg in
            msg.isUnread && !seenIDs.contains(msg.id)
                && (Dates.parse(msg.created_at) ?? .distantPast) >= startedAt
        }
        for msg in newOnes {
            fire(for: msg)
        }
        for msg in messages { seenIDs.insert(msg.id) }
    }

    private func fire(for msg: Message) {
        // Respect the per-account mute toggle from Settings.
        if MinimailNotifier.isMuted(msg.account_email) { return }
        let content = UNMutableNotificationContent()
        content.title = msg.fromParts.name ?? msg.fromParts.email
        content.subtitle = msg.displaySubject
        if let body = msg.snippet, !body.isEmpty {
            content.body = body
        }
        content.sound = .default
        content.userInfo = [
            "messageID": msg.id,
            "from": msg.from_addr,
            "subject": msg.subject ?? "",
        ]
        content.categoryIdentifier = Self.categoryID

        let req = UNNotificationRequest(
            identifier: "minimail-msg-\(msg.id)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(req) { _ in }
    }

    // ── UNUserNotificationCenterDelegate ─────────────────────────────────

    // Show banners even when Minimail is in the foreground (we're an accessory
    // app, so "foreground" is rarely visible anyway).
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping @Sendable (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping @Sendable () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        let id = (userInfo["messageID"] as? Int64)
            ?? (userInfo["messageID"] as? Int).map(Int64.init)
        let actionID = response.actionIdentifier
        let replyText = (response as? UNTextInputNotificationResponse)?.userText ?? ""

        Task { @MainActor in
            guard let id else { completionHandler(); return }
            switch actionID {
            case UNNotificationDismissActionIdentifier:
                break
            case Self.markReadActionID:
                await self.popoverOpener?.appState.markRead(ids: [id])
            case Self.archiveActionID:
                await self.popoverOpener?.appState.archive(ids: [id])
            case Self.replyActionID:
                self.popoverOpener?.openFromNotification(messageID: nil)
                await self.popoverOpener?.appState.replyFromNotification(id: id, text: replyText)
            default:
                self.popoverOpener?.openFromNotification(messageID: id)
            }
            completionHandler()
        }
    }
}
