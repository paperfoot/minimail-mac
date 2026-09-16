# Production Readiness

Last updated: 2026-09-16

## Current Verdict

Minimail is technically close to packageable as a notarized macOS app, but it
is not ready to sell as a commercial product until the paid-release items
below are closed.

## Ready

- The app bundles `email-cli` in `Contents/MacOS/email-cli`; users do not need
  a separate CLI install for the GUI.
- Settings can install or update the bundled CLI for Terminal and agents.
- First-run setup creates the Resend profile and account from inside the app.
- Settings can repair or rotate the Resend API key.
- API keys are stored in the macOS Keychain by `email-cli`.
- The release script builds, signs, notarizes, staples, creates a DMG, tags git,
  and publishes a GitHub release.
- The build script now builds the sibling `email-cli` release binary before
  embedding it and validates the expected CLI contract.
- The Developer ID identity for SUPER SIMPLE LEARNING LTD is configured;
  the 0.8.0 app and helper signatures were verified after local installation.

## Not Ready For Paid Public Release

- Restore the configured Apple notarization profile before publishing 0.8.0.
  The local signed build is installed, but public notarization/publication
  remain pending; see [the release record](0.8.0.md).
- Payment and license activation are still product/server work. The legal docs
  mention license activation, but the app does not enforce a paid license yet.
- Legal docs are drafts and still say counsel review is required.
- A public download/update channel and customer support path need to be
  confirmed before launch.

## Release Gate

Before shipping a DMG to users:

1. Run `swift test`.
2. Run `cargo test -- --test-threads=1` in `../email-cli`.
3. Run `cargo clippy --all-targets -- -D warnings -A clippy::collapsible_if`
   in `../email-cli`.
4. Run `./scripts/verify.sh`.
5. Run `APPLE_TEAM_ID=<team> SIGNING_IDENTITY="<Developer ID Application: ...>" ./scripts/release.sh <version>`.
6. Install the produced DMG on a clean user account and verify first launch,
   onboarding, Settings -> Command line tool, send, sync, outbox retry, and
   launch-at-login.
