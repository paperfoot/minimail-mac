import AppKit

// AppKit-managed entry point. We don't use the SwiftUI App scene because we
// need full control over NSStatusItem + NSPopover (see README for rationale).
@main
enum MinimailApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
