# EasyConn 移植清单（相对 1.0.6 基线 `75df887`）

> 用途：当原作者发布 1.0.7 时，照着这份清单把「春风 EasyConn」整体移植过去。
> 生成时间：1.0.6 → easyconn-tuned（HEAD `1730ef9`，版本 1.0.134）。

## 一、结论

移植成本很低，因为 EasyConn 做到了**严格隔离**：

| 类型 | 数量 | 移植动作 |
|---|---|---|
| A 新增文件 | 59 | 57 个 Swift + 2 个 md，直接拷贝，零冲突 |
| M 修改文件 | 6 | 都是小改动（见第四节），diff 合并即可 |
| D 删除文件 | **0** | 没有删除任何 1.0.6 原有文件，1.0.7 也不需要删任何东西 |

唯一的隔离开关是 `ReceiverConfiguration.cfmotoTuned`（1 个 Bool）。5 寸 / 6.2 寸（`CfmotoOutput` + `PxcConnection`）路径原样保留，EasyConn 完全不经过它们。

**约束（移植时同样遵守）**：不修改 `Package.swift`、`Tools/generate_project.py`、`App/CfmotoOutput.swift`。工程由 `generate_project.py` 全量 glob `App/*.swift` 生成，所以新文件拷进去就自动进构建，无需手改工程。

---

## 二、59 个新增文件（直接拷贝）

### A1 · 链路核心（1.0.83 的 OpenCfMotoCore 栈，20 个）
```
EasyConnLink.swift  LinkSession.swift  LinkOptions.swift  LinkTypes.swift
LinkSessionContext.swift  LinkStatsTracker.swift
POSIXTransport.swift  Transport.swift  InterfaceAddresses.swift
ClientInfo.swift  ControlChannelHandler.swift  MediaChannelHandler.swift  MediaMessage.swift
ConfigCapture.swift  HuTimeSync.swift
PxcCmd.swift  PxcFrame.swift  PxcTouchFrame.swift  PxcProbe.swift  PxcOrgJSON.swift
```

### A2 · 车机画像 / QR / 触控 / 探测（6 个）
```
BikeProfile.swift  BikeProfileSelection.swift  BikeQR.swift  BikeQRParser.swift
GhostTouchFilter.swift  DashProbeClient.swift
```

### A3 · 签名 / 日志（5 个）
```
PureSwiftHuidSigner.swift  RSAKeyMaterial.swift  RSABigUInt.swift
Log.swift  LogRedactor.swift
```

### A4 · 视频管线（1.0.83，9 个）
```
CfMotoVideoSource.swift  EasyConnH264Encoder.swift  EncoderPlanner.swift  FrameQueue.swift
CanvasFit.swift  VideoTypes.swift  AdaptivePolicy.swift
H264SPS.swift  OcmAnnexB.swift
```

### A5 · 共享几何 / 契约（3 个，视频 + 设置共用，不能省）
```
DisplayList.swift   # DashRect/DashPoint/DashColor/DashFont/DashTransform/DashDrawCommand/DashTextMeasurer
NavTypes.swift      # RouteOptions/RouteMode/MapUnits/MapTheme/MapChrome/Route/GeoPoint/TurnDir
SettingsTypes.swift # ScreenMargins/ScreenFit/VideoQuality/PowerMode/MirrorOrientation/WifiTransport/BikeSettings…
```

### A6 · EasyConn 适配层（1.0.83 App 层，7 个）
```
CfMotoEasyConnLink.swift   # 引擎（推流 + 探测 + 状态 + onProbeFailed）
CfMotoEasyConnOutput.swift # 薄适配（start/append/分辨率查询/日志网页）
CfMotoEasyConnPanel.swift  # 设置面板（画面参数 + 连不上自动停 + 日志）
CfMotoTuning.swift         # 参数持久化（码率/帧率/画布/超时）
CfMotoLogStore.swift       # 文件日志环（毫秒时间戳，Documents/CarWithin-easyconn.log）
CfMotoLogServer.swift      # :10950 日志网页
CrashCatcher.swift         # 上次闪退捕获
```

### A7 · 工具 / JSON（7 个）
```
AppJavaNumber.swift  AppJvmText.swift  OrderedJSON.swift  Async.swift
ByteIO.swift  LanPortScanner.swift  ProblemReport.swift
```

### A8 · 文档（2 个，可选）
```
EASYCONN.md  EASYCONN-TUNING-PLAN.md
```

---

## 三、6 个修改文件（diff 合并，改动都很小）

| 文件 | 改动量 | 内容 |
|---|---|---|
| `App/AppDelegate.swift` | +8 | `didFinishLaunching` 里加 `CrashCatcher.install()` |
| `App/ReceiverConfiguration.swift` | +2 | 加 `var cfmotoTuned = false` 开关字段 |
| `App/PxcConnection.swift` | +2 | init 加 `probePort: UInt16 = Port.probe` 参数 |
| `App/NativeReceiver.swift` | +46 | 加 `cfmotoEasyConn` 实例 + `easyConnOutput`/`onEasyConnLog`/`appendEasyConnLog`；`cfmotoTuned` 时走 EasyConn 分支（start/append/stop），否则走原 `cfmoto5/cfmoto62` |
| `App/ReceiverViewController.swift` | +343/-49 | 唯一的大改动：EasyConn 面板接入、`planDisplay` 分支、等画布启动 CarPlay、探测失败跳过等待、日志上屏、状态行 |
| `App/Localization/Localizable.xcstrings` | +6 | 中文文案 |

---

## 四、移植步骤（1.0.7 出来时）

1. **拷贝**：把第二、三节的 57 个 Swift 文件拷进 1.0.7 的 `App/`。
2. **合并**：6 个 M 文件逐个打补丁（diff 都很小；`ReceiverViewController` 按 `cfmotoTuned` / EasyConn 关键字定位合并）。
3. **验证开关**：确认 `cfmotoTuned` 只在「春风 EasyConn」输出时为 true，5寸/6.2寸不受影响。
4. **跑 CI**：`generate_project.py` 自动 glob 新文件，直接构建验证。
5. **不删任何文件**：1.0.7 原文件一个都不动。

---

## 五、风险与注意

- **唯一需要人工判断的合并点**：如果 1.0.7 原作者也改了 `ReceiverViewController.swift`（尤其 `planDisplay`、`onListening` 启动流程、`stop()`）、`NativeReceiver.swift`、`PxcConnection.swift`，需要三方合并。我们的改动都是「加分支」式的最小侵入，冲突概率低。
- **探测/画布/等待的关键逻辑**（都在 `ReceiverViewController.onListening` 里）：车机在线 → 等画布 → 按车机分辨率 1:1 启动；车机不在线（`onProbeFailed`，探测第 2 次仍无应答）→ 跳过 4 秒等待直接启动。
- **连不上自动停止**：`CfMotoTuning.connectTimeoutMinutes`（默认 5 分钟，0=关），引擎 ticker 每 3 秒检查。
- **日志三处一致**：内存环（设置页）+ 文件（`CarWithin-easyconn.log`）+ 网页（`:10950`），同一份 `CfMotoLogStore`。
