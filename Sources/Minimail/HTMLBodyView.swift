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
    /// Measured natural height after the page renders. Seeded with a small
    /// non-zero placeholder so the view doesn't collapse before the first
    /// measurement comes back.
    @State private var measuredHeight: CGFloat = 80

    init(html: String) {
        self.wrappedHTML = HTMLWebView.wrap(html)
    }

    var body: some View {
        HTMLWebView(wrappedHTML: wrappedHTML, height: $measuredHeight)
            .frame(height: measuredHeight)
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
    @Binding var height: CGFloat

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        // `allowsContentJavaScript = false` blocks scripts inside the loaded
        // page (security: tracking/exfil). It does NOT prevent host-side
        // `evaluateJavaScript(_:)` calls — those still work, which is how we
        // measure content height after layout.
        let prefs = WKWebpagePreferences()
        prefs.allowsContentJavaScript = false
        config.defaultWebpagePreferences = prefs
        config.websiteDataStore = .nonPersistent()

        // PassthroughWebView's scrollWheel forwards every event to the next
        // responder so the outer SwiftUI ScrollView always wins. Combined
        // with disabling the internal NSScrollView's elastic bounce (below),
        // this keeps wheel scrolling smooth even when the cursor is over
        // the email body for the entire viewport.
        let webView = PassthroughWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground")
        webView.navigationDelegate = context.coordinator
        context.coordinator.webView = webView

        Self.attachRuleList(to: webView, coordinator: context.coordinator)
        // Defer until next runloop tick — the internal scroll view isn't
        // attached to the view hierarchy until after `makeNSView` returns.
        DispatchQueue.main.async { [weak webView] in
            guard let webView else { return }
            Self.disableInternalElasticity(in: webView)
        }
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        if context.coordinator.lastLoadedHTML == wrappedHTML { return }
        context.coordinator.pendingHTML = wrappedHTML
        if context.coordinator.rulesReady {
            context.coordinator.flushPending()
        }
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
        rulesPending.append { [weak webView, weak coordinator] list in
            guard let webView, let coordinator else { return }
            if let list { webView.configuration.userContentController.add(list) }
            coordinator.rulesReady = true
            coordinator.flushPending()
        }
        guard !compileStarted else { return }
        compileStarted = true
        WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: "minimail-block-remote",
            encodedContentRuleList: blockRulesJSON
        ) { list, _ in
            Task { @MainActor in
                cachedRuleList = list
                let waiting = rulesPending
                rulesPending = []
                for cb in waiting { cb(list) }
            }
        }
    }

    private static let blockRulesJSON: String = """
    [
      {"trigger": {"url-filter": "^https?://.*",
                   "resource-type": ["image","style-sheet","font","raw","media","svg-document","document","script","fetch","websocket","ping","other"]},
       "action": {"type": "block"}}
    ]
    """

    // ── Coordinator ──────────────────────────────────────────────────────

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        let parent: HTMLWebView
        weak var webView: WKWebView?
        var rulesReady = false
        var pendingHTML: String?
        var lastLoadedHTML: String?

        init(parent: HTMLWebView) { self.parent = parent }

        func flushPending() {
            guard let html = pendingHTML, let webView else { return }
            webView.loadHTMLString(html, baseURL: nil)
            lastLoadedHTML = html
            pendingHTML = nil
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

        private func measureHeight(in webView: WKWebView) {
            webView.evaluateJavaScript(
                "Math.max(document.body.scrollHeight, document.documentElement.scrollHeight)"
            ) { [weak self] result, _ in
                guard let self else { return }
                let h: CGFloat = {
                    if let n = result as? CGFloat { return n }
                    if let n = result as? Double { return CGFloat(n) }
                    if let n = result as? Int { return CGFloat(n) }
                    return 80
                }()
                let clamped = max(40, min(h, 8000))
                Task { @MainActor in
                    if abs(self.parent.height - clamped) > 1 {
                        self.parent.height = clamped
                    }
                }
            }
        }

        // Block all remote resource loads so tracking pixels don't fire.
        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
            if navigationAction.navigationType == .linkActivated,
               let url = navigationAction.request.url {
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }

        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationResponse: WKNavigationResponse,
                     decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void) {
            decisionHandler(.allow)
        }
    }

    // ── HTML wrapping ────────────────────────────────────────────────────

    /// Wrap raw email HTML with our style boilerplate + quote-collapse
    /// transform. Called ONCE from `HTMLBodyView.init`, not from
    /// `updateNSView`. `fileprivate` so the parent view's init can reach it.
    fileprivate static func wrap(_ body: String) -> String {
        let prefersDark = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let fg = prefersDark ? "#f5f5f7" : "#1d1d1f"
        let link = "#0a84ff"
        let transformed = collapseQuotedText(body)
        // Note: `html, body { overflow: hidden }` belt-and-braces with the
        // outer SwiftUI height-binding so the WKWebView never tries to
        // present its own scrollbar. The outer ScrollView is the only one.
        return """
        <!doctype html><html><head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=420, initial-scale=1">
        <style>
          html, body {
            margin: 0;
            padding: 14px;
            background: transparent !important;
            color: \(fg);
            font: 13px/1.5 -apple-system, "SF Pro Text", system-ui, sans-serif;
            -webkit-font-smoothing: antialiased;
            text-size-adjust: 100%;
            overflow: hidden;
          }
          body > :first-child { margin-top: 0; }
          a { color: \(link); }
          img { max-width: 100%; height: auto; }
          img[src^="http"], img[src^="https"] { display: none; }
          table { max-width: 100% !important; }
          body > table, body > div {
            background: transparent !important;
            background-color: transparent !important;
          }
          pre, code { font-family: ui-monospace, "SF Mono", monospace; }
          blockquote {
            border-left: 3px solid rgba(127,127,127,0.2);
            padding-left: 12px;
            color: rgba(127,127,127,0.9);
            margin: 12px 0;
          }
          details.mm-quote { margin: 8px 0 12px 0; }
          details.mm-quote > summary {
            cursor: pointer;
            display: inline-block;
            padding: 2px 8px;
            background: rgba(127,127,127,0.12);
            border-radius: 10px;
            font-size: 11px;
            color: rgba(127,127,127,0.95);
            list-style: none;
            user-select: none;
          }
          details.mm-quote > summary::-webkit-details-marker { display: none; }
          details.mm-quote[open] > summary { margin-bottom: 6px; }
        </style></head>
        <body>\(transformed)</body></html>
        """
    }

    // ── Subclass: forward wheel events ──────────────────────────────────

    /// WKWebView subclass whose `scrollWheel(with:)` forwards every wheel
    /// event up the responder chain rather than handling it locally. We
    /// size our SwiftUI parent's frame to the page's natural content
    /// height (see `HTMLBodyView`), so the web view never has anything to
    /// scroll — letting the parent SwiftUI ScrollView always win means the
    /// user can scroll the entire reader regardless of where the cursor is.
    final class PassthroughWebView: WKWebView {
        override func scrollWheel(with event: NSEvent) {
            nextResponder?.scrollWheel(with: event)
        }
    }

    /// Wrap every top-level blockquote in a `<details>` so the quoted reply
    /// history is collapsed by default. Pure HTML5 — no JS needed.
    private static func collapseQuotedText(_ html: String) -> String {
        let open = "<blockquote"
        let close = "</blockquote>"
        var out = ""
        var idx = html.startIndex
        var depth = 0

        while idx < html.endIndex {
            if depth == 0, html[idx...].hasPrefix(open) {
                out += "<details class=\"mm-quote\"><summary>Show quoted content</summary>"
                depth = 1
                let tagRange = html.range(of: ">", range: idx..<html.endIndex)
                if let tagRange {
                    out.append(contentsOf: html[idx..<tagRange.upperBound])
                    idx = tagRange.upperBound
                } else {
                    out.append(contentsOf: html[idx...])
                    break
                }
                continue
            }
            if html[idx...].hasPrefix(open) {
                depth += 1
                let tagRange = html.range(of: ">", range: idx..<html.endIndex)
                if let tagRange {
                    out.append(contentsOf: html[idx..<tagRange.upperBound])
                    idx = tagRange.upperBound
                } else {
                    out.append(contentsOf: html[idx...])
                    break
                }
                continue
            }
            if html[idx...].hasPrefix(close) {
                out += close
                idx = html.index(idx, offsetBy: close.count)
                depth -= 1
                if depth == 0 {
                    out += "</details>"
                }
                if depth < 0 { depth = 0 }
                continue
            }
            out.append(html[idx])
            idx = html.index(after: idx)
        }
        return out
    }
}
