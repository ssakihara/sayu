import Foundation
import PackagePlugin

/// `swift package bundle-app` で起動される Command Plugin。
///
/// `swift build -c release --arch arm64` で生成されたバイナリを基に、
/// .app バンドル組立・アイコン生成・Info.plist 注入・ad-hoc 署名と、
/// オプションで /Applications インストールを行う。
///
/// 想定ユーザーフロー:
/// ```
/// # ビルドのみ
/// swift build -c release --arch arm64 \
///   && swift package --allow-writing-to-package-directory bundle-app
///
/// # /Applications にインストール (フラグ追加が必要)
/// swift build -c release --arch arm64 \
///   && swift package \
///        --allow-writing-to-package-directory \
///        --allow-writing-to-directory /Applications \
///        bundle-app --install
/// ```
///
/// Plugin sandbox 上の制約から外側 swift-package が SwiftPM build lock を
/// 握っているため、Plugin から `swift build` を再帰呼び出しできない。
/// したがって `swift build` は呼び出し側で事前に実行する設計。
///
/// DMG 生成は hdiutil が plugin sandbox 内で device アクセスできず動作不能
/// (「装置が構成されていません」エラー)。README に hdiutil の生コマンドを
/// 記載しているのでそちらで対応する。
@main
struct BundleAppCommand: CommandPlugin {
    static let appName = "Sayu"
    static let defaultBundleID = "dev.ssakihara.Sayu"

    func performCommand(
        context: PluginContext,
        arguments: [String],
    ) async throws {
        let pkg = context.package.directory
        let env = ProcessInfo.processInfo.environment
        let bundleID = env["SAYU_BUNDLE_ID"] ?? Self.defaultBundleID
        let appName = Self.appName

        // Bundle ID の最低限の妥当性チェック (macOS の逆ドメイン記法)。
        // PlistBuddy はシェルではなく `Process` 直起動なのでコマンド注入の
        // 直接リスクはないが、無効値を弾いて分かりやすく失敗させる。
        guard isValidBundleID(bundleID) else {
            Diagnostics.error(
                """
                Invalid bundle ID: '\(bundleID)'.
                Must be reverse-DNS notation containing a dot, with only \
                alphanumerics, dots, and hyphens (e.g. dev.example.Sayu).
                """,
            )
            throw PluginError.invalidBundleID
        }

        var shouldInstall = false
        for arg in arguments {
            switch arg {
            case "--install":
                shouldInstall = true
            case "--dmg":
                Diagnostics.error(
                    """
                    --dmg is not supported from inside the plugin sandbox \
                    (hdiutil cannot access disk devices). Build the .app first, \
                    then create the DMG with the raw hdiutil command. See README.
                    """,
                )
                throw PluginError.dmgUnsupported
            default:
                Diagnostics.warning("Unknown argument ignored: \(arg)")
            }
        }

        let buildDir = pkg.appending("build")
        let app = buildDir.appending("\(appName).app")
        let macOSDir = app.appending("Contents/MacOS")
        let resourcesDir = app.appending("Contents/Resources")
        let infoPlistDst = app.appending("Contents/Info.plist")
        let iconSource = buildDir.appending("icon-source.png")
        let iconsetDir = buildDir.appending("AppIcon.iconset")
        let icns = buildDir.appending("AppIcon.icns")
        let infoPlistSrc = pkg.appending("Resources/Info.plist")
        let entitlements = pkg.appending("Resources/Sayu.entitlements")
        let prebuilt = pkg.appending(".build/arm64-apple-macosx/release/\(appName)")
        let generateIcon = pkg.appending("tools/generate-icon.swift")

        let fm = FileManager.default

        guard fm.fileExists(atPath: prebuilt.string) else {
            Diagnostics.error(
                """
                Pre-built binary not found at \(prebuilt.string).
                Run `swift build -c release --arch arm64` first, then re-run \
                `swift package bundle-app`.
                """,
            )
            throw PluginError.binaryNotFound
        }

        guard fm.fileExists(atPath: generateIcon.string) else {
            Diagnostics.error(
                """
                Icon generation script not found at \(generateIcon.string).
                Ensure tools/generate-icon.swift exists in the repository.
                """,
            )
            throw PluginError.generateIconNotFound
        }

        // .app 構造を作り直す。既存 .app の削除失敗は明示的にエラーにする
        // （次の createDirectory が失敗するより前に診断を出す）。
        if fm.fileExists(atPath: app.string) {
            try fm.removeItem(atPath: app.string)
        }
        try fm.createDirectory(
            atPath: macOSDir.string,
            withIntermediateDirectories: true,
        )
        try fm.createDirectory(
            atPath: resourcesDir.string,
            withIntermediateDirectories: true,
        )

        // 1. SF Symbol からアイコン PNG を生成
        print("==> Generating icon source from SF Symbol (globe)")
        try runProcess(
            executable: "/usr/bin/swift",
            arguments: [generateIcon.string, iconSource.string],
            cwd: pkg,
        )

        // 2. .iconset を sips でリサイズ → iconutil で .icns
        print("==> Generating AppIcon.icns from \(iconSource.string)")
        try? fm.removeItem(atPath: iconsetDir.string)
        try fm.createDirectory(
            atPath: iconsetDir.string,
            withIntermediateDirectories: true,
        )

        let iconSizes: [(size: Int, file: String)] = [
            (16, "icon_16x16.png"),
            (32, "icon_16x16@2x.png"),
            (32, "icon_32x32.png"),
            (64, "icon_32x32@2x.png"),
            (128, "icon_128x128.png"),
            (256, "icon_128x128@2x.png"),
            (256, "icon_256x256.png"),
            (512, "icon_256x256@2x.png"),
            (512, "icon_512x512.png"),
            (1024, "icon_512x512@2x.png"),
        ]
        for (size, file) in iconSizes {
            try runProcess(
                executable: "/usr/bin/sips",
                arguments: [
                    "-z", "\(size)", "\(size)",
                    iconSource.string,
                    "--out", iconsetDir.appending(file).string,
                ],
                cwd: pkg,
                quiet: true,
            )
        }
        try runProcess(
            executable: "/usr/bin/iconutil",
            arguments: ["-c", "icns", "-o", icns.string, iconsetDir.string],
            cwd: pkg,
        )
        try fm.copyItem(
            atPath: icns.string,
            toPath: resourcesDir.appending("AppIcon.icns").string,
        )

        // 3. ビルド済みバイナリを配置
        try fm.copyItem(
            atPath: prebuilt.string,
            toPath: macOSDir.appending(appName).string,
        )

        // 4. Info.plist のプレースホルダを実値に置換
        try fm.copyItem(
            atPath: infoPlistSrc.string,
            toPath: infoPlistDst.string,
        )
        try runProcess(
            executable: "/usr/libexec/PlistBuddy",
            arguments: [
                "-c", "Set :CFBundleExecutable \(appName)",
                "-c", "Set :CFBundleIdentifier \(bundleID)",
                infoPlistDst.string,
            ],
            cwd: pkg,
        )

        // 5. ad-hoc 署名 + entitlements
        try runProcess(
            executable: "/usr/bin/codesign",
            arguments: [
                "--force", "--sign", "-",
                "--entitlements", entitlements.string,
                app.string,
            ],
            cwd: pkg,
        )

        print("==> Built: \(app.string)")

        if shouldInstall {
            let dest = "/Applications/\(appName).app"
            // 既存 app をいきなり消すと、コピー失敗・中断時にアプリが消失する。
            // 1) staging にコピー → 2) 既存を backup へ rename → 3) staging を本体へ rename
            // → 4) backup 削除、という手順でクラッシュしてもどちらか一方が必ず残るようにする。
            let staging = dest + ".tmp-install"
            let backup = dest + ".backup"
            print("==> Installing to \(dest)")
            try? fm.removeItem(atPath: staging)
            try? fm.removeItem(atPath: backup)

            do {
                try fm.copyItem(atPath: app.string, toPath: staging)

                if fm.fileExists(atPath: dest) {
                    try fm.moveItem(atPath: dest, toPath: backup)
                }

                do {
                    try fm.moveItem(atPath: staging, toPath: dest)
                } catch {
                    // 本体への rename に失敗した場合は backup を復元して
                    // 旧 .app を残す（消失を防ぐ）。
                    if fm.fileExists(atPath: backup) {
                        try? fm.moveItem(atPath: backup, toPath: dest)
                    }
                    throw error
                }

                try? fm.removeItem(atPath: backup)
            } catch {
                try? fm.removeItem(atPath: staging)
                Diagnostics.error(
                    """
                    Failed to install to \(dest): \(error.localizedDescription).
                    Plugin sandbox requires writing permission for /Applications.
                    Re-run with:
                      swift package --allow-writing-to-package-directory \\
                        --allow-writing-to-directory /Applications \\
                        bundle-app --install
                    """,
                )
                throw error
            }
            print("==> Installed: \(dest)")
        }

    }

    /// macOS Bundle ID の最低限の妥当性チェック。
    /// 逆ドメイン記法（ドット必須）、英数字 / ドット / ハイフンのみを許容。
    private func isValidBundleID(_ id: String) -> Bool {
        guard id.contains(".") else { return false }
        return id.allSatisfy { ch in
            ch.isLetter || ch.isNumber || ch == "." || ch == "-"
        }
    }

    /// 外部コマンドを起動し、終了コードを検査する。stdout/stderr は
    /// 既定でコンソールに透過。`quiet: true` で stdout を破棄。
    private func runProcess(
        executable: String,
        arguments: [String],
        cwd: Path,
        quiet: Bool = false,
    ) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: cwd.string)

        if quiet {
            process.standardOutput = Pipe()
        } else {
            process.standardOutput = FileHandle.standardOutput
        }
        process.standardError = FileHandle.standardError

        try process.run()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            let cmd = (executable as NSString).lastPathComponent
            Diagnostics.error(
                "\(cmd) exited with code \(process.terminationStatus)",
            )
            throw PluginError.commandFailed(
                command: cmd,
                status: process.terminationStatus,
            )
        }
    }
}

enum PluginError: Error {
    case binaryNotFound
    case generateIconNotFound
    case invalidBundleID
    case dmgUnsupported
    case commandFailed(command: String, status: Int32)
}
