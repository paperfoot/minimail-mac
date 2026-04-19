import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    let appState = AppState()
    private var eventMonitor: Any?
    private var pollTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        MinimailNotifier.shared.popoverOpener = self
        MinimailNotifier.shared.register()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(
                systemSymbolName: "envelope.fill",
                accessibilityDescription: "Minimail"
            )
            button.image?.isTemplate = true
            button.imagePosition = .imageLeading
            button.action = #selector(togglePopover(_:))
            button.target = self
        }

        popover = NSPopover()
        popover.contentSize = NSSize(width: 420, height: 580)
        // applicationDefined = do NOT auto-dismiss on outside click.
        // We control dismissal explicitly (status-item click, Esc, or in-view close).
        popover.behavior = .applicationDefined
        popover.animates = true
        popover.contentViewController = NSHostingController(
            rootView: RootView()
                .environment(appState)
                .frame(width: 420, height: 580)
        )

        // Esc key closes the popover when it has focus — standard macOS expectation.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(popoverDidClose(_:)),
            name: NSPopover.didCloseNotification,
            object: popover
        )

        Task { @MainActor in
            await appState.bootstrap()
            // Seed "seen" set so we don't backfill notifications for every
            // existing received message on first launch.
            let receivedIDs = appState.inbox.messages
                .filter { $0.direction == "received" }
                .map(\.id)
            MinimailNotifier.shared.seed(receivedIDs)
            refreshStatusTitle()
            startPollingForNewMail()
        }

        // Re-sync the menu bar title whenever the unread count changes.
        // withObservationTracking is one-shot; re-register inside onChange.
        observeUnread()
    }

    /// Background mail check independent of the popover. Runs every 60s while
    /// the app is alive. After each refresh, diff new received messages against
    /// the seen set and fire notifications. Skipped while the user is mid-
    /// compose so their UI doesn't jitter during typing.
    private func startPollingForNewMail() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if case .compose = self.appState.router.currentView { return }
                await self.appState.refreshInbox(pull: true)
                let received = self.appState.inbox.messages.filter { $0.direction == "received" }
                MinimailNotifier.shared.notifyNewMessages(received)
                self.refreshStatusTitle()
            }
        }
    }

    /// Invoked by MinimailNotifier when a notification banner is clicked.
    func openFromNotification(messageID: Int64?) {
        NSApp.activate(ignoringOtherApps: true)
        if !popover.isShown { showPopover() }
        guard let id = messageID else { return }
        if let msg = appState.inbox.messages.first(where: { $0.id == id }) {
            appState.open(message: msg)
        } else {
            appState.router.currentView = .reader(id)
        }
    }

    private func observeUnread() {
        withObservationTracking {
            _ = appState.totalUnread
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.refreshStatusTitle()
                self?.observeUnread()
            }
        }
    }

    @objc private func togglePopover(_ sender: Any?) {
        if popover.isShown {
            popover.performClose(sender)
        } else {
            showPopover()
        }
    }

    private func showPopover() {
        guard let button = statusItem.button else { return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()

        // While the popover is open, watch for clicks on our status item and
        // Esc key; dismiss on either. Clicks elsewhere in other apps are
        // intentionally ignored (applicationDefined behaviour).
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            if event.keyCode == 53 { // Escape
                self?.popover.performClose(nil)
                return nil
            }
            return event
        }

        Task { @MainActor in
            await appState.refreshInbox()
            refreshStatusTitle()
        }
    }

    @objc private func popoverDidClose(_ notification: Notification) {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
    }

    private func refreshStatusTitle() {
        let count = appState.totalUnread
        if let button = statusItem.button {
            if count > 0 {
                let shown = count > 99 ? "99+" : String(count)
                button.title = " \(shown)"
            } else {
                button.title = ""
            }
        }
    }
}
