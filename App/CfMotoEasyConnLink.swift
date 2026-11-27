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
    /// The canvas this EasyConn session negotiated; nil until the dash reports one. The deferred
    /// CarPlay start reads it so the first session already renders at the right size.
    var negotiatedCanvas: VideoCanvas? { lock.withLock { sessionCanvas } }
    private var sessionCanvas: VideoCanvas?
    /// 链路是否正在跑（正式的 CarPlay 会话，或测试图案那条独立链路）。
    /// 设置页的「分辨率查询」靠它决定要不要自己拉起链路。
    var isLinkActive: Bool { lock.withLock { link != nil } }

    /// Recreated on every start: shutting a source down closes its frame queue, so reusing the
    /// instance after Stop would leave the next session with a queue nothing can push into.
    private var source = CfMotoVideoSource()
    /// Bumped by every `stop()`. A delayed `performStart` compares it and gives up, so a Stop clicked
    /// while the restart cooldown is running cannot bring a ghost session up afterwards.
    private var sessionGeneration = 0
    /// Serve colour bars instead of CarPlay frames (bench test of the link alone).
    private(set) var testPattern = false

    /// Hard reset of the video pipeline (decoder + queues + keyframe), used when the app returns to
    /// the foreground: the decompression session is what does not survive being backgrounded.
    /// Re-applies the manual bitrate/profile overrides to the running session.
    func applyTuning() { lock.withLock { source }.reloadTuning() }
    /// The app left or returned to the foreground: the hardware encoder does not survive that.
    func setBackgrounded(_ value: Bool) { lock.withLock { source }.setBackgrounded(value) }

    func resynchronizeVideo() {
        lock.withLock { source }.resynchronize()
        log("回到前台，已重建视频管线")
    }

    /// Live toggle: applies to the running link as well as the next start.
    func setTestPattern(_ on: Bool) {
        testPattern = on
        lock.withLock { source }.setTestPattern(on)
        log("测试图案 \(on ? "已开启" : "已关闭")")
    }
    /// Start the EasyConn link standalone to serve the test pattern, without a CarPlay session.
    /// Reuses the normal start, so the listeners, probe and handshake are exactly the same; the
    /// synthetic source fills in for CarPlay frames.
    func startTestPattern(host: String, port: String) {
        testPattern = true
        start(localAddress: ReceiverConfiguration.wifiIPv4Address() ?? "", targetAddress: host, port: port)
    }
    /// Stop the standalone test-pattern link. The CarPlay start path calls this first so the real
    /// session never serves a test picture.
    func stopTestPattern() {
        testPattern = false
        stop()
    }
    /// Standalone diagnostic for the settings page: probe the dash's EasyConn port without starting
    /// a session. The probe is the same `0x70000010` handshake the session uses, so "通" means a
    /// start would get past this stage. The result goes to the shared log and to the completion,
    /// which is delivered on the main thread as `(summary, accepted)`.
    func testDashPort(host: String, port: UInt16, completion: @escaping (String, Bool) -> Void) {
        let client = DashProbeClient(network: POSIXNetworkProvider(), connectTimeout: 5, readTimeout: 3,
                                     track: { _ in true }, untrack: { _ in })
        Task { [weak self] in
            guard let self else { return }
            self.log("[端口测试] 探测 \(host):\(port) …")
            let outcome = await client.probeOnce(host: host, port: port, attempt: 1)
            let (summary, accepted) = Self.portTestSummary(outcome, host: host, port: port)
            self.log("[端口测试] \(summary)")
            DispatchQueue.main.async { completion(summary, accepted) }
        }
    }
    private static func portTestSummary(_ outcome: DashProbeClient.Outcome, host: String, port: UInt16) -> (String, Bool) {
        switch outcome {
        case .accepted:
            return ("✅ 端口通 \(host):\(port)，车机已应答探测——可以开启测试图案", true)
        case .rejected(let body):
            return ("⚠️ 端口通 \(host):\(port)，但车机拒绝探测：\(body)", false)
        case .noReply:
            return ("⚠️ 端口通 \(host):\(port)，但车机未应答就关闭了连接", false)
        case .unanswered:
            return ("⚠️ 端口通 \(host):\(port)，但车机 3 秒内未应答探测", false)
        case .localNetworkDenied:
            return ("⛔ \(host):\(port) 被系统拦截：本地网络权限未开，或 VPN / 省流量拦截", false)
        case .failed(let detail):
            return ("⛔ 端口不通 \(host):\(port)：\(detail)", false)
        }
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
    /// Last numbers written to the log, so the ticker does not repeat an unchanged snapshot.
    private var lastStatsSignature = ""

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
        // Captured after the cleanup stop() above, so this start's own stop does not invalidate it.
        let generation = lock.withLock { sessionGeneration }
        guard wait > 0 else {
            performStart(localAddress: localAddress, targetAddress: targetAddress, port: port, generation: generation)
            return
        }
        // Give the dash a moment to finish its own teardown: an abrupt close is only visible to it
        // as EOF, and probing again inside that window is what made Start look like it hung.
        log(String(format: "等待 %.1f 秒让车机收尾后再重新探测", wait))
        pendingStart = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            self.pendingStart = nil
            self.performStart(localAddress: localAddress, targetAddress: targetAddress, port: port,
                              generation: generation)
        }
    }

    private func performStart(localAddress: String, targetAddress: String, port: String, generation: Int) {
        // A Stop clicked while the cooldown was running must win: without this the delayed start
        // would bring a link up after the card already read "已停止".
        guard lock.withLock({ sessionGeneration == generation }) else {
            log("已在启动前收到停止请求，本次启动放弃")
            return
        }
        // A fresh frame source per session (see the property comment). It is configured before the
        // swap so no reader can see a half-configured instance, and the old one is only shut down
        // after the swap so a racing stop() cannot close the queue this session pulls from.
        let fresh = CfMotoVideoSource()
        fresh.testPattern = testPattern
        fresh.log = { [weak self] line in
            guard let self else { return }
            self.lock.lock()
            self.recent.append(line)
            if self.recent.count > 12 { self.recent.removeFirst(self.recent.count - 12) }
            self.lock.unlock()
            self.store.append(line)
            self.onLog?(line)
        }
        fresh.onKeyframeRequest = { [weak self] in self?.onKeyframeRequest?() }
        lock.lock()
        let previous = source
        source = fresh
        lock.unlock()
        previous.shutdown()
        lastState = "未启动"
        lock.lock(); sessionCanvas = nil; lock.unlock()

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
                                frameSource: fresh,
                                signer: signer,
                                discovery: nil,
                                gateway: dash.isEmpty ? nil : dash)
        lock.lock()
        // The generation is re-checked here and not only at the top of performStart: building the
        // link takes long enough for a Stop to arrive in between, and installing it afterwards is
        // what let a stopped session come back to life a second later.
        guard sessionGeneration == generation else {
            lock.unlock()
            link.stop()
            fresh.shutdown()
            log("已在启动前收到停止请求，本次启动放弃")
            return
        }
        self.link = link
        lock.unlock()

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
        // 每次启动都记一份当下的网络身份：Wi-Fi 名用预设值（系统 SSID 需定位授权与 wifi-info
        // 权限，侧载签名读不到，所以不再尝试读系统名称）。
        let wifiName = "预设 \(WiFiPresetStore.selected()?.ssid ?? "未设置")"
        log("版本 \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")" +
            " (\(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"))" +
            " · \(UIDevice.current.model) iOS \(UIDevice.current.systemVersion)" +
            " · 本机IP \(localAddress.isEmpty ? "-" : localAddress)" +
            " · Wi-Fi \(wifiName)")
        log("画面参数：\(CfMotoTuning.fullSummary)")
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
                    self.lock.lock(); self.sessionCanvas = canvas; self.lock.unlock()
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
                    // The link publishes stats less often than this ticker runs, so an unchanged
                    // snapshot printed the same numbers every three seconds. Only speak on change.
                    let signature = "\(stats.framesSent)/\(stats.keyframesSent)/\(stats.missedPulls)/" +
                        String(format: "%.1f", stats.pullRate)
                    if signature != self.lastStatsSignature {
                        self.lastStatsSignature = signature
                        self.log("[车机] 已交付 \(stats.framesSent) 帧 · 其中关键帧 \(stats.keyframesSent) · 约 \(stats.bytesSent / 1024) KB" +
                            " · 车机没等到回复 \(stats.missedPulls) 次 · 每秒 \(String(format: "%.1f", stats.pullRate)) 次" +
                            " · 状态：\(state.replacingOccurrences(of: "[状态] ", with: ""))")
                    }
                } else {
                    self.log("[车机] 尚无数据 状态=\(state.replacingOccurrences(of: "[状态] ", with: ""))")
                }
                // Always log the counters: replacing them with a warning hid the one thing needed to
                // tell a CarPlay problem from an EasyConn one.
                self.logDiagnosticIfDue()
                let idle = self.lock.withLock { self.source }.inboundIdle
                if idle > 5 {
                    self.log("[画面] \(self.lock.withLock { self.source }.counters)")
                    // The dash is showing black because CarPlay has not produced a picture; that is a
                    // CarPlay session problem, not an EasyConn one. One line, and only when the
                    // silence changes, so a long black period does not bury the log.
                    self.noteCarPlaySilence(idle)
                } else {
                    self.log("[画面] \(self.lock.withLock { self.source }.counters)")
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
        lock.withLock { source }.append(data, codec: codec, keyframe: keyframe)
    }

    /// Everything needed to diagnose a stalled link, for the settings screen's copy button.
    /// Live snapshot for the readouts on the home screen and above the preview.
    var liveStats: CfMotoLiveStats { lock.withLock { source }.liveStats }

    var diagnostics: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        let (isUp, tail) = lock.withLock { (link != nil, recent.suffix(8).joined(separator: " || ")) }
        let head = "CarWithin \(version) (\(build)) · CFMOTO \(lastState) · \(lock.withLock { source }.counters) · " +
            (isUp ? "link=up" : "link=down")
        return tail.isEmpty ? head : head + "\n--- 最近日志 ---\n" + tail
    }

    /// Every EasyConn log line kept so far, for the Wi-Fi log endpoint.
    var logDump: String {
        let (head, lines) = lock.withLock { (diagnosticsHeadUnlocked(), recent) }
        return lines.isEmpty ? head : head + "\n--- 日志 ---\n" + lines.joined(separator: "\n")
    }

    /// - Note: callers already hold lock (logDump), so this must read source directly.
    ///   Taking the lock again here is a self-deadlock: NSLock is not recursive.
    private func diagnosticsHeadUnlocked() -> String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "CarWithin \(version) (\(build)) · CFMOTO \(lastState) · \(source.counters) · " +
            (link != nil ? "link=up" : "link=down")
    }

    /// Last silence length that was already reported, so the log gets one line per change of scale
    /// rather than one per tick.
    private var lastSilenceSeconds = 0

    private var lastDiagnosticAt = Date.distantPast

    /// One line every ten seconds with everything needed to explain a soft or stuttering picture:
    /// the pair of resolutions (a mismatch means every frame is rescaled), the rate the dash is
    /// actually served at, and how much of it is padding.
    private func logDiagnosticIfDue() {
        guard Date().timeIntervalSince(lastDiagnosticAt) >= 10 else { return }
        lastDiagnosticAt = Date()
        let s = lock.withLock { source }.liveStats
        var text = "[诊断] 车机画面 \(s.canvasSize) ← CarPlay \(s.carPlaySize) · " +
            (s.scaleText == "1:1" ? "尺寸一致，不缩放" : "缩放 \(s.scaleText)（画面会变糊）") +
            String(format: " · 每秒送 %.1f 帧 · 重复画面 %.0f%% · 关键帧 %.0f%% · 每帧 %.1f KB · 约 %.1f Mbps",
                   s.servedFPS, s.paddedRatio * 100, s.keyframeRatio * 100, s.averageFrameKB, s.bitrateMbps)
        if CfMotoTuning.staticPadEnabled {
            text += String(format: " · 静止补帧已开 %.1f Mbps", CfMotoTuning.staticPadMbps)
        }
        log(text)
    }
    /// Reports a CarPlay silence, but only when there is genuinely no picture.
    ///
    /// A static CarPlay screen sends almost nothing: the field run shows 7.7 access units a second
    /// against a dash pulling 20 times, which is normal. Warning "the dash is black" while the dash
    /// was in fact showing a perfectly good frozen map was simply wrong, so this now speaks only
    /// when nothing has ever been served.
    private func noteCarPlaySilence(_ idle: TimeInterval) {
        let active = lock.withLock { source }
        guard !active.liveStats.hasPicture else { return }
        let seconds = Int(idle)
        guard seconds / 10 != lastSilenceSeconds / 10 else { return }
        lastSilenceSeconds = seconds
        log("[警告] CarPlay 已 \(seconds) 秒没有输出任何画面，车机是黑屏 —— 问题在 CarPlay 会话，EasyConn 链路正常")
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
        // Invalidates a delayed start that is still sleeping out the cooldown.
        sessionGeneration += 1
        let dyingSource = source
        lock.unlock()
        // Stop the link BEFORE cancelling the pump: link.stop() publishes .state(.stopped), and a
        // pump that is already cancelled drops it, which left the log ending mid-sentence and made
        // Stop look like it never disconnected anything.
        current?.stop()
        pump?.cancel(); pump = nil
        ticker?.cancel(); ticker = nil
        // Shuts down the source captured under the lock, not whatever `source` points at now: a
        // concurrent performStart may already have installed the next session's instance.
        dyingSource.shutdown()
        // The cooldown only matters when a link was actually up: NativeReceiver starts by calling
        // stop() as its own cleanup, and counting that would delay every single start by it.
        if current != nil {
            // The session is over; its canvas must not be read by the next start.
            lock.lock(); sessionCanvas = nil; lock.unlock()
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
