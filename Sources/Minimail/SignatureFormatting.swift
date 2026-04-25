import AppKit
import Foundation

@MainActor
enum SignatureFormatting {
    static func isHTML(_ value: String) -> Bool {
        let pattern = #"</?(a|b|body|br|div|em|html|i|li|ol|p|span|strong|table|tbody|td|th|tr|u)\b"#
        return value.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    static func attributed(from stored: String) -> NSAttributedString {
        let trimmed = stored.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return NSAttributedString() }
        guard isHTML(trimmed) else {
            return NSAttributedString(string: stored, attributes: plainAttributes)
        }
        let wrapped = trimmed.range(of: "<html", options: .caseInsensitive) == nil
            ? "<html><body>\(trimmed)</body></html>"
            : trimmed
        guard let data = wrapped.data(using: .utf8),
              let attr = try? NSAttributedString(
                  data: data,
                  options: [
                      .documentType: NSAttributedString.DocumentType.html,
                      .characterEncoding: String.Encoding.utf8.rawValue,
                  ],
                  documentAttributes: nil
              ) else {
            return NSAttributedString(string: stored, attributes: plainAttributes)
        }
        return attr
    }

    static func storageString(from attributed: NSAttributedString) -> String {
        let plain = attributed.string
        guard !plain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "" }
        if isHTML(plain) { return plain }
        guard containsRichFormatting(attributed) else { return plain }

        let range = NSRange(location: 0, length: attributed.length)
        let attrs: [NSAttributedString.DocumentAttributeKey: Any] = [
            .documentType: NSAttributedString.DocumentType.html,
            .characterEncoding: String.Encoding.utf8.rawValue,
        ]
        guard let data = try? attributed.data(from: range, documentAttributes: attrs),
              let html = String(data: data, encoding: .utf8) else {
            return plain
        }
        return bodyFragment(from: html)
    }

    static func displayText(from stored: String) -> String {
        guard isHTML(stored) else { return stored }
        return attributed(from: stored)
            .string
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let plainAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 12),
        .foregroundColor: NSColor.labelColor,
    ]

    private static func containsRichFormatting(_ attributed: NSAttributedString) -> Bool {
        var found = false
        let full = NSRange(location: 0, length: attributed.length)
        attributed.enumerateAttributes(in: full, options: []) { attrs, _, stop in
            if attrs[.link] != nil {
                found = true
                stop.pointee = true
                return
            }
            if attrs[.underlineStyle] != nil {
                found = true
                stop.pointee = true
                return
            }
            if let font = attrs[.font] as? NSFont {
                let traits = NSFontManager.shared.traits(of: font)
                if traits.contains(.boldFontMask) || traits.contains(.italicFontMask) {
                    found = true
                    stop.pointee = true
                    return
                }
            }
            if let color = attrs[.foregroundColor] as? NSColor,
               color != NSColor.labelColor,
               color != NSColor.textColor {
                found = true
                stop.pointee = true
            }
        }
        return found
    }

    private static func bodyFragment(from html: String) -> String {
        let ns = html as NSString
        let lower = html.lowercased() as NSString
        let bodyOpen = lower.range(of: "<body")
        guard bodyOpen.location != NSNotFound else {
            return html.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let afterBodyOpen = NSRange(
            location: bodyOpen.location + bodyOpen.length,
            length: max(0, lower.length - (bodyOpen.location + bodyOpen.length))
        )
        let closeAngle = lower.range(of: ">", options: [], range: afterBodyOpen)
        guard closeAngle.location != NSNotFound else {
            return html.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let contentStart = closeAngle.location + closeAngle.length
        let closeBodyRange = NSRange(location: contentStart, length: max(0, lower.length - contentStart))
        let bodyClose = lower.range(of: "</body>", options: [], range: closeBodyRange)
        let contentEnd = bodyClose.location == NSNotFound ? lower.length : bodyClose.location
        guard contentEnd >= contentStart else {
            return html.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return ns.substring(with: NSRange(location: contentStart, length: contentEnd - contentStart))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
