import AppKit

@main
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settings = Settings.shared
    private let loginItemManager = LoginItemManager()
    private let permissionWatcher = PermissionWatcher()
    private lazy var remapper = KeyRemapper(settings: settings)
    private var statusBar: StatusBarController?
    private var preferencesController: PreferencesWindowController?

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusBar = StatusBarController(
            onQuit: { NSApp.terminate(nil) },
            onRequestPermission: { [weak self] in
                self?.requestAccessibilityPermission(prompt: true)
            },
            onOpenPreferences: { [weak self] in
                self?.openPreferences()
            },
            onRestart: { [weak self] in
                self?.restart()
            },
            loginItemManager: loginItemManager,
        )

        if requestAccessibilityPermission(prompt: true) {
            remapper.start()
        } else {
            statusBar?.showPermissionRequired()
            permissionWatcher.start { [weak self] in
                self?.handlePermissionGranted()
            }
        }
    }

    /// 権限付与を検知したときの処理。ユーザー確認を挟んでアプリを再起動する。
    private func handlePermissionGranted() {
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText = "アクセシビリティ権限を確認しました"
        alert.informativeText = "変更を反映するために Sayu を再起動します。"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "再起動")
        alert.runModal()

        // モーダル表示中に権限が再度取り消された可能性に備えて確認する
        guard AXIsProcessTrusted() else {
            NSLog("Sayu: permission was revoked before restart, skipping")
            statusBar?.showPermissionRequired()
            permissionWatcher.start { [weak self] in
                self?.handlePermissionGranted()
            }
            return
        }

        restart()
    }

    /// 自プロセスを終了し、新しい Sayu を起動する。
    /// 子プロセスとして `sh` を spawn し、親終了後に `open` で再起動する。
    private func restart() {
        let bundlePath = Bundle.main.bundlePath
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        // $1 にバンドルパスを渡すことでシェルエスケープを不要化する。
        // $0 にはスクリプト名相当のダミー値を入れる。
        task.arguments = [
            "-c",
            "sleep 0.8; /usr/bin/open \"$1\"",
            "sayu-restart",
            bundlePath,
        ]
        do {
            try task.run()
        } catch {
            NSLog("Sayu: failed to schedule restart: \(error)")
            return
        }
        NSApp.terminate(nil)
    }

    private func openPreferences() {
        if preferencesController == nil {
            preferencesController = PreferencesWindowController(settings: settings)
        }
        preferencesController?.presentWindow()
    }

    @discardableResult
    private func requestAccessibilityPermission(prompt: Bool) -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let opts: NSDictionary = [key: prompt]
        return AXIsProcessTrustedWithOptions(opts)
    }
}
