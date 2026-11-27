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

import Dispatch
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
        // 车机在 REQ_RV_CONFIG_CAPTURE(16) 里报分辨率；引擎协商完就在这里回调（主线程）。
        engine.onCanvas = { [weak self] canvas in self?.handleCanvas(canvas) }
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
        // 正式投屏要接管链路：正在等分辨率的那次查询直接作废，别让它把新会话停掉。
        abandonCanvasQuery("已开始正式投屏，分辨率查询取消")
        // 真正的 CarPlay 会话开始前先关掉测试图案，避免把彩条推给车机（1.0.83 同样如此）。
        if engine.testPattern {
            engine.stopTestPattern()
            log("已停止测试图案，准备启动 CarPlay")
        }
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
            log("测试图案：关 —— 停止测试链路")
        } else {
            log("测试图案：开 —— 启动本机端口并探测 \(host):\(port)")
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
        engine.testDashPort(host: host, port: port) { [weak self] message, ok in
            // 1.0.83 把探测结果也写进 EasyConn 日志，车边排查时能对上时间点。
            self?.log(message)
            completion(message, ok)
        }
    }

    // MARK: - 分辨率查询（端口测试的第二步）

    /// 车机最近一次上报的分辨率（只在内存里，不落盘）。
    private(set) var lastCanvas: VideoCanvas?

    private final class CanvasQuery {
        let completion: (String, Bool) -> Void
        init(completion: @escaping (String, Bool) -> Void) {
            self.completion = completion
        }
    }

    private var canvasQuery: CanvasQuery?
    private var canvasDeadline: DispatchWorkItem?

    /// 端口测试 + 取分辨率：探测应答之后拉一段链路，等车机在 `REQ_RV_CONFIG_CAPTURE(16)` 里把
    /// 分辨率报上来（我们回 `RLY_CONFIG_CAPTURE(17)`，带的编码参数就是协商结果），拿到就停链路。
    ///
    /// - 链路本来就在跑（正式投屏 / 测试图案）时什么都不动，只读已经协商好的结果。
    /// - `progress` 用于在按钮上显示「正在等车机上报分辨率…」。
    func probeThenQueryCanvas(host: String, port: UInt16, timeout: TimeInterval = 15,
                              progress: ((String) -> Void)? = nil,
                              completion: @escaping (String, Bool) -> Void) {
        probe(host: host, port: port) { [weak self] summary, accepted in
            guard let self else { return }
            guard accepted else {
                completion(summary, false)
                return
            }
            if self.engine.isLinkActive || self.engine.testPattern {
                if let canvas = self.engine.negotiatedCanvas ?? self.lastCanvas {
                    completion("✅ 车机分辨率 \(Self.describe(canvas))（链路在跑，直接读取）", true)
                } else {
                    completion("\(summary)；链路正在运行，车机还没报分辨率", true)
                }
                return
            }
            progress?("探测通过，正在等车机上报分辨率…（最多 \(Int(timeout)) 秒）")
            self.beginCanvasQuery(host: host, port: port, timeout: timeout, completion: completion)
        }
    }

    private func beginCanvasQuery(host: String, port: UInt16, timeout: TimeInterval,
                                  completion: @escaping (String, Bool) -> Void) {
        abandonCanvasQuery(nil)
        log("[分辨率] 探测已通过，拉起链路等车机上报 REQ_RV_CONFIG_CAPTURE…")
        canvasQuery = CanvasQuery(completion: completion)
        let work = DispatchWorkItem { [weak self] in self?.finishCanvasQuery(timeout: timeout) }
        canvasDeadline = work
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: work)
        // 复用 1.0.83 的「无 CarPlay 会话」链路：监听端口、等车机回连、走完握手。
        engine.startTestPattern(host: host, port: String(port))
    }

    private func handleCanvas(_ canvas: VideoCanvas) {
        lastCanvas = canvas
        guard let query = canvasQuery else { return }
        canvasQuery = nil
        canvasDeadline?.cancel()
        canvasDeadline = nil
        engine.stopTestPattern()
        let text = "✅ 车机分辨率 \(Self.describe(canvas))（探测已应答）"
        log("[分辨率] \(text)，测试链路已停")
        query.completion(text, true)
    }

    private func finishCanvasQuery(timeout: TimeInterval) {
        canvasDeadline = nil
        guard let query = canvasQuery else { return }
        canvasQuery = nil
        engine.stopTestPattern()
        let text = "⚠️ 探测通过，但 \(Int(timeout)) 秒内没等到车机上报分辨率（测试链路已停）"
        log("[分辨率] \(text)")
        query.completion(text, false)
    }

    /// 作废正在进行的查询；`reason` 为 nil 表示只是重新开始，不回报。
    private func abandonCanvasQuery(_ reason: String?) {
        canvasDeadline?.cancel()
        canvasDeadline = nil
        guard let query = canvasQuery else { return }
        canvasQuery = nil
        guard let reason else { return }
        log("[分辨率] \(reason)")
        query.completion(reason, false)
    }

    private static func describe(_ canvas: VideoCanvas) -> String {
        var text = "\(canvas.width)×\(canvas.height)"
        if canvas.requestedWidth != canvas.width || canvas.requestedHeight != canvas.height {
            text += "（车机请求 \(canvas.requestedWidth)×\(canvas.requestedHeight)）"
        }
        if let fps = canvas.requestedFps { text += " · \(fps) fps" }
        return text
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
        // 日志首行是在 App 启动那一瞬拼的，那时系统 SSID 还没读回来；这里补一行说明最终结果。
        SystemWiFiName.onResolved = { [weak self] result in
            switch result {
            case .available(let name):
                self?.log("[网络] 系统 Wi-Fi：\(name)（日志首行的 Wi-Fi 是启动时的快照）")
            case .locationDenied:
                self?.log("[网络] 系统 Wi-Fi 读不到：未授权定位。日志里的 Wi-Fi 是预设值")
            case .unavailable:
                self?.log("[网络] 系统 Wi-Fi 读不到：有定位权限仍被拒绝（多半是签名没带 wifi-info 权限）。日志里的 Wi-Fi 是预设值")
            case .notAttempted:
                break
            }
        }
    }

    var logURL: String {
        guard let address = ReceiverConfiguration.wifiIPv4Address() else { return "未连接 Wi-Fi" }
        return "http://\(address):\(CfMotoLogServer.defaultPort)/"
    }

    var logURLValue: URL? {
        URL(string: logURL)
    }

    // MARK: - 日志

    func log(_ line: String) {
        store.append(line)
        onLog?(line)
    }
}
