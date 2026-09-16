# Minimail client audit — September 2026

## Workflow and coverage

1. Read every original Swift source file, the existing tests, package configuration, resources, build/release scripts, and project guidance. Trace the UI through AppState and the CLI contract rather than treating text matches as a code review.
2. Trace the corresponding email-cli draft, database, attachment, inbox cursor, and outbox paths. Check old database and JSON compatibility.
3. Implement a shared-state compact/full-window client, then repair the underlying save, navigation, delivery, and notification transitions.
4. Run state/contract regressions and Rust tests with isolated fake executables or temporary databases.
5. Exercise the built app with two synthetic accounts, 144 messages, rich/plain drafts, attachments, long HTML, and blocked network/delivery.
6. Verify the exact embedded helper, sign and notarize the release, publish both repositories, install, and check the installed bundle separately.

The original client contained 24 Swift source files. The review covered their full contents, including unchanged error classification, links, material helpers, login registration, diagnostics, entry point, and signature formatting. New code adds the window presentation and settings operations. Backend coverage focuses on the commands used by this client; this is not an audit of all Resend administrative commands in email-cli.

## Presentation direction

[Apple's window guidance](https://developer.apple.com/design/human-interface-guidelines/windows), [Mailspring](https://github.com/Foundry376/Mailspring), and [Geary](https://wiki.gnome.org/Apps/Geary) informed the structure: mailboxes, message list, reading/composing pane; visible message actions; and restrained chrome. [Geary's test checklist](https://wiki.gnome.org/Apps%282f%29Geary%282f%29TestChecklist.html) informed the interaction checks.

Minimail keeps its quick 420 × 580 menu-bar view. Expand mounts the same state in a resizable AppKit window with persistent mailbox navigation and a native split between messages and the reader. Only one presentation owns editors and shortcuts at a time. The full window appears in the Dock; closing it returns the app to menu-bar operation. Native list selection, sidebar material, titlebar controls, menus, and text editing provide the macOS behavior. Glass remains on floating controls and status surfaces.

## Findings addressed

### Comparison with established open-source clients

This is a workflow comparison against their published documentation, not a claim that every competing client was installed and tested.

| Reference and baseline | Minimail outcome |
|---|---|
| [Mailspring](https://www.getmailspring.com/): unified accounts, desktop layouts, shortcuts, search, and Undo Send | Added the full three-column window and preserved compact access. Checked selection, account scope, search focus, pagination, and the complete Undo Send lifecycle. |
| [Thunderbird account settings](https://support.mozilla.org/en-US/kb/configuration-options-accounts): add, edit, choose a default, remove, and manage identity/signature settings | Added an account/profile manager, validated key replacement, display-name/profile editing, confirmed removal, and a separate signature editor with unsaved-change handling. Default sender and visible mailbox remain independent. |
| [Geary's interaction checklist](https://wiki.gnome.org/Apps%282f%29Geary%282f%29TestChecklist.html): follow complete reading/composing/navigation workflows, including error paths | Built a synthetic multi-account fixture with drafts, threads, attachments, and long HTML. Checked rendered window/compose/compact flows and presentation changes; parser/state tests cover additional transitions and failure paths. |
| Mailspring search and Thunderbird folder behavior: structured queries and recoverable deletion | Remaining gaps: plain full-text search has a 500-result cap; deletion remains confirmed permanent local deletion. Search operators and a recoverable Trash need further work. |
| Thunderbird account/provider and synchronization settings | Remaining gaps: Resend domain accounts only, with no IMAP/OAuth providers, server folders, or per-folder synchronization controls. |
| Mailspring extended mail tools | Contacts/calendar integration, reusable templates, localization, and configurable layouts remain future product work. They were not added merely to match a feature list. |

### Repairs in this release

| Area | Defect or missing behavior | Change |
|---|---|---|
| Window lifecycle | Only the fixed menu-bar surface existed; swapping hosting controllers could shrink the expanded window | Shared-state full window, expansion/return controls, native File/Window menus, saved frame restored after mounting, enforced minimum size, and close-to-menu-bar behavior |
| Status item | Right-click did not expose expected app controls | Open Window, New Message, Check Mail, Settings, and Quit |
| Selection | Compact selection behavior did not provide a desktop mail workflow | Native list selection with Command/Shift and bulk actions; confirmation before permanent local deletion |
| Pagination | Only the initial loaded set was accessible; CLI cursor assumed IDs followed dates | Load Older Messages; cursor follows date plus ID, with tie/missing-cursor tests |
| Account switching | Slow refresh or search could replace the new account's data | Request generation and account checks; settings default-sender changes preserve mailbox choice |
| Navigation | Leaving compose could abandon pending recipients or an unfinished save | Commit token text and flush serialized saves before navigation; retain the draft on save failure |
| Draft persistence | Reply-To and scheduled time disappeared on reopening | Backward-compatible database migration and JSON fields; explicit clear-versus-preserve flags |
| Draft attachments | Repeated edits deleted the source snapshot before copying it | Copy into a fresh revision, commit the row, then clean obsolete files; return fresh paths to the GUI |
| Attachment failures | Missing files could silently disappear | Keep missing files visible and require removal/re-attachment before saving or sending |
| Undo Send | Closing the compact surface cut the grace period short; timer could cancel its own delivery | Full ten-second countdown across presentation changes; separate timer and delivery lifecycle |
| Quit during delivery | Termination could race active network delivery | Wait for save, queued send, active delivery, and draft cleanup |
| Retry identity | Creating a fresh send from the recovery banner risked duplicates | Open the durable Outbox and retain its idempotency key; include Reply-To, schedule, and unambiguous field boundaries in new request identity |
| Startup recovery | Automatically flushing an old unfinished outbox could transmit stale mail | Surface unfinished delivery for explicit review in Outbox |
| Reply/forward | Context-menu replies could quote a list preview | Fetch the full message before seeding compose; keep source account identity |
| Recipient controls | Escape and delimiter handling could discard or split text incorrectly | Escape dismisses suggestions; commit pending input on transitions; honor quoted display names |
| Editor bridge | SwiftUI updates could leave stale bindings or invalid selection ranges | Refresh the coordinator and clamp selection; native editing menus remain installed |
| HTML reader | Fixed height limits clipped long messages; dynamic quoted content did not reliably resize | Isolated host-script height observation, uncapped document height, and wrapping fixes |
| Remote content | Allowance could persist across changes in rendered content | Reapply blocking when permission is revoked; message JavaScript stays disabled |
| Notifications | Historical mail/account switching could generate misleading new alerts; reply could send without review | Time/unread filtering, all-account polling while composing, and Reply opens a draft |
| Settings | Account lifecycle and profile maintenance were incomplete | Separate General, Accounts, Signature, Outbox, and Advanced sections; native add/edit/remove flows; orphan profile visibility; default sender control; confirmed removal with pending-delivery guards |
| Credentials | A replacement profile key could overwrite the working key before validation | Validate candidate credentials before persistence; label testing of the saved key distinctly |
| Signature editing | Navigation and asynchronous loading could discard edits | Dedicated save/cancel sheet, dirty-close confirmation, visible errors, and loading guards |
| Account persistence | Re-adding an account erased omitted identity fields; removal/default changes were not transactional | Preserve omitted fields, transactionally remove dependent local rows, block unfinished Outbox removal, and deterministically replace the default |
| Forwarding | A failed attachment download could silently omit the file | Show download progress, prevent early send/navigation, retain failed attachments visibly, and wait for downloads on quit |
| Email links | `mailto:` links were not handled by the client | Register a handler and open a reviewable draft with recipient/subject/body fields; ignore sender and local-file attachment instructions |
| Small UI details | Archived actions, sender labels, stale star state, focus rings, and error dismissals were inconsistent | Move to Inbox action, sent-recipient labels, synchronized local flags, explicit accessibility labels, and corrected focus/error behavior |
| Packaging | A stale helper could satisfy an incomplete contract check | Require the new draft flags and run smoke checks against a temporary database |

## Verification

Automated tests cover legacy/current draft decoding, empty-field clearing, metadata preservation, repeated attachment snapshots, failed-copy and failed-database rollback, cursor ordering, send identity boundaries, stale account/search results, daylight-saving scheduling, complete Undo Send restoration, and actual timer-triggered delivery through an isolated fake CLI.

`scripts/verify.sh` builds the app and tests the exact embedded email-cli against a temporary database. `scripts/prepare-ui-fixture.py` produces a separate offline QA app and mailbox; it never uses the user's real database and blocks mail delivery and remote sync.

Validation results:

- 49 Swift tests across eight suites passed, including five mailto parsing cases and 21 client workflow regressions.
- 65 Rust tests passed, including account/default rollback, local CRUD, draft snapshots, metadata, pagination, and request identity.
- All 16 build and embedded-helper checks in `scripts/verify.sh` passed with email-cli 0.7.6. Account edit/removal and profile removal ran against a temporary database.
- A separate visual reviewer inspected the 960 × 632 full window, compact popover, and compose pane. Native New Message and Settings menu actions were exercised. Row metadata, compact contrast, the Expand control, and folder navigation were refined after inspection.
- A synthetic `mailto:` populated recipient, subject, and body. Those values appeared intact in the full and compact compose views and were confirmed in the isolated saved-draft database. No real mail was sent.
- Visual round-trip testing found and fixed an AppKit frame shrink on remount. The final full → compact → full capture retained 960 × 580 dimensions and complete draft fields; Settings tabs and all General controls also passed the final layout check.
- Mouse/keyboard automation could not reliably focus SwiftUI controls in this environment. End-to-end typing, keyboard selection, and account CRUD dialogs therefore remain manual acceptance checks; they are not claimed as completed UI tests. Their state/CLI boundaries have automated coverage.

The v0.7.6 backend release publishes Apple Silicon and Intel archives with checksums. Client signing, notarization, and installed-bundle verification are tracked separately from these test results.

## Second pass — 0.8.1

The second pass reread the compact inbox, full-window navigation, settings, compose/editor bridge, reader/WebKit implementation, attachment operations, and their state and CLI contracts. Independent agents inventoried rendering and compose/navigation paths, implemented specified backend fixes and regression tests, and reviewed native captures. Layout and product decisions remained with the lead review.

The comparison focused on [Geary's conversation-oriented interface](https://wiki.gnome.org/Apps/Geary), [Mailspring's desktop mail features](https://github.com/Foundry376/Mailspring), and [Thunderbird's attachment preview/save workflow](https://support.mozilla.org/en-US/kb/how-use-attachments). The resulting split keeps triage and quick replies in the menu bar; the full window owns persistent mailbox navigation, richer composition controls, and account/settings work.

| Area | Change |
|---|---|
| Mini inbox | One compact header with mailbox/account choice, search, compose, expand, and overflow. Search appears on demand. Removed redundant toolbar, row avatars, and permanently reserved hover-action space. Improved date and preview contrast. |
| Full window | Unified-account rows identify the mailbox. Settings and account management use the full window instead of squeezing into the reader column; section links now open the requested section. Persistent navigation compacts to icons, preserving accounts, all folders, Outbox, and Settings. The leading sidebar toggle stays fixed across both modes and Settings. |
| Reader hierarchy | Subject appears once. Sender details disclose full addresses, recipients, date, and account. Conversation history and multiple attachments start collapsed, leaving the message body visible at the minimum window size. |
| Attachments | Native Quick Look, Save As, Save All, progress, and visible retry/error states. Save All reserves unique filenames without overwriting unrelated files and quit waits for the complete batch. |
| Attachment cache | Exported files are copies of a canonical private cache. Editing or deleting an exported file no longer corrupts subsequent downloads. Legacy cache paths migrate when used, and missing pointers repair themselves. |
| Embedded images | Preserve provider content IDs/disposition in the CLI's existing raw metadata. Resolve supported CID bitmap images locally, separately from remote-image consent. Preview budget is 25 MB per message; unavailable assets remain accessible through attachment actions. [Resend's attachment contract](https://resend.com/docs/api-reference/emails/retrieve-received-email-attachment) documents these fields. |
| HTML privacy and fidelity | Validated the actual WebKit content-blocking rule list; remote requests stay blocked until opted in. Preserve paired sender foreground/background colors, collapse quoted blocks through the DOM, and allow horizontal access to wide tables. |
| Long-message hosting | A clipped native host keeps WebKit geometry within the reader while document height follows content changes. Early inactive-window captures were inconclusive; raised native-window and compact captures passed with the long body, paired banner colors, inline CID image, and wide table visible. |
| Compose | Compact formatting is disclosed on demand; full-window formatting stays visible. Sender changes and compose generations reset local field visibility correctly. Save & Close retains failed drafts. One send-review dialog includes every detected warning. |
| Rich text | Preserve fonts, colors, alignment, strikethrough, and links in HTML export, normalize adaptive text color for a light email canvas, and apply list markers to each selected paragraph without destroying formatting. |

New regression coverage includes current and legacy attachment metadata, percent-encoded CID matching, multiple and missing CID references, actual WebKit rule compilation, remote-resource detection, safe filenames and duplicate export names, quit/export batch lifetime, rich HTML serialization, and attributed list edits.

### Sidebar and native interaction review

The follow-up research used [Apple's macOS design guidance](https://developer.apple.com/videos/play/wwdc2019/809/) on stable toolbar actions and sidebar selection, [Apple's toolbar guidance](https://developer.apple.com/design/human-interface-guidelines/toolbars), [Thunderbird's collapsed-navigation discussion](https://bugzilla.mozilla.org/show_bug.cgi?id=1665511), and [Mailspring user feedback about discovering sidebar controls](https://community.getmailspring.com/t/hide-show-contact-sidebar/296). These sources support persistent navigation, a stable leading toggle, and identifiable actions; the particular icon-rail layout is Minimail's design decision.

Native captures reproduced the old toggle moving from x227 to x919 as the sidebar disappeared. The replacement keeps its center at x104 in both states. Compaction preserves the account menu, seven mailbox destinations, Outbox, and Settings, and gives the reader more width. Labels, help text, selection state, the View menu, and Control-Command-S expose the behavior. Settings retains the same navigation and toolbar; its duplicate content heading was removed and replacement API keys now have an explicit label.

Final native checks passed for the expanded and compact sidebars, account-manager navigation, Settings, the compact inbox, HTML reading, rich compose, and full-to-compact draft preservation. Native Quick Look displayed the fixture attachment. Save All exported byte-identical copies while preserving pre-existing files and choosing numbered names. All 72 Swift tests across 11 suites and all 16 build/embedded-helper checks passed with email-cli 0.7.7; the CLI's 71 Rust tests passed separately.

Final release checks and native acceptance results are recorded in [the 0.8.1 receipt](release/0.8.1.md).

## Remaining product scope

- This remains a Resend/domain mailbox client. IMAP, Gmail/Outlook OAuth, server folders, spam classification, and server Trash require additional backend work.
- Delete is permanent in the local mailbox and has a confirmation. It is not presented as a recoverable Trash operation.
- GUI search is full-text across the local account/mailbox, capped at 500 results. Structured search operators are not implemented.
- Scheduled drafts retain their time, but provider-side cancellation after submission is not exposed in the GUI.
- Draft attachment replacement is transactional within one CLI invocation. Separate processes editing the same draft simultaneously do not yet have revision conflict detection.
- Real email delivery is not part of UI QA; fixture delivery is deliberately blocked. Automated delivery-state tests use a fake executable.
