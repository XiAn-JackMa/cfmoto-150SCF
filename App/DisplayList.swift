// SPDX-License-Identifier: AGPL-3.0-or-later
// CONTRACT FILE — EasyConn 视频路径用到的几何原语（DashRect / DashPoint / DashSize）。
//
// 坐标：仪表画布像素，原点左上，y 向下。
//
// 精简说明：这里曾包含整套平台无关的 Dash 渲染描述（DashPath / DashFont / DashDrawCommand /
// DashDisplayList / DashTextMeasurer / DashTransform…），那些类型只服务已删除的 Dash 自绘 UI，
// EasyConn 视频路径只需要这三个几何原语，其余已移除。

import Foundation

public struct DashPoint: Hashable, Sendable, Codable {
    public var x: Double
    public var y: Double
    public init(_ x: Double, _ y: Double) { self.x = x; self.y = y }
    public init(x: Double, y: Double) { self.x = x; self.y = y }
    public static let zero = DashPoint(0, 0)
}

public struct DashSize: Hashable, Sendable, Codable {
    public var width: Double
    public var height: Double
    public init(width: Double, height: Double) { self.width = width; self.height = height }
}

public struct DashRect: Hashable, Sendable, Codable, CustomStringConvertible {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
    public static let zero = DashRect(x: 0, y: 0, width: 0, height: 0)
    public var minX: Double { x }
    public var minY: Double { y }
    public var maxX: Double { x + width }
    public var maxY: Double { y + height }
    public var midX: Double { x + width / 2 }
    public var midY: Double { y + height / 2 }
    public var center: DashPoint { DashPoint(midX, midY) }
    public var size: DashSize { DashSize(width: width, height: height) }
    public var isEmpty: Bool { width <= 0 || height <= 0 }
    public func contains(_ p: DashPoint) -> Bool { p.x >= x && p.x < maxX && p.y >= y && p.y < maxY }
    public func insetBy(dx: Double, dy: Double) -> DashRect {
        DashRect(x: x + dx, y: y + dy, width: width - 2 * dx, height: height - 2 * dy)
    }
    public func offsetBy(dx: Double, dy: Double) -> DashRect { DashRect(x: x + dx, y: y + dy, width: width, height: height) }
    public func intersects(_ o: DashRect) -> Bool { x < o.maxX && o.x < maxX && y < o.maxY && o.y < maxY }
    public func union(_ o: DashRect) -> DashRect {
        let nx = min(x, o.x), ny = min(y, o.y)
        return DashRect(x: nx, y: ny, width: max(maxX, o.maxX) - nx, height: max(maxY, o.maxY) - ny)
    }
    public var description: String { String(format: "(%.1f,%.1f %.1fx%.1f)", x, y, width, height) }
}
