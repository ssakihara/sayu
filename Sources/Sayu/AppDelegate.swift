import AppKit

@main
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settings = Settings.shared
    private let loginItemManager = LoginItemManager()
    private let permissionWatcher = PermissionWatcher()
    private lazy var remapper = KeyRemapper(settings: settings)
    private var statusBar: StatusBarController?
    private var preferencesController: PreferencesWindowController?

    /// PermissionWatcher の状態変化通知で「次の不足権限ペインを自動で開く」処理を
    /// 一度だけ動かすためのフラグ。ユーザーがアラートで「権限設定を開く」を選んだ
    /// 後にだけ自動遷移したい（待機モードに戻った後の意図しないペイン強制起動を防ぐ）。
    private var autoChainOpenPanes = false

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    func applicationDidFinishLaunching(_: Notification) {
        statusBar = StatusBarController(
            onQuit: { NSApp.terminate(nil) },
            onRequestPermission: { [weak self] in
                self?.handleRequestPermission()
            },
            onOpenPreferences: { [weak self] in
                self?.openPreferences()
            },
            onRestart: { [weak self] in
                self?.restart()
            },
            loginItemManager: loginItemManager
        )

        // OS のダイアログは初回のみ表示。以降は何もしない。
        Permissions.requestAccessibility(prompt: true)
        Permissions.requestInputMonitoring()

        if Permissions.allGranted {
            remapper.start()
            return
        }

        statusBar?.showPermissionRequired()
        showPermissionAlert()
        startWatchingPermissions()
    }

    /// 権限不足アラートを表示する。
    /// 「権限設定を開く」を選んだ場合は最初の不足権限のペインを開き、
    /// バトンタッチ自動遷移を開始する。
    private func showPermissionAlert() {
        let missing = currentlyMissingPermissions()
        guard let firstMissing = missing.first else { return }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Sayu に必要な権限を許可してください"
        alert.informativeText = """
        左右⌘の単独押しを検出するには次の権限が必要です。
        「権限設定を開く」を押すと、不足している権限のシステム設定が順番に開きます。
        各画面で Sayu のトグルを ON にしてください。

        \(missing.map { "・\($0.label)" }.joined(separator: "\n"))

        全ての権限が揃うと自動で再起動します。
        """
        alert.addButton(withTitle: "権限設定を開く")
        alert.addButton(withTitle: "あとで")

        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            firstMissing.openSettings()
            autoChainOpenPanes = true
        }
    }

    private func currentlyMissingPermissions() -> [MissingPermission] {
        var missing: [MissingPermission] = []
        if !Permissions.hasAccessibility {
            missing.append(.accessibility)
        }
        if !Permissions.hasInputMonitoring {
            missing.append(.inputMonitoring)
        }
        return missing
    }

    private enum MissingPermission {
        case accessibility
        case inputMonitoring

        var label: String {
            switch self {
            case .accessibility: "アクセシビリティ"
            case .inputMonitoring: "入力監視 (Input Monitoring)"
            }
        }

        func openSettings() {
            switch self {
            case .accessibility: Permissions.openAccessibilitySettings()
            case .inputMonitoring: Permissions.openInputMonitoringSettings()
            }
        }
    }

    private func startWatchingPermissions() {
        permissionWatcher.start { [weak self] in
            self?.handlePermissionStateChanged()
        }
    }

    /// 権限の付与状態に変化があったときの処理。
    /// - 全権限揃った場合: 再起動アラートを出して自動再起動
    /// - 一部だけ揃った場合: ユーザーが事前に「権限設定を開く」を選んでいれば、
    ///   次の不足権限のペインを自動で開いてバトンタッチする
    private func handlePermissionStateChanged() {
        if Permissions.allGranted {
            permissionWatcher.stop()
            promptRestartAfterPermissionGranted()
            return
        }

        guard autoChainOpenPanes else { return }
        if let next = currentlyMissingPermissions().first {
            NSApp.activate(ignoringOtherApps: true)
            next.openSettings()
        }
    }

    /// メニューから明示的に呼ばれたときの権限要求。アラートを再表示する。
    private func handleRequestPermission() {
        // 念のため再度プロンプトをかける（macOS によっては表示されないこともある）。
        Permissions.requestAccessibility(prompt: true)
        Permissions.requestInputMonitoring()

        if Permissions.allGranted {
            // メニュー操作中に既に揃っていたらそのまま再起動アラートに進む
            promptRestartAfterPermissionGranted()
            return
        }

        showPermissionAlert()
        // 既に start 済みなら no-op、未開始なら開始
        startWatchingPermissions()
    }

    /// 権限付与を検知したときの処理。ユーザー確認を挟んでアプリを再起動する。
    private func promptRestartAfterPermissionGranted() {
        autoChainOpenPanes = false
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText = "必要な権限を確認しました"
        alert.informativeText = "変更を反映するために Sayu を再起動します。"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "再起動")
        alert.runModal()

        // モーダル表示中に権限が再度取り消された可能性に備えて確認する
        guard Permissions.allGranted else {
            NSLog("Sayu: permission was revoked before restart, skipping")
            statusBar?.showPermissionRequired()
            startWatchingPermissions()
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
}
