# Sayu

macOS のメニューバー常駐アプリ。左右の Command キーの**単独押し**を検出して、JIS の英数 / かな（または任意のキー）を発火する。

- 左 ⌘ 単独押し → **英数**（既定）
- 右 ⌘ 単独押し → **かな**（既定）
- ⌘ + 他キー（⌘C 等）は通常通り動作（単独押しではないため抑止される）

## 機能

- 単独押し判定の閾値（`0.1` 〜 `1.0` 秒）を環境設定で変更可能
- 左右それぞれの発火キーを `英数 / かな / Esc / Tab / Return / 無効` から選択
- ログイン時の自動起動（`SMAppService.mainApp`）をメニューから切替
- アクセシビリティ権限のポーリング監視と、付与後の自動再起動
- メニューバーアイコンは SF Symbol "globe"（テンプレート画像なのでライト/ダークに自動追従）

## 必要要件

- macOS 13.0 以降
- Apple Silicon (arm64) ※ Plugin は arm64 専用ビルド
- Swift 5.9+ （Xcode または Xcode Command Line Tools に同梱）

## アーキテクチャ

```
sayu/
├── Sources/Sayu/                    # アプリ本体（AppKit, ServiceManagement, ApplicationServices）
│   ├── AppDelegate.swift            # @main, 起動シーケンス, 権限要求, 再起動制御
│   ├── KeyRemapper.swift            # CGEventTap でキー監視, 単独押し検出と発火
│   ├── StatusBarController.swift    # メニューバー UI（NSStatusItem + NSMenu）
│   ├── PreferencesWindowController.swift  # 環境設定ウィンドウ（AppKit 直書き）
│   ├── Settings.swift               # UserDefaults 永続化 + NSLock キャッシュ
│   ├── LoginItemManager.swift       # SMAppService.mainApp の登録/解除
│   └── PermissionWatcher.swift      # AXIsProcessTrusted() のポーリング監視
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
| `AppDelegate.swift` | プロセス起動・`StatusBarController` 構築・アクセシビリティ権限要求・権限付与検知時の再起動 |
| `KeyRemapper.swift` | `cgSessionEventTap` で `flagsChanged` / `keyDown` を購読。⌘ down→up の経過時間を計測し、閾値内かつ他キー未押下なら `CGEvent` で対象キーを送出 |
| `StatusBarController.swift` | `NSStatusItem` の生成、メニュー構築、ログイン項目トグル、再起動・終了アクションのディスパッチ |
| `PreferencesWindowController.swift` | NSSlider / NSPopUpButton で閾値と左右割り当てを編集。値変更は `Settings` に即時反映 |
| `Settings.swift` | `UserDefaults` 永続化。CGEvent タップは別スレッドから読むため、内部で `NSLock` 保護のキャッシュを保持 |
| `LoginItemManager.swift` | macOS 13+ の `SMAppService.mainApp.register() / unregister()` を薄くラップ |
| `PermissionWatcher.swift` | macOS は権限付与の通知 API を持たないため、`AXIsProcessTrusted()` を 1.5 秒間隔でポーリング |

### 単独押し判定の流れ（`KeyRemapper`）

1. `flagsChanged` で ⌘ down を検出 → 押下時刻 (`commandDownAt`) と左右 (`commandDownIsLeft`) を保存
2. ⌘ 押下中に `keyDown` が来たら `otherKeyPressedWhileCommand = true` で抑止フラグを立てる
3. ⌘ up を検出した時、
   - 経過時間 < `Settings.aloneThreshold`
   - かつ `otherKeyPressedWhileCommand == false`

   なら、`Settings.leftAssignment` / `rightAssignment` に応じた仮想キーコードを `CGEvent` で送出
4. `tapDisabledByTimeout` / `tapDisabledByUserInput` を受けたら自動で `tapEnable` し直す

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

```bash
# build/Sayu.app が存在する前提
mkdir -p build/dmg-stage \
  && cp -R build/Sayu.app build/dmg-stage/ \
  && ln -sfn /Applications build/dmg-stage/Applications \
  && hdiutil create -volname Sayu \
       -srcfolder build/dmg-stage \
       -ov -format UDZO \
       build/Sayu.dmg \
  && rm -rf build/dmg-stage
```

### Plugin の主な処理

1. `swift tools/generate-icon.swift build/icon-source.png` でアイコン PNG をレンダリング
2. `sips` でリサイズして `iconutil` から `AppIcon.icns` を生成
3. `.build/arm64-apple-macosx/release/Sayu` を `.app/Contents/MacOS/` にコピー
4. `PlistBuddy` で `Info.plist` のプレースホルダ（`$(EXECUTABLE_NAME)` / `$(PRODUCT_BUNDLE_IDENTIFIER)`）を実値に置換
5. アドホック署名（`codesign --force --sign -`）+ `Sayu.entitlements` を適用

## インストール

ビルド済みの DMG をリポジトリに同梱している。GitHub から直接ダウンロードしてインストール可能:

1. リポジトリの [`build/Sayu.dmg`](build/Sayu.dmg) を **Download** から取得
2. DMG を開いて `Sayu.app` を `Applications` にドラッグ
3. `open /Applications/Sayu.app` で起動

アドホック署名のため、初回起動時に Gatekeeper の警告が出る。
**設定 > プライバシーとセキュリティ** の下部に「`Sayu` がブロックされました」と表示されるので、「このまま開く」を選択する。

自分でビルドする場合は [ビルド](#ビルド) を参照。

## 初回セットアップ

1. `Sayu.app` を起動
2. アクセシビリティ権限要求ダイアログ → 「システム設定を開く」
3. **設定 > プライバシーとセキュリティ > アクセシビリティ** で `Sayu` を **ON**
4. Sayu が `PermissionWatcher` で権限を検知し、再起動アラートを表示 → 「再起動」を押す
5. メニューバーに地球儀アイコンが表示されれば成功

ログイン時の自動起動はメニュー > **ログイン時に起動** で切替（`SMAppService.mainApp`）。
連携設定は **設定 > 一般 > ログイン項目** からも確認できる。

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
| メニューバーに何も出ない | `pkill -x Sayu` してから `open /Applications/Sayu.app` で再起動。アクセシビリティ権限の付与状況を確認 |
| アイコンの右に `!` が表示される | アクセシビリティ権限が未付与。メニュー > 「アクセシビリティ権限を許可…」で再要求 |
| ⌘ 単独押しで何も発火しない | 環境設定で割り当てが「無効」になっていないか / 単独押し閾値が短すぎないかを確認 |
| ⌘C / ⌘V が効かない | 通常時は素通し実装。別アプリ（Karabiner-Elements 等）の干渉を疑う |
| 設定を変えても反映されない | `Settings` は即時反映。フロントアプリ側のショートカットキャッシュが原因のことがあるので Sayu とフロントアプリを再起動 |
| ログイン項目に追加できない | システム設定 > 一般 > ログイン項目 から手動で追加 |

ログ確認:

```bash
log stream --predicate 'process == "Sayu"' --info
```

## 配布

- App Sandbox を必須とする Mac App Store 配布は**不可**（CGEventTap が App Sandbox 下では動かない）
- Developer ID 署名 + `notarytool` での公証で外部配布可能
- 現在の `bundle-app` Plugin はアドホック署名のため、ローカル実行限定。配布時は Plugin 内 `codesign` 呼び出しを Developer ID 証明書に差し替えて再ビルドする

## ライセンス

MIT を想定（必要に応じて `LICENSE` を追加）。
