import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private let appState = AppState()
    private var eventMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
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
            refreshStatusTitle()
        }

        // Re-sync the menu bar title whenever the unread count changes.
        // withObservationTracking is one-shot; re-register inside onChange.
        observeUnread()
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
