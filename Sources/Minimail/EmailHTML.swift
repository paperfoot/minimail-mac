import Foundation

/// Display policy only. WebKit's content blocker enforces network privacy;
/// this detector decides whether to offer the per-message load button.
enum EmailHTML {
    static let inlineImageTypes: Set<String> = ["image/png", "image/jpeg", "image/gif", "image/webp", "image/avif"]
    private static let cidPattern = try! NSRegularExpression(pattern: #"cid:([^\s\"'<>\)]+)"#, options: .caseInsensitive)

    static func normalizedContentID(_ value: String) -> String {
        (value.removingPercentEncoding ?? value).trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
    }

    static func referencesContentID(_ id: String, in html: String) -> Bool {
        unresolvedContentIDs(in: html, images: [:]).contains(normalizedContentID(id))
    }

    static func unresolvedContentIDs(in html: String, images: [String: String]) -> Set<String> {
        Set(cidPattern.matches(in: html, range: NSRange(html.startIndex..., in: html)).compactMap { match in
            guard let range = Range(match.range(at: 1), in: html) else { return nil }
            let id = normalizedContentID(String(html[range]))
            return images[id] == nil ? id : nil
        })
    }

    static func resolvingInlineImages(in html: String, images: [String: String]) -> String {
        var result = html
        for match in cidPattern.matches(in: html, range: NSRange(html.startIndex..., in: html)).reversed() {
            guard let idRange = Range(match.range(at: 1), in: html), let range = Range(match.range, in: result),
                  let dataURL = images[normalizedContentID(String(html[idRange]))] else { continue }
            result.replaceSubrange(range, with: dataURL)
        }
        return result
    }

    static let blockRulesJSON = #"[{"trigger":{"url-filter":"^https?://.*"},"action":{"type":"block"}}]"#

    private static let resourcePatterns = [
        #"<(?!a\b)[a-z][^>]*\b(?:src|srcset|poster|background)\s*=\s*(?:["'][^"']*|[^\s>]*)(?:https?:|//)"#,
        #"<link\b[^>]*\bhref\s*=\s*["']?(?:https?:)?//"#,
        #"(?:url\s*\(\s*["']?|@import\s+["'])(?:https?:)?//"#
    ].compactMap { try? NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }

    static func hasRemoteResources(_ html: String) -> Bool {
        // Entity-encoded URLs are common in exported email HTML.
        let normalized = html.replacingOccurrences(of: "&#58;", with: ":")
            .replacingOccurrences(of: "&#x3a;", with: ":", options: .caseInsensitive)
            .replacingOccurrences(of: "&colon;", with: ":")
            .replacingOccurrences(of: "&quot;", with: "\"")
        let range = NSRange(normalized.startIndex..., in: normalized)
        return resourcePatterns.contains { $0.firstMatch(in: normalized, range: range) != nil }
    }

    static func wrappedDocument(_ body: String) -> String {
        // Email HTML normally assumes a light canvas. Keep sender-specified
        // backgrounds and foregrounds together instead of selectively
        // clearing backgrounds and making white text disappear.
        """
        <!doctype html><html><head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta name="color-scheme" content="light">
        <style>
          html { margin: 0; padding: 0; background: #fff; color: #1d1d1f; }
          body {
            margin: 0; padding: 14px; box-sizing: border-box;
            font: 13px/1.5 -apple-system, "SF Pro Text", system-ui, sans-serif;
            -webkit-font-smoothing: antialiased; text-size-adjust: 100%;
            overflow-wrap: anywhere;
          }
          html, body { overflow-y: hidden; }
          .mm-document { width: 100%; overflow-x: auto; }
          .mm-document > :first-child { margin-top: 0; }
          a { color: #0066cc; }
          img { max-width: 100%; height: auto; }
          pre { white-space: pre-wrap; }
          pre, code { font-family: ui-monospace, "SF Mono", monospace; }
          details.mm-quote { margin: 8px 0 12px; }
          details.mm-quote > summary {
            cursor: pointer; display: inline-block; padding: 2px 8px;
            background: #eee; border-radius: 12px; font-size: 11px;
            color: #555; list-style: none; user-select: none;
          }
          details.mm-quote > summary::-webkit-details-marker { display: none; }
          details.mm-quote[open] > summary { margin-bottom: 6px; }
        </style></head><body>\(body)</body></html>
        """
    }
}
