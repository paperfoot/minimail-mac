import AppKit
import Foundation
import Testing
@testable import Minimail

@MainActor
@Suite("Rich text list editing")
struct RichTextToolbarTests {
    @Test("List markers apply to every selected paragraph")
    func marksMultipleParagraphs() throws {
        let source = NSAttributedString(string: "Alpha\nBeta\nGamma")

        let edit = try #require(
            RichTextToolbar.listMarkerEdit(
                in: source,
                selectedRange: NSRange(location: 0, length: source.length),
                marker: "• "
            )
        )

        #expect(edit.range == NSRange(location: 0, length: source.length))
        #expect(edit.replacement.string == "• Alpha\n• Beta\n• Gamma")
        #expect(edit.selection == NSRange(location: 2, length: source.length + 4))
    }

    @Test("Existing bullets are not duplicated")
    func doesNotDuplicateBullets() throws {
        let source = NSAttributedString(string: "• Existing\nPlain")

        let edit = try #require(
            RichTextToolbar.listMarkerEdit(
                in: source,
                selectedRange: NSRange(location: 0, length: source.length),
                marker: "• "
            )
        )

        #expect(edit.replacement.string == "• Existing\n• Plain")
        #expect(edit.replacement.string.components(separatedBy: "• Existing").count - 1 == 1)
    }

    @Test("List insertion preserves text formatting without extending links to markers")
    func listMarkersRetainFormatting() throws {
        let source = NSMutableAttributedString(
            string: "Alpha\nBeta",
            attributes: [
                .font: NSFont.boldSystemFont(ofSize: 15),
                .foregroundColor: NSColor.systemRed,
            ]
        )
        let link = try #require(URL(string: "https://example.com/alpha"))
        source.addAttribute(.link, value: link, range: NSRange(location: 0, length: 5))
        source.addAttribute(
            .underlineStyle,
            value: NSUnderlineStyle.single.rawValue,
            range: NSRange(location: 6, length: 4)
        )

        let edit = try #require(
            RichTextToolbar.listMarkerEdit(
                in: source,
                selectedRange: NSRange(location: 0, length: source.length),
                marker: "• "
            )
        )
        let result = edit.replacement

        #expect(result.string == "• Alpha\n• Beta")
        #expect(result.attribute(.font, at: 0, effectiveRange: nil) as? NSFont == NSFont.boldSystemFont(ofSize: 15))
        #expect(result.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor == NSColor.systemRed)
        #expect(result.attribute(.link, at: 0, effectiveRange: nil) == nil)
        #expect(result.attribute(.link, at: 2, effectiveRange: nil) as? URL == link)
        #expect(result.attribute(.underlineStyle, at: 10, effectiveRange: nil) as? Int == NSUnderlineStyle.single.rawValue)
    }
}
