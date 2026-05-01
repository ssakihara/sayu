#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="Sayu"
BUNDLE_ID="${SAYU_BUNDLE_ID:-dev.ssakihara.Sayu}"
DEPLOYMENT_TARGET="13.0"
BUILD_DIR="build"
APP="${BUILD_DIR}/${APP_NAME}.app"
ICON_SOURCE="${BUILD_DIR}/icon-source.png"
ICONSET_DIR="${BUILD_DIR}/AppIcon.iconset"
ICNS="${BUILD_DIR}/AppIcon.icns"

mkdir -p "${BUILD_DIR}"
rm -rf "${APP}"
mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources"

# --- SF Symbol "globe" からアイコン用 PNG を生成 ---
echo "==> Generating icon source from SF Symbol (globe)"
swift tools/generate-icon.swift "${ICON_SOURCE}"

# --- AppIcon.icns を icon.png から生成 ---
if [[ -f "${ICON_SOURCE}" ]]; then
    echo "==> Generating AppIcon.icns from ${ICON_SOURCE}"
    rm -rf "${ICONSET_DIR}"
    mkdir -p "${ICONSET_DIR}"

    sips -z 16 16     "${ICON_SOURCE}" --out "${ICONSET_DIR}/icon_16x16.png"      >/dev/null
    sips -z 32 32     "${ICON_SOURCE}" --out "${ICONSET_DIR}/icon_16x16@2x.png"   >/dev/null
    sips -z 32 32     "${ICON_SOURCE}" --out "${ICONSET_DIR}/icon_32x32.png"      >/dev/null
    sips -z 64 64     "${ICON_SOURCE}" --out "${ICONSET_DIR}/icon_32x32@2x.png"   >/dev/null
    sips -z 128 128   "${ICON_SOURCE}" --out "${ICONSET_DIR}/icon_128x128.png"    >/dev/null
    sips -z 256 256   "${ICON_SOURCE}" --out "${ICONSET_DIR}/icon_128x128@2x.png" >/dev/null
    sips -z 256 256   "${ICON_SOURCE}" --out "${ICONSET_DIR}/icon_256x256.png"    >/dev/null
    sips -z 512 512   "${ICON_SOURCE}" --out "${ICONSET_DIR}/icon_256x256@2x.png" >/dev/null
    sips -z 512 512   "${ICON_SOURCE}" --out "${ICONSET_DIR}/icon_512x512.png"    >/dev/null
    sips -z 1024 1024 "${ICON_SOURCE}" --out "${ICONSET_DIR}/icon_512x512@2x.png" >/dev/null

    iconutil -c icns -o "${ICNS}" "${ICONSET_DIR}"
    cp "${ICNS}" "${APP}/Contents/Resources/AppIcon.icns"
else
    echo "==> ${ICON_SOURCE} not found, skipping icon generation"
fi

echo "==> Building Sayu (arm64)"
swiftc -O \
    -target "arm64-apple-macos${DEPLOYMENT_TARGET}" \
    -o "${APP}/Contents/MacOS/${APP_NAME}" \
    Sources/Sayu/*.swift

# Info.plist のプレースホルダを実値に置換して配置
cp Resources/Info.plist "${APP}/Contents/Info.plist"
/usr/libexec/PlistBuddy \
    -c "Set :CFBundleExecutable ${APP_NAME}" \
    -c "Set :CFBundleIdentifier ${BUNDLE_ID}" \
    "${APP}/Contents/Info.plist"

# アドホック署名（ローカル実行に必要）
codesign --force --sign - \
    --entitlements Resources/Sayu.entitlements \
    "${APP}"

echo "==> Built: ${APP}"

if [[ "${INSTALL:-0}" == "1" ]]; then
    DEST="/Applications/${APP_NAME}.app"
    [[ -d "${DEST}" ]] && rm -rf "${DEST}"
    cp -R "${APP}" "${DEST}"
    echo "==> Installed: ${DEST}"
fi

if [[ "${DMG:-0}" == "1" ]]; then
    echo "==> Creating DMG"
    DMG_PATH="${BUILD_DIR}/${APP_NAME}.dmg"
    STAGE="${BUILD_DIR}/dmg-stage"
    rm -rf "${STAGE}" "${DMG_PATH}"
    mkdir -p "${STAGE}"
    cp -R "${APP}" "${STAGE}/"
    ln -s /Applications "${STAGE}/Applications"

    hdiutil create -volname "${APP_NAME}" \
        -srcfolder "${STAGE}" \
        -ov -format UDZO \
        "${DMG_PATH}"

    rm -rf "${STAGE}"
    echo "==> Built: ${DMG_PATH}"
fi
