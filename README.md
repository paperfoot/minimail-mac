# Minimail

Minimalist macOS menu bar email client. A 420×580 popover that lives in the menu bar and talks to the [`email-cli`](https://github.com/paperfoot/email-cli) Rust engine for every data operation.

- **macOS 26 Tahoe only.** Built for Liquid Glass.
- **Zero local database.** The Rust CLI owns the data; Minimail is a view.
- **Persistent popover.** `NSPopover.behavior = .applicationDefined` — stays open while you work in other apps.

## Build

Requires the Swift 6 toolchain shipped with Xcode 26 (or the Swift 6.3+ standalone toolchain).

```bash
./scripts/build-app.sh
open .build/Minimail.app
```

Minimail expects `email-cli` in `PATH`. Install it via:

```bash
brew install paperfoot/tap/email-cli
```

## Architecture

- `AppDelegate` manages `NSStatusItem` + `NSPopover`.
- SwiftUI `RootView` hosted via `NSHostingController`; survives show/hide.
- `@Observable AppState` is the single source of truth for UI state.
- `actor EmailCLI` shells out to the Rust binary, decodes JSON envelopes.
- `WKWebView` renders HTML bodies with JS disabled and remote images blocked.

## License

MIT.
