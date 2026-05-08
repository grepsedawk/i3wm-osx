#!/usr/bin/env bash
# Build i3wm-osx and package it as a proper .app bundle so macOS TCC
# (Accessibility / Input Monitoring) can attribute permissions to it
# directly instead of to whatever terminal launched it.
set -euo pipefail

cd "$(dirname "$0")"

CONFIG="${CONFIG:-release}"
APP_NAME="i3wm-osx"
APP_DIR="build/${APP_NAME}.app"
MACOS_DIR="${APP_DIR}/Contents/MacOS"
RES_DIR="${APP_DIR}/Contents/Resources"

echo "==> swift build -c ${CONFIG}"
swift build -c "${CONFIG}"

BIN="$(swift build -c "${CONFIG}" --show-bin-path)/${APP_NAME}"
MSG_BIN="$(swift build -c "${CONFIG}" --show-bin-path)/i3-msg"
if [[ ! -x "${BIN}" ]]; then
    echo "build failed: ${BIN} not found" >&2
    exit 1
fi

echo "==> assembling ${APP_DIR}"
rm -rf "${APP_DIR}"
mkdir -p "${MACOS_DIR}" "${RES_DIR}"
cp "${BIN}" "${MACOS_DIR}/${APP_NAME}"
cp "${MSG_BIN}" "${MACOS_DIR}/i3-msg"
cp Resources/Info.plist "${APP_DIR}/Contents/Info.plist"
printf 'APPL????' > "${APP_DIR}/Contents/PkgInfo"

SIGN_ID="${SIGN_ID:-i3wm-osx-ci}"
# `-v` filters out self-signed identities (CSSMERR_TP_NOT_TRUSTED) but codesign
# itself accepts them just fine, so we look without the validity filter.
if security find-identity -p codesigning 2>/dev/null | grep -q "\"${SIGN_ID}\""; then
    echo "==> signing with identity: ${SIGN_ID} (stable cdhash → TCC grants persist)"
    codesign --force --deep --sign "${SIGN_ID}" --identifier "org.piechowski.i3wm-osx" "${APP_DIR}"
else
    echo "==> ad-hoc signing (no '${SIGN_ID}' identity found — run ./setup-signing.sh"
    echo "    to avoid TCC re-prompting on every rebuild)"
    codesign --force --deep --sign - --identifier "org.piechowski.i3wm-osx" "${APP_DIR}"
fi

echo
echo "Built: ${APP_DIR}"
echo
echo "Run with:    open ${APP_DIR}"
echo "Or:          ${MACOS_DIR}/${APP_NAME}"
echo
echo "Logs go to stderr when run from terminal; for 'open' use Console.app"
echo "or: log stream --predicate 'process == \"${APP_NAME}\"'"
echo
echo "First run: System Settings → Privacy & Security → Accessibility,"
echo "click +, choose ${APP_DIR}. Then quit & restart i3wm-osx."
echo "Same for Input Monitoring (needed for global hotkeys)."
