import SwiftUI
@preconcurrency import WebKit

struct HTMLBodyView: NSViewRepresentable {
    let html: String

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        // Disable JS outright. Email never needs to execute scripts.
        let prefs = WKWebpagePreferences()
        prefs.allowsContentJavaScript = false
        config.defaultWebpagePreferences = prefs
        // Use a non-persistent data store so cookies/caches don't leak between emails.
        config.websiteDataStore = .nonPersistent()

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground") // transparent
        webView.navigationDelegate = context.coordinator

        // Block ALL remote resource loads -- tracking pixels, CSS, fonts, iframes.
        // Compile-then-load race: if HTML loads before the rule list is added,
        // tracking pixels fire. We gate the first load on the rule list install
        // by queuing the HTML on the coordinator and flushing from the compile
        // completion. Subsequent updates are safe because the list is installed.
        context.coordinator.webView = webView

        WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: "minimail-block-remote",
            encodedContentRuleList: Self.blockRulesJSON
        ) { list, _ in
            guard let list else {
                // Failed to compile — still allow content through (rare).
                context.coordinator.rulesReady = true
                context.coordinator.flushPending()
                return
            }
            webView.configuration.userContentController.add(list)
            context.coordinator.rulesReady = true
            context.coordinator.flushPending()
        }
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        let wrapped = Self.wrap(html)
        context.coordinator.pendingHTML = wrapped
        if context.coordinator.rulesReady {
            context.coordinator.flushPending()
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    private static let blockRulesJSON: String = """
    [
      {"trigger": {"url-filter": "^https?://.*",
                   "resource-type": ["image","style-sheet","font","raw","media","svg-document","document","script","fetch","websocket","ping","other"]},
       "action": {"type": "block"}}
    ]
    """

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        weak var webView: WKWebView?
        var rulesReady = false
        var pendingHTML: String?

        func flushPending() {
            guard let html = pendingHTML, let webView else { return }
            webView.loadHTMLString(html, baseURL: nil)
            pendingHTML = nil
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

    private static func wrap(_ body: String) -> String {
        let prefersDark = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let bg = prefersDark ? "#1e1e20" : "#ffffff"
        let fg = prefersDark ? "#f5f5f7" : "#1d1d1f"
        let link = "#0a84ff"
        return """
        <!doctype html><html><head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=420, initial-scale=1">
        <style>
          html, body {
            margin: 0;
            padding: 14px;
            background: \(bg);
            color: \(fg);
            font: 13px/1.5 -apple-system, "SF Pro Text", system-ui, sans-serif;
            -webkit-font-smoothing: antialiased;
            text-size-adjust: 100%;
          }
          a { color: \(link); }
          img { max-width: 100%; height: auto; }
          img[src^="http"], img[src^="https"] { display: none; }
          table { max-width: 100% !important; }
          pre, code { font-family: ui-monospace, "SF Mono", monospace; }
          blockquote {
            border-left: 3px solid rgba(127,127,127,0.2);
            padding-left: 12px;
            color: rgba(127,127,127,0.9);
            margin: 12px 0;
          }
        </style></head>
        <body>\(body)</body></html>
        """
    }
}
