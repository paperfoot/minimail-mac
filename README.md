<div align="center">

# Minimail

**Menu bar email client for macOS. The human-facing half of an agent-first email stack.**

<br />

[![macOS](https://img.shields.io/badge/macOS-26%20Tahoe-black?style=for-the-badge&logo=apple&logoColor=white)](https://www.apple.com/macos/)
[![SwiftUI](https://img.shields.io/badge/SwiftUI-6-orange?style=for-the-badge&logo=swift&logoColor=white)](https://developer.apple.com/xcode/swiftui/)
[![Powered by email-cli](https://img.shields.io/badge/Powered_by-email--cli-blue?style=for-the-badge)](#two-components)

---

A 420×580 popover that lives in your menu bar. Glance at the inbox, reply in a sentence, star or snooze a thread, and close it again. Minimail is the human interface for `email-cli` — the Rust engine that AI agents use to send and receive mail on your behalf.

[Why](#why) | [Two Components](#two-components) | [Install](#install) | [Features](#features) | [Business Model](#business-model)

</div>

## Why

You gave your AI agent an email address. The agent runs inside whatever harness you prefer — Claude Code, Cursor, Warp, Codex, Gemini CLI, your own scripts. It sends mail, replies to threads, files things.

You still want to peek at the inbox sometimes. Reply to a human when the agent flags one. Recap the day without tailing a log file.

Minimail is that peek. Click the menu bar icon, see the inbox, hit `r` to reply, close the popover. First launch asks for the Resend key and sender address; after that it stays out of the Dock and lives in the menu bar.

## Two Components

Minimail is one half of a product. The other half is a Rust CLI.

| Component | For | Install | License |
|---|---|---|---|
| **email-cli** | AI agents. Any harness that invokes a CLI — Claude Code, Cursor, Codex, Warp, Gemini CLI, shell scripts. | `brew install paperfoot/tap/email-cli` | MIT, free |
| **Minimail** (this repo) | Humans. Quick visual check of what the agent did. Reply in five seconds, star, snooze, archive. | DMG (paid, coming soon) | Proprietary |

The CLI is the primary interface. It does everything Minimail does — `send`, `inbox ls`, `reply`, `draft`, `broadcast`, 50+ commands in total. Minimail shells out to it for every operation. No business logic lives in the Swift code.

Think of it as: **email-cli is the backend your agent uses.** **Minimail is the window you open when you want to see what happened.**

## Business Model

- **email-cli** — MIT, free, distributed via crates.io, Homebrew, and packaged releases. It's the agent tool. Agents shouldn't have to pay for the dial tone.
- **Minimail** — paid macOS app. One-time purchase, license key, notarized DMG. It's optional. If you want a GUI for quick human inspection without typing commands, this is the sanctioned one.

On macOS, already using email-cli with an agent? Minimail buys you five-second check-ins instead of `email-cli inbox ls --limit 20 | less`.

## Install

### Requirements

1. **macOS 26 Tahoe.** Built for Liquid Glass. No backport.
2. **A Resend account.** That's the only external dependency. Free tier (100 emails/day) is enough to start. Verify a domain in the Resend dashboard and you're done — no SMTP, no IMAP, no OAuth.
3. **email-cli** is vendored inside the `.app` bundle. Settings can install/update that same bundled binary onto your user PATH for agents; Homebrew and Cargo are optional.

### Get Minimail

Paid release coming soon. To build from source today:

```bash
./scripts/build-app.sh
open .build/Minimail.app
```

Requires Xcode 26 (Swift 6 toolchain).

## Features

- **Menu bar popover** — 420×580, persistent behaviour. Stays open while you work in other apps.
- **Gmail-style inbox** — day-grouped rows, two-line preview (subject + snippet), hover actions, bulk select.
- **Threaded reader** — collapsed quoted text, tracking-pixel badge, star / snooze / unsubscribe in the header.
- **Rich-text compose** — ⌘B/I/U, paste rich text, drag-drop attachments, signature preview.
- **Undo send** — 10-second grace period after hitting Send.
- **Multiple accounts** — `⌘1–9` account switcher. Per-account mute for noisy inboxes.
- **Native notifications** — `UNUserNotificationCenter` with inline Reply / Mark Read / Archive action buttons.
- **Search operators** — `from:`, `to:`, `subject:`, `has:attachment`, `is:unread`, `is:starred`.
- **Starred / Snoozed folders** — surface what matters, defer what doesn't.
- **Liquid Glass** — toasts, popovers, autocomplete, account capsule. Apple's native material, no custom shadows.
- **Zero local database.** The CLI owns the data; Minimail is a view.

## How It Works

```
┌─────────────────────────────────┐
│         You (in the app)        │
│    click / type / keyboard      │
└───────────────┬─────────────────┘
                │  SwiftUI → AppState
                ▼
┌─────────────────────────────────┐
│      actor EmailCLI (Swift)     │
│   async/await wrapper around    │
│   the vendored email-cli binary │
└───────────────┬─────────────────┘
                │  Process + structured JSON
                ▼
┌─────────────────────────────────┐
│   email-cli (Rust, vendored)    │
│  same binary your agent uses    │
└──────┬────────────────────┬─────┘
       │                    │
   ┌───▼──────┐      ┌──────▼────────┐
   │ Local    │      │  Resend API   │
   │ SQLite   │      │  (send +      │
   │ mailbox  │      │   webhook)    │
   └──────────┘      └───────────────┘
```

Minimail does not talk to Resend. It does not touch the SQLite database. It runs `email-cli send ... --json`, parses the envelope, updates the UI. Every feature in Minimail maps to an `email-cli` subcommand — when email-cli grows a capability, Minimail inherits it after a button gets wired up.

## Architecture Notes

- `AppDelegate` — `NSStatusItem` + `NSPopover` (applicationDefined behaviour).
- `RootView` — SwiftUI, hosted via `NSHostingController`. Survives show/hide.
- `AppState` — `@Observable`, single source of truth for UI state.
- `EmailCLI` — Swift actor. Shells out to the Rust binary, decodes JSON envelopes, honours semantic exit codes.
- `WKWebView` — renders HTML bodies with JavaScript disabled and remote images blocked by default.

See [`CLAUDE.md`](CLAUDE.md) for the non-obvious rules we've learned the hard way. Read that before modifying code.

## FAQ

**Do I need email-cli installed separately?**
No. The `.app` bundle ships a vendored copy. Open Settings -> Command line tool to install/update that same binary for Terminal and agents.

**What data leaves my machine?**
Outgoing mail bodies go to Resend. Incoming mail arrives via Resend webhooks. Everything else — drafts, read state, local cache — lives in SQLite on your machine. Resend API keys live in the macOS Keychain. Minimail itself makes no direct network calls; the CLI does.

**Is this open source?**
`email-cli` is MIT. Minimail is paid commercial software. Source is visible so you can audit it, but the license is proprietary. See [LICENSE](LICENSE) and [docs/legal/eula.md](docs/legal/eula.md).

**Is there a Linux or Windows version?**
No. The CLI works everywhere (`cargo install email-cli`). Minimail is macOS-only and will stay that way — it's a menu bar app built on Apple's Liquid Glass design system.

**Why not ship this as an MCP server?**
MCP adds a network hop, a process-lifecycle problem, and a config burden per agent harness. One signed binary is simpler: agents install it, run `agent-info` once, and work from memory.

## Legal

- [Privacy Policy](docs/legal/privacy.md)
- [Terms of Service](docs/legal/terms.md)
- [End User License Agreement](docs/legal/eula.md)

## Contributing

Bug reports and feature requests: support@paperfoot.com. Pull requests are tricky on Minimail since it's commercial software — start with a discussion first. `email-cli` is MIT and maintained separately.

## License

Proprietary. See [LICENSE](LICENSE) and [docs/legal/eula.md](docs/legal/eula.md). The companion `email-cli` repo is MIT.

---

<div align="center">

Author: Paperfoot AI (SG) Pte. Ltd.

</div>
