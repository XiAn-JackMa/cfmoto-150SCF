// SPDX-License-Identifier: AGPL-3.0-or-later
// CONTRACT FILE — EasyConn 视频路径使用的设置值类型。Raw values 沿用 Android 持久化字符串。
//
// 精简说明：这里曾包含整个 OpenCfMotoCore 的设置契约（BikeSettings / MapPreferences /
// ButtonAction / ButtonGesture / ButtonClusterPreset / ButtonTiming / MirrorOrientation），
// 那些类型只服务已删除的设置存储 / 把手 / 导航 UI，EasyConn 视频路径用不到，已移除。

import Foundation

public enum VideoQuality: String, Sendable, Codable, CaseIterable {
    case smooth = "SMOOTH", balanced = "BALANCED", sharp = "SHARP"
    /// Multiplier on the profile base bitrate (2.5 Mbit/s).
    public var bitrateFactor: Double {
        switch self {
        case .smooth: return 0.7
        case .balanced: return 1.0
        case .sharp: return 1.6
        }
    }
}

public enum ScreenFit: String, Sendable, Codable, CaseIterable {
    case fill = "FILL", fit = "FIT", stretch = "STRETCH"
}

public enum PowerMode: String, Sendable, Codable, CaseIterable {
    case auto = "AUTO", smooth = "SMOOTH", balanced = "BALANCED", saver = "SAVER"
    /// Frame cap (fps). AUTO starts at 30 and adapts (AdaptivePolicy).
    public var frameCap: Int {
        switch self {
        case .auto, .smooth: return 30
        case .balanced: return 24
        case .saver: return 20
        }
    }
}

public enum WifiTransport: String, Sendable, Codable, CaseIterable {
    case auto = "auto", ap = "ap", p2p = "p2p"
}

/// Per-edge insets in dash pixels (0…200). `customised == false` → the profile default applies
/// (800NK Advanced: top 22, all others 0).
public struct ScreenMargins: Sendable, Equatable, Codable {
    public var customised: Bool
    public var top: Int
    public var bottom: Int
    public var left: Int
    public var right: Int
    public init(customised: Bool = false, top: Int = 0, bottom: Int = 0, left: Int = 0, right: Int = 0) {
        self.customised = customised; self.top = top; self.bottom = bottom; self.left = left; self.right = right
    }
    public static let zero = ScreenMargins()
    public func clamped() -> ScreenMargins {
        func c(_ v: Int) -> Int { min(200, max(0, v)) }
        return ScreenMargins(customised: customised, top: c(top), bottom: c(bottom), left: c(left), right: c(right))
    }
}
