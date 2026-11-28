// SPDX-License-Identifier: AGPL-3.0-only
//
// 春风 EasyConn 车把按键（只走音量通道）。
//
// 150SCF 是非触摸仪表，车把 ▲▼ 以「蓝牙 AVRCP 绝对音量」形式到达手机：每次按键真的改变
// 系统音量。这里监听 outputVolume 的变化，锁屏时把它当作车把按键（单击/双击），转成
// CarPlay 控制，然后立刻把音量写回用户设定的目标音量——所以骑多久音量都不漂。
//
// 只走音量通道，因此不接管「正在播放」：SET 与 ▲▼ 长按等传输键本来就不需要，全部砍掉。

import AVFoundation
import Foundation
import MediaPlayer
import UIKit

/// 一条原始按键记录，设置页的日志区用。
struct HandlebarRawSample: Identifiable, Sendable, Equatable {
    let id = UUID()
    let date: Date
    /// 例如 "音量+"、"音量−"。
    let source: String
    /// 附加信息：音量变化范围、步数等。
    let detail: String
}

final class HandlebarProbe: @unchecked Sendable {
    /// 每观察到一条事件就回调（主线程）。
    var onSample: ((HandlebarRawSample) -> Void)?
    var onLog: ((String) -> Void)?
    /// 识别出手势后，把对应的 CarPlay 控制交给 App（主线程）。
    var onControl: ((CarPlayControl) -> Void)?

    // MARK: 设置（持久化，长期生效）

    /// 车把按键控制总开关。开启后 App 启动自动生效。
    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "easyConnHandlebarEnabled") }
        set { UserDefaults.standard.set(newValue, forKey: "easyConnHandlebarEnabled") }
    }

    /// 目标音量（0–100）。每次按键后把系统音量拨回这个值。
    static var targetVolumePercent: Int {
        get {
            let v = UserDefaults.standard.integer(forKey: "easyConnHandlebarTargetVolume")
            return (1 ... 100).contains(v) ? v : 50
        }
        set { UserDefaults.standard.set(min(100, max(1, newValue)), forKey: "easyConnHandlebarTargetVolume") }
    }

    /// 目标音量换算成 0…1。
    static var targetVolume: Float { Float(targetVolumePercent) / 100 }

    // MARK: 状态

    private var volumeObservation: NSKeyValueObservation?
    private var lockObservers: [NSObjectProtocol] = []
    /// 设备是否锁屏。只有锁屏时才把音量键当车把按键。
    private var screenLocked = false
    private(set) var isRunning = false

    // 双击识别：每个方向记录上一次按下的时间，第二次落在双击窗口内即双击。
    private var lastArrow: [Int: Date] = [:]
    /// 第一次按下后延迟触发单击的定时器（等双击窗口关闭）。
    private var singleDelayTimers: [Int: Timer] = [:]

    /// 拨回音量用的离屏 MPVolumeView：只有挂到窗口，slider 写值才会真的改变系统音量。
    private var volumeView: MPVolumeView?

    // 日志环
    private let lock = NSLock()
    private var samples: [HandlebarRawSample] = []
    private var eventSequence = 0
    private var lastEventAt: Date?

    // MARK: 日志

    private func record(_ source: String, _ detail: String = "") {
        let now = Date()
        let seq: Int
        let delta: String
        lock.lock()
        eventSequence += 1
        seq = eventSequence
        delta = lastEventAt.map { String(format: "+%.0fms", now.timeIntervalSince($0) * 1000) } ?? "首个"
        lastEventAt = now
        let sample = HandlebarRawSample(date: now, source: source, detail: detail)
        samples.append(sample)
        if samples.count > 60 { samples.removeFirst(samples.count - 60) }
        lock.unlock()
        onLog?("[按键 #\(seq) \(delta)] \(source)\(detail.isEmpty ? "" : " · \(detail)")")
        DispatchQueue.main.async { [weak self] in self?.onSample?(sample) }
    }

    var recent: [HandlebarRawSample] {
        lock.lock(); defer { lock.unlock() }
        return samples
    }

    /// 已观察到的条数，用于设置页「有没有收到」的廉价判断。
    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return samples.count
    }

    // MARK: 生命周期

    func start() {
        guard !isRunning else { return }
        isRunning = true
        lock.lock()
        // 锁屏/后台都可作为「骑行中」的信号。isProtectedDataAvailable 在 App 未启用
        // Data Protection 时始终为 true，因此再叠加 applicationState == .background 兜底。
        screenLocked = UIApplication.shared.applicationState == .background
            || !UIApplication.shared.isProtectedDataAvailable
        lock.unlock()
        observeLockState()
        // 前台时就预创建 MPVolumeView 并挂窗，让内部 slider 先生成；锁屏后台再挂窗
        // 往往拿不到窗口。延迟到下一轮 runloop，确保 keyWindow 已建立。
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.ensureVolumeView() != nil {
                self.onLog?("[车把] 音量拨回视图已就绪")
            } else {
                self.onLog?("[车把] 音量拨回视图未就绪：前台挂窗失败，锁屏后将无法拨回")
            }
        }
        startVolumeObservation()
        onLog?("[车把] 已启用：锁屏/后台时音量键＝车把按键，目标音量 \(Self.targetVolumePercent)%")
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        volumeObservation?.invalidate()
        volumeObservation = nil
        singleDelayTimers.values.forEach { $0.invalidate() }
        singleDelayTimers.removeAll()
        lastArrow.removeAll()
        volumeView?.removeFromSuperview()
        volumeView = nil
        removeLockObservers()
        onLog?("[车把] 已停用")
    }

    // MARK: 锁屏 / 后台

    private func observeLockState() {
        removeLockObservers()
        let center = NotificationCenter.default
        lockObservers = [
            // 进后台（锁屏、切 App）→ 当作骑行中，音量键开始驱动 CarPlay。
            center.addObserver(forName: UIApplication.didEnterBackgroundNotification,
                               object: nil, queue: .main) { [weak self] _ in
                guard let self else { return }
                self.lock.lock(); self.screenLocked = true; self.lock.unlock()
                self.onLog?("[车把] 已进入后台：音量键开始当作车把按键")
            },
            // 回前台（解锁、切回）→ 音量键恢复正常调音量。
            center.addObserver(forName: UIApplication.willEnterForegroundNotification,
                               object: nil, queue: .main) { [weak self] _ in
                guard let self else { return }
                self.lock.lock(); self.screenLocked = false; self.lock.unlock()
                self.onLog?("[车把] 已回前台：音量键恢复正常调音量")
            },
            // 若 App 启用了 Data Protection，锁屏/解锁会更精确，也一并监听。
            center.addObserver(forName: UIApplication.protectedDataWillBecomeUnavailableNotification,
                               object: nil, queue: .main) { [weak self] _ in
                guard let self else { return }
                self.lock.lock(); self.screenLocked = true; self.lock.unlock()
                self.onLog?("[车把] 已锁屏（数据保护）：音量键开始当作车把按键")
            },
            center.addObserver(forName: UIApplication.protectedDataDidBecomeAvailableNotification,
                               object: nil, queue: .main) { [weak self] _ in
                guard let self else { return }
                self.lock.lock(); self.screenLocked = false; self.lock.unlock()
                self.onLog?("[车把] 已解锁（数据保护）：音量键恢复正常调音量")
            },
            // 每次回到前台活跃时，确保拨回用的 MPVolumeView 已就绪（锁屏拨回复用它）。
            center.addObserver(forName: UIApplication.didBecomeActiveNotification,
                               object: nil, queue: .main) { [weak self] _ in
                guard let self else { return }
                _ = self.ensureVolumeView()
            }
        ]
    }

    private func removeLockObservers() {
        lockObservers.forEach { NotificationCenter.default.removeObserver($0) }
        lockObservers = []
    }

    // MARK: 音量观察

    private func startVolumeObservation() {
        let session = AVAudioSession.sharedInstance()
        record("起始音量", String(format: "%.0f%%", session.outputVolume * 100))
        volumeObservation = session.observe(\.outputVolume, options: [.old, .new]) { [weak self] _, change in
            guard let self, let old = change.oldValue, let new = change.newValue, old != new else { return }
            // 回声过滤：new 落在目标音量附近（半格内），就是自己刚拨回的那次，忽略。
            if abs(new - Self.targetVolume) < 0.032 { return }
            // 没锁屏：音量键就是正常调音量，不触发、不拨回。
            self.lock.lock(); let locked = self.screenLocked; self.lock.unlock()
            guard locked else { return }
            let steps = abs(new - old)
            self.record(new > old ? "音量+" : "音量−",
                        String(format: "%.0f%% → %.0f%%（%.3f，约 %d 格）", old * 100, new * 100, steps,
                               Int((steps * 16).rounded())))
            self.handleVolume(direction: new > old ? 1 : -1, steps: steps)
        }
    }

    // MARK: 手势识别

    /// ▲/▼ 音量步进。一次 ≥0.075 的跳变是固件把快速双击合并成的一大步，直接判双击；
    /// 否则第一次按下先憋住，双击窗口内来了第二次就判双击，窗口结束没有第二次才判单击。
    private func handleVolume(direction: Int, steps: Float) {
        // 无论是否触发手势，都先把音量拨回目标值。
        restoreToTargetVolume()
        guard onControl != nil else { return }
        let now = Date()

        if steps >= 0.075 {
            // 固件合并了快速双击。
            cancelPendingSingle(direction)
            lastArrow[direction] = nil
            onLog?("[手势] 步进 \(String(format: "%.3f", steps)) ≥ 0.075，固件已合并 → 双击")
            fire(direction > 0 ? .arrowUpDouble : .arrowDownDouble)
            return
        }

        if let last = lastArrow[direction], now.timeIntervalSince(last) < HandlebarMapping.doubleTapWindow {
            // 双击窗口内的第二次：慢双击。
            cancelPendingSingle(direction)
            lastArrow[direction] = nil
            onLog?("[手势] 与上次间隔 \(String(format: "%.0f", now.timeIntervalSince(last) * 1000))ms → 双击（取消单击）")
            fire(direction > 0 ? .arrowUpDouble : .arrowDownDouble)
            return
        }

        // 第一次：可能还是双击的前半段，先延迟单击。
        lastArrow[direction] = now
        cancelPendingSingle(direction)
        let d = direction
        let timer = Timer(timeInterval: HandlebarMapping.doubleTapWindow, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.lastArrow[d] = nil
            self.singleDelayTimers[d] = nil
            guard self.onControl != nil else { return }
            self.onLog?("[手势] 双击窗口结束，无第二次 → 单击")
            self.fire(d > 0 ? .arrowUpShort : .arrowDownShort)
        }
        RunLoop.main.add(timer, forMode: .common)
        singleDelayTimers[direction] = timer
        onLog?("[手势] 记录 \(direction > 0 ? "▲" : "▼") 首次按下，等待双击窗口 \(String(format: "%.0f", HandlebarMapping.doubleTapWindow * 1000))ms")
    }

    private func cancelPendingSingle(_ direction: Int) {
        singleDelayTimers[direction]?.invalidate()
        singleDelayTimers[direction] = nil
    }

    /// 按映射表执行一个手势。
    private func fire(_ gesture: HandlebarGesture) {
        let action = HandlebarMapping.action(for: gesture)
        guard action != .none, let control = action.control else { return }
        record("→ \(gesture.title) = \(action.title)")
        DispatchQueue.main.async { [weak self] in self?.onControl?(control) }
    }

    // MARK: 拨回目标音量

    /// 离屏 MPVolumeView 挂到窗口上，返回它内部的 UISlider。slider 是懒生成的，所以
    /// 尽量在 App 前台时先调用一次（start 里），后台复用同一个实例。
    private func ensureVolumeView() -> UISlider? {
        if volumeView == nil {
            let view = MPVolumeView(frame: CGRect(x: -1000, y: -1000, width: 100, height: 100))
            view.alpha = 0.01
            let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
            let window = scene?.windows.first(where: { $0.isKeyWindow }) ?? scene?.windows.first
            window?.addSubview(view)
            view.setNeedsLayout()
            view.layoutIfNeeded()
            volumeView = view
        }
        guard let view = volumeView else { return nil }
        if let slider = findVolumeSlider(in: view) { return slider }
        // slider 可能还没生成，再催一次布局并等下一轮 runloop 重找。
        view.setNeedsLayout()
        view.layoutIfNeeded()
        return findVolumeSlider(in: view)
    }

    /// 把系统音量写回用户设定的目标音量。回声在 startVolumeObservation 里按「值匹配」过滤。
    private func restoreToTargetVolume() {
        let target = Self.targetVolume
        onLog?("[回拨] 拨回目标音量 \(Self.targetVolumePercent)%")
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if let slider = self.ensureVolumeView() {
                slider.value = target
                slider.sendActions(for: .touchUpInside)
                self.onLog?("[回拨] 已写入 \(Int(slider.value * 100))%")
            } else {
                self.onLog?("[回拨] 未找到音量 slider，音量可能没有拨回")
            }
        }
    }

    private func findVolumeSlider(in view: UIView) -> UISlider? {
        if let slider = view as? UISlider { return slider }
        for subview in view.subviews {
            if let found = findVolumeSlider(in: subview) { return found }
        }
        return nil
    }
}
