import SwiftUI

/// Apply the macOS 26 Liquid Glass effect with a shape default that matches
/// our other glass surfaces. Deployment target is 26.0 so no fallback is
/// needed — `glassEffect` is always available.
extension View {
    func glassSurface<S: Shape>(in shape: S = RoundedRectangle(cornerRadius: 12)) -> some View {
        self.glassEffect(.regular, in: shape)
    }
}
