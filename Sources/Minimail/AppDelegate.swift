import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuItemValidation {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    let appState = AppState()
    private var mailWindow: NSWindow?
    private var mailWindowFrame: NSRect?
    private var intervalObserver: NSObjectProtocol?
    private var isTransferring = false
    private var isTerminating = false
    private var pollTimer: Timer?
    private var pollInFlight = false
    private var bootstrapFinished = false
    private var deferredMailURLs: [URL] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        // LSUIElement apps don't get a default menu, which means NSTextField
        // never receives the standard ⌘C / ⌘V / ⌘X / ⌘A / ⌘Z key equivalents
        // — Cocoa routes those through Edit-menu items, not NSTextField's
        // internal handling. Install a minimal Edit menu so all text inputs
        // behave correctly. This is the Apple-sanctioned pattern for
        // accessory apps (cf. "Menu Bar Extras" in Human Interface Guidelines).
        Self.installMinimalMenuBar()
        installMailMenus()
        intervalObserver = NotificationCenter.default.addObserver(
            forName: .minimailSyncIntervalChanged, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.startPollingForNewMail() }
        }
        NotificationCenter.default.addObserver(self, selector: #selector(expandToWindow), name: .minimailExpandWindow, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(returnToMenuBar), name: .minimailReturnToMenuBar, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(closePopover), name: .minimailClosePopover, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(openMailtoNotification(_:)), name: .minimailOpenMailto, object: nil)

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
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        popover = NSPopover()
        popover.contentSize = NSSize(width: 420, height: 580)
        // applicationDefined = do NOT auto-dismiss on outside click.
        // We control dismissal explicitly (status-item click, Esc, or in-view close).
        popover.behavior = .applicationDefined
        popover.animates = true
        installPopoverContent()

        // Esc key closes the popover when it has focus — standard macOS expectation.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(popoverDidClose(_:)),
            name: NSPopover.didCloseNotification,
            object: popover
        )

        Task { @MainActor in
            await appState.bootstrap()
            bootstrapFinished = true
            let urls = deferredMailURLs
            deferredMailURLs = []
            if !urls.isEmpty { await openMailURLs(urls) }
            // Seed "seen" set so we don't backfill notifications for every
            // existing received message on first launch.
            let receivedIDs = appState.inbox.messages
                .filter { $0.direction == "received" }
                .map(\.id)
            MinimailNotifier.shared.seed(receivedIDs)
            refreshStatusTitle()
            startPollingForNewMail()
            #if DEBUG
            await configureQAPresentation()
            #endif
        }

        // Re-sync the menu bar title whenever the unread count changes.
        // withObservationTracking is one-shot; re-register inside onChange.
        observeUnread()
    }

    #if DEBUG
    /// Deterministic entry points for the isolated offline fixture bundle.
    /// They do not exist in release builds or affect the real app's data.
    private func configureQAPresentation() async {
        guard Bundle.main.bundleIdentifier == "ai.paperfoot.minimail.qa" else { return }
        let arguments = ProcessInfo.processInfo.arguments
        guard let flag = arguments.firstIndex(of: "--qa-view"), arguments.indices.contains(flag + 1) else { return }
        pollTimer?.invalidate()
        if arguments.contains("--qa-dark") { NSApp.appearance = NSAppearance(named: .darkAqua) }
        let route = arguments[flag + 1].split(separator: ":", maxSplits: 1).map(String.init)
        if arguments.contains("--qa-expanded") { expandToWindow() }
        else { showPopover() }
        switch route.first {
        case "reader":
            if route.count == 2, let id = Int64(route[1]) { appState.openMessage(id: id) }
        case "draft":
            if route.count == 2, let draft = appState.inbox.drafts.first(where: { $0.id == route[1] }) {
                await appState.openDraft(draft)
            }
        case "settings":
            await appState.openSettings(section: route.count == 2 ? route[1] : "general")
        default: break
        }
    }
    #endif

    func application(_ application: NSApplication, open urls: [URL]) {
        if !bootstrapFinished { deferredMailURLs.append(contentsOf: urls); return }
        Task { await openMailURLs(urls) }
    }

    @objc private func openMailtoNotification(_ notification: Notification) {
        guard let url = notification.object as? URL else { return }
        application(NSApp, open: [url])
    }

    private func openMailURLs(_ urls: [URL]) async {
        for url in urls where url.scheme?.lowercased() == "mailto" {
            expandToWindow()
            await appState.composeMailto(url)
        }
    }

    /// Background mail check independent of the popover. Runs every 60s while
    /// the app is alive. After each refresh, diff new received messages against
    /// the seen set and fire notifications. All accounts keep syncing while
    /// a draft is open; composing no longer suspends mail checks.
    private func startPollingForNewMail() {
        pollTimer?.invalidate()
        let storedInterval = UserDefaults.standard.integer(forKey: SettingsKey.syncIntervalSeconds)
        let seconds = storedInterval == 0 ? 60 : max(30, storedInterval)
        pollTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(seconds), repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard !self.pollInFlight else { return }
                self.pollInFlight = true
                defer { self.pollInFlight = false }
                let received = await self.appState.pollForNewMail()
                MinimailNotifier.shared.notifyNewMessages(received)
                self.refreshStatusTitle()
            }
        }

    }

    /// Invoked by MinimailNotifier when a notification banner is clicked.
    func openFromNotification(messageID: Int64?) {
        NSApp.activate(ignoringOtherApps: true)
        if appState.router.isExpanded { expandToWindow() }
        else if !popover.isShown { showPopover() }
        guard let id = messageID else { return }
        // Delegated to AppState.openMessage(id:) — handles both the "already
        // in the inbox list" and "route to reader + lazy-load body" cases,
        // plus mirrors the in-place mark-read mutation used by
        // open(message:). Previously the else-branch only changed the route,
        // so the reader would mount with reader.loaded == nil and render an
        // empty shell until the user navigated away and back.
        Task {
            guard await appState.prepareToLeaveCompose() else { return }
            appState.openMessage(id: id)
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
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            let menu = NSMenu()
            addAction("Open Mail Window", action: #selector(expandToWindow), to: menu)
            addAction("New Message", action: #selector(newMessage), to: menu)
            menu.addItem(.separator())
            addAction("Check for New Mail", action: #selector(checkMail), to: menu)
            addAction("Settings…", action: #selector(showSettings), to: menu)
            menu.addItem(.separator())
            menu.addItem(withTitle: "Quit Minimail", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
            statusItem.menu = menu
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
        } else if appState.router.isExpanded {
            expandToWindow()
        } else if popover.isShown {
            popover.performClose(sender)
        } else {
            showPopover()
        }
    }

    private func installPopoverContent() {
        popover.contentViewController = NSHostingController(
            rootView: RootView().environment(appState).frame(width: 420, height: 580)
        )
    }

    private func commitRecipients() {
        NotificationCenter.default.post(name: .minimailCommitRecipients, object: nil)
        // Resigning first responder also commits any IME composition.
        NSApp.keyWindow?.makeFirstResponder(nil)
    }

    private func showPopover() {
        guard let button = statusItem.button else { return }
        if popover.contentViewController == nil { installPopoverContent() }
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        Task { @MainActor in
            await appState.refreshInbox(pull: false)
            refreshStatusTitle()
        }
    }

    @objc private func closePopover() { popover.performClose(nil) }

    @objc private func expandToWindow() {
        if let window = mailWindow, appState.router.isExpanded {
            restoreMailWindowFrame(window)
            NSApp.activate(ignoringOtherApps: true)
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
            return
        }
        commitRecipients()
        isTransferring = true
        popover.performClose(nil)
        popover.contentViewController = nil
        appState.router.isExpanded = true
        NSApp.setActivationPolicy(.regular)
        let window = mailWindow ?? NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1180, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        if mailWindow == nil {
            window.title = "Minimail"
            window.titlebarAppearsTransparent = true
            window.toolbarStyle = .unified
            window.minSize = NSSize(width: 960, height: 580)
            window.isReleasedWhenClosed = false
            window.delegate = self
            if !window.setFrameUsingName("Minimail.MailWindow") { window.center() }
            window.setFrameAutosaveName("Minimail.MailWindow")
            window.collectionBehavior.insert(.fullScreenPrimary)
            mailWindow = window
            mailWindowFrame = window.frame
        }
        window.contentViewController = NSHostingController(rootView: RootView().environment(appState))
        // Swapping hosting controllers can resize an NSWindow to the new
        // view's fitting size, even below its user-resize minimum. Restore
        // the frame after mounting so compact-to-window keeps the mail layout.
        restoreMailWindowFrame(window)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        isTransferring = false
    }

    @objc private func returnToMenuBar() {
        commitRecipients()
        isTransferring = true
        mailWindowFrame = mailWindow?.frame
        mailWindow?.orderOut(nil)
        mailWindow?.contentViewController = nil
        if appState.router.currentView == .settings { appState.back() }
        appState.router.isExpanded = false
        NSApp.setActivationPolicy(.accessory)
        installPopoverContent()
        isTransferring = false
        showPopover()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        commitRecipients()
        Task { await appState.flushAutosave() }
        mailWindowFrame = sender.frame
        sender.orderOut(nil)
        sender.contentViewController = nil
        if appState.router.currentView == .settings { appState.back() }
        appState.router.isExpanded = false
        NSApp.setActivationPolicy(.accessory)
        return false
    }

    private func restoreMailWindowFrame(_ window: NSWindow) {
        var frame = mailWindowFrame ?? window.frame
        frame.size.width = max(frame.width, 960)
        frame.size.height = max(frame.height, 580)
        window.minSize = NSSize(width: 960, height: 580)
        window.setFrame(frame, display: true)
    }

    func windowDidResize(_ notification: Notification) {
        guard !isTransferring, appState.router.isExpanded,
              let window = notification.object as? NSWindow, window === mailWindow,
              window.frame.width >= 960, window.frame.height >= 580 else { return }
        mailWindowFrame = window.frame
    }

    func windowDidMove(_ notification: Notification) {
        guard !isTransferring, appState.router.isExpanded,
              let window = notification.object as? NSWindow, window === mailWindow,
              window.frame.width >= 960, window.frame.height >= 580 else { return }
        mailWindowFrame = window.frame
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        expandToWindow()
        return true
    }

    @objc private func popoverDidClose(_ notification: Notification) {
        guard !isTransferring else { return }
        commitRecipients()
        appState.dismissLaunchAtLoginOfferIfShown()
        // Hiding the interface must preserve the full Undo Send countdown.
        Task { await appState.flushAutosave() }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isTerminating else { return .terminateLater }
        isTerminating = true
        commitRecipients()
        Task { @MainActor in
            await appState.waitForAttachmentDownloads()
            await appState.flushAutosave()
            await appState.flushPendingSendNow()
            await appState.waitForDelivery()
            // Failed drafts remain editable; don't silently quit over a save error.
            if appState.compose.hasContent && appState.compose.error != nil {
                isTerminating = false
                expandToWindow()
                sender.reply(toApplicationShouldTerminate: false)
            } else {
                sender.reply(toApplicationShouldTerminate: true)
            }
        }
        return .terminateLater
    }

    @objc private func newMessage() {
        if appState.router.isExpanded { expandToWindow() }
        else if !popover.isShown { showPopover() }
        Task { await appState.saveComposeAndStartNew() }
    }

    @objc private func checkMail() { Task { await appState.refreshInbox() } }

    @objc private func showSettings() {
        expandToWindow()
        Task { await appState.navigate(to: .settings) }
    }

    @objc private func toggleCompactSidebar() {
        let defaults = UserDefaults.standard
        defaults.set(!defaults.bool(forKey: SettingsKey.compactSidebar), forKey: SettingsKey.compactSidebar)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(toggleCompactSidebar) {
            menuItem.state = UserDefaults.standard.bool(forKey: SettingsKey.compactSidebar) ? .on : .off
            return appState.router.isExpanded
        }
        return true
    }

    private func addAction(_ title: String, action: Selector, key: String = "", to menu: NSMenu) {
        let item = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
        item.target = self
    }

    private func installMailMenus() {
        guard let main = NSApp.mainMenu else { return }
        if let appMenu = main.items.first?.submenu {
            let settings = NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
            settings.target = self
            appMenu.insertItem(settings, at: 0)
            appMenu.insertItem(.separator(), at: 1)
        }
        let file = NSMenu(title: "File")
        addAction("New Message", action: #selector(newMessage), key: "n", to: file)
        addAction("Open Mail Window", action: #selector(expandToWindow), key: "1", to: file)
        file.items.last?.keyEquivalentModifierMask = [.command, .option]
        addAction("Check for New Mail", action: #selector(checkMail), key: "n", to: file)
        file.items.last?.keyEquivalentModifierMask = [.command, .shift]
        file.addItem(.separator())
        file.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        let fileItem = NSMenuItem(title: "File", action: nil, keyEquivalent: "")
        fileItem.submenu = file
        main.insertItem(fileItem, at: 1)
        let viewMenu = NSMenu(title: "View")
        addAction("Use Compact Sidebar", action: #selector(toggleCompactSidebar), key: "s", to: viewMenu)
        viewMenu.items.last?.keyEquivalentModifierMask = [.command, .control]
        let viewItem = NSMenuItem(title: "View", action: nil, keyEquivalent: "")
        viewItem.submenu = viewMenu
        main.addItem(viewItem)
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(.separator())
        addAction("Return to Menu Bar", action: #selector(returnToMenuBar), to: windowMenu)
        let windowItem = NSMenuItem(title: "Window", action: nil, keyEquivalent: "")
        windowItem.submenu = windowMenu
        main.addItem(windowItem)
        NSApp.windowsMenu = windowMenu
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

extension Notification.Name {
    static let minimailExpandWindow = Notification.Name("minimail.expandWindow")
    static let minimailReturnToMenuBar = Notification.Name("minimail.returnToMenuBar")
    static let minimailClosePopover = Notification.Name("minimail.closePopover")
    static let minimailFocusSearch = Notification.Name("minimail.focusSearch")
}
