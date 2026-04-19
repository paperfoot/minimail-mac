import SwiftUI

/// Wraps a view with the macOS 26 Liquid Glass effect, falling back to
/// `.ultraThinMaterial` on older OS versions. Use this instead of calling
/// `.glassEffect()` directly so fallbacks stay consistent across the app.
extension View {
    @ViewBuilder
    func glassSurface<S: Shape>(in shape: S = RoundedRectangle(cornerRadius: 12)) -> some View {
        if #available(macOS 26, *) {
            self.glassEffect(.regular, in: shape)
        } else {
            self.background(.ultraThinMaterial, in: shape)
        }
    }
}
