// SPDX-License-Identifier: AGPL-3.0-only
//
// Probe for the motorcycle's handlebar buttons.
//
// The dash's buttons never travel over the EasyConn/Wi-Fi link: they are Bluetooth AVRCP commands
// from the bike's BT module (docs/spec/input-controls.md §7). On iOS an app only sees AVRCP
// transport keys while it is the "Now Playing" app, and on the non-touch dashes (this bike is one:
// its CLIENT_INFO reports supportScreenTouch=false) ▲▼ arrive as absolute-volume steps rather than
// key events.
//
// Measured on a 150SCF (probe run, 2026-11-23), which is why the mapping below looks like this:
//   ▲▼        absolute-volume steps, one press = 0.05; a fast double is merged by the firmware into
//             one 0.10 step, so a double is only visible as a bigger jump.
//   enter     togglePlayPauseCommand (sometimes a bare next/previous arrives instead).
//   holds     none: the dash never sends seek/FAST_FORWARD, so no key has a real press/release pair.
// So ▲▼ turn the wheel, a merged double steps once and then goes Back (a way out of a screen), enter
// (which arrives only as play/pause = the held press) maps straight to Select, and a bare track key
// is treated as the same notch.

import AVFoundation
import Foundation
import MediaPlayer
import UIKit

/// One raw event as observed on the phone.
struct HandlebarRawSample: Identifiable, Sendable, Equatable {
    let id = UUID()
    let date: Date
    /// e.g. "playCommand", "togglePlayPauseCommand", "volume+" — the thing the bike actually sent.
    let source: String
    /// Extra detail: volume old→new, seek begin/end.
    let detail: String
}

final class HandlebarProbe: @unchecked Sendable {
    /// Called on the main thread for every observed event.
    var onSample: ((HandlebarRawSample) -> Void)?
    var onLog: ((String) -> Void)?
    /// When set, raw events are also turned into CarPlay controls. Nil = observe only.
    var onControl: ((CarPlayControl) -> Void)?

    /// What the bike actually sends, measured on a 150SCF (see the class comment):
    /// ▲▼ = absolute-volume steps, enter = togglePlayPause (and sometimes a bare next/previous),
    /// no seek events at all, so there is no server-side hold.

    /// Last ▲ and ▼ press, per direction: a second press on the same arrow inside the window is a
    /// double (the firmware merges a very fast one into a single bigger step, handled below).
    private var lastArrow: [Int: Date] = [:]
    /// Volume before we dial it back, so a ▲▼ press does not accumulate to full scale.
    private var restoringVolume = false
    private var savedVolume: Float?
    /// Held-arrow repeat: while the dash keeps sending track keys, keep scrolling.
    private var repeatTimer: Timer?
    private var heldRepeatCount = 0
    private let heldRepeatInterval: TimeInterval = 0.12
    private let heldRepeatLimit = 40
    /// Monotonic event counter and last-event time, so every raw line shows its own timing relative
    /// to the previous press - that is what tells a single from a double in the log.
    private var eventSequence = 0
    private var lastEventAt: Date?

    private let lock = NSLock()
    private var samples: [HandlebarRawSample] = []
    private var commandTargets: [(MPRemoteCommand, Any)] = []
    private var volumeObservation: NSKeyValueObservation?
    private var silent: AVAudioPlayer?
    private var nowPlayingObservers: [NSObjectProtocol] = []
    private var nowPlayingWatchdog: Timer?
    private var nowPlayingRestarts = 0
    private var nowPlayingTicks = 0
    private(set) var isRunning = false

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

    /// Number of samples seen, for a cheap "is anything arriving at all" check.
    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return samples.count
    }

    // MARK: - Lifecycle

    /// Registers every remote command and starts watching the volume.
    ///
    /// Deliberately does NOT try to become Now Playing by itself: `becomeNowPlaying` below is what a
    /// test has to call, and whether the bike displaces other audio is exactly what the probe reports.
    func start() {
        guard !isRunning else { return }
        isRunning = true
        registerCommands()
        startVolumeObservation()
        onLog?("[探测] 车把按键探测已启动（未接管音频会话）")
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        for (command, target) in commandTargets {
            command.removeTarget(target)
            command.isEnabled = false
        }
        commandTargets.removeAll()
        volumeObservation?.invalidate()
        volumeObservation = nil
        repeatTimer?.invalidate(); repeatTimer = nil
        stopNowPlayingKeepAlive()
        silent?.stop()
        silent = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        onLog?("[探测] 车把按键探测已停止")
    }

    // MARK: - Commands

    private func registerCommands() {
        let center = MPRemoteCommandCenter.shared()

        func add(_ command: MPRemoteCommand, _ name: String) {
            command.isEnabled = true
            let target = command.addTarget { [weak self] _ in
                self?.record(name)
                return .success
            }
            commandTargets.append((command, target))
        }

        center.playCommand.isEnabled = true
        commandTargets.append((center.playCommand, center.playCommand.addTarget { [weak self] _ in
            self?.record("playCommand"); self?.handleSelect(); return .success
        }))
        center.pauseCommand.isEnabled = true
        commandTargets.append((center.pauseCommand, center.pauseCommand.addTarget { [weak self] _ in
            self?.record("pauseCommand"); self?.handleSelect(); return .success
        }))
        center.togglePlayPauseCommand.isEnabled = true
        commandTargets.append((center.togglePlayPauseCommand, center.togglePlayPauseCommand.addTarget { [weak self] _ in
            self?.record("togglePlayPauseCommand"); self?.handleSelect(); return .success
        }))
        center.nextTrackCommand.isEnabled = true
        commandTargets.append((center.nextTrackCommand, center.nextTrackCommand.addTarget { [weak self] _ in
            self?.record("nextTrackCommand"); self?.handleTrack(forward: true); return .success
        }))
        center.previousTrackCommand.isEnabled = true
        commandTargets.append((center.previousTrackCommand, center.previousTrackCommand.addTarget { [weak self] _ in
            self?.record("previousTrackCommand"); self?.handleTrack(forward: false); return .success
        }))

        // Seek commands are how a long press usually surfaces; without them a hold looks like a tap.
        center.skipForwardCommand.isEnabled = true
        commandTargets.append((center.skipForwardCommand, center.skipForwardCommand.addTarget { [weak self] _ in
            self?.record("skipForwardCommand")
            return .success
        }))
        center.skipBackwardCommand.isEnabled = true
        commandTargets.append((center.skipBackwardCommand, center.skipBackwardCommand.addTarget { [weak self] _ in
            self?.record("skipBackwardCommand")
            return .success
        }))

        center.seekForwardCommand.isEnabled = true
        commandTargets.append((center.seekForwardCommand, center.seekForwardCommand.addTarget { [weak self] event in
            guard let seek = event as? MPSeekCommandEvent else { return .commandFailed }
            self?.record("seekForwardCommand", seek.type == .beginSeeking ? "按住开始" : "按住结束")
            return .success
        }))
        center.seekBackwardCommand.isEnabled = true
        commandTargets.append((center.seekBackwardCommand, center.seekBackwardCommand.addTarget { [weak self] event in
            guard let seek = event as? MPSeekCommandEvent else { return .commandFailed }
            self?.record("seekBackwardCommand", seek.type == .beginSeeking ? "按住开始" : "按住结束")
            return .success
        }))

        // Everything else: recorded so a firmware surprise shows up instead of being ignored.
        center.changePlaybackPositionCommand.isEnabled = true
        commandTargets.append((center.changePlaybackPositionCommand,
                               center.changePlaybackPositionCommand.addTarget { [weak self] event in
            let time = (event as? MPChangePlaybackPositionCommandEvent)?.positionTime ?? 0
            self?.record("changePlaybackPositionCommand", "位置 \(Int(time))s")
            return .success
        }))
        center.stopCommand.isEnabled = true
        commandTargets.append((center.stopCommand, center.stopCommand.addTarget { [weak self] _ in
            self?.record("stopCommand")
            return .success
        }))
    }

    // MARK: - Volume (▲▼ on a non-touch dash)

    private func startVolumeObservation() {
        let session = AVAudioSession.sharedInstance()
        record("起始音量", String(format: "%.2f", session.outputVolume))
        volumeObservation = session.observe(\.outputVolume, options: [.old, .new]) { [weak self] _, change in
            guard let self, let old = change.oldValue, let new = change.newValue, old != new else { return }
            // Our own dial-back must not look like another press.
            guard !self.restoringVolume else { return }
            let steps = abs(new - old)
            self.record(new > old ? "音量+" : "音量−",
                        String(format: "%.2f → %.2f（%.3f，约 %d 格）", old, new, steps, Int((steps * 16).rounded())))
            self.handleVolume(direction: new > old ? 1 : -1, steps: steps)
        }
    }

    // MARK: - Raw events → CarPlay controls
    //
    // What this dashboard gives the phone (measured, and matches the owner's manual):
    //   ▲▼ short   absolute-volume step (+/- 0.05) — and the manual says it also means "previous /
    //              next item" on menus, which is what we map it to. Because the volume really moves,
    //              every step is undone below, or 20 presses would leave ▲ with nothing to send.
    //   ▲▼ long    previousTrack / nextTrack — a separate, clean event.
    //   SET long   togglePlayPause.
    //   SET short  consumed by the dash (opens its settings menu) — the phone never sees it.
    //   BACK       consumed by the dash — the phone never sees it.
    // So confirm and back cannot come from their own buttons and are built from doubles.

    /// ▲/▼ short press. A second press on the same arrow inside the window is a double; a jump the
    /// firmware merged is a double by itself.
    private func handleVolume(direction: Int, steps: Float) {
        restoreVolume(direction: direction, steps: steps)
        guard onControl != nil else { return }
        let now = Date()

        if steps >= Float(0.075) {
            // The firmware merged a fast double into one bigger step.
            lastArrow.removeAll()
            onLog?("[手势] 步进 \(String(format: "%.3f", steps)) ≥ 0.075，固件已合并 → 双击")
            fire(direction > 0 ? .arrowUpDouble : .arrowDownDouble)
            return
        }

        if let last = lastArrow[direction], now.timeIntervalSince(last) < HandlebarMapping.doubleTapWindow {
            lastArrow.removeAll()
            onLog?("[手势] 与上次间隔 \(String(format: "%.0f", now.timeIntervalSince(last) * 1000))ms < 双击窗口 \(String(format: "%.0f", HandlebarMapping.doubleTapWindow * 1000))ms → 双击")
            fire(direction > 0 ? .arrowUpDouble : .arrowDownDouble)
            return
        }
        lastArrow[direction] = now
        onLog?("[手势] 记录 \(direction > 0 ? "▲" : "▼") 单击，进入双击窗口")
        fire(direction > 0 ? .arrowUpShort : .arrowDownShort)
    }

    /// Puts the system volume back where the press found it, so ▲▼ stay usable at full scale.
    ///
    /// The dash reads its own arrow as a volume key, so the phone's volume is a side effect of
    /// navigating. Restoring it needs no UI: `MPVolumeView`'s slider is the supported way to write
    /// `outputVolume`, and the change it makes is filtered out so it is not taken for another press.
    private func restoreVolume(direction: Int, steps: Float) {
        let session = AVAudioSession.sharedInstance()
        let current = session.outputVolume
        let target = max(0, min(1, current - (direction > 0 ? steps : -steps)))
        restoringVolume = true
        onLog?("[回拨] 音量 \(String(format: "%.3f", current)) → \(String(format: "%.3f", target))（\(direction > 0 ? "↑" : "↓") 回拨 \(String(format: "%.3f", steps))）")
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            var foundSlider = false
            let slider = MPVolumeView(frame: CGRect(x: -1000, y: -1000, width: 1, height: 1))
            for view in slider.subviews {
                guard let control = view as? UISlider else { continue }
                control.value = target
                control.sendActions(for: .touchUpInside)
                foundSlider = true
                break
            }
            if !foundSlider {
                self.onLog?("[回拨] 未找到音量 slider，音量可能没有拨回")
            }
            // The write echoes back through the observer; ignore it, then allow presses again.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { self.restoringVolume = false }
        }
    }

    /// SET reaches the phone only as a play/pause command, and only when SET is HELD: a short SET
    /// opens the dash's own settings menu and the phone never sees it. So the play/pause event here
    /// IS the long press — there is no press/release pair to time, and the old 0.12 s / 0.60 s
    /// timers always resolved to "short" before the hold could ever fire.
    private func handleSelect() {
        guard onControl != nil else { return }
        let music = AVAudioSession.sharedInstance().isOtherAudioPlaying
        onLog?("[SET] 收到（播放/暂停 = SET 长按，直接映射）· 此刻其它音频在播 \(music ? "是" : "否")")
        fire(.setLong)
    }

    /// ▲/▼ long press: a clean track key with no volume side effect. A held arrow keeps sending them,
    /// so they can either keep scrolling (repeat) or act once.
    private func handleTrack(forward: Bool) {
        guard onControl != nil else { return }
        lastArrow[forward ? 1 : -1] = nil
        let music = AVAudioSession.sharedInstance().isOtherAudioPlaying
        onLog?("[按键] \(forward ? "下一曲(▼长按)" : "上一曲(▲长按)") 收到 · 此刻其它音频在播 \(music ? "是" : "否")")
        let gesture: HandlebarGesture = forward ? .arrowDownLong : .arrowUpLong
        let action = HandlebarMapping.action(for: gesture)
        if action == .none { return }
        fire(gesture)
        guard HandlebarMapping.repeatsWhenHeld, action == .knobNext || action == .knobPrevious else { return }
        startHeldRepeat(action)
    }

    /// Keeps scrolling while the dash keeps sending track keys. Each new event restarts the timer, so
    /// letting go stops it within one interval.
    private func startHeldRepeat(_ action: HandlebarAction) {
        repeatTimer?.invalidate()
        repeatTimer = Timer.scheduledTimer(withTimeInterval: heldRepeatInterval, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.onControl?(action.control ?? .select)
            self.heldRepeatCount += 1
            if self.heldRepeatCount >= self.heldRepeatLimit {
                self.repeatTimer?.invalidate(); self.repeatTimer = nil
            }
        }
    }

    /// Runs the configured action for a gesture.
    private func fire(_ gesture: HandlebarGesture) {
        let action = HandlebarMapping.action(for: gesture)
        guard action != .none, let control = action.control else { return }
        record("→ \(gesture.title) = \(action.title)", "")
        onControl?(control)
    }

    // MARK: - Now Playing claim (what makes the keys arrive at all)

    /// Whether this app currently looks like the "Now Playing" app, which is the condition iOS puts
    /// on delivering AVRCP transport keys. `nowPlayingInfo` is the cheap proxy the UI reads; the
    /// watchdog below also checks that the silent loop is actually still playing, because a cleared
    /// or interrupted session can keep the info while the keys have already moved to the music app.
    var isNowPlaying: Bool { MPNowPlayingInfoCenter.default().nowPlayingInfo != nil }

    /// Publishes Now Playing info and starts a near-silent loop, so the bike sends its keys here
    /// instead of to the music app. Because the loop is mixed (`.mixWithOthers`) it no longer pauses
    /// the user's music; the probe reports whether the claim worked rather than pretending.
    @discardableResult
    func becomeNowPlaying() -> Bool {
        logAudioState("接管前")
        let ok = replaySilentLoop()
        if ok {
            let music = AVAudioSession.sharedInstance().isOtherAudioPlaying
            record("已接管正在播放（混音模式，不暂停音乐）",
                   music ? "检测到其它音频仍在播" : "当前没有其它音频")
            startNowPlayingKeepAlive()
        } else {
            onLog?("[探测] 接管播放失败（此时车机会继续把按键发给音乐 App）")
        }
        return ok
    }

    /// Rebuilds the silent loop and the Now Playing info. Factored out so the first claim and the
    /// watchdog's revive share exactly the same path.
    ///
    /// Uses `.mixWithOthers` on purpose: the old exclusive `[]` category paused the user's music and
    /// fought BackgroundKeepAlive for the same session. Mixing keeps music playing and still sets
    /// `nowPlayingInfo`, which is what the bike's transport keys are supposed to follow.
    @discardableResult
    private func replaySilentLoop() -> Bool {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
            let player = try AVAudioPlayer(data: BackgroundKeepAlive.silentLoopData,
                                           fileTypeHint: AVFileType.wav.rawValue)
            player.numberOfLoops = -1
            player.volume = 0.01
            player.prepareToPlay()
            guard player.play() else {
                onLog?("[保活] 静音循环被系统拒绝播放")
                return false
            }
            silent = player
            MPNowPlayingInfoCenter.default().nowPlayingInfo = [
                MPMediaItemPropertyTitle: "CarWithin",
                MPMediaItemPropertyArtist: "车把按键探测",
                MPNowPlayingInfoPropertyPlaybackRate: 1.0,
                MPNowPlayingInfoPropertyIsLiveStream: true
            ]
            logAudioState("接管后")
            return true
        } catch {
            onLog?("[保活] 重建静音循环失败：\(error.localizedDescription)")
            return false
        }
    }

    /// Watches the Now Playing claim. The silent loop is the only thing keeping the bike's keys
    /// arriving here; if it stops (interruption, route change, another app taking the session) the
    /// keys silently leak to the music app, so every death is revived and logged with its reason.
    private func startNowPlayingKeepAlive() {
        stopNowPlayingKeepAlive()
        nowPlayingRestarts = 0
        nowPlayingTicks = 0
        let center = NotificationCenter.default
        nowPlayingObservers = [
            center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
                guard let self else { return }
                let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt ?? 0
                let reason = note.userInfo?[AVAudioSessionInterruptionReasonKey] as? UInt ?? 0
                let kind = AVAudioSession.InterruptionType(rawValue: raw) == .ended ? "结束" : "开始"
                self.onLog?("[保活] 音频中断：\(kind)（type=\(raw) reason=\(reason)）")
                self.logAudioState("中断时")
                if AVAudioSession.InterruptionType(rawValue: raw) == .ended {
                    self.reviveNowPlaying(reason: "音频中断结束")
                }
            },
            center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
                guard let self else { return }
                self.onLog?("[保活] 系统媒体服务重置")
                self.silent = nil
                self.reviveNowPlaying(reason: "媒体服务重置")
            },
            center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
                guard let self else { return }
                let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt ?? 0
                self.onLog?("[保活] 音频路由变化（reason=\(raw)）")
                self.logAudioState("路由变化时")
                if self.silent?.isPlaying != true {
                    self.reviveNowPlaying(reason: "路由变化")
                }
            }
        ]
        // Catches everything else (session deactivated, category changed, player stopped) — the
        // observers only cover the events iOS bothers to announce.
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.nowPlayingTicks += 1
            let playing = self.silent?.isPlaying == true
            let claimed = MPNowPlayingInfoCenter.default().nowPlayingInfo != nil
            if !playing || !claimed {
                self.reviveNowPlaying(reason: playing ? "nowPlayingInfo 丢失" : "静音循环停止")
            } else if self.nowPlayingTicks % 15 == 0 {
                self.onLog?("[保活] 心跳正常（第 \(self.nowPlayingTicks) 次检查 · 静音在播 · NowPlaying 已声明 · 其它音频在播 \(AVAudioSession.sharedInstance().isOtherAudioPlaying ? "是" : "否")）")
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        nowPlayingWatchdog = timer
        onLog?("[保活] 已开始监视 Now Playing（每 2 秒查一次，断了就重建并记录原因）")
    }

    private func reviveNowPlaying(reason: String) {
        nowPlayingRestarts += 1
        logAudioState("恢复前（\(reason)）")
        let ok = replaySilentLoop()
        if nowPlayingRestarts <= 3 || nowPlayingRestarts % 10 == 0 {
            onLog?(ok
                ? "[保活] 已恢复（\(reason)，第 \(nowPlayingRestarts) 次）"
                : "[保活] 恢复失败（\(reason)，第 \(nowPlayingRestarts) 次）——车机按键将漏给音乐 App")
        }
    }

    private func stopNowPlayingKeepAlive() {
        nowPlayingWatchdog?.invalidate(); nowPlayingWatchdog = nil
        nowPlayingObservers.forEach(NotificationCenter.default.removeObserver)
        nowPlayingObservers = []
    }

    /// One line with the audio-session facts that decide whether the bike's keys still reach us.
    private func logAudioState(_ label: String) {
        let session = AVAudioSession.sharedInstance()
        let route = session.currentRoute.outputs.map { $0.portType.rawValue }.joined(separator: ",")
        let options = session.categoryOptions
        let optionText = options.contains(.mixWithOthers) ? "混音" : (options.isEmpty ? "独占" : String(options.rawValue))
        let claimed = MPNowPlayingInfoCenter.default().nowPlayingInfo != nil
        onLog?("[保活] \(label)：类别 \(session.category.rawValue) · 选项 \(optionText)(\(options.rawValue)) · 模式 \(session.mode.rawValue) · 路由 \(route.isEmpty ? "无" : route) · 其它音频在播 \(session.isOtherAudioPlaying ? "是" : "否") · 静音循环在播 \(silent?.isPlaying == true ? "是" : "否") · nowPlayingInfo \(claimed ? "已设" : "空")")
    }
}