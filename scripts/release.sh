#!/usr/bin/env bash
# Cuts a Minimail release: builds a Developer-ID-signed .app with embedded
# email-cli, notarizes + staples the .app, wraps it in a DMG, notarizes +
# staples the DMG (so offline first-launch works), tags git, and creates
# a GitHub release with the DMG asset.
#
# Usage: ./scripts/release.sh 0.1.9
#
# Required environment:
#   SIGNING_IDENTITY   e.g. "Developer ID Application: SUPER SIMPLE LEARNING LTD (S25N6MXJCF)"
#                      (defaults to the SSLL team cert)
#   NOTARY_PROFILE     keychain profile name for notarytool (default: "minimail-notary")
#
# One-time setup (before first release):
#   1. Install Developer ID Application cert into login keychain
#      (via ~/Keys/apple-developer-id/ + `security import`).
#   2. Generate an app-specific password at https://appleid.apple.com
#      (Sign-In and Security → App-Specific Passwords → "Minimail notarize").
#   3. Store it in the keychain — omit --password so notarytool prompts
#      securely (keeps the app-specific password out of shell history):
#        xcrun notarytool store-credentials minimail-notary \
#            --apple-id "<your-apple-id-email>" \
#            --team-id "S25N6MXJCF"
#      The profile "minimail-notary" then works without further auth.
#
# Optional env:
#   NOTARIZE=0         skip notarization + stapling (local test builds).
#                      Implies SKIP_GH=1 — a non-notarized DMG is useless
#                      to end users, so the script refuses to publish it.
#   SKIP_GH=1          skip git tag + GitHub release (build-only).

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
APP_ZIP=".build/${APP_NAME}-${VERSION}.zip"
DMG_NAME="Minimail-${VERSION}.dmg"
DMG_PATH=".build/${DMG_NAME}"
TEAM_ID="S25N6MXJCF"
GH_REPO="paperfoot/minimail-mac"

: "${SIGNING_IDENTITY:=Developer ID Application: SUPER SIMPLE LEARNING LTD (${TEAM_ID})}"
: "${NOTARY_PROFILE:=minimail-notary}"
: "${NOTARIZE:=1}"
: "${SKIP_GH:=0}"

# ── Enforce NOTARIZE ⇒ SKIP_GH implication ────────────────────────────
# A non-notarized DMG fails Gatekeeper on every end-user Mac, so never
# publish one to a public release. Only permit NOTARIZE=0 with SKIP_GH=1.
if [ "${NOTARIZE}" != "1" ] && [ "${SKIP_GH}" != "1" ]; then
    echo "✗ NOTARIZE=${NOTARIZE} requires SKIP_GH=1." >&2
    echo "  A non-notarized DMG would fail Gatekeeper for every user." >&2
    echo "  To build a local test without notarization + GitHub release, run:" >&2
    echo "    NOTARIZE=0 SKIP_GH=1 $0 ${VERSION}" >&2
    exit 1
fi

# ── Pre-flight ────────────────────────────────────────────────────────
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
        echo "  Run once (omit --password to prompt securely):" >&2
        echo "    xcrun notarytool store-credentials ${NOTARY_PROFILE} \\" >&2
        echo "        --apple-id \"<your-apple-id>\" \\" >&2
        echo "        --team-id \"${TEAM_ID}\"" >&2
        echo "  Get the app-specific password from https://appleid.apple.com" >&2
        echo "  (Sign-In and Security → App-Specific Passwords)" >&2
        exit 1
    fi
    echo "   notarytool profile OK"
fi

# ── Remote-tag + existing-release guard (fail fast) ───────────────────
# Prevents re-publishing an existing version by accident. Doing this
# before the build saves 5+ minutes on the retry.
if [ "${SKIP_GH}" != "1" ]; then
    if git ls-remote --exit-code --tags origin "${TAG}" >/dev/null 2>&1; then
        echo "✗ tag ${TAG} already exists on origin." >&2
        echo "  Bump the version, or: git push --delete origin ${TAG}" >&2
        exit 1
    fi
    if gh release view "${TAG}" --repo "${GH_REPO}" >/dev/null 2>&1; then
        echo "✗ release ${TAG} already exists on GitHub." >&2
        echo "  Bump the version, or: gh release delete ${TAG} --repo ${GH_REPO}" >&2
        exit 1
    fi
    echo "   no prior tag or release at ${TAG}"
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
# Helper lives in Contents/MacOS/ per Apple's Bundle Programming Guide.
if [ ! -f "${APP_DIR}/Contents/MacOS/email-cli" ]; then
    echo "✗ refusing to release: email-cli not embedded in .app" >&2
    echo "  build ../email-cli with 'cargo build --release' first" >&2
    exit 1
fi

# ── Notarize helper (used twice: once for .app.zip, once for DMG) ─────
# notarytool's default text output prints "id: <uuid>" and "status: <text>"
# lines. We parse those verbatim because the format has been stable since
# Xcode 13 and we don't want a JSON-parser dependency in bash.
notarize_or_die() {
    local target="$1"
    local kind="$2"
    local submit_log
    submit_log=$(mktemp -t minimail-notary.XXXXXX)

    echo "▸ submitting ${kind} to Apple notary service (may take 1–5 min)…"
    if ! xcrun notarytool submit "${target}" \
            --keychain-profile "${NOTARY_PROFILE}" \
            --wait 2>&1 | tee "${submit_log}"; then
        echo "✗ notarytool submit failed for ${kind}" >&2
        rm -f "${submit_log}"
        exit 1
    fi

    local id status
    id=$(grep -E '^[[:space:]]*id:' "${submit_log}" | tail -1 | awk '{print $NF}')
    status=$(grep -E '^[[:space:]]*status:' "${submit_log}" | tail -1 | awk '{print $NF}')
    rm -f "${submit_log}"

    if [ -z "${id}" ] || [ -z "${status}" ]; then
        echo "✗ could not parse notarytool output (id='${id}' status='${status}')" >&2
        exit 1
    fi

    if [ "${status}" != "Accepted" ]; then
        echo "✗ ${kind} notarization: ${status}" >&2
        echo "  Log:" >&2
        xcrun notarytool log "${id}" --keychain-profile "${NOTARY_PROFILE}" >&2 || true
        exit 1
    fi

    echo "   ✓ ${kind} notarized (submission ${id})"
    # Even on Accepted, surface warnings from the log so we don't miss
    # deprecation advice or implicit problems that won't fail today but
    # will eventually.
    local log_file
    log_file=$(mktemp -t minimail-notary-log.XXXXXX)
    if xcrun notarytool log "${id}" --keychain-profile "${NOTARY_PROFILE}" > "${log_file}" 2>/dev/null; then
        # issues[] is empty on a clean notarization; if present, print a digest.
        if grep -q '"issues"' "${log_file}" && ! grep -q '"issues" *: *\[\]' "${log_file}"; then
            echo "   ⚠ notarization log has issues (first 20 lines):" >&2
            head -20 "${log_file}" >&2
        fi
    fi
    rm -f "${log_file}"
}

# ── Notarize + staple the .app first (enables offline first-launch) ──
# Flow per Apple's docs: submit a flat .zip of the .app, wait for Accepted,
# then staple the ticket to the original .app on disk. The stapled bundle
# can be mounted offline without the Gatekeeper online check.
if [ "${NOTARIZE}" = "1" ]; then
    echo "▸ zipping .app for notarization"
    rm -f "${APP_ZIP}"
    /usr/bin/ditto -c -k --keepParent "${APP_DIR}" "${APP_ZIP}"

    notarize_or_die "${APP_ZIP}" ".app"

    echo "▸ stapling .app"
    xcrun stapler staple "${APP_DIR}"

    echo "▸ validating stapled .app with stapler"
    xcrun stapler validate "${APP_DIR}"

    echo "▸ spctl assessment on stapled .app (execute context)"
    spctl --assess --type execute --verbose=2 "${APP_DIR}"

    rm -f "${APP_ZIP}"
fi

# ── Build DMG (from the stapled .app when notarized) ──────────────────
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

# ── Sign DMG (Developer ID, timestamped) ──────────────────────────────
echo "▸ signing DMG"
codesign --force --timestamp --sign "${SIGNING_IDENTITY}" "${DMG_PATH}"
codesign --verify --verbose=2 "${DMG_PATH}"

# ── Notarize + staple DMG ─────────────────────────────────────────────
if [ "${NOTARIZE}" = "1" ]; then
    notarize_or_die "${DMG_PATH}" "DMG"

    echo "▸ stapling DMG"
    xcrun stapler staple "${DMG_PATH}"

    echo "▸ spctl assessment on DMG (open context)"
    spctl --assess --type open --context context:primary-signature --verbose=2 "${DMG_PATH}"
else
    echo "⚠ skipping notarization (NOTARIZE=0) — DMG will NOT pass Gatekeeper"
fi

# ── SKIP_GH=1 exit path ───────────────────────────────────────────────
if [ "${SKIP_GH}" = "1" ]; then
    # Warn if the version bump left the tree dirty so Boris doesn't carry
    # it into the next release by accident.
    if ! git diff --quiet -- "${PLIST}" 2>/dev/null \
       || ! git diff --cached --quiet -- "${PLIST}" 2>/dev/null; then
        echo "" >&2
        echo "⚠ ${PLIST} version bump is in the working tree (uncommitted)." >&2
        echo "  Discard with:   git checkout -- ${PLIST}" >&2
        echo "  Keep:           git add ${PLIST} && git commit" >&2
    fi
    echo "✓ built + signed ${DMG_PATH} (SKIP_GH=1, not releasing to GitHub)"
    exit 0
fi

# ── Dirty-tree check — staged AND unstaged, only Info.plist permitted ─
# `awk 'NF'` (print lines with fields) replaces `grep -v '^$'` here because
# grep exits 1 on no-match under set -euo pipefail, aborting clean-tree
# releases. awk exits 0 regardless of match count.
STAGED="$(git diff --cached --name-only)"
UNSTAGED="$(git diff --name-only)"
ALL_DIRTY="$(printf '%s\n%s\n' "${STAGED}" "${UNSTAGED}" | awk 'NF' | sort -u)"

if [ -n "${ALL_DIRTY}" ]; then
    if [ "${ALL_DIRTY}" = "${PLIST}" ]; then
        echo "▸ committing Info.plist version bump"
        git add "${PLIST}"
        git commit -m "release: v${VERSION}"
    else
        echo "✗ working tree dirty with unexpected files:" >&2
        echo "${ALL_DIRTY}" | sed 's/^/    /' >&2
        echo "  Commit, stash, or revert them before tagging." >&2
        exit 1
    fi
fi

# ── Tag (local + remote, idempotent across partial failures) ──────────
# Bind the tag to the exact HEAD we signed, and pass --target to gh so
# the release doesn't drift to whatever origin/HEAD is at release time.
COMMIT_SHA="$(git rev-parse HEAD)"
LOCAL_TAG_SHA="$(git rev-parse --verify "refs/tags/${TAG}" 2>/dev/null || true)"

if [ -z "${LOCAL_TAG_SHA}" ]; then
    git tag "${TAG}" "${COMMIT_SHA}"
elif [ "${LOCAL_TAG_SHA}" != "${COMMIT_SHA}" ]; then
    echo "✗ local tag ${TAG} points at ${LOCAL_TAG_SHA} but HEAD is ${COMMIT_SHA}" >&2
    echo "  Delete and recreate: git tag -d ${TAG} && $0 ${VERSION}" >&2
    exit 1
fi

# Push branch then tag. Branch push is a no-op when already up to date.
git push origin HEAD

# Re-query origin in case a parallel release landed between the pre-flight
# guard and now. If remote tag is absent, push; if present, confirm it
# points at our SHA (otherwise bail).
REMOTE_TAG_SHA="$(git ls-remote --tags origin "refs/tags/${TAG}" 2>/dev/null | awk '{print $1}' || true)"
if [ -z "${REMOTE_TAG_SHA}" ]; then
    git push origin "${TAG}"
elif [ "${REMOTE_TAG_SHA}" != "${COMMIT_SHA}" ]; then
    echo "✗ remote tag ${TAG} points at ${REMOTE_TAG_SHA} but we built ${COMMIT_SHA}" >&2
    exit 1
fi

# ── Release notes + gh release create ─────────────────────────────────
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
    echo "Signed + notarized by Apple; stapled for offline first-launch."
    echo "The email-cli engine is bundled inside Minimail.app — no separate install needed."
} > "${BODY_FILE}"

gh release create "${TAG}" "${DMG_PATH}" \
    --repo "${GH_REPO}" \
    --target "${COMMIT_SHA}" \
    --title "Minimail ${VERSION}" \
    --notes-file "${BODY_FILE}" \
    --latest

rm -f "${BODY_FILE}"
echo "✓ released ${TAG}"
