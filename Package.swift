// swift-tools-version:5.9
import PackageDescription

// このマニフェストは:
//   - Sayu 本体のコンパイル (`swift build` 経由)
//   - SwiftLint / SwiftFormat の Plugin 利用
//   - `swift package bundle-app` による .app バンドル組立
// を担う。`swift build` でバイナリを生成 → `bundle-app` Plugin で
// アイコン生成・Info.plist 注入・ad-hoc 署名・.app バンドル組立を行う。
let package = Package(
    name: "Sayu",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/realm/SwiftLint", from: "0.57.0"),
        .package(url: "https://github.com/nicklockwood/SwiftFormat", from: "0.55.0"),
    ],
    targets: [
        .executableTarget(
            name: "Sayu",
            path: "Sources/Sayu",
        ),
        .plugin(
            name: "BundleApp",
            capability: .command(
                intent: .custom(
                    verb: "bundle-app",
                    description: "Assemble the .app bundle from a pre-built binary (run 'swift build -c release --arch arm64' first)",
                ),
                permissions: [
                    .writeToPackageDirectory(
                        reason: "Generate icons, assemble .app bundle, and sign in build/",
                    ),
                ],
            ),
            path: "Plugins/BundleAppCommand",
        ),
    ],
)
