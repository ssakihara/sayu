import AppKit
import ApplicationServices
import IOKit.hid

/// Sayu が動作するために必要な OS 権限のチェックと要求を集約する。
///
/// 必要な権限は 2 種類:
///   - アクセシビリティ: `CGEvent.post` の発火と `flagsChanged` の監視に使う
///   - 入力監視 (Input Monitoring): `CGEventTap` および `NSEvent.addGlobalMonitorForEvents`
///     で keyDown/keyUp を取得するために必要 (macOS Catalina 以降)
enum Permissions {
    /// アクセシビリティ権限が付与されているか。
    static var hasAccessibility: Bool {
        AXIsProcessTrusted()
    }

    /// 入力監視権限が付与されているか。
    static var hasInputMonitoring: Bool {
        IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
    }

    /// 必要な権限がすべて揃っているか。
    static var allGranted: Bool {
        hasAccessibility && hasInputMonitoring
    }

    /// アクセシビリティ権限を要求する。`prompt: true` の場合、未許可なら OS の
    /// ダイアログを表示する。許可済みなら即 true。
    @discardableResult
    static func requestAccessibility(prompt: Bool) -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let opts: NSDictionary = [key: prompt]
        return AXIsProcessTrustedWithOptions(opts)
    }

    /// 入力監視権限を要求する。未許可なら OS のダイアログを表示し、付与済みなら即 true。
    /// プロンプト表示の挙動はシステム依存（初回起動時に一度だけ表示されるケースあり）。
    @discardableResult
    static func requestInputMonitoring() -> Bool {
        IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
    }

    /// システム設定の「アクセシビリティ」ペインを開く。
    static func openAccessibilitySettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    /// システム設定の「入力監視」ペインを開く。
    static func openInputMonitoringSettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"
        ) else { return }
        NSWorkspace.shared.open(url)
    }
}
