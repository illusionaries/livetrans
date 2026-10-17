#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

CONFIG="${CONFIG:-release}"
APP_NAME="LiveTrans"
APP="build/${APP_NAME}.app"

echo "==> swift build -c ${CONFIG}"
swift build -c "${CONFIG}" --product "${APP_NAME}"
BIN_DIR="$(swift build -c "${CONFIG}" --show-bin-path)"

echo "==> assemble ${APP}"
rm -rf "${APP}"
mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources"
cp "${BIN_DIR}/${APP_NAME}" "${APP}/Contents/MacOS/${APP_NAME}"
cp "App/Info.plist" "${APP}/Contents/Info.plist"
printf 'APPL????' > "${APP}/Contents/PkgInfo"

# 本地化资源（en.lproj / zh-Hans.lproj）
cp -R "App/Resources/." "${APP}/Contents/Resources/"

# 优先用本机的 Apple Development 证书；没有就 ad-hoc 签名。
IDENTITY="${CODESIGN_IDENTITY:-}"
if [[ -z "${IDENTITY}" ]]; then
  IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
    | awk -F'"' '/Apple Development/ {print $2; exit}')"
fi
if [[ -z "${IDENTITY}" ]]; then
  IDENTITY="-"
fi

echo "==> codesign with: ${IDENTITY}"
codesign --force --deep --sign "${IDENTITY}" --identifier "blog.illusion.LiveTrans" "${APP}"

echo "==> done: ${APP}"
echo "    open ${APP}"
