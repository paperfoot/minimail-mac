#!/usr/bin/env bash
# Builds Minimail and packages it as a proper .app bundle with the
# email-cli helper binary embedded in Contents/MacOS so the shipped
# app works without any external dependency. Helper placement matches
# Apple's Bundle Programming Guide — auxiliary executables live in
# Contents/MacOS alongside the main binary, never in Contents/Resources.
set -euo pipefail

cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
APP_NAME="Minimail"
APP_DIR=".build/${APP_NAME}.app"

# ── Compile Swift binary ───────────────────────────────────────────────
echo "▸ swift build -c ${CONFIG}"
swift build -c "${CONFIG}"

BIN=".build/${CONFIG}/${APP_NAME}"
if [ ! -f "${BIN}" ]; then
    echo "✗ build output missing: ${BIN}" >&2
    exit 1
fi

# ── Locate email-cli binary to embed ──────────────────────────────────
# Order: sibling release build > installed homebrew/cargo > bail.
EMAIL_CLI=""
for candidate in \
    "../email-cli/target/release/email-cli" \
    "/opt/homebrew/bin/email-cli" \
    "/usr/local/bin/email-cli" \
    "${HOME}/.cargo/bin/email-cli"; do
    if [ -x "${candidate}" ]; then
        EMAIL_CLI="${candidate}"
        break
    fi
done

if [ -z "${EMAIL_CLI}" ]; then
    echo "⚠ no email-cli binary found to embed — the shipped app will fall back to PATH"
fi

# ── Build the .app layout ─────────────────────────────────────────────
echo "▸ packaging ${APP_DIR}"
rm -rf "${APP_DIR}"
mkdir -p "${APP_DIR}/Contents/MacOS"
mkdir -p "${APP_DIR}/Contents/Resources"
cp "${BIN}" "${APP_DIR}/Contents/MacOS/${APP_NAME}"
cp Resources/Info.plist "${APP_DIR}/Contents/Info.plist"
if [ -f Resources/AppIcon.icns ]; then
    cp Resources/AppIcon.icns "${APP_DIR}/Contents/Resources/AppIcon.icns"
    echo "   embedded AppIcon.icns"
fi
if [ -n "${EMAIL_CLI}" ]; then
    cp "${EMAIL_CLI}" "${APP_DIR}/Contents/MacOS/email-cli"
    chmod +x "${APP_DIR}/Contents/MacOS/email-cli"
    echo "   embedded email-cli from ${EMAIL_CLI}"
fi

# ── Sign ──────────────────────────────────────────────────────────────
# SIGNING_IDENTITY (env): if set, full Developer ID signing with hardened
# runtime + entitlements (required for notarization). If unset, ad-hoc
# signing for local dev builds. Sign inner binaries before outer bundle —
# --deep is avoided because modern codesign prefers per-binary signing.
ENTITLEMENTS="Resources/Minimail.entitlements"
if [ -n "${SIGNING_IDENTITY:-}" ]; then
    echo "▸ codesigning with '${SIGNING_IDENTITY}' (hardened runtime)"
    if [ ! -f "${ENTITLEMENTS}" ]; then
        echo "✗ missing entitlements file: ${ENTITLEMENTS}" >&2
        exit 1
    fi
    if [ -f "${APP_DIR}/Contents/MacOS/email-cli" ]; then
        codesign --force --timestamp --options runtime \
            --entitlements "${ENTITLEMENTS}" \
            --sign "${SIGNING_IDENTITY}" \
            "${APP_DIR}/Contents/MacOS/email-cli"
    fi
    codesign --force --timestamp --options runtime \
        --entitlements "${ENTITLEMENTS}" \
        --sign "${SIGNING_IDENTITY}" \
        "${APP_DIR}"
    # Verify strict signature so we fail fast here instead of during notarization
    codesign --verify --strict --verbose=2 "${APP_DIR}"
else
    echo "▸ ad-hoc codesigning (dev build; set SIGNING_IDENTITY for Developer ID)"
    if [ -f "${APP_DIR}/Contents/MacOS/email-cli" ]; then
        codesign --force --sign - "${APP_DIR}/Contents/MacOS/email-cli"
    fi
    codesign --force --deep --sign - "${APP_DIR}"
fi

echo "✓ built ${APP_DIR}"
