// SPDX-License-Identifier: AGPL-3.0-only
//
// 春风 EasyConn 的输出设置：连接、端口测试、测试图案、日志（内联，不做二级页）、
// 画面参数（手动覆盖）与逐条说明。
//
// 版式照 1.0.83 的 `cfmotoOutputSections()`（提交 17b1c48 那一版：隐藏画质之前），
// 文案逐条搬过来，只把宿主从 `ReceiverViewController` 换成这个独立文件。
//
// 只在「春风 EasyConn」这一项下面出现；春风 5 寸 / 6.2 寸 仍然走上游原来的
// `CfmotoOutput`，看不到这些控件，行为也不变。

import UIKit

extension SettingsRow {
    /// 1.0.6 只有 `.note(UILabel)`；补一个字符串版本，省掉每行都包一个 UILabel。
    static func note(_ text: String) -> Self {
        let label = UILabel()
        label.text = text
        return .note(label)
    }
}

final class CfMotoEasyConnPanel {
    /// 只弱引用：面板的生命周期跟着设置页，输出跟着接收器。
    weak var output: CfMotoEasyConnOutput?
    /// 仪表 IP 输入框由设置页提供（那里本来就有）。
    var addressField: UITextField?
    /// 需要整页刷新时调用（探测结果、参数落盘后）。
    var onChange: (() -> Void)?
    /// 分享日志文件时的宿主。
    var presenter: () -> UIViewController? = { nil }

    private let portField: UITextField = {
        let field = UITextField()
        field.keyboardType = .numberPad
        field.textAlignment = .right
        field.placeholder = "10930"
        field.returnKeyType = .done
        return field
    }()

    private let bitrateField = CfMotoEasyConnPanel.numberField("2.5", decimal: true)
    private let fpsField = CfMotoEasyConnPanel.numberField("20", decimal: false)
    private let keyframeField = CfMotoEasyConnPanel.numberField("1.0", decimal: true)
    private let canvasWaitField = CfMotoEasyConnPanel.numberField("4", decimal: false)
    private let canvasField = CfMotoEasyConnPanel.plainField("1024x512")
    private let baselineSwitch = UISwitch()
    private let staticPadSwitch = UISwitch()
    private let bufferDepthField = CfMotoEasyConnPanel.numberField("6", decimal: false)
    private let idrWaitField = CfMotoEasyConnPanel.numberField("2.0", decimal: true)
    private let staticIdleField = CfMotoEasyConnPanel.numberField("0.35", decimal: true)
    private let staticPadSavingField = CfMotoEasyConnPanel.numberField("30", decimal: false)
    private let staticPadMaxField = CfMotoEasyConnPanel.numberField("0.8", decimal: true)
    private let staticPadQualityField = CfMotoEasyConnPanel.numberField("0.15", decimal: true)
    private let allIntraSwitch = UISwitch()

    /// 日志直显在这里（不做二级页面）。
    private let logView: UITextView = {
        let view = UITextView()
        view.isEditable = false
        view.isSelectable = true
        view.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        view.textColor = .label
        view.backgroundColor = .secondarySystemBackground
        view.layer.cornerRadius = 10
        view.clipsToBounds = true
        view.textContainerInset = UIEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        view.heightAnchor.constraint(equalToConstant: 220).isActive = true
        return view
    }()

    /// 设备信息框（软件版本 / iOS 版本 / Wi-Fi 名 / 本机 IP）：和日志框同样式，只读、可复制。
    private let infoBox: UITextView = {
        let view = UITextView()
        view.isEditable = false
        view.isSelectable = true
        view.isScrollEnabled = false
        view.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        view.textColor = .label
        view.backgroundColor = .secondarySystemBackground
        view.layer.cornerRadius = 10
        view.clipsToBounds = true
        view.textContainerInset = UIEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        view.heightAnchor.constraint(equalToConstant: 96).isActive = true
        return view
    }()

    private var probeText = CWL("未测试")
    private var probePassed = false
    /// 局域网扫描的结果，直接显示在按钮上（按钮标题下方那行说明）。
    private var scanText = CWL("未扫描")
    private var scanRunning = false
    private var logTimer: Timer?

    init() {
        for field in [bitrateField, fpsField, keyframeField, canvasWaitField, canvasField,
                      bufferDepthField, idrWaitField, staticIdleField, staticPadSavingField,
                      staticPadMaxField, staticPadQualityField] {
            field.addTarget(self, action: #selector(commitTuning), for: .editingDidEnd)
            field.addTarget(self, action: #selector(commitTuning), for: .editingDidEndOnExit)
        }
        portField.addTarget(self, action: #selector(commitPort), for: .editingDidEnd)
        portField.addTarget(self, action: #selector(commitPort), for: .editingDidEndOnExit)
        for toggle in [baselineSwitch, staticPadSwitch, allIntraSwitch] {
            toggle.addTarget(self, action: #selector(commitTuning), for: .valueChanged)
        }
    }

    // MARK: - 页面内容

    func sections() -> [SettingsSection] {
        refreshFields()
        refreshInfoBox()
        refreshLogView()
        startLogTimer()
        return [
            SettingsSection("春风 EasyConn（MotoPlay）",
                footer: "iPhone 先加入车机热点（如 CFMOTO-5962fb），车机进入投屏待连界面后再启动 CarPlay。"
                      + "地址留空表示使用本机当前 Wi-Fi 网关。CarPlay 会按车机要求的画布 1:1 渲染（150SCF 为 1024×512），"
                      + "所以上面「画面 › 尺寸/分辨率/宽高比」在本模式下不生效，也不会有黑边。"
                      + "「端口测试」在车机应答后会顺便问出它的分辨率，直接显示在按钮上。"
                      + "声音走 iPhone 或蓝牙，触控暂不支持。",
                [
                    addressRow,
                    .field(CWL("EasyConn 端口"), portField, placeholder: "10930"),
                    .action(scanTitle, icon: scanIcon, detail: { [weak self] in self?.scanText }) { [weak self] in
                        self?.runScan()
                    },
                    .action(CWL("端口测试（探测车机）"), icon: ("antenna.radiowaves.left.and.right", .systemGreen),
                            detail: { [weak self] in self?.probeText }) { [weak self] in
                        self?.runProbe()
                    },
                    .action(testPatternTitle, icon: testPatternIcon, detail: { [weak self] in self?.testPatternDetail }) { [weak self] in
                        self?.toggleTestPattern()
                    },
                    .view(infoBox),
                    .view(logView),
                    .action(CWL("浏览器打开实时日志"), icon: ("safari", .systemBlue),
                            detail: { [weak self] in self?.logURLText }) { [weak self] in
                        self?.openLogPage()
                    },
                    .action(CWL("分享日志文件"), icon: ("square.and.arrow.up", .systemBlue)) { [weak self] in
                        self?.shareLog()
                    },
                    .action(CWL("复制日志"), icon: ("doc.on.doc", .systemBlue)) { [weak self] in
                        UIPasteboard.general.string = self?.output?.logDump ?? ""
                    },
                    .action(CWL("清空日志"), icon: ("trash", .systemGray), destructive: true) { [weak self] in
                        self?.output?.store.clear()
                        self?.refreshLogView()
                    },
                ]),
            SettingsSection(CWL("画面参数（手动覆盖）"),
                [
                    .field(CWL("码率（Mbps）"), bitrateField, placeholder: "2.5"),
                    .field(CWL("帧率上限（10–40）"), fpsField, placeholder: "20"),
                    .field(CWL("关键帧间隔（秒）"), keyframeField, placeholder: "1.0"),
                    .field(CWL("启动等待画布（秒）"), canvasWaitField, placeholder: "4"),
                    .field(CWL("固定画布（留空跟随车机）"), canvasField, placeholder: "1024x512"),
                    .control(CWL("强制 Baseline 3.1"), baselineSwitch),
                    .control(CWL("静止画面用轻量补帧"), staticPadSwitch),
                    .field(CWL("缓存深度（帧）"), bufferDepthField, placeholder: "6"),
                    .field(CWL("等关键帧上限（秒）"), idrWaitField, placeholder: "2.0"),
                    .field(CWL("静止判定（秒）"), staticIdleField, placeholder: "0.35"),
                    .field(CWL("补帧最小节省（%）"), staticPadSavingField, placeholder: "30"),
                    .field(CWL("补帧码率上限（Mbps）"), staticPadMaxField, placeholder: "0.8"),
                    .field(CWL("补帧画质（0.05–0.5）"), staticPadQualityField, placeholder: "0.15"),
                    .control(CWL("强制全关键帧"), allIntraSwitch),
                    .note("当前：" + CfMotoTuning.summary),
                    .action(CWL("恢复默认参数"), icon: ("arrow.counterclockwise", .systemGray), destructive: true) { [weak self] in
                        self?.restoreDefaults()
                    },
                    .note(CWL("码率：越大越清晰，也越费流量。")),
                    .note(CWL("帧率：每秒张数；车机不能触摸，20 帧足够，越高越糊。")),
                    .note(CWL("关键帧间隔：多久发一张完整图；越短丢帧恢复越快、越费流量。")),
                    .note(CWL("等待画布：开局等车机报分辨率的最长秒数。")),
                    .note(CWL("固定画布：留空跟随车机；填「宽x高」强制指定。")),
                    .note(CWL("Baseline：关 = Main profile（更省码率）；开 = Baseline 3.1（兼容性最好）。")),
                    .note(CWL("静止补帧：画面不动时发小图省流量，代价是静止画面变糊。")),
                    .note(CWL("缓存深度：允许积压的帧数；大 = 顺但延迟，小 = 跟手但易跳帧。")),
                    .note(CWL("等关键帧上限：丢关键帧后最多等几秒才用旧图顶。")),
                    .note(CWL("静止判定：画面多久不动才算静止（只影响静止补帧）。")),
                    .note(CWL("补帧最小节省：轻量包须比正常关键帧小多少（%）才用它；0 = 只要更小就用。")),
                    .note(CWL("补帧码率上限：补帧码率最高到多少；调高静止更清晰，但轻量包更大、可能过不了上面的节省门槛。")),
                    .note(CWL("补帧画质：补帧编码质量，越大越清晰、包越大（与上限/门槛互相制约）。")),
                    .note(CWL("全关键帧：每帧都是完整图，彻底消除撕裂，带宽约翻倍。")),
                ]),
        ]
    }

    private var addressRow: SettingsRow {
        guard let addressField else { return .note(CWL("缺少仪表 IP 输入框")) }
        return .field(CWL("车机 IP 地址"), addressField, placeholder: "192.168.0.1")
    }

    private var testPatternTitle: String {
        output?.testPatternEnabled == true ? CWL("停止测试图案") : CWL("启动测试图案")
    }

    private var testPatternIcon: (String, UIColor) {
        output?.testPatternEnabled == true ? ("stop.fill", .systemRed) : ("play.fill", .systemGreen)
    }

    private var testPatternDetail: String? {
        probePassed ? nil : CWL("先通过端口测试")
    }

    private var scanTitle: String {
        scanRunning ? CWL("扫描局域网设备（扫描中…）") : CWL("扫描局域网设备")
    }

    private var scanIcon: (String, UIColor) {
        scanRunning ? ("hourglass", .systemOrange) : ("magnifyingglass", .systemBlue)
    }

    private var logURLText: String {
        output?.logURL ?? CWL("未连接 Wi-Fi")
    }

    // MARK: - 端口 / 测试图案

    @objc private func commitPort() {
        let raw = (portField.text ?? "").trimmingCharacters(in: .whitespaces)
        let value = UInt16(raw) ?? 10930
        CfMotoEasyConnOutput.probePort = value == 0 ? 10930 : value
        refreshFields()
        onChange?()
    }

    // MARK: - 局域网扫描

    private func runScan() {
        guard !scanRunning else { return }
        scanRunning = true
        let port = CfMotoEasyConnOutput.probePort
        scanText = CWL("扫描中…（探测 \(port) 端口，约 1–3 秒）")
        onChange?()
        output?.log(CWL("开始扫描局域网：本机所在网段，探测 \(port) 端口"))
        LanPortScanner.scan(port: port) { [weak self] outcome in
            guard let self else { return }
            self.scanRunning = false
            self.applyScan(outcome, port: port)
            self.onChange?()
        }
    }

    /// 扫到的第一台直接填进「车机 IP 地址」，并走 1.0.6 原来的保存路径落盘。
    private func applyScan(_ outcome: LanPortScanner.Outcome, port: UInt16) {
        let seconds = String(format: "%.1f", outcome.seconds)
        if let failure = outcome.failure {
            scanText = failure
            output?.log(CWL("扫描未进行：\(failure)"))
            return
        }
        guard !outcome.open.isEmpty else {
            // 整个网段都「连都连不上」，基本是 iOS 的「本地网络」权限没给，而不是车机没开。
            if outcome.unreachable >= max(1, outcome.scanned * 9 / 10) {
                scanText = CWL("整个网段都连不上：检查「设置 › CarWithin › 本地网络」是否允许")
                output?.log(CWL("扫描 \(outcome.network)：\(outcome.unreachable)/\(outcome.scanned) 台连不上，疑似没有本地网络权限（\(seconds)s）"))
                return
            }
            scanText = CWL("\(outcome.scanned) 台里没有开 \(port) 的设备（\(seconds)s）")
            output?.log(CWL("扫描 \(outcome.network)：\(outcome.scanned) 台都没有开 \(port) 端口（\(seconds)s）"))
            return
        }
        let chosen = outcome.open[0]
        addressField?.text = chosen
        // `saveHeadUnitOutput` 是 1.0.6 自己的保存入口（写 UserDefaults 的 cfmotoAddress）。
        addressField?.sendActions(for: .editingDidEnd)
        probeText = CWL("未测试")
        probePassed = false
        if outcome.open.count == 1 {
            scanText = CWL("扫描到 \(chosen)，已填入车机 IP（\(seconds)s）")
        } else {
            let all = outcome.open.joined(separator: "、")
            scanText = CWL("扫描到 \(outcome.open.count) 台（\(all)），已填入 \(chosen)")
        }
        output?.log(CWL("扫描 \(outcome.network)：开 \(port) 的设备 \(outcome.open.joined(separator: "、"))，已填入 \(chosen)（\(seconds)s）"))
    }

    private func runProbe() {
        output?.ensureLogServer()
        probeText = CWL("探测中…")
        onChange?()
        let host = (addressField?.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        // 一步两段：先探测 10930；车机应答之后再拉链路，要它的分辨率。
        output?.probeThenQueryCanvas(host: host, port: CfMotoEasyConnOutput.probePort,
                                     progress: { [weak self] step in
            guard let self else { return }
            self.probeText = step
            self.onChange?()
        }) { [weak self] message, ok in
            guard let self else { return }
            self.probeText = message
            self.probePassed = ok
            self.onChange?()
        }
    }

    private func toggleTestPattern() {
        guard probePassed || output?.testPatternEnabled == true else {
            probeText = CWL("先点「端口测试」，通过了才能开测试图案")
            onChange?()
            return
        }
        // 1.0.83 的做法：测试图案自己起一条链路，不依赖 CarPlay 是否在跑。
        let host = (addressField?.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        output?.toggleTestPattern(host: host, port: CfMotoEasyConnOutput.probePort)
        onChange?()
    }

    // MARK: - 日志

    private func startLogTimer() {
        output?.ensureLogServer()
        guard logTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            guard self.logView.window != nil else {
                self.logTimer?.invalidate()
                self.logTimer = nil
                return
            }
            self.refreshInfoBox()
            self.refreshLogView()
        }
        RunLoop.main.add(timer, forMode: .common)
        logTimer = timer
    }

    private func refreshLogView() {
        // 1.0.83 的面板日志就是日志环原文（`store.text`），不带诊断表头，方便和车边截图对照。
        let body = output?.store.text ?? ""
        guard logView.text != body else { return }
        let offset = logView.contentOffset
        logView.text = body
        logView.contentOffset = offset
    }

    // MARK: - 设备信息框

    /// 四行固定内容，跟着日志每秒刷一次：换 Wi-Fi、掉网、切热点能立刻看出来。
    private func refreshInfoBox() {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        let name = info?["CFBundleDisplayName"] as? String
            ?? info?["CFBundleName"] as? String
            ?? "CarWithin"
        let body = [
            alignedRow("软件版本", "\(name) \(version) (\(build))"),
            alignedRow("iOS 版本", UIDevice.current.systemVersion),
            alignedRow("Wi-Fi 名", currentWiFiText),
            alignedRow("本地 IP", ReceiverConfiguration.wifiIPv4Address() ?? "未连接 Wi-Fi"),
        ].joined(separator: "\n")
        guard infoBox.text != body else { return }
        let offset = infoBox.contentOffset
        infoBox.text = body
        infoBox.contentOffset = offset
    }

    /// Wi-Fi 名写清来源：系统读到的，还是预设里填的（读不到时把原因也写出来）。
    private var currentWiFiText: String {
        if let name = SystemWiFiName.current { return "\(name)（系统）" }
        let preset = WiFiPresetStore.selected()?.ssid ?? "未设置"
        switch SystemWiFiName.currentStatus {
        case .locationDenied: return "\(preset)（预设·需定位权限）"
        case .unavailable: return "\(preset)（预设·系统读取失败）"
        default: return "\(preset)（预设）"
        }
    }

    /// 等宽字体下的对齐：中日韩字符按两格算，标签右侧补空格，让四行的值从同一列开始。
    private func alignedRow(_ label: String, _ value: String) -> String {
        var cells = 0
        for scalar in label.unicodeScalars {
            let v = scalar.value
            let wide = (v >= 0x1100 && v <= 0x115F) || (v >= 0x2E80 && v <= 0xA4CF)
                || (v >= 0xAC00 && v <= 0xD7A3) || (v >= 0xF900 && v <= 0xFAFF)
                || (v >= 0xFE30 && v <= 0xFE6F) || (v >= 0xFF00 && v <= 0xFF60)
                || (v >= 0xFFE0 && v <= 0xFFE6)
            cells += wide ? 2 : 1
        }
        return label + String(repeating: " ", count: max(1, 9 - cells)) + value
    }

    private func openLogPage() {
        guard let url = output?.logURLValue else {
            // 1.0.83 把这一句也写进 EasyConn 日志，车边排查时能看到当时为什么打不开。
            output?.log(CWL("日志服务地址未知：请先连接 Wi-Fi"))
            probeText = CWL("先连上 Wi-Fi，或在本机直接用浏览器打开 127.0.0.1:\(CfMotoLogServer.defaultPort)")
            onChange?()
            return
        }
        UIApplication.shared.open(url)
    }

    private func shareLog() {
        guard let file = output?.store.fileForSharing(), let host = presenter() else { return }
        let sheet = UIActivityViewController(activityItems: [file], applicationActivities: nil)
        sheet.popoverPresentationController?.sourceView = logView
        sheet.popoverPresentationController?.sourceRect = logView.bounds
        host.present(sheet, animated: true)
    }

    // MARK: - 写参数

    @objc private func commitTuning() {
        if let value = number(bitrateField) { CfMotoTuning.bitrateMbps = value }
        if let value = Int((fpsField.text ?? "").trimmingCharacters(in: .whitespaces)) { CfMotoTuning.frameRate = value }
        if let value = number(keyframeField) { CfMotoTuning.keyframeSeconds = value }
        if let value = number(canvasWaitField) { CfMotoTuning.canvasWaitSeconds = value }
        CfMotoTuning.canvasOverride = canvasField.text
        CfMotoTuning.forceBaseline = baselineSwitch.isOn
        CfMotoTuning.staticPadEnabled = staticPadSwitch.isOn
        if let value = Int((bufferDepthField.text ?? "").trimmingCharacters(in: .whitespaces)) { CfMotoTuning.bufferDepth = value }
        if let value = number(idrWaitField) { CfMotoTuning.idrWaitSeconds = value }
        if let value = number(staticIdleField) { CfMotoTuning.staticIdleSeconds = value }
        if let value = Int((staticPadSavingField.text ?? "").trimmingCharacters(in: .whitespaces)) {
            CfMotoTuning.staticPadMinSavingPct = value
        }
        if let value = number(staticPadMaxField) { CfMotoTuning.staticPadMaxMbps = value }
        if let value = number(staticPadQualityField) { CfMotoTuning.staticPadQuality = value }
        CfMotoTuning.allIntra = allIntraSwitch.isOn
        output?.reloadTuning()
        refreshFields()
        onChange?()
    }

    private func restoreDefaults() {
        CfMotoTuning.reset()
        refreshFields()
        output?.reloadTuning()
        onChange?()
    }

    // MARK: - 字段填充

    private func refreshFields() {
        bitrateField.text = trimmed(CfMotoTuning.bitrateMbps, digits: 1)
        fpsField.text = "\(CfMotoTuning.frameRate)"
        keyframeField.text = trimmed(CfMotoTuning.keyframeSeconds, digits: 1)
        canvasWaitField.text = trimmed(CfMotoTuning.canvasWaitSeconds, digits: 0)
        canvasField.text = CfMotoTuning.canvasOverride ?? ""
        baselineSwitch.isOn = CfMotoTuning.forceBaseline
        staticPadSwitch.isOn = CfMotoTuning.staticPadEnabled
        bufferDepthField.text = "\(CfMotoTuning.bufferDepth)"
        idrWaitField.text = trimmed(CfMotoTuning.idrWaitSeconds, digits: 1)
        staticIdleField.text = trimmed(CfMotoTuning.staticIdleSeconds, digits: 2)
        staticPadSavingField.text = "\(CfMotoTuning.staticPadMinSavingPct)"
        staticPadMaxField.text = trimmed(CfMotoTuning.staticPadMaxMbps, digits: 2)
        staticPadQualityField.text = trimmed(CfMotoTuning.staticPadQuality, digits: 2)
        allIntraSwitch.isOn = CfMotoTuning.allIntra
        portField.text = "\(CfMotoEasyConnOutput.probePort)"
    }

    private func trimmed(_ value: Double, digits: Int) -> String {
        var text = String(format: "%.\(digits)f", value)
        while text.contains("."), text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }

    private func number(_ field: UITextField) -> Double? {
        let raw = (field.text ?? "").replacingOccurrences(of: ",", with: ".")
        return Double(raw.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    // MARK: - 控件工厂

    private static func numberField(_ placeholder: String, decimal: Bool) -> UITextField {
        let field = plainField(placeholder)
        field.keyboardType = decimal ? .decimalPad : .numberPad
        return field
    }

    private static func plainField(_ placeholder: String) -> UITextField {
        let field = UITextField()
        field.placeholder = placeholder
        field.keyboardType = .decimalPad
        field.textAlignment = .right
        field.autocorrectionType = .no
        field.autocapitalizationType = .none
        field.returnKeyType = .done
        return field
    }
}
