#!/usr/bin/env bash
# Builds the Swift executable and wraps it in a proper .app bundle.
set -euo pipefail

cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
APP_NAME="Minimail"
BUNDLE_ID="ai.paperfoot.minimail"
APP_DIR=".build/${APP_NAME}.app"

echo "▸ swift build -c ${CONFIG}"
swift build -c "${CONFIG}"

BIN=".build/${CONFIG}/${APP_NAME}"
if [ ! -f "${BIN}" ]; then
    echo "✗ build output missing: ${BIN}" >&2
    exit 1
fi

echo "▸ packaging ${APP_DIR}"
rm -rf "${APP_DIR}"
mkdir -p "${APP_DIR}/Contents/MacOS"
mkdir -p "${APP_DIR}/Contents/Resources"
cp "${BIN}" "${APP_DIR}/Contents/MacOS/${APP_NAME}"
cp Resources/Info.plist "${APP_DIR}/Contents/Info.plist"

# Copy any Swift Package resources bundle if it exists
BUNDLE_RES="$(find .build -name "${APP_NAME}_${APP_NAME}.bundle" -maxdepth 6 2>/dev/null | head -1 || true)"
if [ -n "${BUNDLE_RES}" ] && [ -d "${BUNDLE_RES}" ]; then
    cp -R "${BUNDLE_RES}" "${APP_DIR}/Contents/Resources/"
fi

echo "▸ ad-hoc codesigning"
codesign --force --deep --sign - "${APP_DIR}"

echo "✓ built ${APP_DIR}"
