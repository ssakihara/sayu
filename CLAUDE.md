# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## プロジェクト概要

Sayu は左右⌘の単独押しを検知して英数/かな（JIS）に切り替える macOS メニューバーアプリ。
SwiftPM ＋自作 Command Plugin（`Plugins/BundleAppCommand`）で `.app` を組み立てる。Xcode プロジェクトは使わない（必要なら README 記載の手順で手動生成）。

- Swift Tools 5.9 / ターゲット macOS 13.0+ / arm64
- `CGEventTap` の `flagsChanged` で押下時間からの単独押しを判定
- 配布形態は `build/Sayu.dmg`（リポジトリ同梱、ad-hoc 署名）

## ビルド・実行コマンド

非標準なフラグが多いので、以下のコマンドをそのまま使うこと。`--allow-writing-to-package-directory` を省略すると SwiftPM plugin の sandbox により失敗する。

| 用途 | コマンド |
|---|---|
| バイナリビルド | `swift build -c release --arch arm64` |
| `.app` バンドル | `swift package --allow-writing-to-package-directory bundle-app` |
| `/Applications` へインストール | `swift build -c release --arch arm64 && swift package --allow-writing-to-package-directory --allow-writing-to-directory /Applications bundle-app --install` |
| DMG 生成 | プラグイン外で `hdiutil` を直接使う（README 参照）。plugin sandbox では device access 不可 |
| Lint | `swift package plugin --allow-writing-to-package-directory swiftlint lint Sources/` |
| Format（適用） | `swift package plugin --allow-writing-to-package-directory swiftformat Sources/` |
| Format（チェックのみ） | `swift package plugin --allow-writing-to-package-directory swiftformat --lint Sources/` |
| ログ確認 | `log stream --predicate 'process == "Sayu"' --info` |

テストターゲット（XCTest）は未整備。`swift test` は通らない。検証はビルド成否と lint/format で行うこと。

## 動作確認の境界

- Claude が行う: `swift build` の成否確認、SwiftLint / SwiftFormat の実行
- ユーザーが行う: `bundle-app --install` での `.app` 差し替え、アクセシビリティ権限の再付与、`pkill Sayu && open /Applications/Sayu.app` による起動確認

アクセシビリティ権限はバンドルパス + 署名 ID で識別されるため `.app` を入れ替えると外れることがある。Claude 側で勝手に install / 起動まで進めないこと。

## macOS 固有の注意点

- **App Sandbox は無効**（`Resources/Sayu.entitlements`）。Mac App Store には出せない。`CGEventTap` を使うため必須の構成。
- **LSUIElement = YES**: Dock に出ないメニューバー常駐。`NSApplication.setActivationPolicy(.accessory)` を `AppDelegate` で明示。
- **合成 Cmd イベントの除外**: `Sources/Sayu/KeyRemapper.swift` の `minimumAlonePressDuration`（20ms）と `commandFlickerWindow`（50ms）は Raycast 等の合成イベントによる誤発火対策。閾値を変更する場合は影響範囲を必ず説明すること。
- **`bundle-app` プラグインの制約**: sandbox 内で `swift build` の再帰呼び出し不可・`hdiutil` のデバイス操作不可。DMG は plugin 外でしか作れない。

## コーディング規約

- SwiftFormat / SwiftLint のデフォルトに従う（プロジェクト独自の `.swiftformat` `.swiftlint.yml` は置かない）
- AppKit 直書き（Storyboard / XIB は使わない）
- `Settings` のキャッシュは `CGEventTap` コールバックからも読まれるため、必ず `NSLock` でガードする

## Git 運用

- **コミットメッセージは日本語**。`feat:` `fix:` などの Conventional Commits プレフィックス + 日本語サマリ（`git log` 参照）。
- **`build/Sayu.dmg` はリリース対象の変更（バージョン更新・ユーザーから見える挙動変更）が入ったときに再生成してコミットに含める**。内部リファクタのみの場合は再生成不要。
- DMG 再生成は README 記載の `hdiutil` 手順をそのまま実行する。
