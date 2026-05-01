import Foundation
import CoreGraphics

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
        case .eisu: return "英数 (JIS Eisu)"
        case .kana: return "かな (JIS Kana)"
        case .escape: return "Esc"
        case .tab: return "Tab"
        case .return: return "Return"
        case .disabled: return "無効"
        }
    }

    /// 発火時に送出する仮想キーコード。`disabled` は nil。
    var keyCode: CGKeyCode? {
        switch self {
        case .eisu: return 0x66
        case .kana: return 0x68
        case .escape: return 0x35
        case .tab: return 0x30
        case .return: return 0x24
        case .disabled: return nil
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

    /// 単独押し判定の閾値（秒）の許容範囲。
    static let thresholdRange: ClosedRange<TimeInterval> = 0.1...1.0
    static let defaultThreshold: TimeInterval = 0.3

    private enum Keys {
        static let aloneThreshold = "aloneThreshold"
        static let leftAssignment = "leftAssignment"
        static let rightAssignment = "rightAssignment"
    }

    private let defaults: UserDefaults
    private let lock = NSLock()

    private var cachedThreshold: TimeInterval
    private var cachedLeft: AssignableKey
    private var cachedRight: AssignableKey

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        if defaults.object(forKey: Keys.aloneThreshold) != nil {
            cachedThreshold = Self.thresholdRange.clamp(
                defaults.double(forKey: Keys.aloneThreshold),
            )
        } else {
            cachedThreshold = Self.defaultThreshold
        }

        cachedLeft = (defaults.string(forKey: Keys.leftAssignment)
            .flatMap(AssignableKey.init(rawValue:))) ?? .eisu
        cachedRight = (defaults.string(forKey: Keys.rightAssignment)
            .flatMap(AssignableKey.init(rawValue:))) ?? .kana
    }

    var aloneThreshold: TimeInterval {
        get {
            lock.lock()
            defer { lock.unlock() }
            return cachedThreshold
        }
        set {
            let clamped = Self.thresholdRange.clamp(newValue)
            lock.lock()
            cachedThreshold = clamped
            lock.unlock()
            defaults.set(clamped, forKey: Keys.aloneThreshold)
        }
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

private extension ClosedRange where Bound: Comparable {
    func clamp(_ value: Bound) -> Bound {
        Swift.min(Swift.max(value, lowerBound), upperBound)
    }
}
