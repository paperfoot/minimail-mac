import SwiftUI
@preconcurrency import WebKit

/// SwiftUI wrapper that renders sanitised email HTML in a WKWebView and
/// **resizes itself to the content's natural height** so the outer
/// SwiftUI `ScrollView` is the only scroller in the hierarchy. This is what
/// eliminates the "multiple stacked scrollbars" we used to see in a thread
/// view: the inner WKWebView no longer scrolls, the outer SwiftUI ScrollView
/// does the scrolling for the entire thread.
///
/// Performance:
/// - The content-blocking rule list is compiled **once globally** (cached
///   static) and reused across every WKWebView instance.
/// - HTML wrapping (style boilerplate + quote-collapse transform) runs in
///   the view's `init` — NOT in `updateNSView` — so a reused WKWebView
///   doesn't re-wrap the same HTML on every observable invalidation wave.
struct HTMLBodyView: View {
    /// Pre-wrapped HTML. Computed in `init` so the costly `wrap` + quote
    /// transform doesn't re-run on every SwiftUI update.
    private let wrappedHTML: String
    /// External opt-in: the reader footer flips this to true when the user
    /// hits "Load remote content" for the currently-shown message. We DO
    /// NOT persist across messages — see `onChange(of: wrappedHTML)` below.
    private let remoteContentAllowed: Bool
    /// Measured natural height after the page renders. Seeded with a small
    /// non-zero placeholder so the view doesn't collapse before the first
    /// measurement comes back.
    @State private var measuredHeight: CGFloat = 80
    /// Flips true if the content-blocking rule list failed to compile. We
    /// refuse to render any HTML in that state — privacy trumps display,
    /// since the whole point of the rule list is to block remote trackers
    /// and tracking pixels in incoming mail.
    @State private var rulesFailed: Bool = false
    @State private var linkError: String?

    init(html: String, remoteContentAllowed: Bool = false) {
        self.wrappedHTML = EmailHTML.wrappedDocument(html)
        self.remoteContentAllowed = remoteContentAllowed
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let linkError {
                Text(linkError).font(.caption).foregroundStyle(.secondary).padding(12)
            }
            if rulesFailed {
                // Fail-closed banner. We intentionally do NOT load the email
                // HTML when the blocker rule list didn't compile — the HTML
                // could contain remote images/pixels that would silently
                // fire and expose the user to trackers. Showing a minimal
                // banner is better than a blank area (confusing) or a
                // rendered body (unsafe).
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.shield.fill")
                        .foregroundStyle(.orange)
                    Text("Message hidden — privacy filter failed to load. Reopen the message to retry.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                HTMLWebView(
                    wrappedHTML: wrappedHTML,
                    remoteContentAllowed: remoteContentAllowed,
                    height: $measuredHeight,
                    rulesFailed: $rulesFailed,
                    linkError: $linkError
                )
                .frame(height: measuredHeight)
            }
        }
        // Reset the fail-closed latch when a new message is shown. Without
        // this, the @State var persists across identical SwiftUI view
        // identities — once a compile failure flipped it true, j/k
        // navigation between messages kept rendering the banner even after
        // the compile retried successfully on the next instance.
        .onChange(of: wrappedHTML) { _, _ in
            if rulesFailed { rulesFailed = false }
            linkError = nil
        }
    }
}

/// NSViewRepresentable doing the actual WKWebView work. Reports its content
/// height back to the SwiftUI parent via a binding so the parent can resize
/// itself instead of the web view scrolling internally.
private struct HTMLWebView: NSViewRepresentable {
    /// Already-wrapped HTML. Wrapping (style + quote collapse) happens in the
    /// parent `HTMLBodyView.init`, not here, so a reused WebView on a
    /// downstream invalidation doesn't pay the wrap cost again.
    let wrappedHTML: String
    /// When true, detach the content-blocking rule list (so remote images,
    /// stylesheets, fonts render) and reload the wrapped HTML. Per-message
    /// opt-in only — the parent resets it to false whenever the HTML
    /// changes so the choice never leaks to the next message.
    let remoteContentAllowed: Bool
    @Binding var height: CGFloat
    /// Set true if the shared content-blocking rule list fails to compile.
    /// Parent uses this to swap the web view out for a fail-closed banner
    /// rather than leaking remote resource loads.
    @Binding var rulesFailed: Bool
    @Binding var linkError: String?

    func makeNSView(context: Context) -> HTMLHostView {
        let config = WKWebViewConfiguration()
        // `allowsContentJavaScript = false` blocks scripts inside the loaded
        // page (security: tracking/exfil). It does NOT prevent host-side
        // `evaluateJavaScript(_:)` calls — those still work, which is how we
        // measure content height after layout.
        let prefs = WKWebpagePreferences()
        prefs.allowsContentJavaScript = false
        config.defaultWebpagePreferences = prefs
        config.websiteDataStore = .nonPersistent()
        config.userContentController.add(context.coordinator, contentWorld: .defaultClient, name: "mailHeight")
        // An isolated host script observes layout; email-provided scripts stay disabled.
        config.userContentController.addUserScript(WKUserScript(source: """
            // Wrap the document without altering sender colors or table widths.
            // Wide invoices/newsletters remain reachable with a horizontal gesture.
            const content = document.createElement('div');
            content.className = 'mm-document';
            while (document.body.firstChild) content.appendChild(document.body.firstChild);
            document.body.appendChild(content);
            document.querySelectorAll('blockquote').forEach(quote => {
                if (quote.parentElement.closest('blockquote, details')) return;
                const details = document.createElement('details');
                details.className = 'mm-quote';
                const summary = document.createElement('summary');
                summary.textContent = 'Show quoted content';
                quote.replaceWith(details);
                details.append(summary, quote);
            });
            const report = () => window.webkit.messageHandlers.mailHeight.postMessage(document.body.getBoundingClientRect().height);
            new ResizeObserver(report).observe(document.body);
            document.addEventListener('toggle', report, true);
            report();
            """, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: .defaultClient))

        // PassthroughWebView's scrollWheel forwards every event to the next
        // responder so the outer SwiftUI ScrollView always wins. Combined
        // with disabling the internal NSScrollView's elastic bounce (below),
        // this keeps wheel scrolling smooth even when the cursor is over
        // the email body for the entire viewport.
        let webView = PassthroughWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground")
        webView.navigationDelegate = context.coordinator
        context.coordinator.webView = webView

        if remoteContentAllowed {
            // Opt-in path: user already clicked "Load remote content" before
            // the webview was materialised (unusual but possible under
            // rapid j/k navigation). Skip attaching the blocklist entirely
            // and mark the coordinator ready so the HTML loads immediately.
            context.coordinator.rulesReady = true
            context.coordinator.remoteContentAllowed = true
        } else {
            Self.attachRuleList(to: webView, coordinator: context.coordinator)
        }
        // Defer until next runloop tick — the internal scroll view isn't
        // attached to the view hierarchy until after `makeNSView` returns.
        DispatchQueue.main.async { [weak webView] in
            guard let webView else { return }
            Self.disableInternalElasticity(in: webView)
        }
        return HTMLHostView(webView: webView)
    }

    func updateNSView(_ host: HTMLHostView, context: Context) {
        let webView = host.webView
        context.coordinator.parent = self
        if !remoteContentAllowed && context.coordinator.remoteContentAllowed {
            webView.stopLoading()
            context.coordinator.remoteContentAllowed = false
            context.coordinator.rulesReady = false
            context.coordinator.lastLoadedHTML = nil
            context.coordinator.pendingHTML = wrappedHTML
            Self.attachRuleList(to: webView, coordinator: context.coordinator)
            return
        }
        // Opt-in flip: if the user just allowed remote content, strip the
        // rule list off THIS webview, mark the coordinator's state so it
        // doesn't re-attach, then reload the HTML so previously-blocked
        // images/styles/fonts actually request bytes.
        if remoteContentAllowed && !context.coordinator.remoteContentAllowed {
            webView.configuration.userContentController.removeAllContentRuleLists()
            context.coordinator.remoteContentAllowed = true
            context.coordinator.rulesReady = true
            // Force a reload of the currently-displayed HTML by clearing
            // the dedup key — flushPending will rerun loadHTMLString below.
            context.coordinator.lastLoadedHTML = nil
            context.coordinator.pendingHTML = wrappedHTML
            context.coordinator.flushPending()
            return
        }
        if context.coordinator.lastLoadedHTML == wrappedHTML { return }
        context.coordinator.pendingHTML = wrappedHTML
        if context.coordinator.rulesReady {
            context.coordinator.flushPending()
        }
    }

    static func dismantleNSView(_ host: HTMLHostView, coordinator: Coordinator) {
        let webView = host.webView
        webView.stopLoading()
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "mailHeight", contentWorld: .defaultClient)
        webView.navigationDelegate = nil
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    // ── Cached content rule list ─────────────────────────────────────────

    /// Compile state for the shared content-blocking rule list. The closure
    /// completion fires on the main thread; subscribers are notified there.
    @MainActor private static var cachedRuleList: WKContentRuleList?
    @MainActor private static var rulesPending: [(WKContentRuleList?) -> Void] = []
    @MainActor private static var compileStarted = false

    /// Walk the WKWebView's subview tree, find the private internal
    /// `NSScrollView`, and disable elastic bouncing in both axes. This is
    /// what keeps the inner scroll view from rubber-band-consuming wheel
    /// events when the (overflow:hidden) page can't actually scroll. Also
    /// hides the inner scroller for safety.
    @MainActor
    private static func disableInternalElasticity(in webView: WKWebView) {
        func walk(_ view: NSView) {
            if let scroll = view as? NSScrollView {
                scroll.verticalScrollElasticity = .none
                scroll.horizontalScrollElasticity = .none
                scroll.hasVerticalScroller = false
                scroll.hasHorizontalScroller = false
            }
            for sv in view.subviews { walk(sv) }
        }
        walk(webView)
    }

    @MainActor
    private static func attachRuleList(to webView: WKWebView, coordinator: Coordinator) {
        if let list = cachedRuleList {
            webView.configuration.userContentController.add(list)
            coordinator.rulesReady = true
            coordinator.flushPending()
            return
        }
        // Previously ignored a nil list here: we'd set `rulesReady = true`
        // and flush the pending HTML anyway, which meant a compile failure
        // silently rendered email bodies with no privacy filter attached —
        // remote trackers and tracking pixels would fire. Fail closed
        // instead: propagate the failure up through the parent's
        // rulesFailed binding and never load HTML in this webview.
        rulesPending.append { [weak webView, weak coordinator] list in
            guard let webView, let coordinator else { return }
            // If the user clicked "Load remote content" while we were still
            // compiling, the opt-in path already marked this coordinator as
            // `remoteContentAllowed` and reloaded the HTML without a blocker.
            // Attaching the rule list now would silently re-enable blocking
            // for the same message the user explicitly allowed — clobbering
            // their choice. Skip the attach; still mark ready so any pending
            // HTML flushes (already flushed in the opt-in path, but safe).
            if coordinator.remoteContentAllowed {
                coordinator.rulesReady = true
                return
            }
            if let list {
                webView.configuration.userContentController.add(list)
                coordinator.rulesReady = true
                coordinator.flushPending()
            } else {
                coordinator.rulesReady = false
                coordinator.markRulesFailed()
            }
        }
        guard !compileStarted else { return }
        compileStarted = true
        WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: "minimail-block-remote",
            encodedContentRuleList: blockRulesJSON
        ) { list, error in
            Task { @MainActor in
                if list == nil || error != nil {
                    // Don't cache a nil — a future webview instance might
                    // get lucky (transient WebKit compiler state, disk
                    // issues clearing up). Flush pending waiters as failed
                    // this round.
                    let waiting = rulesPending
                    rulesPending = []
                    compileStarted = false
                    for cb in waiting { cb(nil) }
                    return
                }
                cachedRuleList = list
                let waiting = rulesPending
                rulesPending = []
                for cb in waiting { cb(list) }
            }
        }
    }

    // Omit resource-type to block every remote request, including CSS and frames.
    // Unsupported resource-type names make WebKit reject the entire rule list.
    private static let blockRulesJSON = EmailHTML.blockRulesJSON

    // ── Coordinator ──────────────────────────────────────────────────────

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var parent: HTMLWebView
        weak var webView: WKWebView?
        var rulesReady = false
        var pendingHTML: String?
        var lastLoadedHTML: String?
        /// Mirror of the parent's `remoteContentAllowed` so we don't re-
        /// strip the blocklist on every SwiftUI invalidation wave — only
        /// on the transition from false → true.
        var remoteContentAllowed = false

        init(parent: HTMLWebView) { self.parent = parent }

        func flushPending() {
            guard let html = pendingHTML, let webView else { return }
            webView.loadHTMLString(html, baseURL: nil)
            lastLoadedHTML = html
            pendingHTML = nil
        }

        /// Flip the parent view's failure binding so it can swap this web
        /// view for a fail-closed banner. Also drop any pending HTML so a
        /// late retry can't accidentally load it through an unguarded
        /// webview. Called from `attachRuleList` when compile returns nil
        /// or an error.
        func markRulesFailed() {
            pendingHTML = nil
            parent.rulesFailed = true
        }

        // After the page lays out, ask the document for its real scrollHeight
        // and feed that back to SwiftUI so the parent frame matches. This is
        // what makes the outer SwiftUI scroll view the *only* scroller.
        //
        // We measure twice: once immediately on didFinish, then once again
        // AFTER the open spring animation settles (~0.35s for response=0.3).
        // The second pass catches late layout shifts from font-glyph fallback
        // that can arrive after didFinish. Moving the second pass out of the
        // animation window means any height correction is invisible to the
        // user (the reader is already fully open). Previous 100ms placement
        // caused a visible height bump mid-animation.
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            measureHeight(in: webView)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.40) { [weak self] in
                guard let self, let webView = self.webView else { return }
                self.measureHeight(in: webView)
            }
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.frameInfo.isMainFrame, let number = message.body as? NSNumber else { return }
            updateHeight(number.doubleValue)
        }

        private func updateHeight(_ value: Double) {
            guard value.isFinite, value >= 0 else { return }
            let height = max(40, value.rounded(.up))
            if abs(parent.height - height) > 1 { parent.height = height }
        }

        private func measureHeight(in webView: WKWebView) {
            webView.evaluateJavaScript("document.body.getBoundingClientRect().height", in: nil, in: .defaultClient) { [weak self] result in
                if case .success(let value) = result, let number = value as? NSNumber {
                    self?.updateHeight(number.doubleValue)
                }
            }
        }

        // Block all remote resource loads so tracking pixels don't fire.
        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
            if navigationAction.navigationType == .linkActivated,
               let url = navigationAction.request.url {
                // The href is attacker-controlled email HTML. Only open web /
                // mail schemes — never file://, custom schemes, etc.
                if url.scheme == "about", url.fragment != nil {
                    decisionHandler(.allow)
                    return
                }
                if !ExternalLink.open(url) {
                    parent.linkError = "This link could not be opened. Only web and email links are supported."
                }
                decisionHandler(.cancel)
                return
            }
            // Mail must not navigate itself to a remote document (meta refresh,
            // form submission, or a frame), even after image opt-in.
            let scheme = navigationAction.request.url?.scheme?.lowercased()
            decisionHandler(scheme == "about" ? .allow : .cancel)
        }

        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationResponse: WKNavigationResponse,
                     decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void) {
            decisionHandler(.allow)
        }
    }

    /// Vertical wheel events belong to the conversation. Horizontal events
    /// stay in WebKit so wide tables can scroll within their own document.
    final class PassthroughWebView: WKWebView {
        override func scrollWheel(with event: NSEvent) {
            if abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) {
                super.scrollWheel(with: event)
            } else {
                nextResponder?.scrollWheel(with: event)
            }
        }
    }

    /// A flipped, clipped host aligns WebKit drawing with the SwiftUI scroll viewport.
    final class HTMLHostView: NSView {
        let webView: WKWebView
        override var isFlipped: Bool { true }

        init(webView: WKWebView) {
            self.webView = webView
            super.init(frame: .zero)
            clipsToBounds = true
            webView.frame = bounds
            webView.autoresizingMask = [.width, .height]
            addSubview(webView)
        }

        required init?(coder: NSCoder) { nil }
    }
}
