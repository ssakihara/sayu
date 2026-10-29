# Sayu

macOS のメニューバー常駐アプリ。左右の Command キーの**単独押し**を検出して、JIS の英数 / かな（または任意のキー）を発火する。

- 左 ⌘ 単独押し → **英数**（既定）
- 右 ⌘ 単独押し → **かな**（既定）
- ⌘ + 他キー（⌘C 等）は通常通り動作（単独押しではないため抑止される）

## 機能

- 左右それぞれの発火キーを `英数 / かな / Esc / Tab / Return / 無効` から選択
- ログイン時の自動起動（`SMAppService.mainApp`）をメニューから切替
- 必要な権限（アクセシビリティ / 入力監視）のポーリング監視と、付与後の自動再起動
- 権限不足時はメニューバーに `!` を表示し、アラートから該当のシステム設定ペインを順に開いてユーザーをガイド
- メニューバーアイコンは SF Symbol "globe"（テンプレート画像なのでライト/ダークに自動追従）

## 判定ロジック

**押下時間の閾値判定は持たない**。

- modifier-down 時点の keyCode を保持
- modifier-up 時、保持していた keyCode と一致すれば「単独押し」として発火
- その間に他キー入力（keyDown / keyUp）・マウス操作・スクロールが一度でも発生したら保持中の keyCode を nil にして発火条件を破棄

つまり「Cmd-down から Cmd-up までの間に他の入力が一切無い」ことだけを条件に判定する。Cmd を押した時間がいくら長くても短くても、他の入力が混じれば発火しない。

## 必要要件

- macOS 13.0 以降
- Apple Silicon (arm64) ※ Plugin は arm64 専用ビルド
- Swift 5.9+ （Xcode または Xcode Command Line Tools に同梱）

## アーキテクチャ

```
sayu/
├── Sources/Sayu/                    # アプリ本体（AppKit, ServiceManagement, ApplicationServices, IOKit.hid）
│   ├── AppDelegate.swift            # @main, 起動シーケンス, 権限案内アラート, 再起動制御
│   ├── KeyRemapper.swift            # CGEventTap + NSEvent monitor で単独押し検出と発火
│   ├── StatusBarController.swift    # メニューバー UI（NSStatusItem + NSMenu）
│   ├── PreferencesWindowController.swift  # 環境設定ウィンドウ（AppKit 直書き）
│   ├── Settings.swift               # UserDefaults 永続化 + NSLock キャッシュ
│   ├── LoginItemManager.swift       # SMAppService.mainApp の登録/解除
│   ├── Permissions.swift            # アクセシビリティ / 入力監視権限のチェック・要求
│   └── PermissionWatcher.swift      # 両権限の付与状況をポーリングし、状態変化を通知
├── Resources/
│   ├── Info.plist                   # LSUIElement=YES で Dock 非表示
│   └── Sayu.entitlements            # com.apple.security.app-sandbox = false
├── tools/
│   └── generate-icon.swift          # SF Symbol → 1024x1024 PNG レンダリング
├── Plugins/
│   └── BundleAppCommand/Plugin.swift # `swift package bundle-app` コマンド本体
├── Package.swift                    # SwiftPM マニフェスト (本体ターゲット + Plugin + lint/format)
└── README.md
```

### モジュール責務

| ファイル | 責務 |
|---|---|
| `AppDelegate.swift` | プロセス起動・`StatusBarController` 構築・権限案内アラートとシステム設定ペインへの誘導・権限付与検知時の自動再起動 |
| `KeyRemapper.swift` | `cgSessionEventTap` で `flagsChanged` / `keyDown` / `keyUp` を購読、NSEvent global+local monitor でマウス・スクロール・キーも併監視。modifier-down 時の keyCode を保持し、その間に他イベントが一度でも発生したら nil リセット、一致した modifier-up でのみ発火 |
| `StatusBarController.swift` | `NSStatusItem` の生成、メニュー構築、ログイン項目トグル、再起動・終了アクションのディスパッチ |
| `PreferencesWindowController.swift` | NSPopUpButton で左右⌘の割り当てを編集。値変更は `Settings` に即時反映 |
| `Settings.swift` | `UserDefaults` 永続化。CGEvent タップは別スレッドから読むため、内部で `NSLock` 保護のキャッシュを保持 |
| `LoginItemManager.swift` | macOS 13+ の `SMAppService.mainApp.register() / unregister()` を薄くラップ |
| `Permissions.swift` | アクセシビリティ (`AXIsProcessTrustedWithOptions`) と入力監視 (`IOHIDCheckAccess` / `IOHIDRequestAccess`) のチェック・要求、システム設定ペインの URL オープン |
| `PermissionWatcher.swift` | macOS は権限付与の通知 API を持たないため両権限の状態を 1.5 秒間隔でポーリングし、状態変化のたびに購読者へ通知 |

### 単独押し判定の流れ（`KeyRemapper`）

1. `flagsChanged` で左右⌘の modifier-down を検出 → `lastModifierKeyCode` にその keyCode を保存
2. その間に届く任意の `keyDown` / `keyUp` / マウスイベント / 他 modifier 変化で `lastModifierKeyCode = nil`（発火条件を破棄）
3. 左右⌘の modifier-up を検出した時、`lastModifierKeyCode` が一致していれば `Settings.leftAssignment` / `rightAssignment` に応じた仮想キーコードを `CGEvent` で送出
4. `tapDisabledByTimeout` / `tapDisabledByUserInput` を受けたら自動で `tapEnable` し直す

押下時間の上限・下限は持たない。「Cmd-down から Cmd-up までの間に他の入力が一切無いか」だけを見る。CGEventTap で keyDown/keyUp が上位フックに消費される環境（Raycast 等）への保険として NSEvent global+local monitor 経由でも同じ条件を監視している。

合成イベント（`CGEventPost` 由来）は `eventSourceUnixProcessID != 0` で物理入力と区別し、合成 Cmd-down は単独押し検出の対象外にする。

仮想キーコード参考: `JIS Eisu = 0x66`, `JIS Kana = 0x68`, `Esc = 0x35`, `Tab = 0x30`, `Return = 0x24`

## ビルド

SwiftPM ネイティブの2段階構成。`swift build` で Sayu をコンパイルし、続けて
Command Plugin `bundle-app` で .app バンドル組立・アイコン生成・署名を行う。

```bash
# 1. Sayu をコンパイル → .build/arm64-apple-macosx/release/Sayu
swift build -c release --arch arm64

# 2. .app バンドル組立 → build/Sayu.app
swift package --allow-writing-to-package-directory bundle-app

# /Applications にインストール (フラグ追加が必要)
swift package \
    --allow-writing-to-package-directory \
    --allow-writing-to-directory /Applications \
    bundle-app --install

# Bundle ID 上書き（既定: dev.ssakihara.Sayu）
SAYU_BUNDLE_ID=dev.example.Sayu \
    swift package --allow-writing-to-package-directory bundle-app
```

> [!TIP]
> コマンドが長いので shell alias を設定すると便利:
>
> ```bash
> # ~/.zshrc 等に追記
> alias sayu-build='swift build -c release --arch arm64 \
>   && swift package --allow-writing-to-package-directory bundle-app'
> alias sayu-install='swift build -c release --arch arm64 \
>   && swift package \
>        --allow-writing-to-package-directory \
>        --allow-writing-to-directory /Applications \
>        bundle-app --install'
> ```

### 設計上の制約

- **`swift build` を Plugin から呼べない**: Plugin 実行中の swift-package が
  SwiftPM の build lock を握っているため再帰呼び出しがデッドロックする。
  したがって `swift build` を呼び出し側で先に実行する2段構成。
- **`/Applications` への書き込みは追加フラグが必要**: Plugin sandbox が
  パッケージ外への書き込みをデフォルトで拒否する。`--allow-writing-to-directory /Applications` を渡す。
- **DMG 生成は Plugin 不可**: hdiutil が sandbox 内で device アクセス
  できないため、Plugin から呼ぶと「装置が構成されていません」で失敗する。
  下記の DMG 節を参照して直接コマンドで生成する。

### DMG 生成

hdiutil は Plugin sandbox 内で動かないため、配布用 DMG は [リリース](#リリース) の `scripts/build-dmg.sh` で作る。

### Plugin の主な処理

1. `swift tools/generate-icon.swift build/icon-source.png` でアイコン PNG をレンダリング
2. `sips` でリサイズして `iconutil` から `AppIcon.icns` を生成
3. `.build/arm64-apple-macosx/release/Sayu` を `.app/Contents/MacOS/` にコピー
4. `PlistBuddy` で `Info.plist` のプレースホルダ（`$(EXECUTABLE_NAME)` / `$(PRODUCT_BUNDLE_IDENTIFIER)`）を実値に置換
5. アドホック署名（`codesign --force --sign -`）+ `Sayu.entitlements` を適用（配布用は `scripts/build-dmg.sh` が Developer ID で署名し直す）

## インストール

Homebrew でインストールできる:

```bash
brew install --cask ssakihara/tap/sayu
```

または [GitHub Releases](https://github.com/ssakihara/sayu/releases/latest) から `Sayu-<バージョン>.dmg` を取得し、`Sayu.app` を `Applications` にドラッグする。
DMG は Developer ID 署名 + 公証済みなので Gatekeeper の警告なしで起動できる。

自分でビルドする場合は [ビルド](#ビルド) を参照。

## 初回セットアップ

Sayu は左右⌘の単独押し検出に **2 種類の権限** が必要:

- **アクセシビリティ**: `CGEvent.post` での発火と `flagsChanged` の監視に必要
- **入力監視 (Input Monitoring)**: `CGEventTap` / `NSEvent.addGlobalMonitorForEvents` で `keyDown` / `keyUp` を取得するために必要（macOS Catalina 以降の OS 要件）

どちらか欠けると単独押し検出が正しく動かない（特に入力監視が無いと Cmd+V のような他キー併用が単独押しと誤判定されて切り替わってしまう）。

セットアップ手順:

1. `Sayu.app` を起動
2. 起動直後に「Sayu に必要な権限を許可してください」アラートが表示される
3. **「権限設定を開く」** を押すと、不足している権限のシステム設定ペインが順に開く
4. 各画面で **Sayu のトグルを ON** にする
   - アクセシビリティ → 入力監視 の順で自動的にバトンタッチされる
5. 両方とも ON にすると Sayu が自動で検知し、再起動アラート → 「再起動」 で完了
6. メニューバーに地球儀アイコンが表示されれば成功

権限が外れた場合（バイナリ差し替え時など）はメニューバーのアイコンに `!` が付く。メニューから **「必要な権限を許可…」** を選ぶと再度アラートが表示される。

ログイン時の自動起動はメニュー > **ログイン時に起動** で切替（`SMAppService.mainApp`）。
連携設定は **設定 > 一般 > ログイン項目** からも確認できる。

> [!NOTE]
> macOS のセキュリティモデル上、これらの権限はユーザーがシステム設定で手動でトグルを ON にするしかない（管理者パスワードを入れて自動付与する API は存在しない）。Sayu はアラートとペイン誘導を最小限の操作で完了できるよう自動化している。

## 開発フロー

```bash
# 編集
$EDITOR Sources/Sayu/KeyRemapper.swift

# 再ビルド + /Applications を更新
swift build -c release --arch arm64 \
  && swift package \
       --allow-writing-to-package-directory \
       --allow-writing-to-directory /Applications \
       bundle-app --install

# 既存プロセスを終了して再起動
pkill -x Sayu || true
open /Applications/Sayu.app
```

### Lint / Format

`Package.swift` で SwiftLint と SwiftFormat を SwiftPM Plugin として導入している。

```bash
# 依存解決（初回のみ）
swift package resolve

# Lint（SwiftLint 0.63+）
swift package plugin --allow-writing-to-package-directory swiftlint lint Sources/

# Lint 自動修正（autocorrect 可能なルールのみ）
swift package plugin --allow-writing-to-package-directory swiftlint --fix Sources/

# Format チェックのみ
swift package plugin --allow-writing-to-package-directory swiftformat --lint Sources/

# Format 適用
swift package plugin --allow-writing-to-package-directory swiftformat Sources/
```

ルールカスタマイズが必要なら `.swiftlint.yml` / `.swiftformat` をリポジトリ直下に配置する（未配置時はそれぞれのデフォルトルール）。

> [!NOTE]
> アクセシビリティ権限は **バンドルパス + 実行ファイルの署名識別子** で記録される。
> アドホック署名でも `/Applications/Sayu.app` を同じパスに上書きする限り権限は引き継がれる。
> パスを変える（`build/Sayu.app` を直接起動する等）と権限を付け直す必要がある。
> どうしても引き継げない場合は、設定の一覧から `Sayu` を削除して再追加すれば良い。

### Xcode で開発したい場合

`.xcodeproj` は同梱していない。必要なら以下の手順で作成する:

1. **File > New > Project... > macOS > App** で新規作成
2. 生成された `AppDelegate.swift` / `ViewController.swift` / `Main.storyboard` / `Assets.xcassets` を削除
3. `Sources/Sayu/` 配下の Swift ファイルを Target に追加
4. **General > Deployment Info** を macOS 13.0+ に
5. **Signing & Capabilities** で App Sandbox を OFF（または Capability ごと削除）
6. **Build Settings > Code Signing Entitlements** に `Resources/Sayu.entitlements` を指定
7. **Info.plist** を `Resources/Info.plist` に差し替え（最低 `LSUIElement = YES` が必要）

## トラブルシューティング

| 症状 | 対処 |
|---|---|
| メニューバーに何も出ない | `pkill -x Sayu` してから `open /Applications/Sayu.app` で再起動。アクセシビリティ・入力監視の両権限の付与状況を確認 |
| アイコンの右に `!` が表示される | アクセシビリティまたは入力監視の権限が未付与。メニュー > 「必要な権限を許可…」で再要求 |
| ⌘ + V のような他キー併用で勝手に英数/かなが切り替わる | **入力監視権限が未付与の典型症状**。`tccutil reset ListenEvent dev.ssakihara.Sayu` の後に Sayu を再起動し、アラートから入力監視を ON にする |
| ⌘ 単独押しで何も発火しない | 環境設定で割り当てが「無効」になっていないか / 入力監視権限が ON かを確認 |
| ⌘C / ⌘V が効かない | 通常時は素通し実装。別アプリ（Karabiner-Elements 等）の干渉を疑う |
| 設定を変えても反映されない | `Settings` は即時反映。フロントアプリ側のショートカットキャッシュが原因のことがあるので Sayu とフロントアプリを再起動 |
| ログイン項目に追加できない | システム設定 > 一般 > ログイン項目 から手動で追加 |

ログ確認:

```bash
# 一般的なログ（NSLog による警告など）
/usr/bin/log stream --predicate 'process == "Sayu"' --info

# Sayu の os_log カテゴリだけに絞る
/usr/bin/log stream --predicate 'subsystem == "io.github.ssakihara.sayu"' --style compact --info
```

`log` は zsh の builtin なので、`/usr/bin/log` を明示的に呼ぶ必要がある。

## 配布

- App Sandbox を必須とする Mac App Store 配布は**不可**（CGEventTap が App Sandbox 下では動かない）
- GitHub Releases に Developer ID 署名 + 公証済みの DMG を置き、[homebrew-tap](https://github.com/ssakihara/homebrew-tap) の Cask から配布する

## リリース

公証用の認証情報を一度だけキーチェーンに保存する（App 用パスワードは appleid.apple.com で発行）。

```bash
xcrun notarytool store-credentials sayu-notary --apple-id <Apple ID> --team-id <Team ID> --password <App 用パスワード>
```

「Developer ID Application」証明書がキーチェーンに入っている状態で実行する。

```bash
TEAM_ID=<Team ID> NOTARY_PROFILE=sayu-notary scripts/build-dmg.sh
```

`build/release/Sayu-<バージョン>.dmg` ができ、最後に sha256 が表示される。バージョンは `Resources/Info.plist` の `CFBundleShortVersionString`（`VERSION=0.2.0` で上書き可）。

1. `gh release create v<バージョン> build/release/Sayu-<バージョン>.dmg --generate-notes` で GitHub Releases に公開
2. homebrew-tap の `Casks/sayu.rb` の `version` と `sha256` を更新してコミット

> [!NOTE]
> Developer ID 署名に切り替えると署名識別子が変わるため、ad-hoc 署名版から乗り換えた初回はアクセシビリティ / 入力監視の権限を付け直す必要がある。

## ライセンス

MIT を想定（必要に応じて `LICENSE` を追加）。
