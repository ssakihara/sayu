import AppKit

/// アクセシビリティ + 入力監視の両権限の付与状況をメインスレッド上のタイマーで監視する。
///
/// macOS は権限が付与されたタイミングでアプリへ通知する公式手段を持たないため、
/// 一定間隔でポーリングして状態変化（granted⇔denied のトグル）を検知する。
/// 「次の不足権限のペインを自動で開く」「全権限揃ったら再起動アラートを出す」
/// のためのハンドラを購読者側で実装する。
final class PermissionWatcher {
    private let interval: TimeInterval
    private var timer: Timer?
    private var onChanged: (() -> Void)?
    private var lastSnapshot: Snapshot?

    init(interval: TimeInterval = 1.5) {
        self.interval = interval
    }

    deinit {
        stop()
    }

    /// 監視を開始する。`onChanged` は購読者が状態を読み直すきっかけ。
    /// 既に全権限揃っていれば次のランループで一度発火する。
    func start(onChanged: @escaping () -> Void) {
        guard timer == nil else { return }
        self.onChanged = onChanged
        lastSnapshot = Snapshot.current

        if Permissions.allGranted {
            DispatchQueue.main.async { [weak self] in
                self?.fire()
            }
            return
        }

        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            guard let self else { return }
            let current = Snapshot.current
            guard current != lastSnapshot else { return }
            lastSnapshot = current
            fire()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        onChanged = nil
        lastSnapshot = nil
    }

    private func fire() {
        guard let callback = onChanged else { return }
        callback()
    }

    private struct Snapshot: Equatable {
        let accessibility: Bool
        let inputMonitoring: Bool

        static var current: Snapshot {
            Snapshot(
                accessibility: Permissions.hasAccessibility,
                inputMonitoring: Permissions.hasInputMonitoring
            )
        }
    }
}
