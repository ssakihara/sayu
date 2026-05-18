import AppKit
import ApplicationServices

/// アクセシビリティ権限の付与状況をメインスレッド上のタイマーで監視する。
///
/// macOS は権限が付与されたタイミングでアプリへ通知する公式手段を持たないため、
/// 一定間隔の `AXIsProcessTrusted()` ポーリングで検知する。
final class PermissionWatcher {
    private let interval: TimeInterval
    private var timer: Timer?
    private var onGranted: (() -> Void)?

    init(interval: TimeInterval = 1.5) {
        self.interval = interval
    }

    deinit {
        stop()
    }

    /// 監視を開始する。既に許可済みなら次のランループで `onGranted` を発火する。
    func start(onGranted: @escaping () -> Void) {
        guard timer == nil else { return }
        self.onGranted = onGranted

        if AXIsProcessTrusted() {
            DispatchQueue.main.async { [weak self] in
                self?.fire()
            }
            return
        }

        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            guard let self else { return }
            if AXIsProcessTrusted() {
                fire()
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        onGranted = nil
    }

    private func fire() {
        guard let callback = onGranted else { return }
        stop()
        callback()
    }
}
