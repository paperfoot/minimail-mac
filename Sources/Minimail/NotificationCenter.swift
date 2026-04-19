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
    /// Set by AppDelegate so the notifier can route taps.
    weak var popoverOpener: AppDelegate?

    func register() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
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
            msg.direction == "received" && !seenIDs.contains(msg.id)
        }
        for msg in newOnes {
            fire(for: msg)
        }
        for msg in messages { seenIDs.insert(msg.id) }
    }

    private func fire(for msg: Message) {
        let content = UNMutableNotificationContent()
        content.title = msg.fromParts.name ?? msg.fromParts.email
        content.subtitle = msg.displaySubject
        if let body = msg.text_body, !body.isEmpty {
            content.body = String(body.prefix(180))
        }
        content.sound = .default
        content.userInfo = ["messageID": msg.id]

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
        Task { @MainActor in
            self.popoverOpener?.openFromNotification(messageID: id)
            completionHandler()
        }
    }
}
