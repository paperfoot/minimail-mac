<div align="center">

# Minimail

**A compact menu-bar inbox that expands into a native macOS mail window.**

<br />

[![macOS](https://img.shields.io/badge/macOS-26%20Tahoe-black?style=for-the-badge&logo=apple&logoColor=white)](https://www.apple.com/macos/)
[![SwiftUI](https://img.shields.io/badge/SwiftUI-6-orange?style=for-the-badge&logo=swift&logoColor=white)](https://developer.apple.com/xcode/swiftui/)
[![Powered by email-cli](https://img.shields.io/badge/Powered_by-email--cli-blue?style=for-the-badge)](#two-components)

---

Start with a 420×580 menu-bar inbox, then expand into a resizable three-column mail window. Read threads, compose with attachments, manage accounts, or return to the compact view without losing your place. Minimail is the human interface for `email-cli` — the Rust engine that AI agents use to send and receive mail on your behalf.

[Why](#why) | [Two Components](#two-components) | [Install](#install) | [Features](#features) | [Business Model](#business-model)

</div>

## Why

You gave your AI agent an email address. The agent runs inside whatever harness you prefer — Claude Code, Cursor, Warp, Codex, Gemini CLI, your own scripts. It sends mail, replies to threads, files things.

You still want to peek at the inbox sometimes. Reply to a human when the agent flags one. Recap the day without tailing a log file.

Click the menu bar icon for a quick check, or choose **Open Mail Window** for a full workspace. First launch asks for the Resend key and sender address. The app appears in the Dock while its mail window is open and returns to the menu bar when you close it.

## Two Components

Minimail is one half of a product. The other half is a Rust CLI.

| Component | For | Install | License |
|---|---|---|---|
| **email-cli** | AI agents. Any harness that invokes a CLI — Claude Code, Cursor, Codex, Warp, Gemini CLI, shell scripts. | `brew install paperfoot/tap/email-cli` | MIT, free |
| **Minimail** (this repo) | Humans. Read, compose, search, and manage the same mailboxes as their agents. | DMG (paid, coming soon) | Proprietary |

The CLI is the primary interface. It does everything Minimail does — `send`, `inbox ls`, `reply`, `draft`, `broadcast`, 50+ commands in total. Minimail uses it for mailbox and delivery operations. Swift owns presentation, navigation, draft editing, and the Undo Send countdown.

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

Download the signed, notarized DMG from [GitHub Releases](https://github.com/paperfoot/minimail-mac/releases/latest), or build from source:

```bash
./scripts/build-app.sh
open .build/Minimail.app
```

Requires Xcode 26 (Swift 6 toolchain).

## Features

- **Menu bar popover** — 420×580, persistent behaviour. Stays open while you work in other apps.
- **Full mail window** — native mailbox sidebar, resizable columns, message selection with ⌘/Shift, and a reading or composing pane.
- **Status-item menu** — right-click for Open Mail Window, New Message, Check Mail, Settings, and Quit.
- **Inbox** — day-grouped compact rows, sender and subject previews, context actions, bulk selection, and older-message pagination.
- **Threaded reader** — collapsed quoted text, tracking-pixel badge, star / snooze / unsubscribe in the header.
- **Rich-text compose** — ⌘B/I/U, paste rich text, drag-drop attachments, signature preview.
- **Undo send** — 10-second grace period after hitting Send.
- **Multiple accounts** — `⌘1–9` account switcher. Per-account mute for noisy inboxes.
- **Native notifications** — Reply opens a draft for review; Mark Read and Archive act on the selected message.
- **Full-text search** — ⌘F searches the local mailbox across folders, within the selected account or all accounts. Up to 500 results; structured operators are not supported in the GUI.
- **Persistent drafts** — recipients, sender, Reply-To, rich text, attachments, and scheduled time survive reopening.
- **Account and delivery settings** — add, edit, remove, and choose default accounts; manage profiles and signatures; inspect Outbox and retry failed delivery with the original request identity.
- **Email links** — open `mailto:` links as drafts for review.
- **Starred / Snoozed folders** — surface what matters, defer what doesn't.
- **Liquid Glass** — toasts, popovers, autocomplete, account capsule. Apple's native material, no custom shadows.
- **One shared local database.** The CLI owns SQLite; Minimail and agents use the same mailbox.

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

- `AppDelegate` — `NSStatusItem`, `NSPopover`, and a resizable `NSWindow`; one presentation is mounted at a time.
- `RootView` — SwiftUI, hosted via `NSHostingController`; shared state survives presentation changes.
- `AppState` — `@Observable`, single source of truth for UI state.
- `EmailCLI` — Swift actor. Shells out to the Rust binary, decodes JSON envelopes, honours semantic exit codes.
- `WKWebView` — blocks message JavaScript and remote assets by default; an isolated app script measures document height.

See [`CLAUDE.md`](CLAUDE.md) for the non-obvious rules we've learned the hard way. Read that before modifying code.

## FAQ

**Do I need email-cli installed separately?**
No. The `.app` bundle ships a vendored copy. Open Settings → Advanced → Command line tool to install/update that same binary for Terminal and agents.

**What data leaves my machine?**
Outgoing mail bodies go to Resend. Incoming mail arrives via Resend webhooks. Everything else — drafts, read state, local cache — lives in SQLite on your machine. Profile credentials are managed by email-cli. Remote message assets remain blocked until you choose to load them.

**Is this open source?**
`email-cli` is MIT. Minimail is paid commercial software. Source is visible so you can audit it, but the license is proprietary. See [LICENSE](LICENSE) and [docs/legal/eula.md](docs/legal/eula.md).

**Is there a Linux or Windows version?**
No. The CLI works everywhere (`cargo install email-cli`). Minimail is macOS-only and will stay that way — it uses native AppKit windows, SwiftUI controls, and Liquid Glass navigation surfaces.

**Why not ship this as an MCP server?**
MCP adds a network hop, a process-lifecycle problem, and a config burden per agent harness. One signed binary is simpler: agents install it, run `agent-info` once, and work from memory.

## Legal

- [Privacy Policy](docs/legal/privacy.md)
- [Terms of Service](docs/legal/terms.md)
- [End User License Agreement](docs/legal/eula.md)

## Verification

Run `./scripts/verify.sh` for Swift tests, a release build, and isolated bundled-helper checks. For interaction testing, run `swift build`, build the sibling CLI, then `python3 scripts/prepare-ui-fixture.py`. Open `.build/MinimailQA.app` for a separate offline mailbox; its helper blocks delivery and remote sync.

The [September 2026 audit](docs/client-audit-2026-09.md) records coverage, fixes, and remaining scope.

## Contributing

Bug reports and feature requests: support@paperfoot.com. Pull requests are tricky on Minimail since it's commercial software — start with a discussion first. `email-cli` is MIT and maintained separately.

## License

Proprietary. See [LICENSE](LICENSE) and [docs/legal/eula.md](docs/legal/eula.md). The companion `email-cli` repo is MIT.

---

<div align="center">

Author: Paperfoot AI (SG) Pte. Ltd.

</div>
