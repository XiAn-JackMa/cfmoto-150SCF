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
// This file only OBSERVES. It registers the remote commands, watches outputVolume, and reports every
// raw event; no mapping to CarPlay controls happens here, because the 150SCF's firmware is not
// documented and guessing would hide the very thing we need to measure. Read the log, then map.

import AVFoundation
import Foundation
import MediaPlayer

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

        add(center.playCommand, "playCommand")
        add(center.pauseCommand, "pauseCommand")
        add(center.togglePlayPauseCommand, "togglePlayPauseCommand")
        add(center.nextTrackCommand, "nextTrackCommand")
        add(center.previousTrackCommand, "previousTrackCommand")

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
            guard let old = change.oldValue, let new = change.newValue, old != new else { return }
            let steps = abs(new - old)
            self?.record(new > old ? "音量+" : "音量−",
                         String(format: "%.2f → %.2f（%.3f，约 %d 格）", old, new, steps, Int((steps * 16).rounded())))
        }
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