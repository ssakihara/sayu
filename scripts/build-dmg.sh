#!/usr/bin/env bash
# Sayu を Developer ID で署名し、公証済みの DMG を作る。
#
# 必須の環境変数:
#   TEAM_ID            Apple Developer の Team ID（10桁）
# 公証の認証（どちらか一方）:
#   NOTARY_PROFILE     `xcrun notarytool store-credentials` で保存したプロファイル名（ローカル向け）
#   NOTARY_KEY_PATH, NOTARY_KEY_ID, NOTARY_ISSUER_ID   App Store Connect API キー（CI 向け）
# 任意:
#   VERSION            設定すると CFBundleShortVersionString を上書きする（例: 0.2.0）
#   SAYU_BUNDLE_ID     Bundle ID を上書きする（既定: dev.ssakihara.Sayu）
#   SKIP_NOTARIZE=1    公証をスキップする（署名だけ確かめたいとき）
set -euo pipefail

cd "$(dirname "$0")/.."

: "${TEAM_ID:?TEAM_ID を設定してください}"

APP_NAME="Sayu"
APP_PATH="build/$APP_NAME.app"
BUILD_DIR="build/release"
DMG_STAGING="$BUILD_DIR/dmg"
ENTITLEMENTS="Resources/$APP_NAME.entitlements"

# 同じ Team ID の「Developer ID Application」証明書を SHA-1 で特定する。
# 名前の部分一致だと複数チームの証明書があるときに曖昧になるため。
SIGN_IDENTITY=$(security find-identity -v -p codesigning \
  | grep "Developer ID Application" \
  | grep "($TEAM_ID)" \
  | head -n 1 \
  | awk '{print $2}')
if [[ -z "$SIGN_IDENTITY" ]]; then
  echo "Team ID $TEAM_ID の Developer ID Application 証明書がキーチェーンに見つかりません" >&2
  exit 1
fi

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

echo "==> Build"
swift build -c release --arch arm64
swift package --allow-writing-to-package-directory bundle-app

if [[ -n "${VERSION:-}" ]]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP_PATH/Contents/Info.plist"
fi

echo "==> Sign"
# bundle-app の ad-hoc 署名を Developer ID + Hardened Runtime で上書きする（公証に必須）。
codesign --force --options runtime --timestamp \
  --entitlements "$ENTITLEMENTS" \
  --sign "$SIGN_IDENTITY" \
  "$APP_PATH"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"

APP_VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP_PATH/Contents/Info.plist")
DMG_PATH="$BUILD_DIR/$APP_NAME-$APP_VERSION.dmg"

echo "==> DMG"
mkdir -p "$DMG_STAGING"
cp -R "$APP_PATH" "$DMG_STAGING/"
ln -s /Applications "$DMG_STAGING/Applications"
hdiutil create \
  -volname "$APP_NAME" \
  -srcfolder "$DMG_STAGING" \
  -fs HFS+ \
  -format UDZO \
  -ov "$DMG_PATH"
rm -rf "$DMG_STAGING"
codesign --sign "$SIGN_IDENTITY" --timestamp "$DMG_PATH"

if [[ "${SKIP_NOTARIZE:-}" == "1" ]]; then
  echo "==> 公証をスキップしました: $DMG_PATH"
  exit 0
fi

echo "==> Notarize"
if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  notary_auth=(--keychain-profile "$NOTARY_PROFILE")
else
  : "${NOTARY_KEY_PATH:?NOTARY_PROFILE か NOTARY_KEY_PATH を設定してください}"
  : "${NOTARY_KEY_ID:?NOTARY_KEY_ID を設定してください}"
  : "${NOTARY_ISSUER_ID:?NOTARY_ISSUER_ID を設定してください}"
  notary_auth=(--key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID")
fi
xcrun notarytool submit "$DMG_PATH" "${notary_auth[@]}" --wait
xcrun stapler staple "$DMG_PATH"
spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG_PATH"

echo "==> 完了: $DMG_PATH"
echo "    sha256: $(shasum -a 256 "$DMG_PATH" | awk '{print $1}')"
