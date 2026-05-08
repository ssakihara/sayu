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

    private let settings: Settings

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    private var lastFlags: CGEventFlags = []
    private var commandDownAt: Date?
    private var commandDownIsLeft = false
    private var otherKeyPressedWhileCommand = false

    init(settings: Settings = .shared) {
        self.settings = settings
    }

    func start() {
        guard eventTap == nil else { return }

        let mask = (1 << CGEventType.flagsChanged.rawValue)
                 | (1 << CGEventType.keyDown.rawValue)

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
            userInfo: Unmanaged.passUnretained(self).toOpaque(),
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
        event: CGEvent,
    ) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)

        case .keyDown:
            if lastFlags.contains(.maskCommand) {
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
                    commandDownAt = Date()
                    commandDownIsLeft = isLeft
                    otherKeyPressedWhileCommand = false
                }
            } else if nowUp {
                if !isSynthetic,
                   let downAt = commandDownAt,
                   !otherKeyPressedWhileCommand {
                    let elapsed = Date().timeIntervalSince(downAt)
                    if elapsed >= Self.minimumAlonePressDuration,
                       elapsed < settings.aloneThreshold {
                        let assignment = commandDownIsLeft
                            ? settings.leftAssignment
                            : settings.rightAssignment
                        if let target = assignment.keyCode {
                            postKey(target)
                        }
                    }
                }
                commandDownAt = nil
            }
        }

        lastFlags = flags
    }

    private func postKey(_ keyCode: CGKeyCode) {
        let source = CGEventSource(stateID: .hidSystemState)
        let down = CGEvent(
            keyboardEventSource: source,
            virtualKey: keyCode,
            keyDown: true,
        )
        let up = CGEvent(
            keyboardEventSource: source,
            virtualKey: keyCode,
            keyDown: false,
        )
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}
