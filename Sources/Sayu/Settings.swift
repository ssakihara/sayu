import CoreGraphics
import Foundation

/// 左右⌘ キーに割り当て可能なキー種別。
enum AssignableKey: String, CaseIterable {
    case eisu
    case kana
    case escape
    case tab
    case `return`
    case disabled

    var displayName: String {
        switch self {
        case .eisu: "英数 (JIS Eisu)"
        case .kana: "かな (JIS Kana)"
        case .escape: "Esc"
        case .tab: "Tab"
        case .return: "Return"
        case .disabled: "無効"
        }
    }

    /// 発火時に送出する仮想キーコード。`disabled` は nil。
    var keyCode: CGKeyCode? {
        switch self {
        case .eisu: 0x66
        case .kana: 0x68
        case .escape: 0x35
        case .tab: 0x30
        case .return: 0x24
        case .disabled: nil
        }
    }
}

/// UserDefaults を背後に持つアプリ設定。
///
/// CGEvent タップコールバック (KeyRemapper) は専用スレッドから読むため、
/// 内部で値をキャッシュし `NSLock` で保護する。
/// 書き込みは UI スレッド経由を想定しているが、安全のため lock 経由で行う。
final class Settings {
    static let shared = Settings()

    private enum Keys {
        static let leftAssignment = "leftAssignment"
        static let rightAssignment = "rightAssignment"
    }

    private let defaults: UserDefaults
    private let lock = NSLock()

    private var cachedLeft: AssignableKey
    private var cachedRight: AssignableKey

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        cachedLeft = (defaults.string(forKey: Keys.leftAssignment)
            .flatMap(AssignableKey.init(rawValue:))) ?? .eisu
        cachedRight = (defaults.string(forKey: Keys.rightAssignment)
            .flatMap(AssignableKey.init(rawValue:))) ?? .kana
    }

    var leftAssignment: AssignableKey {
        get {
            lock.lock()
            defer { lock.unlock() }
            return cachedLeft
        }
        set {
            lock.lock()
            cachedLeft = newValue
            lock.unlock()
            defaults.set(newValue.rawValue, forKey: Keys.leftAssignment)
        }
    }

    var rightAssignment: AssignableKey {
        get {
            lock.lock()
            defer { lock.unlock() }
            return cachedRight
        }
        set {
            lock.lock()
            cachedRight = newValue
            lock.unlock()
            defaults.set(newValue.rawValue, forKey: Keys.rightAssignment)
        }
    }
}
