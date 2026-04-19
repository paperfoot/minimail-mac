#!/usr/bin/env bash
# Cuts a Minimail release: builds the signed .app with embedded email-cli,
# wraps it in a DMG, tags git, creates a GitHub release with the DMG asset.
# Usage: ./scripts/release.sh 0.1.9
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

# ── Build the signed .app with the bundled helper ─────────────────────
./scripts/build-app.sh release

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

# ── Git tag + GH release ──────────────────────────────────────────────
if ! git diff --quiet || ! git diff --cached --quiet; then
    echo "✗ working tree dirty — commit before tagging" >&2
    exit 1
fi

if git rev-parse "${TAG}" >/dev/null 2>&1; then
    echo "⚠ tag ${TAG} already exists — skipping re-tag"
else
    git tag "${TAG}"
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
    echo "The email-cli engine is bundled inside Minimail.app — no separate install needed."
} > "${BODY_FILE}"

gh release create "${TAG}" "${DMG_PATH}" \
    --repo paperfoot/minimail-mac \
    --title "Minimail ${VERSION}" \
    --notes-file "${BODY_FILE}" \
    --latest

rm -f "${BODY_FILE}"
echo "✓ released ${TAG}"
