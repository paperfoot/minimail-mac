import AppKit
import SwiftUI

/// Shared handle so ComposeView's toolbar can reach the live NSTextView
/// without prop-drilling bindings through SwiftUI. Set during makeNSView,
/// cleared automatically when the scroll view deallocates.
@MainActor
final class RichTextEditorHandle {
    weak var textView: NSTextView?
}

/// NSTextView wrapped for SwiftUI with rich-text editing enabled. All the
/// macOS text-handling shortcuts work out of the box because this is a real
/// NSTextView: ⌘C/⌘V/⌘A/⌘Z/⌘⇧Z plus the font-panel bindings ⌘B / ⌘I / ⌘U for
/// bold / italic / underline. Paste preserves formatting from Word, Pages,
/// Google Docs, Notes, etc.
///
/// The binding is an NSAttributedString so the compose state owns the full
/// typed representation; `ComposeView` asks for a plain-text copy (via
/// `.string`) for autosave + draft persistence and an HTML copy (via
/// `data(from:documentAttributes:)`) at send time.
struct RichTextEditor: NSViewRepresentable {
    @Binding var attributedText: NSAttributedString
    /// Called after each edit so the parent can schedule autosave without
    /// needing to observe the binding directly.
    var onEdit: (() -> Void)? = nil
    /// Optional handle that stores a weak pointer to the NSTextView so a
    /// sibling toolbar can dispatch formatting actions to it.
    var handle: RichTextEditorHandle?

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true

        guard let textView = scroll.documentView as? NSTextView else { return scroll }
        textView.delegate = context.coordinator
        textView.isRichText = true
        textView.allowsUndo = true
        textView.allowsImageEditing = false
        textView.importsGraphics = false
        textView.usesFontPanel = false
        textView.usesInspectorBar = false
        textView.isAutomaticLinkDetectionEnabled = true
        textView.isAutomaticDataDetectionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = true
        textView.isGrammarCheckingEnabled = false
        textView.drawsBackground = false
        textView.setAccessibilityLabel("Message body")
        textView.font = .systemFont(ofSize: 13)
        textView.textColor = .labelColor
        textView.linkTextAttributes = [
            .foregroundColor: NSColor(red: 0.04, green: 0.52, blue: 1.0, alpha: 1.0),
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .cursor: NSCursor.pointingHand,
        ]
        textView.textContainerInset = NSSize(width: 10, height: 10)
        if let storage = textView.textStorage {
            storage.setAttributedString(attributedText)
        }
        context.coordinator.textView = textView
        handle?.textView = textView
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? NSTextView,
              let storage = textView.textStorage else { return }
        // NSViewRepresentable keeps the coordinator alive across SwiftUI
        // updates, so refresh its copy of this value to keep the current
        // binding and callback rather than the ones captured at creation.
        context.coordinator.parent = self
        handle?.textView = textView
        // Skip the update we just triggered ourselves — otherwise the round-
        // trip from delegate → binding → updateNSView → textStorage.set…
        // would clobber the user's cursor position every keystroke.
        if context.coordinator.suppressNextUpdate {
            context.coordinator.suppressNextUpdate = false
            return
        }
        if !storage.isEqual(to: attributedText) {
            let selection = textView.selectedRanges
            storage.setAttributedString(attributedText)
            // Replacing content can make a previous cursor or selection
            // extend past the end of the new string. AppKit expects every
            // restored range to fit the current text storage.
            textView.selectedRanges = selection.map { value in
                let range = value.rangeValue
                let location = min(range.location, storage.length)
                let length = min(range.length, storage.length - location)
                return NSValue(range: NSRange(location: location, length: length))
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: RichTextEditor
        weak var textView: NSTextView?
        var suppressNextUpdate = false

        init(_ parent: RichTextEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView,
                  let storage = textView.textStorage else { return }
            suppressNextUpdate = true
            parent.attributedText = NSAttributedString(attributedString: storage)
            parent.onEdit?()
        }
    }
}

/// Toolbar hover/click targets for the rich-text compose editor. Each button
/// dispatches a standard Cocoa action through the responder chain so the
/// currently-focused NSTextView performs the transformation, exactly as if
/// the user had hit the corresponding menu item.
struct RichTextToolbar: View {
    /// Parent supplies a ref to the live text view so toolbar buttons can
    /// manipulate it directly when a stock responder action doesn't exist
    /// (e.g. our custom bullet/numbered insertions).
    let textViewProvider: () -> NSTextView?

    var body: some View {
        HStack(spacing: 2) {
            toolButton(symbol: "bold", help: "Bold (⌘B)") {
                toggleFontTrait(.boldFontMask)
            }
            toolButton(symbol: "italic", help: "Italic (⌘I)") {
                toggleFontTrait(.italicFontMask)
            }
            toolButton(symbol: "underline", help: "Underline (⌘U)") {
                toggleUnderline()
            }
            divider
            toolButton(symbol: "list.bullet", help: "Bullet list") { insertListMarker("•  ") }
            toolButton(symbol: "list.number", help: "Numbered list") { insertListMarker("1. ") }
            divider
            toolButton(symbol: "link", help: "Add link (⌘K)") { promptForLink() }
            toolButton(symbol: "eraser", help: "Clear formatting") { clearFormatting() }
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color.primary.opacity(0.03))
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.1))
            .frame(width: 1, height: 14)
            .padding(.horizontal, 4)
    }

    private func toolButton(symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 24, height: 22)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(help)
        // VoiceOver: the `help` string already describes the action + key
        // shortcut ("Bold (⌘B)"), so reuse it as the accessibility label
        // rather than surface the raw SF Symbol name ("bold").
        .accessibilityLabel(help)
    }

    private func toggleFontTrait(_ trait: NSFontTraitMask) {
        guard let textView = textViewProvider(),
              let storage = textView.textStorage else { return }
        let manager = NSFontManager.shared
        let fallback = textView.font ?? NSFont.systemFont(ofSize: 13)
        let selected = textView.selectedRange()

        if selected.length == 0 {
            var attrs = textView.typingAttributes
            let font = attrs[.font] as? NSFont ?? fallback
            let traits = manager.traits(of: font)
            attrs[.font] = traits.contains(trait)
                ? manager.convert(font, toNotHaveTrait: trait)
                : manager.convert(font, toHaveTrait: trait)
            textView.typingAttributes = attrs
            return
        }

        var allSelectedTextHasTrait = true
        storage.enumerateAttribute(.font, in: selected, options: []) { value, _, stop in
            let font = value as? NSFont ?? fallback
            if !manager.traits(of: font).contains(trait) {
                allSelectedTextHasTrait = false
                stop.pointee = true
            }
        }

        if textView.shouldChangeText(in: selected, replacementString: nil) {
            storage.beginEditing()
            storage.enumerateAttribute(.font, in: selected, options: []) { value, range, _ in
                let font = value as? NSFont ?? fallback
                let updated = allSelectedTextHasTrait
                    ? manager.convert(font, toNotHaveTrait: trait)
                    : manager.convert(font, toHaveTrait: trait)
                storage.addAttribute(.font, value: updated, range: range)
            }
            storage.endEditing()
            textView.didChangeText()
        }
    }

    private func toggleUnderline() {
        guard let textView = textViewProvider(),
              let storage = textView.textStorage else { return }
        let selected = textView.selectedRange()
        let style = NSUnderlineStyle.single.rawValue

        if selected.length == 0 {
            var attrs = textView.typingAttributes
            let current = attrs[.underlineStyle] as? Int
            attrs[.underlineStyle] = current == style ? nil : style
            textView.typingAttributes = attrs
            return
        }

        var allSelectedTextIsUnderlined = true
        storage.enumerateAttribute(.underlineStyle, in: selected, options: []) { value, _, stop in
            if (value as? Int) != style {
                allSelectedTextIsUnderlined = false
                stop.pointee = true
            }
        }

        if textView.shouldChangeText(in: selected, replacementString: nil) {
            if allSelectedTextIsUnderlined {
                storage.removeAttribute(.underlineStyle, range: selected)
            } else {
                storage.addAttribute(.underlineStyle, value: style, range: selected)
            }
            textView.didChangeText()
        }
    }

    /// Prepend a simple list marker to each selected, nonempty paragraph.
    /// Keeps the HTML export readable even without real `<ul>` output —
    /// recipients see "•" or "1." markers preserved inline.
    private func insertListMarker(_ marker: String) {
        guard let textView = textViewProvider(),
              let storage = textView.textStorage else { return }
        let selection = textView.selectedRange()
        guard let edit = Self.listMarkerEdit(
            in: storage,
            selectedRange: selection,
            marker: marker
        ) else { return }

        let undoManager = textView.undoManager
        undoManager?.beginUndoGrouping()
        defer { undoManager?.endUndoGrouping() }

        if textView.shouldChangeText(in: edit.range, replacementString: edit.replacement.string) {
            storage.replaceCharacters(in: edit.range, with: edit.replacement)
            textView.didChangeText()
            textView.setSelectedRange(edit.selection)
            undoManager?.setActionName(marker.hasPrefix("•") ? "Bullet List" : "Numbered List")
        }
    }

    /// Pure list transformation kept separate from NSTextView mutation so the
    /// edit is deterministic and can be covered without constructing AppKit UI.
    /// The returned replacement retains every existing text attribute.
    static func listMarkerEdit(
        in attributedText: NSAttributedString,
        selectedRange: NSRange,
        marker: String
    ) -> (range: NSRange, replacement: NSAttributedString, selection: NSRange)? {
        guard attributedText.length > 0, !marker.isEmpty else { return nil }

        let text = attributedText.string as NSString
        let location = min(selectedRange.location, attributedText.length)
        let selectionLength = min(selectedRange.length, attributedText.length - location)
        let selectionEnd = location + selectionLength
        let lastSelectedLocation = selectionLength > 0 ? selectionEnd - 1 : location

        let firstParagraph = text.paragraphRange(for: NSRange(location: location, length: 0))
        let lastParagraph = text.paragraphRange(
            for: NSRange(location: lastSelectedLocation, length: 0)
        )
        let editRange = NSUnionRange(firstParagraph, lastParagraph)
        guard editRange.length > 0 else { return nil }

        var insertionLocations: [Int] = []
        var paragraphLocation = editRange.location
        let editEnd = NSMaxRange(editRange)
        while paragraphLocation < editEnd {
            let paragraphRange = text.paragraphRange(
                for: NSRange(location: paragraphLocation, length: 0)
            )
            let paragraph = text.substring(with: paragraphRange)
            let content = paragraph.trimmingCharacters(in: .whitespacesAndNewlines)
            if !content.isEmpty, !paragraphAlreadyHasMarker(content, marker: marker) {
                insertionLocations.append(paragraphRange.location)
            }

            let nextLocation = NSMaxRange(paragraphRange)
            guard nextLocation > paragraphLocation else { break }
            paragraphLocation = nextLocation
        }
        guard !insertionLocations.isEmpty else { return nil }

        let replacement = NSMutableAttributedString(
            attributedString: attributedText.attributedSubstring(from: editRange)
        )
        for insertionLocation in insertionLocations.reversed() {
            let attributeLocation = min(insertionLocation, attributedText.length - 1)
            var attributes = attributedText.attributes(at: attributeLocation, effectiveRange: nil)
            // A list marker should match the surrounding text, but must not
            // accidentally become part of a leading link or attachment.
            attributes.removeValue(forKey: .link)
            attributes.removeValue(forKey: .attachment)
            replacement.insert(
                NSAttributedString(string: marker, attributes: attributes),
                at: insertionLocation - editRange.location
            )
        }

        let markerLength = (marker as NSString).length
        let adjustedSelection: NSRange
        if selectionLength == 0 {
            let insertionsBeforeCursor = insertionLocations.count { $0 <= location }
            adjustedSelection = NSRange(
                location: location + insertionsBeforeCursor * markerLength,
                length: 0
            )
        } else {
            let insertionsBeforeStart = insertionLocations.count { $0 <= location }
            let insertionsBeforeEnd = insertionLocations.count { $0 < selectionEnd }
            let adjustedStart = location + insertionsBeforeStart * markerLength
            let adjustedEnd = selectionEnd + insertionsBeforeEnd * markerLength
            adjustedSelection = NSRange(
                location: adjustedStart,
                length: adjustedEnd - adjustedStart
            )
        }

        return (editRange, replacement, adjustedSelection)
    }

    private static func paragraphAlreadyHasMarker(_ content: String, marker: String) -> Bool {
        if marker.hasPrefix("•") {
            return content.hasPrefix("•")
        }
        if marker.first?.isNumber == true {
            let token = content.prefix { !$0.isWhitespace }
            guard token.last == "." || token.last == ")" else { return false }
            return !token.dropLast().isEmpty && token.dropLast().allSatisfy(\.isNumber)
        }
        return content.hasPrefix(marker)
    }

    private func clearFormatting() {
        guard let textView = textViewProvider(),
              let storage = textView.textStorage else { return }
        let range = textView.selectedRange().length > 0
            ? textView.selectedRange()
            : NSRange(location: 0, length: storage.length)
        let plain: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13),
            .foregroundColor: NSColor.labelColor,
        ]
        if textView.shouldChangeText(in: range, replacementString: nil) {
            storage.setAttributes(plain, range: range)
            textView.didChangeText()
        }
    }

    private func promptForLink() {
        guard let textView = textViewProvider(),
              let storage = textView.textStorage else { return }
        let selected = textView.selectedRange()
        let alert = NSAlert()
        alert.messageText = "Insert link"
        alert.informativeText = "Paste the URL below."
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        input.placeholderString = "https://…"
        alert.accessoryView = input
        guard alert.runModal() == .alertFirstButtonReturn,
              let url = URL(string: input.stringValue), input.stringValue.contains("://") else { return }
        let displayText = selected.length > 0
            ? (storage.string as NSString).substring(with: selected)
            : input.stringValue
        let attrString = NSAttributedString(string: displayText, attributes: [
            .link: url,
            .foregroundColor: NSColor(red: 0.04, green: 0.52, blue: 1.0, alpha: 1.0),
            .underlineStyle: NSUnderlineStyle.single.rawValue,
        ])
        if textView.shouldChangeText(in: selected, replacementString: displayText) {
            storage.replaceCharacters(in: selected, with: attrString)
            textView.didChangeText()
        }
    }
}
