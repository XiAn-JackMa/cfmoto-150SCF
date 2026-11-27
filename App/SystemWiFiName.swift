// SPDX-License-Identifier: AGPL-3.0-only
//
// 系统当前的 Wi-Fi 名称（SSID）。
//
// iOS 只允许在「用户已授权定位」且「签名带 com.apple.developer.networking.wifi-info」时读到真实
// SSID，否则 `NEHotspotNetwork.fetchCurrent` 一律回调 nil。所以这里只做「能读就读」：
// 启动后静默试一次并存起来，读不到就交给调用方回退到 Wi-Fi 预设。
//
// 刻意不主动申请定位权限：那会在启动时弹框，而这个字段只用于排障（日志首行）。
// 已经授权过定位的用户会直接读到真实名称；没授权就安静地标记原因。

import CoreLocation
import Foundation
import NetworkExtension

enum SystemWiFiName {
    /// 一次读取的结果。日志里要能看出「为什么没有」，否则「Wi-Fi 不对」永远说不清。
    enum Status {
        /// 还没读过（App 刚启动，或根本没调 `prefetch()`）。
        case notAttempted
        /// 没有定位授权，系统不给。
        case locationDenied
        /// 有授权却还是拿不到：多半是签名没带 wifi-info 权限，或者当前没连 Wi-Fi。
        case unavailable
        case available(String)
    }

    private static let lock = NSLock()
    private static var status: Status = .notAttempted
    private static var started = false

    /// 读到的真实 SSID；nil 表示没读到。
    static var current: String? {
        lock.lock(); defer { lock.unlock() }
        if case .available(let name) = status { return name }
        return nil
    }

    static var currentStatus: Status {
        lock.lock(); defer { lock.unlock() }
        return status
    }

    /// 谁想知道结果就挂这里（`CfMotoEasyConnOutput` 用它补一行日志）。
    /// 挂的时候如果结果已经出来了，会立刻回调一次，避免「结果先到、观察者后挂」漏掉。
    static var onResolved: ((Status) -> Void)? {
        didSet {
            guard let observer = onResolved else { return }
            let snapshot = currentStatus
            if case .notAttempted = snapshot { return }
            DispatchQueue.main.async { observer(snapshot) }
        }
    }

    /// App 启动时调一次：不同步、不弹权限框、失败就安静放弃。
    static func prefetch() {
        guard Thread.isMainThread else { DispatchQueue.main.async { prefetch() }; return }
        lock.lock()
        let alreadyStarted = started
        started = true
        lock.unlock()
        guard !alreadyStarted else { return }
        let authorization = CLLocationManager().authorizationStatus
        guard authorization == .authorizedWhenInUse || authorization == .authorizedAlways else {
            finish(.locationDenied)
            return
        }
        NEHotspotNetwork.fetchCurrent { network in
            guard let name = network?.ssid, !name.isEmpty else { finish(.unavailable); return }
            finish(.available(name))
        }
    }

    private static func finish(_ new: Status) {
        lock.lock(); status = new; lock.unlock()
        // 成功和失败都要通知一次：失败原因本身就是日志里要看到的东西。
        DispatchQueue.main.async { onResolved?(new) }
    }
}
