// SPDX-License-Identifier: AGPL-3.0-only
//
// 春风 EasyConn 的输出设置面板 + 日志页。
//
// 只在「春风 EasyConn」这一项下面出现；春风 5 寸 / 6.2 寸 仍然走上游原来的
// `CfmotoOutput`，看不到这些控件，行为也不变。
//
// 所有数值都写进 `CfMotoTuning`（越界会被它自己夹到合法区间），写完后调用
// `output.reloadTuning()` 重建编码器，并在日志里留下一行新参数作为凭证。

import UIKit

final class CfMotoEasyConnPanel {
    /// 只弱引用：面板的生命周期跟着设置页，输出跟着接收器。
    weak var output: CfMotoEasyConnOutput?
    /// 仪表 IP 由设置页提供（那里本来就有输入框）。
    var addressProvider: () -> String = { "" }
    /// 需要整页刷新时调用（探测结果、参数落盘后）。
    var onChange: (() -> Void)?

    private let bitrateField = CfMotoEasyConnPanel.numberField("2.5", decimal: true)
    private let fpsField = CfMotoEasyConnPanel.numberField("20", decimal: false)
    private let keyframeField = CfMotoEasyConnPanel.numberField("1.0", decimal: true)
    private let canvasField = CfMotoEasyConnPanel.plainField("1024x512")
    private let baselineSwitch = UISwitch()
    private let staticPadSwitch = UISwitch()
    private let staticIdleField = CfMotoEasyConnPanel.numberField("0.35", decimal: true)
    private let staticPadMaxField = CfMotoEasyConnPanel.numberField("0.8", decimal: true)
    private let staticPadQualityField = CfMotoEasyConnPanel.numberField("0.15", decimal: true)
    private let staticPadSavingField = CfMotoEasyConnPanel.numberField("30", decimal: false)
    private let testPatternSwitch = UISwitch()

    private var probeText = CWL("未测试")
    private var probePassed = false

    init() {
        for field in [bitrateField, fpsField, keyframeField, canvasField,
                      staticIdleField, staticPadMaxField, staticPadQualityField, staticPadSavingField] {
            field.addTarget(self, action: #selector(commitTuning), for: .editingDidEnd)
            field.addTarget(self, action: #selector(commitTuning), for: .editingDidEndOnExit)
        }
        baselineSwitch.addTarget(self, action: #selector(commitTuning), for: .valueChanged)
        staticPadSwitch.addTarget(self, action: #selector(commitTuning), for: .valueChanged)
        testPatternSwitch.addTarget(self, action: #selector(toggleTestPattern), for: .valueChanged)
    }

    // MARK: - 页面内容

    func sections() -> [SettingsSection] {
        refreshFields()
        let sections: [SettingsSection] = [
            SettingsSection(CWL("编码参数"),
                            footer: CWL("默认 2.5 Mbit/s · 20 FPS（与 1.0.83 一致）。改完立刻生效，日志里会留一行新参数。"),
                            [
                                .field(CWL("码率上限（Mbit/s）"), bitrateField, placeholder: "2.5"),
                                .field(CWL("帧率上限（FPS）"), fpsField, placeholder: "20"),
                                .field(CWL("关键帧间隔（秒）"), keyframeField, placeholder: "1.0"),
                                .field(CWL("固定画布（可留空）"), canvasField, placeholder: "1024x512"),
                                .control(CWL("强制 Baseline"), baselineSwitch),
                            ]),
            SettingsSection(CWL("静态补位"),
                            footer: CWL("画面静止时改用轻量的关键帧顶上，省流量；代价是静止画面会稍微粗一点。"),
                            [
                                .control(CWL("开启静态补位"), staticPadSwitch),
                                .field(CWL("静止判定（秒）"), staticIdleField, placeholder: "0.35"),
                                .field(CWL("轻量码率上限（Mbit/s）"), staticPadMaxField, placeholder: "0.8"),
                                .field(CWL("质量偏置"), staticPadQualityField, placeholder: "0.15"),
                                .field(CWL("最小节省（%）"), staticPadSavingField, placeholder: "30"),
                            ]),
            SettingsSection(CWL("诊断"),
                            footer: CWL("端口测试只检查「能不能连上仪表 10930」，不发协议字节；测试图案用来确认「链路通、画面不对」时问题在编码这一侧。"),
                            [
                                .action(CWL("端口测试（仪表 10930）"),
                                        icon: ("antenna.radiowaves.left.and.right", .systemGreen),
                                        detail: { [weak self] in self?.probeText }) { [weak self] in self?.runProbe() },
                                .control(CWL("测试图案（彩条）"), testPatternSwitch),
                                .info(CWL("当前画面"), output?.liveStats.summary ?? CWL("输出未启动")),
                                .info(CWL("静态补位"), staticPadNote),
                            ]),
            SettingsSection(footer: CWL("只影响春风 EasyConn；春风 5 寸 / 6.2 寸 不受影响。"),
                            [
                                .action(CWL("恢复默认画面参数"), icon: ("arrow.counterclockwise", .systemRed), destructive: true) { [weak self] in
                                    self?.restoreDefaults()
                                },
                                .page(CWL("日志"), icon: ("doc.text.fill", .systemGray)) { [weak self] in
                                    self?.makeLogPage() ?? UIViewController()
                                },
                            ]),
        ]
        return sections
    }

    private var staticPadNote: String {
        guard let output, output.liveStats.staticPadNote.isEmpty == false else {
            return CfMotoTuning.staticPadEnabled ? CWL("已开启，等待静止画面") : CWL("未开启")
        }
        return output.liveStats.staticPadNote
    }

    // MARK: - 写参数

    @objc private func commitTuning() {
        if let value = number(bitrateField) { CfMotoTuning.bitrateMbps = value }
        if let value = Int((fpsField.text ?? "").trimmingCharacters(in: .whitespaces)) { CfMotoTuning.frameRate = value }
        if let value = number(keyframeField) { CfMotoTuning.keyframeSeconds = value }
        CfMotoTuning.canvasOverride = canvasField.text
        CfMotoTuning.forceBaseline = baselineSwitch.isOn
        CfMotoTuning.staticPadEnabled = staticPadSwitch.isOn
        if let value = number(staticIdleField) { CfMotoTuning.staticIdleSeconds = value }
        if let value = number(staticPadMaxField) { CfMotoTuning.staticPadMaxMbps = value }
        if let value = number(staticPadQualityField) { CfMotoTuning.staticPadQuality = value }
        if let value = Int((staticPadSavingField.text ?? "").trimmingCharacters(in: .whitespaces)) {
            CfMotoTuning.staticPadMinSavingPct = value
        }
        output?.reloadTuning()
        refreshFields()
        onChange?()
    }

    @objc private func restoreDefaults() {
        CfMotoTuning.reset()
        baselineSwitch.isOn = CfMotoTuning.forceBaseline
        staticPadSwitch.isOn = CfMotoTuning.staticPadEnabled
        refreshFields()
        output?.reloadTuning()
        onChange?()
    }

    @objc private func toggleTestPattern() {
        output?.setTestPattern(testPatternSwitch.isOn)
        onChange?()
    }

    @objc private func runProbe() {
        let host = addressProvider()
        probeText = CWL("探测中…")
        onChange?()
        output?.probe(host: host) { [weak self] message, ok in
            DispatchQueue.main.async {
                guard let self else { return }
                self.probeText = message
                self.probePassed = ok
                self.onChange?()
            }
        }
    }

    // MARK: - 字段填充

    private func refreshFields() {
        bitrateField.text = trimmed(CfMotoTuning.bitrateMbps, digits: 1)
        fpsField.text = "\(CfMotoTuning.frameRate)"
        keyframeField.text = trimmed(CfMotoTuning.keyframeSeconds, digits: 1)
        canvasField.text = CfMotoTuning.canvasOverride ?? ""
        baselineSwitch.isOn = CfMotoTuning.forceBaseline
        staticPadSwitch.isOn = CfMotoTuning.staticPadEnabled
        staticIdleField.text = trimmed(CfMotoTuning.staticIdleSeconds, digits: 2)
        staticPadMaxField.text = trimmed(CfMotoTuning.staticPadMaxMbps, digits: 2)
        staticPadQualityField.text = trimmed(CfMotoTuning.staticPadQuality, digits: 2)
        staticPadSavingField.text = "\(CfMotoTuning.staticPadMinSavingPct)"
        if let output { testPatternSwitch.isOn = output.testPatternEnabled }
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

    // MARK: - 日志页

    func makeLogPage() -> SettingsPageController {
        let text = UITextView()
        text.isEditable = false
        text.isSelectable = true
        text.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        text.textColor = .label
        text.backgroundColor = .secondarySystemBackground
        text.layer.cornerRadius = 10
        text.clipsToBounds = true
        text.textContainerInset = UIEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        text.heightAnchor.constraint(equalToConstant: 380).isActive = true

        let controller = SettingsPageController(title: CWL("日志")) { [weak self] in
            guard let self else { return [] }
            var sections: [SettingsSection] = [
                SettingsSection(footer: CWL("最近 400 条，不含 Wi-Fi 密码与 MFi 私钥。"), [.view(text)]),
                SettingsSection([
                    .action(CWL("复制日志"), icon: ("doc.on.doc.fill", .systemBlue)) { [weak self] in
                        UIPasteboard.general.string = self?.output?.logDump ?? ""
                    },
                    .action(CWL("清空日志"), icon: ("trash.fill", .systemRed), destructive: true) { [weak self] in
                        self?.output?.store.clear()
                        text.text = ""
                    },
                ]),
            ]
            if let address = ReceiverConfiguration.wifiIPv4Address() {
                let url = "http://\(address):\(CfMotoLogServer.defaultPort)/"
                sections.append(SettingsSection(footer: CWL("同一 Wi-Fi 下的电脑用浏览器打开这个地址，可以实时看日志。"), [
                    .info(CWL("日志网址"), url),
                    .action(CWL("复制网址"), icon: ("link", .systemTeal)) {
                        UIPasteboard.general.string = url
                    },
                ]))
            }
            return sections
        }
        controller.onAppear = { [weak self] in
            let body = self?.output?.logDump ?? ""
            text.text = body
            if !body.isEmpty {
                text.scrollRangeToVisible(NSRange(location: body.utf16.count - 1, length: 1))
            }
        }
        return controller
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
