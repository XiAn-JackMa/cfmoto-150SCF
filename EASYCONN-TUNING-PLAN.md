# 春风 EasyConn · 调参面板移植方案（供检查，未动代码）

> 目标：`CarWithin-new`（上游 1.0.6）里选中 **春风 EasyConn** 后，输出设置页出现 1.0.83 的调参：
> **码率 / 帧率 / 关键帧 / 静态补位 / 端口测试 / 测试图案**（附赠 **Baseline** 与 **画布覆盖**）。
> 约束：**尽量不改 1.0.6 的文件**，改动面越小越好，且 5 寸 / 6.2 寸的行为一点点都不能变。

---

## 0. 结论先说

1. **"零改动"做不到**：这 6 项里有 4 项必须改到 1.0.6 的编码器与输出类内部（原因见 §2）。
2. 能做到的最小面是 **改 3 个文件、全部是新增式（不改任何现有语句）、约 +140 行**，其余逻辑放进 **4 个新文件**（约 600 行）。
3. 关键是**参数必须真生效**，不能只摆几个假开关。所以不搬 1.0.83 那 1259 行 `CfMotoVideoSource`，而是**在 1.0.6 自己的拉流模型上就地增强**——1.0.6 是"仪表来拉一次、我们编一帧"，这个模型做静态补位反而比 1.0.83 更省。

---

## 1. 你要的 6 项，在 1.0.6 里的落点（已勘查）

| 参数 | 1.0.83 在哪实现 | 1.0.6 现状（实测代码） | 能不能真生效 |
|---|---|---|---|
| **码率** | `CfMotoVideoSource` 编码时给 | `CfmotoOutput.Session.effectiveBitrate`（`CfmotoOutput.swift:100`，协商后 `:153` 赋值） | ✅ 卡上限即可 |
| **帧率** | `CfMotoVideoSource` 拉流节流 | `effectiveFps`（`:99`、`:152`），拉流循环用 `1/effectiveFps`（`:169`） | ✅ 卡上限即可 |
| **关键帧间隔** | `H264Encoder(MaxKeyFrameInterval*)` | 1.0.6 的 `H264Encoder.init` **没有**这两个属性（`NinebotH264Encoder.swift:109`） | ⚠️ 必须给编码器加参数 |
| **静态补位** | `CfMotoVideoSource` 判静止后复用轻量关键帧 | 1.0.6 没有；但拉流循环 `:162-197` 是"拉一次发一帧"，天然适合做 | ⚠️ 要在 `Session` 里加约 40 行 |
| **端口测试** | `CfMotoOutput.testDashPort` | 无（`PxcConnection` 只管连，不给探测接口） | ✅ 新文件里自己连 TCP 10930 |
| **测试图案** | `CfMotoOutput.startTestPattern` | 无，但循环只发 `latest` 这一张（`:172`） | ⚠️ 要能把合成图塞进 `latest` |
| （附赠）**Baseline** | `H264Encoder` 传 `profileLevel` | **1.0.6 的 `H264Encoder` 已经有 `profileLevel:` 参数**（`:110`） | ✅ 白送 |
| （附赠）**画布覆盖** | `CfMotoVideoSource` | `encodeWidth/Height` 协商后覆盖（`:148-149`） | ✅ 卡一下即可 |

---

## 2. 三条硬事实，决定了"零改动"不可能

1. **Swift 扩展拦不住存储属性**。`effectiveFps` / `effectiveBitrate` / `latest` / `encoder` 都是 `Session` 的 `private var`，只能改文件。
2. **`H264Encoder` 是 1.0.6 的文件且没有关键帧/质量参数**，且 `VTCompressionSession` 是 `private`，外部改不了属性 → **关键帧间隔这一项绕不过去**（这是唯一必须碰的"别人的库文件"）。
3. **测试图案**必须替换"喂给编码器的那张图"，那是 `Session.latest`。

反过来说：只要把这 3 个钩子开出来，剩下全部（面板 UI、参数存储、端口测试、彩条生成、静止判定）都能放进新文件，1.0.6 的其余 340 个文件一个字节都不用动。

---

## 3. 三个方案对比

| | **B（推荐）就地增强** | **D 并行新实现** | **C 只做 UI** |
|---|---|---|---|
| 做法 | 给 1.0.6 的 `Session` 开 3 个钩子，参数真生效 | 抄 1.0.83 的 `CfMotoOutput` 改成新类，EasyConn 走新类 | 面板照搬，参数只存不生效 |
| 改 1.0.6 文件 | **3 个**（+140 行） | 4 个（+200 行） | 1 个（+30 行） |
| 新增代码 | ~600 行（4 文件） | ~1100 行（5 文件，含重复的会话/重连逻辑） | ~250 行（2 文件） |
| 复用 1.0.6 的重连/看门狗/协商 | ✅ 全复用 | ❌ 复制一份，以后上游修 bug 吃不到 | ✅ |
| 风险 | 中（改到共享类，但**默认参数 + 独立开关**，5/6.2 寸走原路径） | 中高（两套 PXC 会话并存，调 bug 要判断走哪套） | 低，但**功能是假的** |
| 是否满足你的要求 | ✅ 6 项全真生效 | ✅ 6 项全真生效 | ❌ 只有端口测试是真的 |

**推荐 B。** D 的唯一优势是"不碰 `CfmotoOutput.swift`"，但代价是复制 400 多行会话逻辑，以后上游修重连 bug 我们这套吃不到；而 B 的改动是**纯新增 + 默认关闭**，5 寸 / 6.2 寸走的还是原来的代码路径。

---

## 4. 推荐方案 B · 施工单

### 4.1 新增文件（不动 1.0.6 任何东西）

| 文件 | 职责 | 估行 |
|---|---|---|
| `App/CfMotoTuning.swift` | 参数存储（UserDefaults），从 1.0.83 同名文件裁剪：只留 9 个 key，删掉 `bufferDepth` / `idrWait` / `allIntra` / `canvasWait` 的存取（key 名保留，旧值不丢） | ~180 |
| `App/CfMotoTuningPanel.swift` | 面板构建器：持有输入框/开关，`rows() -> [SettingsRow]`、`save()`、`reset()`、`runPortTest()`、`toggleTestPattern()` | ~230 |
| `App/CfMotoDashProbe.swift` | 端口测试：`NWConnection` 连 `ip:10930`，3 s 超时，回调 "通过 12 ms / 拒绝 / 超时" | ~80 |
| `App/CfMotoTestPattern.swift` | ① 彩条 `CVPixelBuffer`（8 色竖条 + 中央十字 + 四角标 + 中央文字"1075×513 TEST"）；② 画面指纹（32 点采样 → `UInt64`）用于判静止 | ~110 |

### 4.2 修改 1.0.6 的文件（3 个，全部新增式）

**① `App/NinebotH264Encoder.swift`（+45 行）**
- `init(...)` 在 `profileLevel:` 之后加两个**带默认值**的参数：`quality: Double? = nil`、`keyframeSeconds: Double = 1.0` → 全工程 21 处现有调用点**一个字都不用改**。
- `configure()` 里补两句：`kVTCompressionPropertyKey_Quality`（有 `quality` 时）与 `MaxKeyFrameInterval = round(keyframeSeconds × fps)`、`MaxKeyFrameIntervalDuration = keyframeSeconds`。
- 加 `NSLock`（`encode` / `complete` / `invalidate` / `set` 四处）——静态补位会临时另建一个轻量编码器，加锁避免并发。
- 这段改动我在 `CarWithin-merged` 上已经跑过 CI（0 error），是验证过的写法。

**② `App/CfmotoOutput.swift`（+65 行）**
- `Session` 加一个 `let tuned: Bool`（由 `CfmotoTuning.active` 决定，`active` 只在选中 EasyConn 时为真）。
- `:124-125` / `:152-153` 之后：`effectiveFps`、`effectiveBitrate` 在 `tuned` 时取 `min(profile.值, 参数)`。
- `:148-149`：`tuned` 且有画布覆盖时用覆盖值。
- `:353` 建编码器时传 `keyframeSeconds`、`quality`、`profileLevel`（Baseline）。
- `:171-174` 拉流处：
  - 测试图案开着 → 用彩条图替换 `latest`，仪表来拉就给彩条（**不碰解码**，随时可关）；
  - 静止补位开着且画面指纹 N 次不变 → **不编码**，直接把上次的关键帧按原样再发一次；若轻量关键帧（低码率重建）比主关键帧小过阈值，就用轻量那个。
- 新增两个方法：`setTestPattern(_:)`、`setTuningActive(_:)`（各 3 行）。

**③ `App/ReceiverViewController.swift`（+30 行）**
- `:3104` 那个 `case .cfmoto5, .cfmoto62, .cfmotoEasyConn:` 拆成两支：5 寸 / 6.2 寸保持**原样一行不动**；EasyConn 单独一支，返回「IP + 状态 + 调参面板 + 端口测试 + 测试图案」。
- 选中 EasyConn 时置 `CfMotoTuning.active = true`，切走时置 false（保证 5/6.2 寸永远走原逻辑）。
- 停止输出 / 切模式时关掉测试图案。

### 4.3 需要你确认的"不碰"清单

`Info.plist`（版本仍是 1.0.6/18）、`Tools/generate_project.py`、`project.pbxproj`（新文件都在 `App/` 下，工程是目录 glob，重新生成自动纳入）、`NativeReceiver.swift`、`ReceiverConfiguration.swift`、`SettingsUI.swift`（面板只用现有 `.field / .control / .action / .note / .info` 行类型）、其余 338 个文件。

---

## 5. 面板长什么样（选中春风 EasyConn 后）

```
┌ 春风 EasyConn ─────────────────────────────┐
│ 仪表 IP 地址            [ 留空尝试 .1    ] │   ← 原有
│ 状态：等待启动 CarPlay · 仪表 IP：…        │   ← 原有 .note
├ 画面参数 ──────────────────────────────────┤
│ 码率上限                [ 4.5 ] Mbit/s     │   0.6 – 12
│ 帧率上限                [ 30  ] FPS        │   10 – 40
│ 关键帧间隔              [ 1.0 ] 秒         │   0.2 – 5
│ 编码 Baseline           [ off ]            │   兼容性排查用
│ 固定画布（可留空）      [ 1024x512 ]       │   留空 = 跟仪表协商
├ 静态补位 ──────────────────────────────────┤
│ 静态补位                [ off ]            │   ← 1.0.83 默认也是关
│   静止判定              [ 0.35] 秒         │   0.15 – 2
│   轻量包码率上限        [ 0.8 ] Mbit/s     │   0.4 – 1.6
│   轻量包质量偏置        [ 0.15]            │   0.05 – 0.5
│   最小节省              [ 30  ] %          │   0 – 60
├ 连接诊断 ──────────────────────────────────┤
│ 端口测试 10930          [ 测试 ] → 通过 12 ms │
│ 测试图案                [ off ]            │   开着时仪表应显示彩条
│ 恢复默认参数            [ 恢复 ]            │
└────────────────────────────────────────────┘
```
说明：`.control` 行放 `UITextField` / `UISwitch`（1.0.6 已有这行类型），按钮用 `.action`；端口测试结果用 `.note` 现成行类型，**不用改 `SettingsUI.swift`**。

---

## 6. 每个参数的真实生效链路

```
用户改面板 → CfMotoTuning（UserDefaults）
              ├─ 码率/帧率/画布/Baseline/关键帧 ──→ 下次建立输出时读一次
              │      → Session.effectiveFps/Bitrate、H264Encoder(...)
              └─ 静态补位/测试图案 ──→ 拉流循环每次读（UserDefaults 有内存缓存，30 次/秒无压力）
                     ├─ 测试图案：latest ← 彩条 CVPixelBuffer
                     └─ 静态补位：指纹不变 → 跳过编码，重发缓存关键帧（必要时先建轻量编码器出一张小的）
```

---

## 7. 5 寸 / 6.2 寸为什么一点不受影响

| 机制 | 说明 |
|---|---|
| 开关 | `CfmotoTuning.active` 只在选中 EasyConn 时为真；`Session` 里所有增强都 `if tuned` 罩着 |
| 编码器参数 | 新增参数都有默认值，`quality: nil` + `keyframeSeconds: 1.0` = 1.0.6 现有行为 |
| 加锁 | 只影响并发安全，不改变调用顺序与结果 |
| 面板 | 只有 EasyConn 那支分支返回，5/6.2 寸的 `case` 一行不改 |
| 回归验证 | 见 §9 第 6–8 条 |

---

## 8. 不搬的 4 个 1.0.83 参数（以及为什么）

| 参数 | 不搬的原因 |
|---|---|
| `bufferDepth`（缓冲深度） | 1.0.6 是"拉一次发一帧"，没有帧队列，这个参数没有对应物 |
| `idrWaitSeconds` | 1.0.6 的关键帧等待是硬编码 3 秒重试（`:178`），改它属于改现有行为，不在你的 6 项里 |
| `allIntra`（全 I 帧） | 同上，会改变 1.0.6 的码流形态，风险大于收益 |
| `canvasWaitSeconds` | 1.0.6 用仪表协商值，没有等待窗口 |

如果以后需要，这三项都可以在 B 方案上继续加，不用重做。

---

## 9. 验收清单

**编译**
1. 推分支跑 GitHub Actions `build-ipa` → `BUILD SUCCEEDED`、0 error。
2. 二进制里能查到新增的 `CFMOTO_TUNING` 键名与「测试图案」字面量。

**设备（150SCF）**
3. 选中「春风 EasyConn」→ 设置页出现面板，5 个数值项可改、能落盘（杀进程重进还在）。
4. 码率改 1.5 Mbit/s 重启输出 → 日志行 `… 编码 30 FPS / 1.5 Mbit/s` 与实际观感变化一致。
5. 帧率改 15 → 日志与画面帧率同步变化。
6. 关键帧间隔改 3 s → 关键帧频率下降（日志统计关键帧间隔）。
7. 端口测试：仪表 IP 填错 → 超时；填对 → `通过 xx ms`。
8. 测试图案开 → 仪表立刻显示彩条；关 → 回到 CarPlay 画面。

**回归（最重要）**
9. 切到「春风 6.2 寸」→ 行为与改动前完全一致（日志 `4.5 Mbit/s / 30 FPS`，面板**不出现**）。
10. 切到「春风 5 寸」→ 同上，`2.5 Mbit/s / 25 FPS` 公式照旧。
11. 其它品牌（九号/极核/首驱）设置页无任何变化。

---

## 10. 需要你拍板的 4 件事

1. **方案**：B（就地增强，改 3 个文件 / 新增 4 个文件）—— 还是 D（并行新实现，改 4 个文件但多出 500 行重复逻辑）？
2. **默认值**：面板初始值
   - **A（推荐）**：跟随 EasyConn 现在的 profile —— **4.5 Mbit/s / 30 FPS**，用户不动参数时画面与「6.2 寸」一模一样；
   - B：照抄 1.0.83 —— 2.5 Mbit/s / 20 FPS（省流量，但第一次上手可能觉得比 6.2 寸糊）。
3. **面板位置**：嵌在「连接设置」页（同 1.0.83，一屏到底）—— 还是单独一页「画面参数」（页面更清爽，但多一次点击）？
4. **要不要也给「5 寸 / 6.2 寸」这面板**？默认**不给**（保持 1.0.6 原样）；给的话改动从 3 个文件变成 3 个文件+2 行分支，代码量几乎不变。

---

## 11. 施工顺序（确认后 3 个提交，1 轮 CI）

| 提交 | 内容 | 可独立验证 |
|---|---|---|
| 1 | `CfMotoTuning.swift` + `NinebotH264Encoder.swift` 参数化 | 编译通过、5/6.2 寸行为不变 |
| 2 | `CfmotoOutput.swift` 三个钩子（码率/帧率/画布/Baseline/关键帧/测试图案/静态补位） | 日志里看到生效值 |
| 3 | `CfMotoTuningPanel.swift` + `CfMotoDashProbe.swift` + `CfMotoTestPattern.swift` + 设置页接线 | 设备验收 §9 |

回滚极简单：面板「恢复默认参数」= 删掉 UserDefaults 的 9 个 key，全部回到 1.0.6 原始行为。
