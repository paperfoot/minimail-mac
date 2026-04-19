#!/usr/bin/env bash
# Builds Minimail and packages it as a proper .app bundle with the
# email-cli helper binary embedded in Contents/Resources so the shipped
# app works without any external dependency.
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
if [ -n "${EMAIL_CLI}" ]; then
    cp "${EMAIL_CLI}" "${APP_DIR}/Contents/Resources/email-cli"
    chmod +x "${APP_DIR}/Contents/Resources/email-cli"
    echo "   embedded email-cli from ${EMAIL_CLI}"
fi

# ── Sign everything ad-hoc ────────────────────────────────────────────
echo "▸ ad-hoc codesigning"
if [ -f "${APP_DIR}/Contents/Resources/email-cli" ]; then
    codesign --force --sign - "${APP_DIR}/Contents/Resources/email-cli"
fi
codesign --force --deep --sign - "${APP_DIR}"

echo "✓ built ${APP_DIR}"
