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
// selects with a timed hold for Home, and a bare track key is treated as the same notch.

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
    private let doubleTapWindow: TimeInterval = 0.55
    private let selectHoldDelay: TimeInterval = 0.60
    /// Last ▲ and ▼ press, per direction: a second press on the same arrow inside the window is a
    /// double (the firmware merges a very fast one into a single bigger step, handled below).
    private var lastArrow: [Int: Date] = [:]
    /// Volume before we dial it back, so a ▲▼ press does not accumulate to full scale.
    private var restoringVolume = false
    private var savedVolume: Float?
    private var selectDown: Date?
    private var selectHoldTimer: Timer?
    private var selectFired: [(tap: Date, action: CarPlayControl)] = []
    private var lastSelectAt: Date?

    private let lock = NSLock()
    private var samples: [HandlebarRawSample] = []
    private var commandTargets: [(MPRemoteCommand, Any)] = []
    private var volumeObservation: NSKeyValueObservation?
    private var silent: AVAudioPlayer?
    private(set) var isRunning = false

    private func record(_ source: String, _ detail: String = "") {
        let sample = HandlebarRawSample(date: Date(), source: source, detail: detail)
        lock.lock()
        samples.append(sample)
        if samples.count > 60 { samples.removeFirst(samples.count - 60) }
        lock.unlock()
        onLog?("[按键] \(source)\(detail.isEmpty ? "" : " · \(detail)")")
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

    /// ▲/▼ short press: one notch of the wheel, or (second press on the same arrow) Back / Select.
    private func handleVolume(direction: Int, steps: Float) {
        restoreVolume(direction: direction, steps: steps)
        guard onControl != nil else { return }
        let now = Date()

        // A fast double is merged by the firmware into one bigger jump; that is a double by itself.
        if steps >= Float(0.075) {
            lastArrow.removeAll()
            onControl?(direction > 0 ? .back : .select)
            return
        }

        if let last = lastArrow[direction], now.timeIntervalSince(last) < doubleTapWindow {
            lastArrow.removeAll()
            // ▲▲ = Back, ▼▼ = Select: the two actions the dash does not hand us.
            onControl?(direction > 0 ? .back : .select)
            return
        }
        lastArrow[direction] = now
        // Singles fire at once: the manual's "short press = previous/next" is a one-press action and
        // waiting out the double window would be felt on every step.
        onControl?(direction > 0 ? .knobPrevious : .knobNext)
    }

    /// Puts the system volume back where the press found it, so ▲▼ stay usable at full scale.
    ///
    /// The dash reads its own arrow as a volume key, so the phone's volume is a side effect of
    /// navigating. Restoring it needs no UI: `MPVolumeView`'s slider is the supported way to write
    /// `outputVolume`, and the change it makes is filtered out so it is not taken for another press.
    private func restoreVolume(direction: Int, steps: Float) {
        let session = AVAudioSession.sharedInstance()
        let target = max(0, min(1, session.outputVolume - (direction > 0 ? steps : -steps)))
        restoringVolume = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let slider = MPVolumeView(frame: CGRect(x: -1000, y: -1000, width: 1, height: 1))
            for view in slider.subviews {
                guard let control = view as? UISlider else { continue }
                control.value = target
                control.sendActions(for: .touchUpInside)
                break
            }
            // The write echoes back through the observer; ignore it, then allow presses again.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { self.restoringVolume = false }
        }
    }

    /// SET long press = play/pause on this dash, so it is the only clean "enter" we get: a short
    /// pause here is treated as Select, holding it reaches Home.
    private func handleSelect() {
        guard onControl != nil else { return }
        let now = Date()
        if let last = selectFired.last, now.timeIntervalSince(last.tap) < doubleTapWindow {
            selectHoldTimer?.invalidate(); selectHoldTimer = nil
            selectDown = nil
            selectFired.removeAll()
            onControl?(.back)
            return
        }
        selectDown = now
        selectHoldTimer?.invalidate()
        selectHoldTimer = Timer.scheduledTimer(withTimeInterval: selectHoldDelay, repeats: false) { [weak self] _ in
            guard let self, self.selectDown != nil else { return }
            self.selectDown = nil
            self.selectFired.removeAll()
            self.onControl?(.home)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            guard let self, self.selectDown != nil else { return }
            self.selectDown = nil
            self.selectHoldTimer?.invalidate(); self.selectHoldTimer = nil
            self.selectFired.append((Date(), .select))
            self.onControl?(.select)
        }
    }

    /// ▲/▼ long press: a clean track key with no volume side effect.
    private func handleTrack(forward: Bool) {
        guard onControl != nil else { return }
        leftArrowCleared(forward ? 1 : -1)
        onControl?(forward ? .knobNext : .knobPrevious)
    }

    private func leftArrowCleared(_ direction: Int) {
        lastArrow[direction] = nil
    }

    // MARK: - Now Playing claim (what makes the keys arrive at all)

    /// Whether this app currently looks like the "Now Playing" app, which is the condition iOS puts
    /// on delivering AVRCP transport keys.
    var isNowPlaying: Bool { MPNowPlayingInfoCenter.default().nowPlayingInfo != nil }

    /// Publishes Now Playing info and starts a near-silent loop, so the bike sends its keys here
    /// instead of to the music app. This is the step that pauses other audio; the probe reports
    /// whether it worked rather than pretending.
    @discardableResult
    func becomeNowPlaying() -> Bool {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default, options: [])
            try session.setActive(true)
            let player = try AVAudioPlayer(data: BackgroundKeepAlive.silentLoopData,
                                           fileTypeHint: AVFileType.wav.rawValue)
            player.numberOfLoops = -1
            player.volume = 0.01
            player.prepareToPlay()
            guard player.play() else { throw ProbeError.loopDidNotStart }
            silent = player
            MPNowPlayingInfoCenter.default().nowPlayingInfo = [
                MPMediaItemPropertyTitle: "CarWithin",
                MPMediaItemPropertyArtist: "车把按键探测",
                MPNowPlayingInfoPropertyPlaybackRate: 1.0,
                MPNowPlayingInfoPropertyIsLiveStream: true
            ]
            record("已接管正在播放", "车机应把按键发到这里")
            return true
        } catch {
            onLog?("[探测] 接管播放失败：\(error.localizedDescription)（此时车机会继续把按键发给音乐 App）")
            return false
        }
    }

    enum ProbeError: LocalizedError {
        case loopDidNotStart
        var errorDescription: String? { "静音循环没有启动" }
    }
}