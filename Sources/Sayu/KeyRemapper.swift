import AppKit
import CoreGraphics

/// 左右の Command キーの単独押しを検出し、`Settings` で指定されたキーを発火する。
///
/// 検出ロジック:
///   - modifier-down 時の keyCode を保持
///   - modifier-up 時、保持していた keyCode と一致すれば「単独押し」として発火
///   - その間に他キー入力・マウス操作が一度でも発生したら保持中の keyCode を nil
///     にして発火条件を破棄する
///
/// 押下時間の閾値判定は持たない。「Cmd-down から Cmd-up までの間に他の入力が
/// 一切無いか」だけで単独押し判定する。
///
/// CGEventTap で keyDown/keyUp を取得するには macOS Catalina 以降では
/// 「入力監視」権限が必要なため、Sayu はその権限がある前提で動く（無いと
/// keyDown/keyUp が届かず Cmd+V 等で誤発火する）。さらに上位フックに
/// 消費される経路の保険として、NSEvent global+local monitor でも併監視する。
final class KeyRemapper {
    private enum KeyCode {
        static let leftCommand: CGKeyCode = 55
        static let rightCommand: CGKeyCode = 54
    }

    private let settings: Settings

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var globalEventMonitor: Any?
    private var localEventMonitor: Any?

    /// 最後に modifier-down を観測した keyCode。次の modifier-up が同じ keyCode
    /// で来れば単独押しと判定する。他のキー入力・マウス操作・合成 Cmd-down が
    /// 発生したら nil にリセットされる。
    private var lastModifierKeyCode: CGKeyCode?

    init(settings: Settings = .shared) {
        self.settings = settings
    }

    deinit {
        // インスタンス破棄時に明示的に stop() を呼んでいない経路に備え、
        // NSEvent monitor の解放を保証する。
        stop()
    }

    func start() {
        guard eventTap == nil else { return }

        let mask = (1 << CGEventType.flagsChanged.rawValue)
            | (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)

        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else {
                NSLog("Sayu: event tap callback received nil refcon, passing event through")
                return Unmanaged.passUnretained(event)
            }
            let me = Unmanaged<KeyRemapper>.fromOpaque(refcon).takeUnretainedValue()
            return me.handle(type: type, event: event)
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            NSLog("Sayu: failed to create event tap. Accessibility permission required.")
            return
        }

        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        eventTap = tap
        runLoopSource = source

        startAuxiliaryMonitors()
    }

    /// 他キー入力・マウス・スクロール操作を NSEvent global+local monitor 経由で
    /// 監視する。CGEventTap だけでは Raycast 等の上位フックで keyDown が消費される
    /// 環境でフォールバックが効くようにする保険。
    private func startAuxiliaryMonitors() {
        let mask: NSEvent.EventTypeMask = [
            .leftMouseDown, .leftMouseUp,
            .rightMouseDown, .rightMouseUp,
            .otherMouseDown, .otherMouseUp,
            .scrollWheel,
            .keyDown, .keyUp,
        ]
        globalEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] _ in
            self?.lastModifierKeyCode = nil
        }
        localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            self?.lastModifierKeyCode = nil
            return event
        }
    }

    func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil

        if let monitor = globalEventMonitor {
            NSEvent.removeMonitor(monitor)
        }
        if let monitor = localEventMonitor {
            NSEvent.removeMonitor(monitor)
        }
        globalEventMonitor = nil
        localEventMonitor = nil
    }

    private func handle(
        type: CGEventType,
        event: CGEvent
    ) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)

        case .keyDown, .keyUp:
            // どんなキー入力が発生しても単独押しではなくなる。
            lastModifierKeyCode = nil
            return Unmanaged.passUnretained(event)

        case .flagsChanged:
            handleFlagsChanged(event: event)
            return Unmanaged.passUnretained(event)

        default:
            return Unmanaged.passUnretained(event)
        }
    }

    private func handleFlagsChanged(event: CGEvent) {
        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        let isLeft = keyCode == KeyCode.leftCommand
        let isRight = keyCode == KeyCode.rightCommand

        guard isLeft || isRight else {
            // Shift / Option / Control / Fn など他 modifier の変化も
            // 「他キーの入力」とみなして単独押し判定を破棄する。
            lastModifierKeyCode = nil
            return
        }

        // Raycast 等が合成した Cmd イベント（CGEventPost 由来）は実ハードウェア
        // 入力と区別するため発生元 PID を確認する。物理入力は PID = 0。
        let sourcePID = event.getIntegerValueField(.eventSourceUnixProcessID)
        let isSynthetic = sourcePID != 0

        // event.flags の Cmd ビット状態で down / up を判定する。
        // (modifier-down: maskCommand あり / modifier-up: maskCommand なし)
        let isDown = event.flags.contains(.maskCommand)

        if isDown {
            if isSynthetic {
                // 合成 Cmd-down は単独押し検出の対象外。物理 down が改めて来れば
                // そこで lastModifierKeyCode が正しい値で再設定される。
                lastModifierKeyCode = nil
            } else {
                lastModifierKeyCode = keyCode
            }
            return
        }

        // modifier-up
        if !isSynthetic, lastModifierKeyCode == keyCode {
            let assignment = isLeft ? settings.leftAssignment : settings.rightAssignment
            if let target = assignment.keyCode {
                postKey(target)
            }
        }
        lastModifierKeyCode = nil
    }

    private func postKey(_ keyCode: CGKeyCode) {
        let source = CGEventSource(stateID: .hidSystemState)
        let down = CGEvent(
            keyboardEventSource: source,
            virtualKey: keyCode,
            keyDown: true
        )
        let up = CGEvent(
            keyboardEventSource: source,
            virtualKey: keyCode,
            keyDown: false
        )
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}
