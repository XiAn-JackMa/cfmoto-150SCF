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
    private let lock = NSLock()
    private var link: EasyConnLink?
    private var pump: Task<Void, Never>?
    private var ticker: Task<Void, Never>?
    private var lastState = "未启动"
    /// RSA identity for CLIENT_INFO. Kept for the process lifetime: a fresh key per launch is fine
    /// for a test build, but it means the dash sees a new accessory on every start.
    private var signer: PureSwiftHuidSigner?

    func start(localAddress: String, targetAddress: String, port: String) {
        stop()

        // A fresh frame source per session (see the property comment).
        source = CfMotoVideoSource()
        source.log = { [weak self] in self?.onLog?($0) }
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
            stallTimeout: 8,
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

        onLog?("CFMOTO EasyConn → \(dash.isEmpty ? "gateway" : dash):\(port) profile=legacy")
        onState?("正在连接春风车机…")

        pump = Task { [weak self] in
            for await event in link.events {
                guard let self else { return }
                self.onLog?("CFMOTO event: \(String(describing: event))")
                // Every event used to raise the status label, and a status change rebuilds the
                // settings table, so the frequent ones (.stats, .touch) made scrolling that page
                // re-enter its own data source. Only the milestones drive the card; the ticker
                // below carries the counters.
                switch event {
                case .state, .dashIdentified, .canvas, .mediaStarted:
                    break
                case .stats, .touch:
                    continue
                }
                let text = Self.describe(event)
                self.lastState = text
                // UIKit labels are updated from here, so hop to main.
                DispatchQueue.main.async { self.onState?(text) }
            }
        }
        // Frame counters every two seconds: a pull with no frame is the failure to look for.
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard let self, self.lock.withLock({ self.link != nil }) else { return }
                let text = "\(self.lastState) · \(self.source.counters)"
                DispatchQueue.main.async { self.onState?(text) }
            }
        }
        link.start()
    }

    func append(_ data: Data, codec: VideoCodec, keyframe: Bool) {
        guard lock.withLock({ link != nil }) else { return }
        source.append(data, codec: codec, keyframe: keyframe)
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
            case .streaming: return "正在投屏 · 车机已连接"
            case .handshaking: return "已找到车机，握手中…"
            case .awaitingCallback: return "等待车机回连…"
            case .probing(let attempt): return "正在探测车机（第 \(attempt) 次）…"
            case .startingServers: return "正在监听 10920-10922…"
            case .idle: return "未启动"
            default: return "状态：\(state)"
            }
        case .dashIdentified(let info):
            return "已识别车机：\(info)"
        case .canvas(let canvas):
            return "车机画布 \(canvas.width)×\(canvas.height)（请求 \(canvas.requestedWidth)×\(canvas.requestedHeight)）"
        case .mediaStarted:
            return "车机开始拉流"
        case .touch(let touch):
            return "触摸：\(touch)"
        case .stats(let stats):
            return "统计：\(stats)"
        }
    }
}
