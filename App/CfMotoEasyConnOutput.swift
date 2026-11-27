// SPDX-License-Identifier: AGPL-3.0-only
//
// 春风 EasyConn 输出（1.0.6 基线，EasyConn 分支）。
//
// 这里不是一份独立的推流实现，而是一层薄适配：
//
//   · 真正的推流引擎是 `CfMotoOutput`（见 CfMotoEasyConnLink.swift），它驱动的是
//     从 1.0.83 整块搬过来的 OpenCfMotoCore —— `EasyConnLink` + `LinkSession` +
//     `POSIXTransport` + `Protocol/*`，也就是用户 1.0.83 里跑通的那条链路：
//     Bonjour `_EasyConn._tcp` 浏览、iOS 网关阶梯、10915–10935 端口扫描、2 秒心跳、
//     0.5→4 秒退避、失联 20 秒自动重挂。
//   · 画面侧同样是 1.0.83 的 `CfMotoVideoSource` / `CfMotoTuning` / `CfMotoLogStore`。
//
// 上游 `CfmotoOutput`（春风 5 寸 / 6.2 寸，走 1.0.6 自己的 `PxcConnection`）不受影响，
// 两条链路互不引用、互不干扰。
//
// 本类只补三件 1.0.83 里由 App 层负责的事：
//   1. 把日志暴露成 10950 网页（手机/电脑浏览器随时可看，不必等投屏）；
//   2. 端口测试 / 测试图案的开关落到 1.0.83 的 `testDashPort` / `startTestPattern`；
//   3. 保持 1.0.6 的调用签名（`start(...)` 那串参数），避免改 `NativeReceiver` 的逻辑。

import Foundation

final class CfMotoEasyConnOutput {
    /// 仪表探测端口（默认 10930），只在「端口测试」里用。
    /// 实际投屏由 1.0.83 的链路自己按 10930 + 10915…10935 扫描去找，这一点与 1.0.83 一致。
    static var probePort: UInt16 {
        get {
            let value = UserDefaults.standard.integer(forKey: "cfmotoEasyConnPort")
            return value > 0 && value < 65536 ? UInt16(value) : 10930
        }
        set { UserDefaults.standard.set(Int(newValue), forKey: "cfmotoEasyConnPort") }
    }

    /// 1.0.83 的推流引擎（链路 + 画面 + 编码都是它的）。
    private let engine = CfMotoOutput()
    private let logServer = CfMotoLogServer()

    /// 日志环与面板共用同一份（来自 1.0.83 的 `CfMotoLogStore`）。
    var store: CfMotoLogStore { engine.store }

    var onState: ((String) -> Void)?
    var onLog: ((String) -> Void)?
    var onKeyframeRequest: (() -> Void)?
    /// 1.0.83 的链路自己会无限重挂（失联 20 秒后重新发现），不会「连不上就放弃」，
    /// 所以这个回调保留只为兼容 1.0.6 的调用点，实际不会触发。
    var onGiveUp: (() -> Void)?

    init(name: String = "cfmoto-easyconn") {
        engine.onState = { [weak self] state in self?.onState?(state) }
        engine.onLog = { [weak self] line in self?.onLog?(line) }
        engine.onKeyframeRequest = { [weak self] in self?.onKeyframeRequest?() }
    }

    deinit { stop() }

    // MARK: - 生命周期

    /// - Note: `maxBitrate` / `maxFps` / `phone` 是 1.0.6 那套「按 profile 上限取参数」的入参。
    ///   1.0.83 的 EasyConn 由车机在 REQ_RV_DATA_START 里给画布和帧率，码率走 `CfMotoTuning`，
    ///   所以这里不再用它们；保留参数只为不改 `NativeReceiver` 的调用点。
    func start(localAddress: String, targetAddress: String, phone: TailingPhoneInfo,
               maxBitrate: Int, maxFps: Int,
               onState: @escaping (String) -> Void, onLog: @escaping (String) -> Void,
               onKeyframeRequest: @escaping () -> Void, onGiveUp: (() -> Void)? = nil) {
        self.onState = onState
        self.onLog = onLog
        self.onKeyframeRequest = onKeyframeRequest
        self.onGiveUp = onGiveUp
        // 真正的 CarPlay 会话开始前先关掉测试图案，避免把彩条推给车机（1.0.83 同样如此）。
        engine.stopTestPattern()
        ensureLogServer()
        log("链路引擎：OpenCfMotoCore EasyConnLink（1.0.83）· 探测 10930 + 10915…10935 扫描")
        log("端口测试用 \(Self.probePort)；投屏链路按 1.0.83 自己的阶梯发现车机")
        engine.start(localAddress: localAddress, targetAddress: targetAddress,
                     port: String(Self.probePort))
    }

    func stop() {
        engine.stop()
        // 日志服务故意不停：设置页随时能看日志，不必等下一次投屏。
    }

    // MARK: - 画面参数 / 测试图案

    /// 面板改完参数后调用：1.0.83 的 `applyTuning()` 会重建编码器。
    func reloadTuning() {
        engine.applyTuning()
        log("画面参数已应用：\(CfMotoTuning.fullSummary)（编码器已重建）")
    }

    /// 测试图案：独立起一条链路，不需要 CarPlay（与 1.0.83 的「启动/停止测试图案」一致）。
    func toggleTestPattern(host: String, port: UInt16) {
        if engine.testPattern {
            engine.stopTestPattern()
            log("测试图案已关闭")
        } else {
            engine.startTestPattern(host: host, port: String(port))
        }
    }

    /// 只切画面源、不起链路（供内部/调试使用）。
    func setTestPattern(_ on: Bool) {
        engine.setTestPattern(on)
    }

    var testPatternEnabled: Bool { engine.testPattern }

    // MARK: - CarPlay 画面输入

    func append(_ data: Data, codec: VideoCodec, keyframe: Bool) {
        engine.append(data, codec: codec, keyframe: keyframe)
    }

    func resynchronize() {
        engine.resynchronizeVideo()
    }

    var liveStats: CfMotoLiveStats { engine.liveStats }
    var logDump: String { engine.logDump }

    // MARK: - 端口测试

    /// 1.0.83 的端口测试：发一次 `0x70000010` 探测（不是只连 TCP），
    /// 所以「通」意味着握手阶段也能过。
    func probe(host: String, port: UInt16 = 10930, timeout: TimeInterval = 3,
               completion: @escaping (String, Bool) -> Void) {
        engine.testDashPort(host: host, port: port, completion: completion)
    }

    // MARK: - 日志网页

    private var logServerStarted = false

    /// 日志网页随时可访问：打开设置页就起，不必等 CarPlay 启动。
    func ensureLogServer() {
        if logServerStarted { return }
        logServerStarted = true
        logServer.text = { [weak self] in self?.store.text ?? "" }
        logServer.page = { [weak self] index in
            self?.store.lines(from: index) ?? (index, [])
        }
        logServer.onLog = { [weak self] line in self?.store.append(line) }
        logServer.start()
        log("日志服务地址：\(logURL)（手机自身的浏览器可用 http://127.0.0.1:\(CfMotoLogServer.defaultPort)/）")
    }

    var logURL: String {
        guard let address = ReceiverConfiguration.wifiIPv4Address() else { return "未连接 Wi-Fi" }
        return "http://\(address):\(CfMotoLogServer.defaultPort)/"
    }

    var logURLValue: URL? {
        URL(string: logURL)
    }

    // MARK: - 日志

    private func log(_ line: String) {
        store.append(line)
        onLog?(line)
    }
}
