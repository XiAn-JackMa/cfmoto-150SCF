// SPDX-License-Identifier: AGPL-3.0-only
//
// EasyConn ("MotoPlay") output: CarPlay → a CFMOTO / Carbit motorcycle dashboard.
//
// The protocol engine is OpenCfMotoCore (vendored under Sources/OpenCfMotoCore), which is the same
// code that is known to work on a CFMOTO 150SC: PXC handshake on 10922, media control on 10921,
// pulled H.264 on 10920, RSA HUID in the CLIENT_INFO reply. Everything here is wiring.
//
// Profile: CFDL16 / "legacy" is the 150SC (BikeProfileID.legacy). The cap with the canvas comes from
// the dash itself in REQ_RV_DATA_START (16), so no size is hard-coded.

import Foundation

final class CfMotoOutput {
    /// Lifecycle text for the settings screen and the log.
    var onState: ((String) -> Void)?
    var onLog: ((String) -> Void)?
    /// CarPlay must produce a fresh keyframe (the dash's decoder resynchronised).
    var onKeyframeRequest: (() -> Void)?

    /// Recreated on every start: shutting a source down closes its frame queue, so reusing the
    /// instance after Stop would leave the next session with a queue nothing can push into.
    private var source = CfMotoVideoSource()
    /// Serve colour bars instead of CarPlay frames (bench test of the link alone).
    private(set) var testPattern = false

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

    func start(localAddress: String, targetAddress: String, port: String) {
        stop()

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
            phone: PhoneIdentity(phoneBrand: "Apple", phoneModel: "iPhone",
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
                self.log("[管道] \(self.source.counters)")
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

    func stop() {
        pump?.cancel(); pump = nil
        ticker?.cancel(); ticker = nil
        lock.lock()
        let current = link
        link = nil
        lock.unlock()
        current?.stop()
        source.shutdown()
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
