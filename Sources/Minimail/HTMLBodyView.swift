import SwiftUI
@preconcurrency import WebKit

/// SwiftUI wrapper that renders sanitised email HTML in a WKWebView and
/// **resizes itself to the content's natural height** so the outer
/// SwiftUI `ScrollView` is the only scroller in the hierarchy. This is what
/// eliminates the "multiple stacked scrollbars" we used to see in a thread
/// view: the inner WKWebView no longer scrolls, the outer SwiftUI ScrollView
/// does the scrolling for the entire thread.
///
/// Performance: the content-blocking rule list is compiled **once globally**
/// (cached static) and reused across every WKWebView instance — opening a
/// 3-message thread no longer pays the rule-list-compile cost three times.
struct HTMLBodyView: View {
    let html: String
    /// Measured natural height after the page renders. Seeded with a small
    /// non-zero placeholder so the view doesn't collapse before the first
    /// measurement comes back.
    @State private var measuredHeight: CGFloat = 80

    var body: some View {
        HTMLWebView(html: html, height: $measuredHeight)
            .frame(height: measuredHeight)
    }
}

/// NSViewRepresentable doing the actual WKWebView work. Reports its content
/// height back to the SwiftUI parent via a binding so the parent can resize
/// itself instead of the web view scrolling internally.
private struct HTMLWebView: NSViewRepresentable {
    let html: String
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

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground")
        webView.navigationDelegate = context.coordinator
        context.coordinator.webView = webView

        // Install the cached rule list (compiled once globally). If it's not
        // ready yet, queue the first HTML load until it is — same race-fix
        // pattern as the previous implementation.
        Self.attachRuleList(to: webView, coordinator: context.coordinator)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        let wrapped = Self.wrap(html)
        if context.coordinator.lastLoadedHTML == wrapped { return }
        context.coordinator.pendingHTML = wrapped
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
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            measureHeight(in: webView)
            // Layout sometimes changes after async font / image load even in
            // our sanitised HTML (e.g. unicode glyph fallback). Re-measure
            // briefly so the final height is correct.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.10) { [weak self] in
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

    private static func wrap(_ body: String) -> String {
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
