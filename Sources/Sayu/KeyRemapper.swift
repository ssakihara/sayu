import AppKit
import CoreGraphics

/// 左右の Command キーの単独押しを検出し、`Settings` で指定されたキーを発火する。
final class KeyRemapper {
    private enum KeyCode {
        static let leftCommand: Int64 = 55
        static let rightCommand: Int64 = 54
    }

    /// 単独押しと判定する押下時間の下限（秒）。
    /// 人間のキーストロークは概ね 50ms 以上かかるのに対し、これを下回る押下→離上は
    /// Raycast などが合成した Cmd+V のような偽イベントの可能性が高い。
    /// 20ms は合成イベントのスケジューリング遅延を考慮した安全側の閾値。
    private static let minimumAlonePressDuration: TimeInterval = 0.02

    /// 直前の Cmd-up からこの時間以内に発生した Cmd-down は、合成イベントによる
    /// modifier 状態のフリッカー（例: 日本語 IME での Cmd+V 後の Cmd 再アサート）と
    /// 見なす。人間が物理キーを離して再度押すには通常 80ms 以上かかるため、
    /// 50ms はフリッカーと意図的なダブルタップを区別できる安全な閾値。
    private static let commandFlickerWindow: TimeInterval = 0.05

    private let settings: Settings

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    private var lastFlags: CGEventFlags = []
    private var commandDownAt: Date?
    private var commandDownIsLeft = false
    private var otherKeyPressedWhileCommand = false
    private var lastCommandUpAt: Date?

    init(settings: Settings = .shared) {
        self.settings = settings
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
            // Cmd を押している最中に他キーの up/down が発生したら単独押しではない。
            //
            // 検出条件は OR で 2 つ:
            //   (a) commandDownAt != nil
            //       — 物理 Cmd-down が flagsChanged で確定済みの窓内
            //   (b) event.flags.contains(.maskCommand)
            //       — flagsChanged より先に keyDown/keyUp が届くレアケース用の保険
            //
            // ただし Raycast 等の上位フックが Cmd+V の V を消費するケースでは
            // どちらの条件も満たされず取りこぼす。その経路は Settings.aloneThreshold
            // を「チョン押しのみが収まる短い値」に絞ることで時間軸側から弾く。
            if commandDownAt != nil || event.flags.contains(.maskCommand) {
                otherKeyPressedWhileCommand = true
            }
            return Unmanaged.passUnretained(event)

        case .flagsChanged:
            handleFlagsChanged(event: event)
            return Unmanaged.passUnretained(event)

        default:
            return Unmanaged.passUnretained(event)
        }
    }

    private func handleFlagsChanged(event: CGEvent) {
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags

        let isLeft = keyCode == KeyCode.leftCommand
        let isRight = keyCode == KeyCode.rightCommand

        if isLeft || isRight {
            let nowDown = flags.contains(.maskCommand)
                && !lastFlags.contains(.maskCommand)
            let nowUp = !flags.contains(.maskCommand)
                && lastFlags.contains(.maskCommand)

            // 他プロセスが合成した Cmd イベント（Raycast の Cmd+V ペースト等）は
            // 物理キー押下と区別できないと誤発火するため、発生元 PID を確認する。
            // 実ハードウェア入力は PID = 0 で届く。
            let sourcePID = event.getIntegerValueField(.eventSourceUnixProcessID)
            let isSynthetic = sourcePID != 0

            if nowDown {
                if isSynthetic {
                    // 合成 down は単独押し検出の対象外。後続で物理 down が来た場合は
                    // この分岐に再度入らず nowDown ブランチで全状態が再設定される。
                    commandDownAt = nil
                } else {
                    // 直前 Cmd-up 直後の down はフリッカー（合成イベントによる
                    // modifier 状態の瞬断）の可能性があるため、その場合は
                    // otherKeyPressedWhileCommand をリセットしない。
                    let now = Date()
                    let isFlickerAfterUp = lastCommandUpAt.map {
                        now.timeIntervalSince($0) < Self.commandFlickerWindow
                    } ?? false

                    commandDownAt = now
                    commandDownIsLeft = isLeft
                    if !isFlickerAfterUp {
                        otherKeyPressedWhileCommand = false
                    }
                }
            } else if nowUp {
                let now = Date()
                if !isSynthetic,
                   let downAt = commandDownAt,
                   !otherKeyPressedWhileCommand
                {
                    let elapsed = now.timeIntervalSince(downAt)
                    if elapsed >= Self.minimumAlonePressDuration,
                       elapsed < settings.aloneThreshold
                    {
                        let assignment = commandDownIsLeft
                            ? settings.leftAssignment
                            : settings.rightAssignment
                        if let target = assignment.keyCode {
                            postKey(target)
                        }
                    }
                }
                commandDownAt = nil
                if !isSynthetic {
                    lastCommandUpAt = now
                }
            }
        }

        lastFlags = flags
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
