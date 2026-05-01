import Foundation
import ServiceManagement

/// ログイン項目（macOS 13+ の `SMAppService.mainApp`）への登録を管理する。
final class LoginItemManager {
    /// ログイン項目として有効化されているか。
    var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// ログイン項目の有効/無効を切り替える。
    /// - Returns: 成功した場合 true、失敗した場合 false。
    @discardableResult
    func setEnabled(_ enabled: Bool) -> Bool {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return true
        } catch {
            NSLog("Sayu: failed to update login item (enabled=\(enabled)): \(error)")
            return false
        }
    }
}
