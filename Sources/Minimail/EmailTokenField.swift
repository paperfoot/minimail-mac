import AppKit
import SwiftUI

/// NSTokenField wrapped for SwiftUI. Types an email → press comma/space/return →
/// it becomes a pill chip. Full keyboard shortcuts work (⌘A, ⌘C, ⌘V, ⌘Z) because
/// it's a real NSTextField subclass.
struct EmailTokenField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String = ""

    func makeNSView(context: Context) -> NSTokenField {
        let field = NSTokenField()
        field.tokenizingCharacterSet = CharacterSet(charactersIn: ", ;\n\t")
        field.completionDelay = 0.1
        field.delegate = context.coordinator
        field.placeholderString = placeholder
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 13)
        field.bezelStyle = .squareBezel
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.cell?.wraps = true
        field.cell?.isScrollable = false
        return field
    }

    func updateNSView(_ field: NSTokenField, context: Context) {
        let tokens = Self.tokens(from: text)
        let current = (field.objectValue as? [String]) ?? []
        if tokens != current {
            field.objectValue = tokens
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    static func tokens(from string: String) -> [String] {
        string
            .split(whereSeparator: { ",; \n\t".contains($0) })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    @MainActor
    final class Coordinator: NSObject, NSTokenFieldDelegate {
        let parent: EmailTokenField
        init(_ parent: EmailTokenField) { self.parent = parent }

        // SwiftUI binding <-> NSTokenField objectValue
        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTokenField else { return }
            let tokens = (field.objectValue as? [String]) ?? []
            let joined = tokens.joined(separator: ", ")
            if joined != parent.text { parent.text = joined }
        }

        // Valid email → capsule-style pill. Free text → bordered.
        func tokenField(_ tokenField: NSTokenField,
                        styleForRepresentedObject representedObject: Any) -> NSTokenField.TokenStyle {
            if let s = representedObject as? String, s.looksLikeEmail {
                return .rounded
            }
            return .default
        }

        func tokenField(_ tokenField: NSTokenField,
                        displayStringForRepresentedObject representedObject: Any) -> String? {
            representedObject as? String
        }
    }
}
