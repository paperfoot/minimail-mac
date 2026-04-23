#!/usr/bin/env bash
# Cuts a Minimail release: builds a Developer-ID-signed .app with embedded
# email-cli, wraps it in a DMG, notarizes + staples the DMG, tags git, and
# creates a GitHub release with the DMG asset.
#
# Usage: ./scripts/release.sh 0.1.9
#
# Required environment:
#   SIGNING_IDENTITY   e.g. "Developer ID Application: SUPER SIMPLE LEARNING LTD (S25N6MXJCF)"
#                      (defaults to the SSLL team cert if installed)
#   NOTARY_PROFILE     keychain profile name for notarytool (default: "minimail-notary")
#
# One-time setup (before first release):
#   1. Install Developer ID Application cert into login keychain
#      (done via ~/Keys/apple-developer-id/ + security import)
#   2. Generate an app-specific password at https://appleid.apple.com
#      (Sign-In and Security → App-Specific Passwords → "Minimail notarize")
#   3. Store it in keychain:
#        xcrun notarytool store-credentials minimail-notary \
#            --apple-id "<your-apple-id-email>" \
#            --team-id "S25N6MXJCF" \
#            --password "<app-specific-password>"
#      The profile "minimail-notary" then works without further auth.
#
# Optional env:
#   NOTARIZE=0         skip notarization + stapling (local test builds)
#   SKIP_GH=1          skip git tag + GitHub release (build-only)

set -euo pipefail

cd "$(dirname "$0")/.."

VERSION="${1:-}"
if [ -z "${VERSION}" ]; then
    echo "usage: $0 <version>   e.g. $0 0.1.9" >&2
    exit 1
fi

TAG="v${VERSION}"
APP_NAME="Minimail"
APP_DIR=".build/${APP_NAME}.app"
DMG_NAME="Minimail-${VERSION}.dmg"
DMG_PATH=".build/${DMG_NAME}"
TEAM_ID="S25N6MXJCF"

: "${SIGNING_IDENTITY:=Developer ID Application: SUPER SIMPLE LEARNING LTD (${TEAM_ID})}"
: "${NOTARY_PROFILE:=minimail-notary}"
: "${NOTARIZE:=1}"
: "${SKIP_GH:=0}"

# ── Pre-flight checks ─────────────────────────────────────────────────
echo "▸ pre-flight"
if ! security find-identity -v -p codesigning | grep -q "${SIGNING_IDENTITY}"; then
    echo "✗ signing identity not found in keychain:" >&2
    echo "    ${SIGNING_IDENTITY}" >&2
    echo "" >&2
    echo "  Installed identities:" >&2
    security find-identity -v -p codesigning >&2
    exit 1
fi
echo "   signing identity OK"

if [ "${NOTARIZE}" = "1" ]; then
    if ! xcrun notarytool history --keychain-profile "${NOTARY_PROFILE}" --output-format json >/dev/null 2>&1; then
        echo "✗ notarytool profile '${NOTARY_PROFILE}' is missing or invalid" >&2
        echo "  Run once to set it up:" >&2
        echo "    xcrun notarytool store-credentials ${NOTARY_PROFILE} \\" >&2
        echo "        --apple-id \"<your-apple-id>\" \\" >&2
        echo "        --team-id \"${TEAM_ID}\" \\" >&2
        echo "        --password \"<app-specific-password>\"" >&2
        echo "  Get the app-specific password from https://appleid.apple.com" >&2
        echo "  (Sign-In and Security → App-Specific Passwords)" >&2
        exit 1
    fi
    echo "   notarytool profile OK"
fi

# ── Bump Info.plist version ───────────────────────────────────────────
PLIST="Resources/Info.plist"
CURRENT_VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "${PLIST}")
if [ "${CURRENT_VERSION}" != "${VERSION}" ]; then
    echo "▸ bumping Info.plist: ${CURRENT_VERSION} → ${VERSION}"
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${VERSION}" "${PLIST}"
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${VERSION}" "${PLIST}"
fi

# ── Build + sign the .app with the bundled helper ─────────────────────
SIGNING_IDENTITY="${SIGNING_IDENTITY}" ./scripts/build-app.sh release

# Sanity — the embedded helper is what makes distribution work.
if [ ! -f "${APP_DIR}/Contents/Resources/email-cli" ]; then
    echo "✗ refusing to release: email-cli not embedded in .app" >&2
    echo "  build ../email-cli with 'cargo build --release' first" >&2
    exit 1
fi

# ── Build DMG ─────────────────────────────────────────────────────────
echo "▸ building DMG: ${DMG_PATH}"
rm -f "${DMG_PATH}"
STAGING="$(mktemp -d)"
trap 'rm -rf "${STAGING}"' EXIT
cp -R "${APP_DIR}" "${STAGING}/"
ln -s /Applications "${STAGING}/Applications"
hdiutil create \
    -volname "${APP_NAME} ${VERSION}" \
    -srcfolder "${STAGING}" \
    -ov \
    -format UDZO \
    -fs HFS+ \
    -imagekey zlib-level=9 \
    "${DMG_PATH}" >/dev/null
echo "✓ ${DMG_PATH}"

# ── Sign DMG ──────────────────────────────────────────────────────────
echo "▸ signing DMG"
codesign --force --timestamp --sign "${SIGNING_IDENTITY}" "${DMG_PATH}"
codesign --verify --verbose=2 "${DMG_PATH}"

# ── Notarize + staple ─────────────────────────────────────────────────
if [ "${NOTARIZE}" = "1" ]; then
    echo "▸ submitting to Apple notary service (may take 1–5 min)…"
    xcrun notarytool submit "${DMG_PATH}" \
        --keychain-profile "${NOTARY_PROFILE}" \
        --wait

    echo "▸ stapling notarization ticket"
    xcrun stapler staple "${DMG_PATH}"

    # Final Gatekeeper check from the user's perspective.
    echo "▸ spctl assessment"
    spctl --assess --type open --context context:primary-signature --verbose=2 "${DMG_PATH}"
else
    echo "⚠ skipping notarization (NOTARIZE=0) — DMG will NOT pass Gatekeeper"
fi

# ── Git tag + GH release ──────────────────────────────────────────────
if [ "${SKIP_GH}" = "1" ]; then
    echo "✓ built + signed ${DMG_PATH} (SKIP_GH=1, not releasing to GitHub)"
    exit 0
fi

if ! git diff --quiet || ! git diff --cached --quiet; then
    # Info.plist bump is expected; commit it so the tag points at clean tree.
    if git diff --name-only | grep -q "^Resources/Info.plist$" \
       && [ "$(git diff --name-only | wc -l | tr -d ' ')" = "1" ]; then
        echo "▸ committing Info.plist version bump"
        git add "${PLIST}"
        git commit -m "release: v${VERSION}"
    else
        echo "✗ working tree dirty — commit before tagging" >&2
        git status --short >&2
        exit 1
    fi
fi

if git rev-parse "${TAG}" >/dev/null 2>&1; then
    echo "⚠ tag ${TAG} already exists — skipping re-tag"
else
    git tag "${TAG}"
    git push origin HEAD
    git push origin "${TAG}"
fi

# Build the release body.
BODY_FILE="$(mktemp)"
{
    echo "## Minimail ${VERSION}"
    echo
    git log "$(git describe --tags --abbrev=0 "${TAG}^" 2>/dev/null || echo '')..${TAG}" \
        --pretty=format:"- %s" 2>/dev/null || true
    echo
    echo
    echo "### Install"
    echo
    echo "1. Download \`${DMG_NAME}\` below"
    echo "2. Open it, drag Minimail to Applications"
    echo "3. Launch — the envelope icon appears in your menu bar"
    echo
    echo "Signed + notarized by Apple; Gatekeeper will accept it on first launch."
    echo "The email-cli engine is bundled inside Minimail.app — no separate install needed."
} > "${BODY_FILE}"

gh release create "${TAG}" "${DMG_PATH}" \
    --repo paperfoot/minimail-mac \
    --title "Minimail ${VERSION}" \
    --notes-file "${BODY_FILE}" \
    --latest

rm -f "${BODY_FILE}"
echo "✓ released ${TAG}"
