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
        // LSUIElement apps don't get a default menu, which means NSTextField
        // never receives the standard ⌘C / ⌘V / ⌘X / ⌘A / ⌘Z key equivalents
        // — Cocoa routes those through Edit-menu items, not NSTextField's
        // internal handling. Install a minimal Edit menu so all text inputs
        // behave correctly. This is the Apple-sanctioned pattern for
        // accessory apps (cf. "Menu Bar Extras" in Human Interface Guidelines).
        Self.installMinimalMenuBar()

        // Start MetricKit local diagnostics unless the user opted out.
        // Nothing is uploaded; payloads are written to Application Support
        // and the toggle lives in Settings → Diagnostics.
        MetricsManager.shared.applyCurrentSetting()

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
        let storedInterval = UserDefaults.standard.integer(forKey: SettingsKey.syncIntervalSeconds)
        let seconds = storedInterval == 0 ? 60 : max(30, storedInterval)
        pollTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(seconds), repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if case .compose = self.appState.router.currentView { return }
                await self.appState.refreshInbox(pull: true)
                let received = self.appState.inbox.messages.filter { $0.direction == "received" }
                MinimailNotifier.shared.notifyNewMessages(received)
                self.refreshStatusTitle()
            }
        }

        // Restart timer when the user changes the interval in Settings.
        NotificationCenter.default.removeObserver(self, name: .minimailSyncIntervalChanged, object: nil)
        NotificationCenter.default.addObserver(
            forName: .minimailSyncIntervalChanged, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.startPollingForNewMail() }
        }
    }

    /// Invoked by MinimailNotifier when a notification banner is clicked.
    func openFromNotification(messageID: Int64?) {
        NSApp.activate(ignoringOtherApps: true)
        if !popover.isShown { showPopover() }
        guard let id = messageID else { return }
        // Delegated to AppState.openMessage(id:) — handles both the "already
        // in the inbox list" and "route to reader + lazy-load body" cases,
        // plus mirrors the in-place mark-read mutation used by
        // open(message:). Previously the else-branch only changed the route,
        // so the reader would mount with reader.loaded == nil and render an
        // empty shell until the user navigated away and back.
        appState.openMessage(id: id)
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

        // Data-loss prevention: if the user closes the popover mid-draft or
        // with an undo-window still open, any debounced autosave is still
        // pending and the undo-send timer has not fired yet. Flush both now
        // so we never lose the user's keystrokes or their queued outbound
        // message. Both flushes are idempotent (cancelled task is a no-op,
        // empty pendingSend is a no-op), so firing on every close is safe —
        // the previous one-shot `didFlushOnShutdown` guard actively HURT us:
        // only the first close in the app's lifetime flushed; every close
        // thereafter was a silent data-loss window.
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.appState.flushAutosave()
            await self.appState.flushPendingSendNow()
        }
    }

    /// NSApp gives us ~5 seconds to return from this before it hard-kills us.
    /// We use that window to drain the autosave debounce and the undo-send
    /// queue so the user's last keystrokes and last queued message survive
    /// quit.
    ///
    /// Concurrency correctness note: a `DispatchSemaphore.wait()` here would
    /// block the MainActor while the flush Task (also MainActor-bound) is
    /// trying to schedule on it — classic deadlock until our 4-second
    /// timeout. Instead we run the Task detached and pump `RunLoop.current`
    /// in short intervals; that keeps the MainActor alive so the flush's
    /// async hops (CLI calls, attachment writes, etc.) can actually execute.
    func applicationWillTerminate(_ notification: Notification) {
        let done = DispatchSemaphore(value: 0)
        let state = appState
        Task.detached {
            await state.flushAutosave()
            await state.flushPendingSendNow()
            done.signal()
        }
        // Budget: 4.5 seconds total (NSApp gives us 5; keep 0.5s safety).
        let deadline = Date().addingTimeInterval(4.5)
        while done.wait(timeout: .now() + 0.05) == .timedOut {
            if Date() > deadline { break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
    }

    /// Build and install a minimal NSMenu so the standard Cocoa text-editing
    /// key equivalents work inside the popover. An LSUIElement app starts
    /// with `NSApp.mainMenu == nil`, which silently breaks ⌘A / ⌘Z / even
    /// the default `performTextFinderAction:` routing for NSTextField.
    /// Installing an Edit menu with the canonical selectors fixes every
    /// text field, rich-text editor, and WebKit view in one shot.
    private static func installMinimalMenuBar() {
        let mainMenu = NSMenu()

        // App menu (required so the Edit menu isn't the leftmost and so
        // ⌘Q works even though the app is an accessory).
        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu
        appMenu.addItem(withTitle: "Hide Minimail",
                        action: #selector(NSApplication.hide(_:)),
                        keyEquivalent: "h")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "Quit Minimail",
                        action: #selector(NSApplication.terminate(_:)),
                        keyEquivalent: "q")

        // Edit menu — the whole point of this function.
        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editItem.submenu = editMenu

        let undo = editMenu.addItem(withTitle: "Undo",
                                    action: Selector(("undo:")), keyEquivalent: "z")
        undo.keyEquivalentModifierMask = [.command]
        let redo = editMenu.addItem(withTitle: "Redo",
                                    action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(withTitle: "Cut",
                         action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy",
                         action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste",
                         action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        let pasteMatch = editMenu.addItem(withTitle: "Paste and Match Style",
                                          action: #selector(NSTextView.pasteAsPlainText(_:)),
                                          keyEquivalent: "v")
        pasteMatch.keyEquivalentModifierMask = [.command, .option, .shift]
        editMenu.addItem(withTitle: "Delete",
                         action: #selector(NSText.delete(_:)), keyEquivalent: "")
        editMenu.addItem(withTitle: "Select All",
                         action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        // Format submenu provides ⌘B / ⌘I / ⌘U for the rich-text compose
        // editor. NSTextView responds to these automatically via NSFontManager
        // when the menu items are present.
        editMenu.addItem(NSMenuItem.separator())
        let formatItem = editMenu.addItem(withTitle: "Format",
                                          action: nil, keyEquivalent: "")
        let formatMenu = NSMenu(title: "Format")
        formatItem.submenu = formatMenu
        let bold = formatMenu.addItem(withTitle: "Bold",
                                      action: #selector(NSFontManager.addFontTrait(_:)),
                                      keyEquivalent: "b")
        bold.tag = 2  // NSFontManager.addFontTrait reads tag → boldFontMask
        let italic = formatMenu.addItem(withTitle: "Italic",
                                        action: #selector(NSFontManager.addFontTrait(_:)),
                                        keyEquivalent: "i")
        italic.tag = 1  // italicFontMask
        formatMenu.addItem(withTitle: "Underline",
                           action: #selector(NSText.underline(_:)),
                           keyEquivalent: "u")

        NSApp.mainMenu = mainMenu
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
