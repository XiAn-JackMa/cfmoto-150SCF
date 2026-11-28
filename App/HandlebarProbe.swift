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

    /// 锁屏才生效：开（默认）时只有设备锁屏音量键才当车把按键；关时不锁屏也生效。
    static var lockOnly: Bool {
        get {
            if UserDefaults.standard.object(forKey: "easyConnHandlebarLockOnly") == nil { return true }
            return UserDefaults.standard.bool(forKey: "easyConnHandlebarLockOnly")
        }
        set { UserDefaults.standard.set(newValue, forKey: "easyConnHandlebarLockOnly") }
    }

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
        // 只用数据保护状态判断锁屏；不用 applicationState（切到别的 App 也是后台，会误判）。
        screenLocked = !UIApplication.shared.isProtectedDataAvailable
        lock.unlock()
        observeLockState()
        // 拨回主用私有 API（AVSystemController，车机路径下也能写）；MPVolumeView 仅作
        // 非车机路径的备用。延迟到下一轮 runloop 备用挂窗。
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let hasPrivateAPI = NSClassFromString("AVSystemController") != nil
            _ = self.ensureVolumeView()
            self.onLog?("[车把] 拨回方式：私有 API \(hasPrivateAPI ? "可用" : "不可用")，MPVolumeView 备用")
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

    // MARK: 锁屏

    private func observeLockState() {
        removeLockObservers()
        let center = NotificationCenter.default
        // 只用 Data Protection 通知判断锁屏：它精确对应「设备锁屏/解锁」，
        // 不像 didEnterBackground 会把「切到别的 App（设备未锁屏）」误判成锁屏。
        lockObservers = [
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
            // 锁屏才生效开关：开时未锁屏就正常调音量；关时不锁屏也当车把按键。
            self.lock.lock(); let locked = self.screenLocked; self.lock.unlock()
            if Self.lockOnly && !locked {
                self.onLog?("[音量] 未锁屏：音量键正常调音量（\(Int(new * 100))%），不触发车把")
                return
            }
            let steps = abs(new - old)
            self.record(new > old ? "音量+" : "音量−",
                        String(format: "%.0f%% → %.0f%%（%.3f，约 %d 格）", old * 100, new * 100, steps,
                               Int((steps * 16).rounded())))
            self.handleVolume(direction: new > old ? 1 : -1)
        }
    }

    // MARK: 手势识别

    /// ▲/▼ 音量步进。双击判定纯按时间间隔：同方向第二次落在双击窗口内即双击，
    /// 否则第一次先憋住，窗口结束没有第二次才判单击。
    /// 注意步进大小随音量区间变化（低位一档 2 格、高位一档 1 格），不能拿步进当双击信号。
    private func handleVolume(direction: Int) {
        // 无论是否触发手势，都先把音量拨回目标值。
        restoreToTargetVolume()
        guard onControl != nil else { return }
        let now = Date()

        if let last = lastArrow[direction], now.timeIntervalSince(last) < HandlebarMapping.doubleTapWindow {
            // 双击窗口内的第二次：双击。
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
            view.showsRouteButton = false
            // 优先用旧 API（1.0.83 原版用的）：它在 Scene 与非 Scene 生命周期都返回窗口；
            // connectedScenes.windows 在窗口尚未完全建立时可能为空，导致挂窗失败。
            let window = UIApplication.shared.windows.first(where: { $0.isKeyWindow })
                ?? UIApplication.shared.windows.first
            window?.addSubview(view)
            view.setNeedsLayout()
            view.layoutIfNeeded()
            volumeView = view
            onLog?("[回拨] 挂窗 window=\(window != nil ? "有" : "无") subviews=\(view.subviews.count)")
            for (i, sub) in view.subviews.enumerated() {
                onLog?("[回拨]   sub[\(i)] = \(type(of: sub))")
            }
        }
        guard let view = volumeView else { return nil }
        if let slider = findVolumeSlider(in: view) { return slider }
        // slider 可能还没生成，再催一次布局后重找。
        view.setNeedsLayout()
        view.layoutIfNeeded()
        return findVolumeSlider(in: view)
    }

    /// 把系统音量写回用户设定的目标音量。回声在 startVolumeObservation 里按「值匹配」过滤。
    private func restoreToTargetVolume() {
        let target = Self.targetVolume
        onLog?("[回拨] 拨回目标音量 \(Self.targetVolumePercent)%")
        DispatchQueue.main.async { [weak self] in
            self?.writeVolume(target: target, attempt: 0)
        }
    }

    /// 优先用私有 API 直写媒体音量（车机路径下 MPVolumeView 无 slider，但 AVRCP 绝对音量
    /// 仍会同步），失败再退回 MPVolumeView（非车机路径）。
    private func writeVolume(target: Float, attempt: Int) {
        if setSystemVolume(target) {
            onLog?("[回拨] 已写入 \(Int(target * 100))%（私有 API）")
            return
        }
        if let slider = ensureVolumeView() {
            slider.value = target
            slider.sendActions(for: .touchUpInside)
            onLog?("[回拨] 已写入 \(Int(slider.value * 100))%（MPVolumeView）")
        } else if attempt < 3 {
            onLog?("[回拨] slider 未就绪，0.3 秒后重试（第 \(attempt + 1) 次）")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.writeVolume(target: target, attempt: attempt + 1)
            }
        } else {
            onLog?("[回拨] 未找到音量 slider，音量可能没有拨回")
        }
    }

    /// 私有 API：AVSystemController 设置系统媒体音量（0~1）。自用，非 App Store。
    /// 实现走 Bridging Header 的 C 函数（NSClassFromString + NSInvocation），避免链接私有符号。
    private func setSystemVolume(_ volume: Float) -> Bool {
        return tds_set_system_volume(volume)
    }

    private func findVolumeSlider(in view: UIView) -> UISlider? {
        if let slider = view as? UISlider { return slider }
        for subview in view.subviews {
            if let found = findVolumeSlider(in: subview) { return found }
        }
        return nil
    }
}
