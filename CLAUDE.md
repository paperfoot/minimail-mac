# Minimail — conventions for coding agents

This file encodes the non-obvious rules learned the hard way. Future
agents working on this codebase: read this before making changes so
you don't unknowingly regress fixes that took visual QA to find.

## Platform target

- **macOS 26.0 minimum** (`LSMinimumSystemVersion` in `Resources/Info.plist`,
  `platforms: [.macOS("26.0")]` in `Package.swift`).
- Deployment target is `macOS 26`, not `iOS 26` — Liquid Glass availability
  guards should use `#available(macOS 26, *)` if needed, but **prefer to
  remove them entirely** since we never run below the minimum.
- `LSUIElement` is `true` — Minimail is a menu-bar accessory, not a
  regular app. This has downstream consequences (see below).

## Liquid Glass usage — Apple's guidance, applied here

Grounded in the `swiftui-liquid-glass` skill and Apple's
[Applying Liquid Glass to custom views](https://developer.apple.com/documentation/SwiftUI/Applying-Liquid-Glass-to-custom-views).

### Do
- Use `.glassEffect(.regular, in: <shape>)` for floating chrome: toasts,
  popovers, toolbars, capsule buttons, selection bars.
- Use `.glassEffect(.regular.tint(<color>.opacity(0.15)), in: <shape>)`
  when you need a coloured glass surface (e.g. our inbox selection bar).
- Use `.glassSurface(in:)` (our wrapper in `GlassSurface.swift`) when you
  want the default 12pt rounded rectangle.
- Wrap multiple nearby glass elements in `GlassEffectContainer` so they
  sample a shared source region.

### Don't
- **No custom `.shadow()` or `.overlay(Shape().strokeBorder(...))` on a
  glass surface.** The system draws its own edge lighting — adding more
  produces a muddy double border. This specifically killed our first
  toast + popover designs.
- **No `.prominent` glass variant** — it doesn't exist. Only
  `.regular`, `.clear`, and `.identity` do. For prominent actions use
  `.buttonStyle(.glassProminent)`.
- **Don't apply glass to body content** (message rows, scroll view
  contents, long lists). Glass is navigation-layer material only.
- **Don't stack glass on glass.** Nest with `GlassEffectContainer` instead.

### Shape consistency
- Capsule: `.capsule` for pills and toasts.
- Rounded rectangles: **12pt** corner radius is our default. Don't
  introduce 10 / 14 / 16 unless there's a specific visual reason.
- `continuous` style for all rounded rectangles.

## Menu-bar (LSUIElement) gotchas

An `LSUIElement=true` app starts with `NSApp.mainMenu == nil`, which
silently breaks **every Cocoa text-editing keyboard shortcut**
(⌘A / ⌘C / ⌘V / ⌘X / ⌘Z / ⌘⇧Z / ⌘B / ⌘I / ⌘U). NSTextField /
NSTextView route those through Edit / Format menu items, not via
direct key handling.

**We install a minimal main menu in `AppDelegate.applicationDidFinishLaunching`
(`installMinimalMenuBar`).** Do not remove it. If you add a new text-editing
shortcut that users expect, wire it into that menu — don't try to handle
it via `onKeyPress` or a custom hidden Button.

## Focus and keyboard navigation

### `.focusable()` needs `.focusEffectDisabled()`

macOS renders a blue focus ring around any focusable SwiftUI view. On
our inbox / reader scroll views this looks like a giant selection
rectangle. Pattern:

```swift
.focusable()
.focusEffectDisabled()   // required — otherwise blue rectangle on hold
```

Apply this whenever you use `.focusable()`. Documented in
[`focusEffectDisabled(_:)` Apple docs](https://developer.apple.com/documentation/swiftui/view/focuseffectdisabled(_:)).

### Keyboard shortcuts

- **Never** bind a bare letter with `modifiers: []` at a scope where
  text inputs live below (RootView, InboxView root). The shortcut will
  swallow every typed character that matches. Global help key is `⌘/`
  (Gmail convention) — we removed the bare `?` / `/` shortcuts for this
  reason.
- Bare-letter shortcuts are OK in leaf views that contain no text
  inputs. Example: `s` (star) lives on ReaderView, which has no
  descendant TextField. Document the reason inline so a later agent
  doesn't "fix" it back to `⌘S`.

## State architecture

- `AppState` is the single root. It owns five `@Observable` substates:
  `SessionState` (accounts), `InboxState` (folders + selection),
  `ReaderState` (current message + thread), `ComposeState` (draft),
  `RouterState` (navigation).
- **Views should not reach into `EmailCLI.shared` directly.** Call an
  AppState method (`state.markRead(message:)`, `state.archive(ids:)`,
  etc.). The CLI actor is an implementation detail.
- **Substates must not leak fields into each other.** E.g.
  `pendingDeleteConfirm` belongs on `ReaderState`, not `ComposeState`
  (we already moved it — don't move it back).
- `EmailCLI` is a Swift actor. All its methods are async throws. All
  arguments flow through the CLI's `--json` envelopes.

## Logging

Use the typed loggers in `Log.*` (see top of `AppState.swift`):

```swift
Log.send.error("send failed: \(String(describing: error), privacy: .public)")
```

Don't use `NSLog` or `print`. `Logger` (from `os`) survives release
builds and groups correctly in Console.app.

## Helpers you should reuse (don't duplicate)

| Helper | Purpose |
|--------|---------|
| `Dates.parse(_:)` | ISO-8601 / SQLite-UTC timestamp parsing. Non-isolated, thread-safe. |
| `DateFormat.parse(_:)` | Main-actor wrapper around `Dates.parse`. |
| `String.splitAddressTokens()` | Split comma/semicolon/newline-separated address list while preserving display names. |
| `String.looksLikeEmail` | Regex validation for a single address. |
| `View.glassSurface(in:)` | Apply `.glassEffect(.regular, in: shape)` with a 12pt default. |
| `View.glassToastBackground()` | Capsule glass for floating toasts. |
| `RichTextEditor` | NSTextView wrapper with Bold/Italic/Underline/Paste-rich-text. Use this, don't add another `TextEditor`. |
| `EmailTokenField` | Recipient token field with glass autocomplete. Don't reinstate an NSTokenField wrapper. |

## Process / IPC

- `EmailCLI.runPlainData` drains stdout + stderr via `AsyncDataCollector`
  (a pipe drainer). If you're tempted to switch to
  `terminationHandler` + `readDataToEndOfFile`, don't — pipe buffers
  are 64KB and the CLI can emit large JSON payloads (full message
  bodies, HTML). Deadlocks are silent and only reproduce intermittently.

## Build + release

- Build:       `swift build` (debug) or `./scripts/build-app.sh release`.
- Install:     copy `.build/Minimail.app` to `/Applications`, re-sign
               with `codesign --force --deep --sign -`.
- Release DMG: `./scripts/release.sh <version>`. Bumps Info.plist,
               creates DMG, tags git, pushes, creates GitHub release.
- Info.plist version is the source of truth for the app; `Cargo.toml`
  in the sibling `email-cli` repo is the CLI version. They're
  independent.

## Testing

There are snapshot-decode tests in `Tests/MinimailTests/` for the JSON
contract with `email-cli`. If you change `email-cli`'s JSON shape, add
a fixture here that proves the old shape still parses. The user ships
both repos in lockstep via the embedded-CLI pattern (app bundle
contains a vendored copy at `Contents/Resources/email-cli`).
