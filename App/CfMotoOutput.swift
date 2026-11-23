// SPDX-License-Identifier: AGPL-3.0-only
//
// EasyConn ("MotoPlay") output: CarPlay → a CFMOTO / Carbit motorcycle dashboard.
//
// The protocol engine is OpenCfMotoCore (vendored under Sources/OpenCfMotoCore), which is the same
// code that is known to work on a CFMOTO 150SCF: PXC handshake on 10922, media control on 10921,
// pulled H.264 on 10920, RSA HUID in the CLIENT_INFO reply. Everything here is wiring.
//
// Profile: CFDL16 / "legacy" is the 150SCF (BikeProfileID.legacy). The cap with the canvas comes from
// the dash itself in REQ_RV_DATA_START (16), so no size is hard-coded.

import Foundation
import UIKit

final class CfMotoOutput {
    /// Lifecycle text for the settings screen and the log.
    var onState: ((String) -> Void)?
    var onLog: ((String) -> Void)?
    /// CarPlay must produce a fresh keyframe (the dash's decoder resynchronised).
    var onKeyframeRequest: (() -> Void)?
    /// Raised when the dash negotiates a canvas, so CarPlay can render at that exact size.
    var onCanvas: ((VideoCanvas) -> Void)?

    /// Recreated on every start: shutting a source down closes its frame queue, so reusing the
    /// instance after Stop would leave the next session with a queue nothing can push into.
    private var source = CfMotoVideoSource()
    /// Serve colour bars instead of CarPlay frames (bench test of the link alone).
    private(set) var testPattern = false

    /// Hard reset of the video pipeline (decoder + queues + keyframe), used when the app returns to
    /// the foreground: the decompression session is what does not survive being backgrounded.
    func resynchronizeVideo() {
        source.resynchronize()
        log("回到前台，已重建视频管线")
    }

    /// Live toggle: applies to the running link as well as the next start.
    func setTestPattern(_ on: Bool) {
        testPattern = on
        source.setTestPattern(on)
        log("测试图案 \(on ? "已开启" : "已关闭")")
    }
    private let lock = NSLock()
    private var link: EasyConnLink?
    private var pump: Task<Void, Never>?
    private var ticker: Task<Void, Never>?
    private var lastState = "未启动"
    /// Last few diagnostic lines, so the copy button also carries the *reason* a stage failed.
    private var recent: [String] = []
    /// File-backed log: survives a crash or an app kill at the bike.
    let store = CfMotoLogStore()
    /// Latest link statistics, so the periodic line carries the dash's own view.
    private var lastStats: LinkStats?

    /// One line to both the store (persistent) and whoever shows it (settings screen, :10950).
    private func log(_ line: String) {
        store.append(line)
        onLog?(line)
    }
    /// RSA identity for CLIENT_INFO. Kept for the process lifetime: a fresh key per launch is fine
    /// for a test build, but it means the dash sees a new accessory on every start.
    private var signer: PureSwiftHuidSigner?
    /// Kept for the process lifetime: one subscription covers every session.
    private var logSubscription: UUID?

    /// One UUID per installation, so the dash sees the same phone every time.
    private static let stablePhoneUUID: String = {
        let key = "cfmotoPhoneUUID"
        if let existing = UserDefaults.standard.string(forKey: key), !existing.isEmpty { return existing }
        let uuid = UUID().uuidString.lowercased()
        UserDefaults.standard.set(uuid, forKey: key)
        return uuid
    }()

    private var pendingStart: Task<Void, Never>?

    func start(localAddress: String, targetAddress: String, port: String) {
        // The cooldown is measured from the *previous* stop, so read it before stop() refreshes it.
        let wait = restartDelay
        pendingStart?.cancel()
        pendingStart = nil
        stop()
        guard wait > 0 else {
            performStart(localAddress: localAddress, targetAddress: targetAddress, port: port)
            return
        }
        // Give the dash a moment to finish its own teardown: an abrupt close is only visible to it
        // as EOF, and probing again inside that window is what made Start look like it hung.
        log(String(format: "等待 %.1f 秒让车机收尾后再重新探测", wait))
        pendingStart = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            self.pendingStart = nil
            self.performStart(localAddress: localAddress, targetAddress: targetAddress, port: port)
        }
    }

    private func performStart(localAddress: String, targetAddress: String, port: String) {
        // A fresh frame source per session (see the property comment).
        source = CfMotoVideoSource()
        source.testPattern = testPattern
        source.log = { [weak self] line in
            guard let self else { return }
            self.lock.lock()
            self.recent.append(line)
            if self.recent.count > 12 { self.recent.removeFirst(self.recent.count - 12) }
            self.lock.unlock()
            self.store.append(line)
            self.onLog?(line)
        }
        source.onKeyframeRequest = { [weak self] in self?.onKeyframeRequest?() }
        lastState = "未启动"

        let signer: PureSwiftHuidSigner
        if let existing = self.signer {
            signer = existing
        } else {
            signer = PureSwiftHuidSigner.generate(bits: 1024)
            self.signer = signer
        }

        let dash = targetAddress.trimmingCharacters(in: .whitespaces)
        let configuration = LinkConfiguration(
            qr: nil,
            profileOverride: .legacy,
            learnedCanvas: nil,
            forceTouchscreen: false,
            // Stable across sessions and launches: the Android client keeps one UUID for the whole
            // process, and a dash may treat a changing one as a different phone (fakedash warns
            // IDENTITY_CHANGED).
            phone: PhoneIdentity(phoneUUID: Self.stablePhoneUUID, phoneBrand: "Apple", phoneModel: "iPhone",
                                 phoneOsVersion: "35", bluetoothName: "OpenCfMoto"),
            localHost: localAddress.isEmpty ? nil : localAddress,
            dashHost: dash.isEmpty ? nil : dash,
            connectBackTimeout: 10,
            stallTimeout: 20,
            stallReconnectCooldown: 20,
            maxReconnectAttempts: 20,
            framePullTimeout: 3)

        // No Bonjour browser: the T-Box is the access point, so the Wi-Fi gateway is the dash. That
        // also avoids the mDNS permissions the browser would need.
        let link = EasyConnLink(configuration: configuration,
                                network: POSIXNetworkProvider(),
                                frameSource: source,
                                signer: signer,
                                discovery: nil,
                                gateway: dash.isEmpty ? nil : dash)
        lock.lock(); self.link = link; lock.unlock()

        // Core knows why a session ended (watchdog, peer closed, handshake rejected) but reports it
        // through its own Log. Forward the link-relevant lines into our store, otherwise a field log
        // shows "reconnecting" with no reason.
        if logSubscription == nil {
            logSubscription = Log.shared.subscribe { [weak self] line in
                guard let self, self.lock.withLock({ self.link != nil }) else { return }
                guard line.tag == "LINK" || line.tag == "NET" else { return }
                let interesting = line.level >= .warn
                    || line.message.contains("watchdog")
                    || line.message.contains("closed")
                    || line.message.contains("stall")
                    || line.message.contains("reconnect")
                    || line.message.contains("fail")
                guard interesting else { return }
                self.store.append("[核心:\(line.tag)] \(line.message)")
            }
        }

        log("==== EasyConn 目标 \(dash.isEmpty ? "网关" : dash):\(port) · profile=legacy · 测试图案\(testPattern ? "开" : "关") ====")
        log("版本 \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")" +
            " (\(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"))" +
            " · \(UIDevice.current.model) iOS \(UIDevice.current.systemVersion)" +
            " · 本机IP \(localAddress.isEmpty ? "-" : localAddress)")
        onState?("正在连接春风车机…")
        log("等待车机在 10930 响应探测…")

        pump = Task { [weak self] in
            for await event in link.events {
                guard let self else { return }
                if case .stats(let stats) = event {
                    self.lock.lock(); self.lastStats = stats; self.lock.unlock()
                    continue
                }
                if case .canvas(let canvas) = event {
                    // Remembered for planDisplay(): the next session renders CarPlay 1:1 at the
                    // canvas instead of letterboxing a 16:9 picture into it.
                    UserDefaults.standard.set("\(canvas.width)x\(canvas.height)", forKey: "cfmotoCanvas")
                // The dash renegotiated its canvas. CarPlay has to be re-rendered at that size,
                // otherwise every picture is rescaled on the phone and arrives soft.
                DispatchQueue.main.async { [weak self] in self?.onCanvas?(canvas) }
                }
                let line = Self.describe(event)
                self.log(line)
                let cardText = line.split(separator: "\n").first.map(String.init) ?? ""
                self.lastState = cardText
                // UIKit labels are updated from here, so hop to main.
                DispatchQueue.main.async {
                    self.onState?(cardText.replacingOccurrences(of: "[状态] ", with: ""))
                }
            }
        }
        // Frame counters every two seconds: a pull with no frame is the failure to look for.
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard let self, self.lock.withLock({ self.link != nil }) else { return }
                let (state, stats) = self.lock.withLock { (self.lastState, self.lastStats) }
                if let stats {
                    self.log("[车机] 送出=\(stats.framesSent) 关键帧=\(stats.keyframesSent)" +
                        " 字节=\(stats.bytesSent / 1024)KB 漏拉=\(stats.missedPulls)" +
                        " 速率=\(String(format: "%.1f", stats.pullRate)) 状态=\(state.replacingOccurrences(of: "[状态] ", with: ""))")
                } else {
                    self.log("[车机] 尚无数据 状态=\(state.replacingOccurrences(of: "[状态] ", with: ""))")
                }
                // Always log the counters: replacing them with a warning hid the one thing needed to
                // tell a CarPlay problem from an EasyConn one.
                let idle = self.source.inboundIdle
                if idle > 5 {
                    self.log("[管道] \(self.source.counters)")
                    // The dash is showing black because CarPlay has not produced a picture; that is a
                    // CarPlay session problem, not an EasyConn one. One line, and only when the
                    // silence changes, so a long black period does not bury the log.
                    self.noteCarPlaySilence(idle)
                } else {
                    self.log("[管道] \(self.source.counters)")
                    self.lastSilenceSeconds = 0
                }
                // Counters go to the log view only. Raising the status label here would rebuild the
                // settings table every few seconds, which fights the log field the rider is reading.
            }
        }
        link.start()
    }

    func append(_ data: Data, codec: VideoCodec, keyframe: Bool) {
        guard lock.withLock({ link != nil }) else { return }
        source.append(data, codec: codec, keyframe: keyframe)
    }

    /// Everything needed to diagnose a stalled link, for the settings screen's copy button.
    var diagnostics: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        let (isUp, tail) = lock.withLock { (link != nil, recent.suffix(8).joined(separator: " || ")) }
        let head = "CarWithin \(version) (\(build)) · CFMOTO \(lastState) · \(source.counters) · " +
            (isUp ? "link=up" : "link=down")
        return tail.isEmpty ? head : head + "\n--- 最近日志 ---\n" + tail
    }

    /// Every EasyConn log line kept so far, for the Wi-Fi log endpoint.
    var logDump: String {
        let (head, lines) = lock.withLock { (diagnosticsHeadUnlocked(), recent) }
        return lines.isEmpty ? head : head + "\n--- 日志 ---\n" + lines.joined(separator: "\n")
    }

    private func diagnosticsHeadUnlocked() -> String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "CarWithin \(version) (\(build)) · CFMOTO \(lastState) · \(source.counters) · " +
            (link != nil ? "link=up" : "link=down")
    }

    /// Last silence length that was already reported, so the log gets one line per change of scale
    /// rather than one per tick.
    private var lastSilenceSeconds = 0

    /// Reports a CarPlay silence once, naming the component at fault.
    private func noteCarPlaySilence(_ idle: TimeInterval) {
        let seconds = Int(idle)
        guard seconds / 10 != lastSilenceSeconds / 10 else { return }
        lastSilenceSeconds = seconds
        log("[警告] CarPlay 已 \(seconds) 秒没有输出画面，车机显示的是黑屏 —— 问题在 CarPlay 会话，EasyConn 链路正常")
    }

    /// Last time a link was stopped, so a restart can leave the dash time to finish its own teardown.
    private var lastStopAt = Date.distantPast
    /// How long to wait before re-probing. The dash only notices an abrupt close when its sockets
    /// read EOF, and it keeps its own session state for `socketTimeoutPeriodWifi` (9 s on this
    /// bike); probing again immediately is what made "start" appear to hang until it was retried a
    /// few times. Short, because the bike re-probes on its own as soon as the sockets close.
    private let restartCooldown: TimeInterval = 1.5

    func stop() {
        pendingStart?.cancel()
        pendingStart = nil
        lock.lock()
        let current = link
        link = nil
        lock.unlock()
        // Stop the link BEFORE cancelling the pump: link.stop() publishes .state(.stopped), and a
        // pump that is already cancelled drops it, which left the log ending mid-sentence and made
        // Stop look like it never disconnected anything.
        current?.stop()
        pump?.cancel(); pump = nil
        ticker?.cancel(); ticker = nil
        source.shutdown()
        // The cooldown only matters when a link was actually up: NativeReceiver starts by calling
        // stop() as its own cleanup, and counting that would delay every single start by it.
        if current != nil {
            lastStopAt = Date()
            log("EasyConn 已停止：已关闭 10920/10921/10922 与探测连接，车机将看到 EOF")
            // stop() can run on the receiver queue; the card is UIKit.
            DispatchQueue.main.async { [weak self] in self?.onState?("已停止") }
        }
    }

    /// Seconds still to wait before this output may start again (0 when it is allowed now).
    var restartDelay: TimeInterval {
        max(0, restartCooldown - Date().timeIntervalSince(lastStopAt))
    }

    /// Turns engine events into something readable at the bike: state, negotiated canvas, pull counts.
    private static func describe(_ event: LinkEvent) -> String {
        switch event {
        case .state(let state):
            switch state {
            case .streaming: return "[状态] 正在投屏 · 车机已连接"
            case .handshaking: return "[状态] 已找到车机，握手中"
            case .awaitingCallback: return "[状态] 等待车机回连"
            case .probing(let attempt): return "[状态] 探测车机第 \(attempt) 次"
            case .startingServers: return "[状态] 监听 10920-10922"
            case .idle: return "[状态] 已停止"
            default: return "[状态] \(state)"
            }
        case .dashIdentified(let info):
            // Compact on purpose: the full object is unreadable on a phone and floods the file.
            var lines = ["[握手] 车机 \(info.huName) HUID=\(info.huid) 通道=\(info.channel)" +
                         " SDK=\(info.sdkVersion) 触控=\(info.supportsScreenTouch ? "是" : "否")" +
                         " 超时=\(info.socketTimeoutSeconds.map(String.init) ?? "-")s" +
                         " profile=\(info.profile)"]
            if !info.rawJSON.isEmpty { lines.append("[握手] 原始 CLIENT_INFO: \(info.rawJSON)") }
            return lines.joined(separator: "\n")
        case .canvas(let canvas):
            return "[画布] \(canvas.width)×\(canvas.height)（车机请求 \(canvas.requestedWidth)×\(canvas.requestedHeight)）"
        case .mediaStarted:
            return "[视频] 车机开始拉流"
        case .touch(let touch):
            return "[触控] \(touch)"
        case .stats(let stats):
            return "[车机] 送出=\(stats.framesSent) 关键帧=\(stats.keyframesSent)" +
                " 字节=\(stats.bytesSent / 1024)KB 漏拉=\(stats.missedPulls)"
        }
    }
}
