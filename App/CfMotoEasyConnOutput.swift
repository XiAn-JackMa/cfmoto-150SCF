// SPDX-License-Identifier: AGPL-3.0-only
//
// 春风 EasyConn 输出（1.0.6 基线）。
//
// 分工：
//   · `PxcConnection`（1.0.6 原有）负责握手、身份、保活、重连；
//   · `CfMotoVideoSource`（从 1.0.83 移植）负责解码 CarPlay 的 H.264、缩放、
//     重新编码、静态补位、测试图案，并读取 `CfMotoTuning` 的画质参数。
//
// 本文件自己不碰协议细节，只做三件事：连接编排、把仪表的一次拉帧翻译成
// 「向视频源要一帧 → 发出去」、以及把日志与统计暴露给设置页。
//
// 与上游 `CfmotoOutput` 的关系：那个类仍然原样服务「春风 5 寸 / 6.2 寸」，
// 本类只服务「春风 EasyConn」，两者互不影响。

import Foundation
import Network

final class CfMotoEasyConnOutput {
    /// 视频源的日志与回调都从它自己的队列/任务里出来，这里统一收进日志环。
    private let queue: DispatchQueue

    private let source = CfMotoVideoSource()
    private let logServer = CfMotoLogServer()
    let store = CfMotoLogStore()

    var onState: ((String) -> Void)?
    var onLog: ((String) -> Void)?
    var onKeyframeRequest: (() -> Void)?
    var onGiveUp: (() -> Void)?

    private let lock = NSLock()
    private var link: PxcConnection?
    private var worker: Thread?
    private var cancelled = true
    private var preparedCanvas = ""
    private var reportedPicture = false
    private var maxBitrate = 4_500_000
    private var maxFps = 30
    private var localAddress = ""
    private var targetAddress = ""
    private var phone: TailingPhoneInfo?

    init(name: String = "cfmoto-easyconn") {
        queue = DispatchQueue(label: "CarWithin.\(name)", qos: .userInitiated)
        source.log = { [weak self] line in self?.log(line) }
        source.onKeyframeRequest = { [weak self] in self?.onKeyframeRequest?() }
    }

    deinit { stop() }

    // MARK: - 生命周期

    /// - Parameters:
    ///   - maxBitrate / maxFps：上游 profile 的上限，画质参数在此之下取用户值。
    func start(localAddress: String, targetAddress: String, phone: TailingPhoneInfo,
               maxBitrate: Int, maxFps: Int,
               onState: @escaping (String) -> Void, onLog: @escaping (String) -> Void,
               onKeyframeRequest: @escaping () -> Void, onGiveUp: (() -> Void)? = nil) {
        stop()
        self.localAddress = localAddress
        self.targetAddress = targetAddress
        self.phone = phone
        self.maxBitrate = max(maxBitrate, 400_000)
        self.maxFps = max(maxFps, 10)
        self.onState = onState
        self.onLog = onLog
        self.onKeyframeRequest = onKeyframeRequest
        self.onGiveUp = onGiveUp
        lock.lock()
        cancelled = false
        preparedCanvas = ""
        reportedPicture = false
        lock.unlock()
        source.restart()
        source.reloadTuning()
        startLogServer()
        let thread = Thread { [weak self] in self?.run() }
        thread.name = "cfmoto-easyconn"
        thread.qualityOfService = .userInitiated
        lock.lock(); worker = thread; lock.unlock()
        thread.start()
    }

    func stop() {
        lock.lock()
        guard !cancelled else { lock.unlock(); return }
        cancelled = true
        worker = nil
        lock.unlock()
        closeLink()
        source.shutdown()
        logServer.stop()
    }

    private var active: Bool {
        lock.lock(); defer { lock.unlock() }
        return !cancelled
    }

    // MARK: - 画面参数 / 测试图案

    /// 用户在面板里改完参数后调用：重建编码器，并在日志里留一行凭证。
    func reloadTuning() {
        source.reloadTuning()
        lock.lock(); preparedCanvas = ""; lock.unlock()
        log("画面参数已应用：\(CfMotoTuning.fullSummary)（编码器已重建）")
    }

    func setTestPattern(_ on: Bool) {
        source.testPattern = on
        log("测试图案 \(on ? "已开启 —— 仪表应显示彩条" : "已关闭")")
    }

    var testPatternEnabled: Bool { source.testPattern }

    // MARK: - CarPlay 画面输入

    func append(_ data: Data, codec: VideoCodec, keyframe: Bool) {
        guard codec == .h264 else { return }
        source.append(data, codec: codec, keyframe: keyframe)
    }

    func resynchronize() {
        source.resynchronize()
    }

    var liveStats: CfMotoLiveStats { source.liveStats }
    var logDump: String { store.text }

    // MARK: - 端口测试

    /// 探测仪表会不会应答 EasyConn 的发现端口（默认 10930）。
    ///
    /// 只做「连得上吗」，不发任何协议字节：用来区分「网络不通」和
    /// 「连得上但握手不过」。
    func probe(host: String, port: UInt16 = 10930, timeout: TimeInterval = 3,
               completion: @escaping (String, Bool) -> Void) {
        guard !host.isEmpty else {
            completion("请先填写仪表 IP 地址", false)
            return
        }
        let started = Date()
        let result = ProbeBox()
        let connection = NWConnection(host: NWEndpoint.Host(host),
                                      port: NWEndpoint.Port(rawValue: port) ?? 10930,
                                      using: .tcp)
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                guard result.claim() else { return }
                let ms = Int((Date().timeIntervalSince(started) * 1000).rounded())
                completion("通过 \(host):\(port) · \(ms) ms", true)
            case .failed(let error):
                guard result.claim() else { return }
                completion("失败：\(error.localizedDescription)", false)
            case .waiting(let error):
                guard result.claim() else { return }
                completion("不可达：\(error.localizedDescription)", false)
            default:
                break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + timeout) {
            guard result.claim() else { return }
            completion("超时：\(String(format: "%.0f", timeout)) 秒内没有应答", false)
        }
        queue.asyncAfter(deadline: .now() + timeout + 0.2) { connection.cancel() }
    }

    // MARK: - 主循环

    private func run() {
        var retryAttempt = 0
        let retryDelays: [TimeInterval] = [1.5, 3.0, 5.0]
        var disconnectedSince: TimeInterval?
        let giveUpAfter: TimeInterval = 180
        report("正在连接春风 EasyConn 仪表…")
        while active {
            guard let phone else { return }
            guard let target = targetAddress.isEmpty ? PxcConnection.gateway(for: localAddress) : targetAddress else {
                report("没有可用的仪表地址")
                return
            }
            let conn = PxcConnection(localIP: localAddress, targetIP: target, phone: phone,
                                     dashboard: "春风 EasyConn", discoversEasyConn: true,
                                     log: { [weak self] in self?.log($0) })
            guard install(conn) else { return }
            do {
                try conn.start()
                guard active else { break }
                let size = conn.mediaSize
                prepare(size)
                log("仪表已连接，协商尺寸 \(size.width)×\(size.height)@\(size.fps)")
                report("仪表已连接，等待 CarPlay 画面…")
                while active {
                    try conn.checkHealth()
                    try conn.waitForH264Request()
                    guard active else { break }
                    guard let frame = pullFrame(timeout: 2.0) else {
                        // 视频源暂时没有画面（CarPlay 还没起）：别空转。
                        Thread.sleep(forTimeInterval: 0.05)
                        continue
                    }
                    try conn.sendH264(frame.accessUnit)
                    retryAttempt = 0
                    disconnectedSince = nil
                    reportOnce("正在投屏 · \(canvasText) · H.264")
                }
                source.mediaStopped()
            } catch {
                guard active else { break }
                source.mediaStopped()
                clear(conn)
                conn.close()
                let now = ProcessInfo.processInfo.systemUptime
                if disconnectedSince == nil { disconnectedSince = now }
                if let since = disconnectedSince, now - since >= giveUpAfter {
                    log("连续 3 分钟无法连接仪表，已自动停止以节省后台资源")
                    report("持续连接失败，已自动停止")
                    onGiveUp?()
                    return
                }
                let delay = retryDelays[min(retryAttempt, retryDelays.count - 1)]
                retryAttempt += 1
                lock.lock(); reportedPicture = false; lock.unlock()
                log("输出中断（\(error.localizedDescription)），\(String(format: "%.1f", delay)) 秒后重连（第 \(retryAttempt) 次）")
                report("断开，正在重连…")
                sleepWhileActive(delay)
                continue
            }
            clear(conn)
            conn.close()
        }
    }

    private var canvasText: String {
        lock.lock(); defer { lock.unlock() }
        return preparedCanvas.isEmpty ? "—" : preparedCanvas
    }

    private func reportOnce(_ state: String) {
        lock.lock()
        guard !reportedPicture else { lock.unlock(); return }
        reportedPicture = true
        lock.unlock()
        report(state)
    }

    /// 把协商尺寸与画质参数交给视频源；画布可被「固定画布」覆盖。
    private func prepare(_ size: PxcConnection.MediaSize) {
        let override = CfMotoTuning.canvasOverrideSize
        let width = max(override?.width ?? size.width, 2)
        let height = max(override?.height ?? size.height, 2)
        let signature = "\(width)×\(height)@\(min(maxFps, CfMotoTuning.frameRate))"
        lock.lock()
        let same = preparedCanvas == signature
        preparedCanvas = signature
        lock.unlock()
        guard !same else { return }
        let canvas = VideoCanvas(width: width, height: height,
                                 requestedWidth: size.width, requestedHeight: size.height,
                                 requestedFps: size.fps)
        let parameters = EncoderParameters(bitrate: min(maxBitrate, CfMotoTuning.bitrate),
                                           frameRate: min(maxFps, CfMotoTuning.frameRate),
                                           keyframeIntervalSeconds: CfMotoTuning.keyframeSeconds,
                                           forceBaseline: CfMotoTuning.forceBaseline,
                                           repeatLastFrameAfter: CfMotoTuning.staticIdleSeconds)
        source.prepare(canvas: canvas, parameters: parameters)
        log("编码 \(canvas.width)×\(canvas.height) · \(parameters.frameRate) FPS · "
            + "\(String(format: "%.1f", Double(parameters.bitrate) / 1_000_000)) Mbit/s · "
            + "关键帧 \(String(format: "%.1f", parameters.keyframeIntervalSeconds)) s"
            + (override == nil ? "" : " · 固定画布"))
    }

    /// 视频源的 `nextFrame` 是 async，而拉帧循环是同步阻塞的，这里用信号量搭一座桥。
    private final class FrameBox: @unchecked Sendable {
        private let lock = NSLock()
        private var frame: EncodedFrame?
        func set(_ value: EncodedFrame?) { lock.lock(); frame = value; lock.unlock() }
        func take() -> EncodedFrame? { lock.lock(); defer { lock.unlock() }; return frame }
    }

    private func pullFrame(timeout: TimeInterval) -> EncodedFrame? {
        let box = FrameBox()
        let semaphore = DispatchSemaphore(value: 0)
        let source = self.source
        Task.detached(priority: .userInitiated) {
            let frame = await source.nextFrame(timeout: timeout)
            box.set(frame)
            semaphore.signal()
        }
        if semaphore.wait(timeout: .now() + timeout + 1.5) == .timedOut {
            log("等待编码帧超时（\(String(format: "%.1f", timeout)) 秒）")
            return nil
        }
        return box.take()
    }

    // MARK: - 连接簿记

    private func install(_ next: PxcConnection) -> Bool {
        lock.lock()
        guard !cancelled else { lock.unlock(); return false }
        let previous = link
        link = next
        lock.unlock()
        previous?.close()
        return true
    }

    private func clear(_ target: PxcConnection) {
        lock.lock()
        if link === target { link = nil }
        lock.unlock()
    }

    private func closeLink() {
        lock.lock()
        let current = link
        link = nil
        lock.unlock()
        current?.close()
    }

    private func sleepWhileActive(_ seconds: TimeInterval) {
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        while active {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            if remaining <= 0 { break }
            Thread.sleep(forTimeInterval: min(remaining, 0.1))
        }
    }

    // MARK: - 日志

    private func log(_ line: String) {
        store.append(line)
        onLog?(line)
    }

    private func report(_ state: String) {
        onState?(state)
    }

    private func startLogServer() {
        logServer.text = { [weak self] in self?.store.text ?? "" }
        logServer.page = { [weak self] index in
            self?.store.lines(from: index) ?? (index, [])
        }
        logServer.onLog = { [weak self] line in self?.store.append(line) }
        logServer.start()
    }

    /// 只在第一次探测结果上回调，避免「超时」与「稍后失败」重复弹提示。
    private final class ProbeBox: @unchecked Sendable {
        private let lock = NSLock()
        private var claimed = false
        func claim() -> Bool {
            lock.lock(); defer { lock.unlock() }
            if claimed { return false }
            claimed = true
            return true
        }
    }
}
