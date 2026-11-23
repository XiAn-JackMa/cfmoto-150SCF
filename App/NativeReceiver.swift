import Foundation
import Network

/// All listener/session state is confined to queue. UI callbacks are always main-thread.
final class NativeReceiver {
    private let queue = DispatchQueue(label: "TDSCarKit.receiver")
    private var listener: NWListener?
    /// Fires if a fresh listener has not reached .ready: binding can stall without ever
    /// reporting .failed, and then onReady is never called and the UI waits for ever.
    private var readyDeadline: DispatchWorkItem?
    /// Last /feedback seen. The iPhone sends it every two seconds for the whole session; a gap is
    /// the one reliable sign that a connected CarPlay session has actually stopped, as opposed to
    /// merely having nothing new to draw.
    private var lastFeedbackAt: Date?
    private var feedbackCount = 0
    private var connections: [UUID: NWConnection] = [:]
    private var sessions: [UUID: SessionState] = [:]
    /// Access units handed to the main thread but not yet consumed. Over the limit, the local
    /// display skips to the next keyframe instead of dropping arbitrary (dependent) P-frames.
    private var localInFlight = 0
    private var localSkipping = false
    private let maximumLocalInFlight = 12
    #if DEBUG
    private var diagnosticStarted = ProcessInfo.processInfo.systemUptime
    private var diagnosticCPU = TailingPerformanceDiagnostics.cpuTime()
    private var diagnosticFrames = 0, diagnosticBytes = 0
    private var diagnosticPreviousArrival: Double?
    private var diagnosticGap = 0.0, diagnosticWork = 0.0, diagnosticMainDelay = 0.0, diagnosticMainWork = 0.0
    private func recordPerformance(arrival: Double, bytes: Int, work: Double) {
        diagnosticFrames += 1; diagnosticBytes += bytes
        if let previous = diagnosticPreviousArrival { diagnosticGap = max(diagnosticGap, arrival - previous) }
        diagnosticPreviousArrival = arrival; diagnosticWork = max(diagnosticWork, work)
        let elapsed = arrival - diagnosticStarted
        guard elapsed >= 5 else { return }
        let cpu = TailingPerformanceDiagnostics.cpuTime()
        log(String(format: "接收性能：输入 %.1f FPS / %.0f KiB/s，最大帧间隔 %.0f ms，转发最大 %.1f ms，本机队列 %d，主线程排队/处理最大 %.1f/%.1f ms，CPU %.0f%%（单核100%%），热状态 %d，低电量模式 %d",
            Double(diagnosticFrames) / elapsed, Double(diagnosticBytes) / elapsed / 1024,
            diagnosticGap * 1000, diagnosticWork * 1000, localInFlight,
            diagnosticMainDelay * 1000, diagnosticMainWork * 1000,
            (cpu - diagnosticCPU) / elapsed * 100, ProcessInfo.processInfo.thermalState.rawValue,
            ProcessInfo.processInfo.isLowPowerModeEnabled ? 1 : 0))
        diagnosticStarted = arrival; diagnosticCPU = cpu; diagnosticFrames = 0; diagnosticBytes = 0
        diagnosticGap = 0; diagnosticWork = 0; diagnosticMainDelay = 0; diagnosticMainWork = 0
    }
    #endif
    // forceKeyFrame state: throttled sends, resent every second until a keyframe arrives.
    private var keyframeWantedSince: DispatchTime?
    private var keyframeLastSent: DispatchTime?
    private var keyframeAttempts = 0
    private var keyframeReason = ""
    private var touchSlots = TouchSlots(count: CarPlayInfo.touchContacts)
    private var displaySize: (width: Int, height: Int)?
    private var nightMode: Bool?
    private var generation = UUID()
    private var airPlayIdentity: AirPlayCredentials?
    private let videoOutput = VideoOutputServer()
    private let carLife = CarLifeOutput()
    private let zeeho = ZeehoOutput()
    var onZeehoState: ((String) -> Void)?
    private let ninebot = NinebotOutput()
    var onNinebotState: ((String) -> Void)?
    private let tailing = TailingOutput()
    var onTailingState: ((String) -> Void)?
    /// EasyConn output to a CFMOTO / Carbit dashboard.
    private let cfmoto = CfMotoOutput()
    private let cfmotoLogServer = CfMotoLogServer()
    var onCfMotoState: ((String) -> Void)?
    /// The canvas the dash negotiated, so the app can re-render CarPlay at that exact size.
    var onCfMotoCanvas: ((VideoCanvas) -> Void)?
    /// Snapshot for the settings screen's copy button.
    var cfmotoDiagnostics: String { cfmoto.diagnostics }
    /// Live resolution / frame-rate readout for the on-screen labels.
    var cfmotoLiveStats: CfMotoLiveStats { cfmoto.liveStats }
    /// The canvas the current EasyConn session negotiated, nil until the dash reports one.
    var negotiatedCfMotoCanvas: VideoCanvas? { cfmoto.negotiatedCanvas }
    /// Applies the test pattern to a running link, not only to the next start.
    func setCfMotoTestPattern(_ on: Bool) { cfmoto.setTestPattern(on) }
    /// Rebuild the EasyConn video pipeline after the app was in the background.
    func resynchronizeCfMotoVideo() { cfmoto.resynchronizeVideo() }
    /// Bitrate / profile overrides changed on the settings page.
    func applyCfMotoTuning() { cfmoto.applyTuning() }
    /// Full EasyConn log, as shown on screen and served on :10950.
    var cfmotoLogText: String { cfmoto.store.text }
    /// The same log as a file, for the share sheet (works with AirDrop / WeChat / Files).
    var cfmotoLogFile: URL? { cfmoto.store.fileForSharing() }
    func clearCfMotoLog() { cfmoto.store.clear() }
    /// Lets the rest of the app write into the same exported log, so a CarPlay session that never
    /// starts is visible next to the EasyConn traffic instead of missing from it.
    func appendCfMotoLogText(_ line: String) { cfmoto.store.append(line) }
    /// Every EasyConn log line, for the settings screen's text view.
    var onCfMotoLog: ((String) -> Void)?
    private lazy var carLink = CarLinkRelay(queue: queue)
    var onCarLifeState: ((String) -> Void)?
    var onCarLinkState: ((String) -> Void)?
    /// Main thread: the primary browser's screen changed.
    var onBrowserDisplay: ((BrowserDisplay?, UUID?) -> Void)?
    /// Main thread: a browser keeps hitching.
    var onBrowserStruggling: ((String, String) -> Void)?
    /// Main thread: the CarPlay car button was tapped (requestUI).
    var onCarUIRequested: (() -> Void)?
    // NetService must be published/stopped on a thread with a run loop (main).
    private var discoveryService: NetService?
    var onLog: ((String) -> Void)?
    var onListening: ((UInt16) -> Void)?
    var onControlConnected: (() -> Void)?
    var onVideo: ((Data, VideoCodec) -> Void)?
    var onAirPlayReady: ((UUID) -> Void)?
    var onVideoOutputState: ((String) -> Void)?
    var onFailure: (() -> Void)?

    func start(configuration: ReceiverConfiguration, identity: AccessoryIdentity, advertise: Bool = true,
               preferredViewer: UUID? = nil) {
        let listening = onListening
        queue.async { [weak self] in
            guard let self else { return }
            self.log("接收器：队列开始启动")
            self.stopOnQueue()
            self.videoOutput.onLog = { [weak self] in self?.log($0) }
            self.videoOutput.onAirPlayReady = { [weak self] id in
                DispatchQueue.main.async { [weak self] in self?.onAirPlayReady?(id) }
            }
            self.videoOutput.onState = { [weak self] in self?.onVideoOutputState?($0) }
            self.videoOutput.onKeyframeRequest = { [weak self] in self?.requestKeyFrame(reason: $0) }
            self.displaySize = (configuration.width, configuration.height)
            self.videoOutput.onTouches = { [weak self] source, points in self?.touches(source: source, points) }
            self.videoOutput.onControl = { [weak self] in self?.press($0) }
            self.videoOutput.onDisplay = { [weak self] display, viewerID in
                DispatchQueue.main.async { self?.onBrowserDisplay?(display, viewerID) }
            }
            self.videoOutput.onStruggling = { [weak self] peer, reason in DispatchQueue.main.async { self?.onBrowserStruggling?(peer, reason) } }
            if let target = configuration.zeehoAddress {
                let phone = configuration.tailingPhoneInfo ?? TailingPhoneInfo(package: Bundle.main.bundleIdentifier ?? "CarWithin",
                    versionCode: Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0") ?? 0,
                    model: "iPhone", systemVersion: ProcessInfo.processInfo.operatingSystemVersionString,
                    width: configuration.width, height: configuration.height, rotation: 1)
                self.zeeho.start(localAddress: configuration.address, targetAddress: target, phone: phone,
                    onState: { [weak self] in self?.onZeehoState?($0) },
                    onLog: { [weak self] in self?.log($0) },
                    requestKeyframe: { [weak self] in self?.requestKeyFrame(reason: "极核解码恢复") })
            }
            if let target = configuration.ninebotAddress {
                self.ninebot.start(localAddress: configuration.address, targetAddress: target,
                    onState: { [weak self] in self?.onNinebotState?($0) },
                    onLog: { [weak self] in self?.log($0) },
                    requestKeyframe: { [weak self] in self?.requestKeyFrame(reason: "九号解码恢复") })
            }
            if let target = configuration.tailingAddress {
                self.tailing.onLog = { [weak self] in self?.log($0) }
                self.tailing.onState = { [weak self] in self?.onTailingState?($0) }
                self.tailing.onKeyframeRequest = { [weak self] in self?.requestKeyFrame(reason: "台铃解码恢复") }
                let phone = configuration.tailingPhoneInfo ?? TailingPhoneInfo(package: Bundle.main.bundleIdentifier ?? "CarWithin",
                    versionCode: Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0") ?? 0,
                    model: "iPhone", systemVersion: ProcessInfo.processInfo.operatingSystemVersionString,
                    width: configuration.width, height: configuration.height, rotation: 1)
                self.tailing.start(localAddress: configuration.address, targetAddress: target, phone: phone)
            }
            if let target = configuration.cfmotoAddress {
                self.cfmoto.onLog = { [weak self] in
                    self?.onCfMotoLog?($0)
                    // Only the EasyConn view. The line is already in the store (CfMotoOutput writes
                    // it there); routing it through log() as well wrote every line twice, because
                    // log() mirrors to that same store.
                }
                self.cfmoto.onState = { [weak self] in self?.onCfMotoState?($0) }
                self.cfmoto.onCanvas = { [weak self] in self?.onCfMotoCanvas?($0) }
                self.cfmoto.onKeyframeRequest = { [weak self] in
                    self?.requestKeyFrame(reason: "CFMOTO 解码恢复")
                }
                self.cfmoto.setTestPattern(configuration.cfmotoTestPattern)
                self.cfmoto.start(localAddress: ReceiverConfiguration.wifiIPv4Address() ?? configuration.address,
                                  targetAddress: target, port: configuration.cfmotoPort)
                // Read the log from a PC instead of copying it off the phone by hand.
                self.cfmotoLogServer.text = { [weak self] in
                    guard let self else { return "" }
                    return self.cfmotoDiagnostics + "\n\n" + self.cfmotoLogText
                }
                self.cfmotoLogServer.page = { [weak self] since in
                    guard let self else { return (since, []) }
                    return self.cfmoto.store.lines(from: since)
                }
                self.cfmotoLogServer.onLog = { [weak self] in self?.log($0) }
                self.cfmotoLogServer.start()
            }
            if configuration.carLifeEnabled {
                self.carLife.onLog = { [weak self] in self?.log($0) }
                self.carLife.onState = { [weak self] in self?.onCarLifeState?($0) }
                self.carLife.onTouches = { [weak self] in self?.touches(source: "carlife", $0) }
                self.carLife.onControl = { [weak self] in self?.press($0) }
                self.carLife.onKeyframeRequest = { [weak self] in self?.requestKeyFrame(reason: $0) }
                self.carLife.start(targetAddress: configuration.carLifeAddress, width: configuration.width,
                                   height: configuration.height, fps: configuration.maxFPS)
            }
            if let address = configuration.carLinkRelayAddress {
                self.carLink.onState = { [weak self] status in
                    self?.log(status)
                    DispatchQueue.main.async { [weak self] in self?.onCarLinkState?(status) }
                }
                self.carLink.onTouches = { [weak self] in self?.touches(source: "carlink-relay", $0) }
                self.carLink.onControl = { [weak self] in self?.press($0) }
                self.carLink.onKeyframe = { [weak self] in self?.requestKeyFrame(reason: "CarLink 中继") }
                self.carLink.start(host: address, port: ReceiverConfiguration.carLinkRelayPort, fps: configuration.maxFPS)
            }
            if let port = configuration.videoOutputPort {
                self.videoOutput.start(port: port, securePort: configuration.secureVideoOutputPort,
                                       width: configuration.width, height: configuration.height, fps: configuration.maxFPS,
                                       performance: configuration.browserPerformance, showTouches: configuration.showTouches,
                                       preferredViewer: preferredViewer, browserAudio: configuration.browserAudio,
                                       airPlayStreamID: configuration.airPlayStreamID)
            }
            do { self.airPlayIdentity = advertise ? try AirPlayCredentials() : nil }
            catch { self.fail("AirPlay 身份创建失败：\(error.localizedDescription)"); return }
            if configuration.audioEnabled {
                do {
                    for bits: UInt64 in [0x10000000, 0x20000000, 0x40000000] {
                        let format = try ReceiverAudioFormat(bits: bits)
                        _ = try NativeAudioDecoder(format: format)
                        _ = try NativeOpusEncoder(rate: format.sampleRate)
                    }
                    self.log("原生 Opus 语音编解码器可用（16/24/48 kHz）")
                } catch { self.fail("无线音频编解码器不可用：\(error.localizedDescription)"); return }
            }
            self.log("请求 \(configuration.width)×\(configuration.height) @ \(configuration.maxFPS) FPS，\(configuration.videoCodec.displayName)；音频\(configuration.audioEnabled ? "已启用（PCM/AAC/Opus）" : "已关闭")")
            self.listen(configuration: configuration, identity: identity, port: configuration.port, onReady: listening)
        }
    }
    private func listen(configuration: ReceiverConfiguration, identity: AccessoryIdentity, port: UInt16?, onReady: ((UInt16) -> Void)?) {
        let generation = self.generation
        do {
            let candidate = try NWListener(using: .tcp, on: port.flatMap(NWEndpoint.Port.init(rawValue:)) ?? .any)
            if let airPlayIdentity {
                let features = CarPlayInfo.features(audio: configuration.audioEnabled)
                let txt: [String: String] = ["deviceid": configuration.deviceID,
                    "features": String(format: "0x%x,0x%x", UInt32(truncatingIfNeeded: features), UInt32(truncatingIfNeeded: features >> 32)),
                    "flags": "0x4", "model": "TDSCarKit1,1", "srcvers": "509.11", "protovers": "1.1",
                    "pi": airPlayIdentity.identifier, "pk": airPlayIdentity.signingKey.publicKey.rawRepresentation.map { String(format: "%02x", $0) }.joined()]
                candidate.service = NWListener.Service(name: configuration.name, type: "_airplay._tcp", txtRecord: NWTXTRecord(txt))
                candidate.serviceRegistrationUpdateHandler = { [weak self] change in self?.log("Bonjour 注册状态：\(change)") }
            }
            listener = candidate
            candidate.stateUpdateHandler = { [weak self, weak candidate] state in
                guard let self, let candidate, self.generation == generation, self.listener === candidate else { return }
                switch state {
                case .ready:
                    guard let actualPort = candidate.port?.rawValue else { self.fail("监听器未获得端口"); return }
                    self.log("原生 RTSP 监听器已在端口 \(actualPort) 就绪")
                    self.readyDeadline?.cancel(); self.readyDeadline = nil
                    let advertiseDiscovery = self.airPlayIdentity != nil
                    DispatchQueue.main.async { [weak self] in
                        guard let self else { return }
                        if advertiseDiscovery {
                            let service = NetService(domain: "local.", type: ReceiverConfiguration.discoveryType,
                                name: configuration.name, port: Int32(actualPort))
                            service.setTXTRecord(NetService.data(fromTXTRecord: [
                                "app": Data("TDSCarKit".utf8), "deviceid": Data(configuration.deviceID.utf8)]))
                            self.discoveryService?.stop(); self.discoveryService = service; service.publish()
                            self.onLog?("正在通过 \(ReceiverConfiguration.discoveryType) 发布 \(configuration.name)")
                        }
                        onReady?(actualPort)
                    }
                case .failed(let error):
                    if port != nil, case .posix(.EADDRINUSE) = error {
                        self.log("端口 \(port!) 已被占用，正在申请可用端口")
                        candidate.cancel(); self.listener = nil
                        self.listen(configuration: configuration, identity: identity, port: nil, onReady: onReady)
                    } else { self.fail("监听器失败：\(error.localizedDescription)") }
                case .waiting(let error):
                    // A listener that cannot bind reports .waiting, not .failed, and never becomes
                    // .ready on its own. Swallowing it left onReady uncalled, so sameDevice.start
                    // never ran and the app sat on "正在启动本机 CarPlay" with nothing in the log -
                    // which is exactly what a port still held by the previous session looks like.
                    self.log("监听器等待中：\(error.localizedDescription)")
                    if port != nil, case .posix(.EADDRINUSE) = error {
                        self.log("端口 \(port!) 仍被占用，改用任意端口")
                        candidate.cancel(); self.listener = nil
                        self.listen(configuration: configuration, identity: identity, port: nil, onReady: onReady)
                    }
                case .cancelled, .setup:
                    break
                }
            }
            // Binding can stall without ever reporting .failed - typically while the previous
            // listener still holds the port. Give it five seconds, then fall back to any port, so a
            // start can never sit on "正在启动本机 CarPlay" for ever.
            readyDeadline?.cancel()
            let deadline = DispatchWorkItem { [weak self, weak candidate] in
                guard let self, let candidate, self.listener === candidate,
                      self.generation == generation else { return }
                self.log("监听器 5 秒未就绪（端口可能仍被占用）")
                candidate.cancel(); self.listener = nil
                if port != nil {
                    self.listen(configuration: configuration, identity: identity, port: nil, onReady: onReady)
                } else {
                    self.fail("监听器 5 秒未就绪，无法启动")
                }
            }
            readyDeadline = deadline
            queue.asyncAfter(deadline: .now() + 5, execute: deadline)
            candidate.newConnectionHandler = { [weak self, weak candidate] connection in
                guard let self, self.generation == generation, self.listener === candidate,
                      self.connections.count < 8 else { connection.cancel(); return }
                let id = UUID(); self.connections[id] = connection
                let state = SessionState(credentials: self.airPlayIdentity)
                self.sessions[id] = state
                if case .hostPort(let host, _) = connection.endpoint { state.peerAddress = "\(host)" }
                connection.stateUpdateHandler = { [weak self, weak connection] update in
                    guard let self, let connection else { return }
                    switch update {
                    case .ready:
                        self.log("收到控制连接")
                        DispatchQueue.main.async { [weak self] in self?.onControlConnected?() }
                        self.receive(connection, id: id, state: state, configuration: configuration, identity: identity)
                    case .failed, .cancelled:
                        state.media?.stop(); self.sessions.removeValue(forKey: id); self.connections.removeValue(forKey: id)
                    default: break
                    }
                }
                connection.start(queue: self.queue)
            }
            candidate.start(queue: queue)
        } catch let error as NWError {
            if port != nil, case .posix(.EADDRINUSE) = error {
                log("端口 \(port!) 已被占用，正在申请可用端口")
                listen(configuration: configuration, identity: identity, port: nil, onReady: onReady)
            } else { fail("无法创建监听器：\(error.localizedDescription)") }
        } catch { fail("无法创建监听器：\(error)") }
    }
    private func noteFeedback() {
        let now = Date()
        if let last = lastFeedbackAt {
            let gap = now.timeIntervalSince(last)
            if gap > 6 { log("[警告] CarPlay 心跳中断 \(Int(gap)) 秒后恢复（/feedback）") }
        } else {
            log("CarPlay 心跳已建立：iPhone 每 2 秒发一次 /feedback")
        }
        lastFeedbackAt = now
        feedbackCount += 1
    }

    private func fail(_ message: String) {
        log(message); stopOnQueue()
        DispatchQueue.main.async { [weak self] in self?.onFailure?() }
    }
    func stop() { queue.async { [weak self] in self?.stopOnQueue() } }
    private var activeMedia: CarPlayMediaSession? { sessions.values.first(where: { $0.media != nil })?.media }
    /// All fingers currently held by `source` (normalized 0…1); an empty list releases them.
    func touches(source: String, _ points: [TouchPoint]) {
        queue.async { [weak self] in
            guard let self, let size = self.displaySize else { return }
            let report = self.touchSlots.update(source: source, points: points)
            guard !report.isEmpty else { return }
            let contacts = report.map { entry in
                CarPlayInfo.TouchContact(slot: entry.slot,
                    x: UInt16(clamping: Int((min(max(entry.x, 0), 1) * Double(max(size.width - 1, 0))).rounded())),
                    y: UInt16(clamping: Int((min(max(entry.y, 0), 1) * Double(max(size.height - 1, 0))).rounded())),
                    down: entry.down)
            }
            self.activeMedia?.touch(contacts)
        }
    }
    func press(_ control: CarPlayControl) {
        queue.async { [weak self] in
            guard let self, let media = self.activeMedia else { self?.log("CarPlay 尚未连接，无法发送「\(control.title)」"); return }
            let knobUp = CarPlayInfo.knobReport()
            switch control {
            case .home: media.pressHID(CarPlayInfo.HID.knob, CarPlayInfo.knobReport(home: true), release: knobUp)
            case .back: media.pressHID(CarPlayInfo.HID.knob, CarPlayInfo.knobReport(back: true), release: knobUp)
            case .select: media.pressHID(CarPlayInfo.HID.knob, CarPlayInfo.knobReport(select: true), release: knobUp)
            case .knobPrevious: media.pressHID(CarPlayInfo.HID.knob, CarPlayInfo.knobReport(wheel: -1), release: knobUp)
            case .knobNext: media.pressHID(CarPlayInfo.HID.knob, CarPlayInfo.knobReport(wheel: 1), release: knobUp)
            case .previous: media.pressHID(CarPlayInfo.HID.media, Data([CarPlayInfo.MediaKey.previous.rawValue]), release: Data([0]))
            case .playPause: media.pressHID(CarPlayInfo.HID.media, Data([CarPlayInfo.MediaKey.playPause.rawValue]), release: Data([0]))
            case .next: media.pressHID(CarPlayInfo.HID.media, Data([CarPlayInfo.MediaKey.next.rawValue]), release: Data([0]))
            case .siri: media.requestSiri()
            case .hookSwitch: media.pressHID(CarPlayInfo.HID.telephony, Data([CarPlayInfo.TelephonyKey.hookSwitch.rawValue]), release: Data([0]))
            }
        }
    }
    /// Day/night appearance for CarPlay. Remembered across sessions and sent once the event channel is up.
    func setNightMode(_ night: Bool) {
        queue.async { [weak self] in
            guard let self, self.nightMode != night else { return }
            self.nightMode = night
            self.sessions.values.forEach { $0.media?.setNightMode(night) }
        }
    }
    /// Thread-safe entry for decoders (local display, browser viewers) that need a fresh keyframe.
    func requestKeyFrame(reason: String) {
        queue.async { [weak self] in self?.requestKeyFrameOnQueue(reason: reason) }
    }
    private func requestKeyFrameOnQueue(reason: String) {
        let now = DispatchTime.now()
        if keyframeWantedSince == nil { keyframeWantedSince = now; keyframeAttempts = 0; keyframeReason = reason }
        // 250 ms throttle: several viewers recovering together share one request.
        if let last = keyframeLastSent, now.uptimeNanoseconds - last.uptimeNanoseconds < 250_000_000 { return }
        sendKeyFrameRequest()
    }
    private func sendKeyFrameRequest() {
        guard keyframeWantedSince != nil else { return }
        guard let media = sessions.values.first(where: { $0.media?.hasEventChannel == true })?.media else { return }
        keyframeAttempts += 1
        keyframeLastSent = .now()
        guard media.requestKeyFrame() else { return }
        if keyframeAttempts == 1 { log("已请求关键帧（\(keyframeReason)）") }
        // Keep asking instead of giving up: this is the only way to recover without a reconnect, and
        // it is exactly what is needed after the app returns from the background (iOS stops feeding
        // video, the decoder loses its references, and a frozen dash looks like a live stream).
        // The interval widens so a dash-facing session does not spam the request channel.
        let interval: TimeInterval = keyframeAttempts < 8 ? 1 : 3
        if keyframeAttempts == 8 { log("关键帧仍未到达，改为每 3 秒重试，直到收到为止") }
        let run = generation
        queue.asyncAfter(deadline: .now() + interval) { [weak self] in
            guard let self, self.generation == run, self.keyframeWantedSince != nil else { return }
            self.sendKeyFrameRequest()
        }
    }
    private func keyframeArrived() {
        guard let since = keyframeWantedSince else { return }
        keyframeWantedSince = nil
        let ms = (DispatchTime.now().uptimeNanoseconds - since.uptimeNanoseconds) / 1_000_000
        log("关键帧已到达（\(ms) ms，\(keyframeAttempts) 次请求）")
    }
    private static func containsRandomAccess(_ accessUnit: Data, codec: VideoCodec) -> Bool {
        (try? AnnexB.units(in: accessUnit))?.contains { codec.isRandomAccess($0) } ?? false
    }
    private func stopOnQueue() {
        log("接收器：停止开始")
        log("接收器：停止开始")
        // The heartbeat belongs to one CarPlay session; without this the gap across a stop/start
        // was reported as a 30-plus second "heartbeat lost".
        lastFeedbackAt = nil
        DispatchQueue.main.async { [weak self] in self?.discoveryService?.stop(); self?.discoveryService = nil }
        readyDeadline?.cancel(); readyDeadline = nil
        generation = UUID(); listener?.cancel(); listener = nil
        step("videoOutput") { videoOutput.stop() }
        step("carLife") { carLife.stop() }
        step("zeeho") { zeeho.stop() }
        step("ninebot") { ninebot.stop() }
        step("tailing") { tailing.stop() }
        step("cfmoto") { cfmoto.stop() }
        step("cfmotoLogServer") { cfmotoLogServer.stop() }
        step("carLink") { carLink.stop() }
        #if DEBUG
        diagnosticStarted = ProcessInfo.processInfo.systemUptime
        diagnosticCPU = TailingPerformanceDiagnostics.cpuTime()
        diagnosticFrames = 0; diagnosticBytes = 0; diagnosticPreviousArrival = nil
        diagnosticGap = 0; diagnosticWork = 0; diagnosticMainDelay = 0; diagnosticMainWork = 0
        #endif
        localSkipping = false; keyframeWantedSince = nil; keyframeLastSent = nil; keyframeAttempts = 0
        touchSlots.reset()
        for connection in connections.values { connection.cancel() }
        connections.removeAll()
        sessions.values.forEach { $0.media?.stop() }; sessions.removeAll()
        log("接收器：停止完成")
    }
    /// Names the step a stop is in. A stop that blocks used to leave only "停止开始" behind, with no
    /// way to tell which of the eight teardowns never returned.
    private func step(_ name: String, _ body: () -> Void) {
        // Only the start line is unconditional: it identifies the step if one ever blocks (its
        // "完成" never arrives). A step that finishes quickly says nothing, because five of the eight
        // outputs are not running and their stop() is a no-op - logging those made a 4 ms teardown
        // look like heavy work.
        log("接收器：停止 → \(name)")
        let started = ProcessInfo.processInfo.systemUptime
        body()
        let took = (ProcessInfo.processInfo.systemUptime - started) * 1000
        if took >= 5 { log(String(format: "接收器：停止 · %@ 用了 %.0f 毫秒", name, took)) }
    }

    private final class SessionState {
        var parser = RTSPParser()
        var authenticated = false
        var setup: PairSetup?
        var verify: PairVerify?
        var cipher: ControlCipher?
        var media: CarPlayMediaSession?
        var peerAddress = ""
        init(credentials: AirPlayCredentials?) {
            if let credentials {
                setup = PairSetup(identifier: credentials.identifier, signingKey: credentials.signingKey) {
                    try credentials.saveController($0, key: $1)
                }
                verify = PairVerify(identifier: credentials.identifier, signingKey: credentials.signingKey) {
                    try? credentials.controller($0)
                }
            }
        }
    }
    private func receive(_ connection: NWConnection, id: UUID, state: SessionState,
                         configuration: ReceiverConfiguration, identity: AccessoryIdentity) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 32768) { [weak self] data, _, complete, error in
            guard let self, self.connections[id] != nil else { return }
            do {
                if let data, !data.isEmpty {
                    var input = data
                    while true {
                        let plaintext = try state.cipher?.receive(input) ?? input
                        guard let request = try state.parser.append(plaintext, maximumRequests: 1).first else { break }
                        // /feedback 每 2 秒一次，单独处理（见 noteFeedback），否则一小时 1800 行噪音。
                        if request.target != "/feedback" {
                            self.log("\(request.method) \(request.target.prefix(100)) [\(request.body.count) 字节]")
                        }
                        let response = try self.respond(request, state: state, configuration: configuration, identity: identity)
                        let encoded = response.encoded(for: request)
                        let wire = try state.cipher?.encrypt(encoded) ?? encoded
                        connection.send(content: wire, completion: .contentProcessed { [weak self] error in
                            if let error { self?.log("控制通道写入失败：\(error.localizedDescription)"); connection.cancel() }
                        })
                        input = Data()
                        if state.cipher == nil, let keys = state.verify?.keys {
                            // M4 is plaintext. Only subsequent bytes use the negotiated record keys.
                            state.cipher = ControlCipher(readKey: keys.read, writeKey: keys.write)
                            input = state.parser.takeBufferedData()
                            self.log("Pair-Verify 已通过，已启用加密控制")
                        }
                    }
                }
                if complete || error != nil { connection.cancel(); self.connections.removeValue(forKey: id) }
                else { self.receive(connection, id: id, state: state, configuration: configuration, identity: identity) }
            } catch {
                self.log("控制连接被拒绝：\(error)"); connection.cancel(); self.connections.removeValue(forKey: id)
            }
        }
    }
    private func respond(_ request: RTSPRequest, state: SessionState, configuration: ReceiverConfiguration,
                         identity: AccessoryIdentity) throws -> RTSPResponse {
        switch (request.method, request.target.components(separatedBy: "?")[0]) {
        case ("OPTIONS", _): return RTSPResponse()
        case ("SETUP", _):
            guard state.cipher != nil, state.authenticated, let secret = state.verify?.mediaSecret else {
                throw ProtocolError.malformed("在配件会话通过验证前收到 SETUP")
            }
            if state.media == nil {
                let media = CarPlayMediaSession(queue: queue, secret: secret, peerAddress: state.peerAddress,
                                                audioEnabled: configuration.audioEnabled, hevc: configuration.videoCodec == .h265)
                media.onLog = { [weak self] in self?.log($0) }
                if configuration.browserAudio {
                    media.onBrowserAudio = { [weak self] stream, buffer, stamp in
                        self?.videoOutput.appendAudio(buffer, stream: stream, stamp: stamp)
                    }
                }
                if let nightMode { media.setNightMode(nightMode) }
                media.onVideo = { [weak self] data, codec in
                    guard let self else { return }
                    #if DEBUG
                    let diagnosticArrival = ProcessInfo.processInfo.systemUptime
                    defer { self.recordPerformance(arrival: diagnosticArrival, bytes: data.count,
                        work: ProcessInfo.processInfo.systemUptime - diagnosticArrival) }
                    #endif
                    let keyframe = Self.containsRandomAccess(data, codec: codec)
                    if keyframe { self.keyframeArrived() }
                    self.videoOutput.append(data, codec: codec)
                    if configuration.zeehoAddress != nil { self.zeeho.append(data, codec: codec, keyframe: keyframe) }
                    if configuration.ninebotAddress != nil { self.ninebot.append(data, codec: codec, keyframe: keyframe) }
                    if configuration.tailingAddress != nil { self.tailing.append(data, codec: codec) }
                    if configuration.cfmotoAddress != nil { self.cfmoto.append(data, codec: codec, keyframe: keyframe) }
                    if configuration.carLifeEnabled { self.carLife.append(data, codec: codec) }
                    if configuration.carLinkRelayAddress != nil { self.carLink.append(data, codec: codec) }
                    if self.localSkipping {
                        guard keyframe, self.localInFlight < self.maximumLocalInFlight / 2 else { return }
                        self.localSkipping = false
                    } else if self.localInFlight >= self.maximumLocalInFlight, !keyframe {
                        self.localSkipping = true
                        self.requestKeyFrameOnQueue(reason: "本机显示积压")
                        return
                    }
                    self.localInFlight += 1
                    DispatchQueue.main.async { [weak self] in
                        #if DEBUG
                        let mainStarted = ProcessInfo.processInfo.systemUptime
                        #endif
                        self?.onVideo?(data, codec)
                        #if DEBUG
                        let mainElapsed = ProcessInfo.processInfo.systemUptime - mainStarted
                        #endif
                        self?.queue.async { [weak self] in
                            if let self {
                                self.localInFlight = max(0, self.localInFlight - 1)
                                #if DEBUG
                                self.diagnosticMainDelay = max(self.diagnosticMainDelay, mainStarted - diagnosticArrival)
                                self.diagnosticMainWork = max(self.diagnosticMainWork, mainElapsed)
                                #endif
                            }
                        }
                    }
                }
                state.media = media
            }
            return RTSPResponse(body: try state.media!.setup(request.body), contentType: "application/x-apple-binary-plist")
        case ("RECORD", _):
            guard state.media != nil else { throw ProtocolError.malformed("在 SETUP 前收到 RECORD") }
            log("已接受 CarPlay RECORD，正在等待视频")
            return RTSPResponse()
        case ("POST", "/pair-setup"):
            guard state.cipher == nil, let setup = state.setup else { throw ProtocolError.malformed("pair-setup 不可用") }
            let fields = try TLV8.decode(request.body)
            log("Pair-Setup 状态 \(fields[6]?.first ?? 0)，方法 \(fields[0]?.first.map(String.init) ?? "缺失")")
            let body = try setup.handle(request.body)
            if setup.complete { log("Pair-Setup 已完成，已保存通过验证的控制端") }
            return RTSPResponse(body: body, contentType: "application/pairing+tlv8")
        case ("POST", "/pair-verify"):
            guard state.cipher == nil, let verify = state.verify else { throw ProtocolError.malformed("pair-verify 不可用") }
            return RTSPResponse(body: try verify.handle(request.body), contentType: "application/pairing+tlv8")
        case ("GET", "/info"), ("POST", "/info"):
            let info = CarPlayInfo.build(configuration)
            return RTSPResponse(body: try PropertyListSerialization.data(fromPropertyList: info, format: .binary, options: 0),
                                contentType: "application/x-apple-binary-plist")
        case ("POST", "/auth-setup"):
            let body = try MFiSAP.respond(to: request.body, identity: identity)
            state.authenticated = true
            log("已生成 MFiSAP 响应，正在等待 iPhone 接受")
            return RTSPResponse(body: body)
        case ("POST", "/feedback"):
            noteFeedback()
            if let feedback = try state.media?.feedback() {
                return RTSPResponse(body: feedback, contentType: "application/x-apple-binary-plist")
            }
            return RTSPResponse()
        case ("POST", "/command"):
            guard state.cipher != nil else { throw ProtocolError.malformed("验证完成前收到 command") }
            if let command = try PropertyListSerialization.propertyList(from: request.body, format: nil) as? [String: Any] {
                let type = command["type"] as? String ?? "未知"
                log("CarPlay 命令：\(type)；字段：\(command.keys.sorted().joined(separator: ", "))")
                if type == "requestUI" {
                    let url = (command["params"] as? [String: Any])?["url"] as? String
                    // "videoplayback:" is the parked-video player, which CarWithin does not offer.
                    if url == nil || url?.hasPrefix("videoplayback") == false {
                        DispatchQueue.main.async { [weak self] in self?.onCarUIRequested?() }
                    }
                }
                if type == "modesChanged", let params = command["params"] as? [String: Any] {
                    for resource in params["resources"] as? [[String: Any]] ?? [] {
                        let fields = ["resourceID", "entity", "permanentEntity"].compactMap { key -> String? in
                            guard let value = resource[key] as? NSNumber else { return nil }
                            return "\(key)=\(value)"
                        }
                        log("CarPlay 资源：\(fields.joined(separator: ", "))")
                    }
                }

            }
            return RTSPResponse()
        case ("TEARDOWN", _):
            if try state.media?.teardown(request.body) == true { state.media = nil }
            return RTSPResponse()
        default:
            log("尚未实现：\(request.method) \(request.target.prefix(80))；未占用会话")
            return RTSPResponse(status: 501, reason: "Not Implemented")
        }
    }
    private func log(_ message: String) { DispatchQueue.main.async { [weak self] in self?.onLog?(message) } }
}
