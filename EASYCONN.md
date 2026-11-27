# 春风 EasyConn 输出项（基于上游 1.0.6 的最小改动）

**改动范围：只有 `App/ReceiverViewController.swift` 一个文件**，7 处纯新增、0 处删除、0 处改写逻辑（唯一一行"改写"是等价替换，见下）。其余 341 个文件与上游 1.0.6 逐字节一致（已用 SHA256 逐个比对），另外新增了这份说明文件。

## 做了什么

在「当前输出」里新增条目 **春风 EasyConn**，位置紧跟「春风 6.2 寸」，归在「春风」分组。

它复用上游已有的春风 EasyConn/PXC 通路（TCP 10920/10921/10922，探测 10930），只是多了一个独立入口：

| # | 位置 | 改动 |
|---|---|---|
| 1 | `enum HeadUnitOutput` | 追加 case `cfmotoEasyConn`（**追加在最后**，`headUnitOutputV2` 存 rawValue，插中间会改已有选项的含义） |
| 2 | `menuOrder` | `.cfmoto5, .cfmoto62, .cfmotoEasyConn, .cfmoto700MT, …` |
| 3 | `title` | `case .cfmotoEasyConn: return CWL("春风 EasyConn")` |
| 4 | `cfmotoProfile` | `case .cfmotoEasyConn: return .sixInch`（复用 1024×515 · 30 FPS · 4.5 Mbps） |
| 5 | `cfmoto` | `self == .cfmoto5 \|\| self == .cfmoto62 \|\| self == .cfmotoEasyConn`（让连接卡片、仪表 Wi-Fi 判断、状态刷新都认它） |
| 6 | `brands` 分组 | `(CWL("春风"), [.cfmoto5, .cfmoto62, .cfmotoEasyConn, …])` |
| 7 | 连接设置页 | `case .cfmoto5, .cfmoto62, .cfmotoEasyConn:` —— 共用同一张 IP 输入卡片与说明 |
| 7b | 画面页标题 | `let name = outputMode == .cfmoto5 ? … : …` → `let name = outputMode.title`（等价：`title` 对 5 寸/6.2 寸返回完全相同的字符串） |

## 为什么复用 6.2 寸的规格

CFMOTO 150SCF 的仪表要的就是 **1024×515** 画布（1.0.83 源码里的注释：*"a CFMOTO 150SCF asks for 1024x515, rounded to 1024x512"*），与上游 `.sixInch` 一致。所以先复用，不另造一套没验证过的参数。要单独调，把第 4 处的 `.sixInch` 换成新的 `CfmotoProfile(width:height:fps:bitrate:label:)` 即可。

## 没做的事（保持原始内容不变）

- 没有引入 1.0.83 的 `CfMotoTuning` / `CfMotoVideoSource` / 调参卡片 / 手柄探针 / 方向键 / 日志页（那些属于完整移植，见 `CarWithin-1.0.83-改动清单.md` 第 3.8 节）；
- 没改 `Info.plist`（仍是 `1.0.6 / 18`）、没改 `Tools/generate_project.py`、没改任何 `Sources/`；
- 没新增 Swift 文件，所以不需要重新生成工程（`project.pbxproj` 不含新文件）。

## 编译验证

推分支 `easyconn-1.0.6` 到 `XiAn-JackMa/cfmoto-150SCF`，GitHub Actions `build-ipa`（macos-15）实跑：

| | |
|---|---|
| run | **45994248302**（head `75df887`） |
| 结论 | **BUILD SUCCEEDED**，0 error / 7 warning |
| 产物 | `CarWithin-1.0.108-unsigned.ipa`，3.8 MB，build 108 = 18 + run 90 |
| 包内 | `certificate.p7b` / `leaf.cer` / `private.x963` 均已打入（带身份，可直接侧载测试） |
| 已核对 | 二进制内含 `cfmotoEasyConn`（枚举 case 元数据），Bonjour 含 `_EasyConn._tcp` |

另做了一次对照构建（临时分支 `easyconn-check`，已删除）：把标题换成更长的字符串后，编译产物里能直接搜到该字符串 —— 证明 `title` 的这个分支确实进了产物。

本机编译：

```sh
xcodebuild -project TDSCarKit.xcodeproj -scheme TDSCarKit \
  -configuration Release -sdk iphoneos CODE_SIGNING_ALLOWED=NO -derivedDataPath build
```

装到手机后：首页「当前输出」→ 应能看到 **春风 EasyConn**（在「春风 6.2 寸」下面）→ 选它 → 「连接设置」填仪表 IP（留空则尝试同网段 .1）→ 启动本机 CarPlay。

## 已知限制

1. 行为与「春风 6.2 寸」相同（同一块画布、同一套 EasyConn 通路），区别只有入口名称；
2. 没有 1.0.83 的可调参数（码率/帧率/关键帧/静态补位/端口测试/测试图案），需要按改动清单第 3.8 节做完整移植；
3. 上游升级到 1.0.7+ 后要重做时，这 7 处都在 `HeadUnitOutput` 枚举附近，用 `grep -n '春风' App/ReceiverViewController.swift` 就能定位（改动清单 7.4 节有完整验证命令表）。
