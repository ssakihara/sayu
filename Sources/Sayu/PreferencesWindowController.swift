import AppKit

/// 環境設定ウィンドウ。
/// 左右⌘の割り当てキーを編集できる。
final class PreferencesWindowController: NSWindowController, NSWindowDelegate {
    private let settings: Settings

    private let leftPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let rightPopup = NSPopUpButton(frame: .zero, pullsDown: false)

    init(settings: Settings) {
        self.settings = settings

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 160),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Sayu 環境設定"
        window.isReleasedWhenClosed = false
        window.center()

        super.init(window: window)
        window.delegate = self

        buildLayout()
        loadCurrentValues()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("PreferencesWindowController does not support coder init")
    }

    /// ウィンドウを前面に出す。最新の値を再読み込みしてから表示する。
    func presentWindow() {
        loadCurrentValues()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func buildLayout() {
        guard let contentView = window?.contentView else { return }

        for key in AssignableKey.allCases {
            leftPopup.addItem(withTitle: key.displayName)
            leftPopup.lastItem?.representedObject = key
            rightPopup.addItem(withTitle: key.displayName)
            rightPopup.lastItem?.representedObject = key
        }
        leftPopup.target = self
        leftPopup.action = #selector(leftChanged(_:))
        rightPopup.target = self
        rightPopup.action = #selector(rightChanged(_:))

        let leftRow = horizontalRow(views: [label("左 ⌘:"), leftPopup])
        let rightRow = horizontalRow(views: [label("右 ⌘:"), rightPopup])
        let hint = NSTextField(labelWithString: "変更は即時に反映されます。")
        hint.textColor = .secondaryLabelColor
        hint.font = NSFont.preferredFont(forTextStyle: .footnote)

        let stack = NSStackView(views: [leftRow, rightRow, hint])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.edgeInsets = NSEdgeInsets(top: 24, left: 24, bottom: 24, right: 24)
        stack.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])
    }

    private func loadCurrentValues() {
        select(popup: leftPopup, key: settings.leftAssignment)
        select(popup: rightPopup, key: settings.rightAssignment)
    }

    private func select(popup: NSPopUpButton, key: AssignableKey) {
        for (index, item) in popup.itemArray.enumerated() {
            if (item.representedObject as? AssignableKey) == key {
                popup.selectItem(at: index)
                return
            }
        }
    }

    private func label(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.setContentHuggingPriority(.required, for: .horizontal)
        return field
    }

    private func horizontalRow(views: [NSView]) -> NSStackView {
        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.spacing = 8
        row.alignment = .centerY
        return row
    }

    @objc private func leftChanged(_ sender: NSPopUpButton) {
        if let key = sender.selectedItem?.representedObject as? AssignableKey {
            settings.leftAssignment = key
        }
    }

    @objc private func rightChanged(_ sender: NSPopUpButton) {
        if let key = sender.selectedItem?.representedObject as? AssignableKey {
            settings.rightAssignment = key
        }
    }
}
