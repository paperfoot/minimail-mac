# Privacy Policy

**Last updated: 2026-04-26**
**Effective from: TBD (first paid release)**

> This is a draft for review. Before the paid release it should be checked by counsel and hosted at a public URL (for example, `https://paperfoot.com/minimail/privacy`).

Minimail is a macOS email client published by **Paperfoot AI (SG) Pte. Ltd.** ("we", "us"). This policy explains what data the app handles, where it goes, and what choices you have.

## 1. The short version

- Minimail stores your mail locally on your Mac. We do not run a server and we do not see your messages.
- Outgoing and incoming email is handled by **Resend** (your own Resend account). Resend is your email provider, not us.
- **Local diagnostics are ON by default.** Minimail uses Apple's MetricKit to collect crash reports and performance metrics **on your Mac only**. The data is written to `~/Library/Application Support/Minimail/diagnostics/` and is never uploaded. You can turn this off any time in Settings → Diagnostics, or delete the folder directly.
- We do not include analytics, third-party tracking, or advertising SDKs.
- License activation (after the paid release) sends a license key and a machine identifier to our license server. Nothing else.

## 2. Data stored on your device

Minimail uses the bundled `email-cli` binary to maintain a local SQLite database at:

```
~/Library/Application Support/email-cli/email-cli.db
```

This database contains:

- Messages you have sent or received through Resend
- Drafts, attachments, read/unread state, stars, snoozes
- Account configuration (email addresses, display names, signatures)
- A Keychain sentinel for each profile. The Resend API key itself is stored in the macOS Keychain under the `ai.paperfoot.email-cli` service.

This data never leaves your Mac via Minimail. If you delete the app and the database directory, the data is gone.

## 3. Data we (and Resend) process

- **Outgoing email** — the message body, recipients, and attachments are sent to [Resend](https://resend.com) for delivery. Resend is a separate company with its own [Privacy Policy](https://resend.com/legal/privacy-policy) and [Data Processing Agreement](https://resend.com/legal/dpa).
- **Incoming email** — if you enable receiving on your Resend domain, messages arrive via Resend's webhooks and are stored locally.
- **License activation** (after paid release) — when you enter a license key, Minimail sends the key and a randomly generated device identifier to our license server so we can verify the key and count activations. We do not receive your email address, mail content, or Resend API keys through this channel.

## 4. Data we do not collect

- **We do not receive any diagnostics data.** MetricKit writes crash and performance payloads to a folder on your Mac; nothing is uploaded to us or any third party. If we ever add an opt-in upload to help us debug issues you report, it will ship as a separate, clearly labelled checkbox — not silently switched on.
- We do not embed third-party advertising, marketing, or tracking SDKs.
- We do not read or transmit your email bodies. The only components that see your email bodies are your Mac, your Resend account, and the normal recipients of the mail you send.

### What's in the MetricKit payloads

Apple's MetricKit delivers OS-aggregated data once per day. Typical fields include app launch time, memory usage, CPU time, disk I/O, network byte counts, battery usage, and anonymised crash traces with stack frames. The payloads **do not** contain: email content, contact lists, account names, API keys, recipient addresses, subject lines, attachment names, or any other identifiable content from inside the app. You can open any `.json` file in the diagnostics folder to see exactly what Apple handed to the app.

## 5. Retention

- Locally stored mail stays on your device until you delete it. There is no automatic retention period.
- License-activation records (key + device identifier + timestamps) are kept for as long as the license is active plus any period required for accounting and fraud prevention, then deleted.

## 6. Children

Minimail is not directed at children under 13 and should not be used by them.

## 7. International transfers

The license server, when introduced, will run in a jurisdiction we will disclose at launch. If you are in the EU/UK, any transfer will be governed by Standard Contractual Clauses or equivalent safeguards. Resend's own data transfer posture is covered by Resend's DPA.

## 8. Your rights

Depending on where you live, you may have rights under GDPR, CCPA, or similar laws — for example, access, correction, deletion, or portability. Because almost all of your data is on your own device, you can exercise most of these rights yourself by managing the local database. For rights that touch our license-server records, email `privacy@paperfoot.com`.

## 9. Security

- Outgoing / incoming mail is delivered over HTTPS to Resend.
- Resend API keys are stored in the macOS Keychain. The local SQLite database stores only a sentinel that tells the CLI to load the key from Keychain.
- The CLI engine (`email-cli`) is MIT-licensed and auditable, so you can inspect what the app sends where.

## 10. Changes

We will update this policy when the product changes. Material changes will be announced in the release notes and, if you have an active license, by email to the address on your license.

## 11. Contact

Paperfoot AI (SG) Pte. Ltd.
Email: `privacy@paperfoot.com`
