import AppKit

/// メニューバー常駐の UI を担当する。
final class StatusBarController: NSObject, NSMenuDelegate {
    private enum Layout {
        /// メニューバーアイコン（SF Symbol）のポイントサイズ。
        /// メニューバーの描画可能高さは約 22pt で、SF Symbol の実描画高は
        /// pointSize の 1.3〜1.4 倍になるため、14pt 前後が上下に切れず収まる。
        static let symbolPointSize: CGFloat = 14
    }

    private let statusItem: NSStatusItem
    private let onQuit: () -> Void
    private let onRequestPermission: () -> Void
    private let onOpenPreferences: () -> Void
    private let onRestart: () -> Void
    private let loginItemManager: LoginItemManager

    private var permissionRequired = false

    init(
        onQuit: @escaping () -> Void,
        onRequestPermission: @escaping () -> Void,
        onOpenPreferences: @escaping () -> Void,
        onRestart: @escaping () -> Void,
        loginItemManager: LoginItemManager,
    ) {
        self.onQuit = onQuit
        self.onRequestPermission = onRequestPermission
        self.onOpenPreferences = onOpenPreferences
        self.onRestart = onRestart
        self.loginItemManager = loginItemManager

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        super.init()

        if let image = Self.loadMenuBarImage() {
            statusItem.button?.image = image
            statusItem.button?.imagePosition = .imageOnly
        } else {
            statusItem.button?.title = "左右"
        }
        statusItem.button?.toolTip = "Sayu — 左⌘で英数 / 右⌘でかな"

        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        rebuildMenu()
    }

    func showPermissionRequired() {
        permissionRequired = true
        if statusItem.button?.image != nil {
            // 画像はそのまま、警告マークをテキストで併記する
            statusItem.button?.title = " !"
            statusItem.button?.imagePosition = .imageLeading
        } else {
            statusItem.button?.title = "左右!"
        }
        statusItem.button?.toolTip = "Sayu — アクセシビリティ権限が必要です"
        rebuildMenu()
    }

    /// メニューバー用のアイコンを SF Symbol から生成する。
    /// SF Symbol は自動的にライト/ダークモード対応・選択時の色反転に追従する。
    private static func loadMenuBarImage() -> NSImage? {
        let config = NSImage.SymbolConfiguration(
            pointSize: Layout.symbolPointSize,
            weight: .regular,
        )
        let image = NSImage(
            systemSymbolName: "globe",
            accessibilityDescription: "Sayu",
        )?.withSymbolConfiguration(config)
        image?.isTemplate = true
        return image
    }

    // MARK: - NSMenuDelegate

    func menuWillOpen(_ menu: NSMenu) {
        rebuildMenu()
    }

    // MARK: - Menu

    private func rebuildMenu() {
        guard let menu = statusItem.menu else { return }
        menu.removeAllItems()

        if permissionRequired {
            let item = NSMenuItem(
                title: "アクセシビリティ権限を許可…",
                action: #selector(requestPermission),
                keyEquivalent: "",
            )
            item.target = self
            menu.addItem(item)
            menu.addItem(.separator())
        }

        let preferences = NSMenuItem(
            title: "環境設定…",
            action: #selector(openPreferences),
            keyEquivalent: ",",
        )
        preferences.target = self
        menu.addItem(preferences)

        let loginItem = NSMenuItem(
            title: "ログイン時に起動",
            action: #selector(toggleLoginItem),
            keyEquivalent: "",
        )
        loginItem.target = self
        loginItem.state = loginItemManager.isEnabled ? .on : .off
        menu.addItem(loginItem)

        menu.addItem(.separator())

        let restart = NSMenuItem(
            title: "Sayu を再起動",
            action: #selector(restart),
            keyEquivalent: "",
        )
        restart.target = self
        menu.addItem(restart)

        let quit = NSMenuItem(
            title: "Sayu を終了",
            action: #selector(quit),
            keyEquivalent: "q",
        )
        quit.target = self
        menu.addItem(quit)
    }

    @objc private func quit() {
        onQuit()
    }

    @objc private func requestPermission() {
        onRequestPermission()
    }

    @objc private func openPreferences() {
        onOpenPreferences()
    }

    @objc private func restart() {
        onRestart()
    }

    @objc private func toggleLoginItem() {
        let next = !loginItemManager.isEnabled
        let success = loginItemManager.setEnabled(next)
        if !success {
            let alert = NSAlert()
            alert.messageText = next
                ? "ログイン項目への登録に失敗しました"
                : "ログイン項目の解除に失敗しました"
            alert.informativeText = "システム設定 > 一般 > ログイン項目から手動で確認してください。"
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
        rebuildMenu()
    }
}
