// SPDX-License-Identifier: AGPL-3.0-only
//
// 局域网扫描：找出同一网段里开着指定 TCP 端口的设备。
//
// 只服务 EasyConn 设置页的「扫描局域网设备」：先扫出车机 IP，省掉手填。
// 这里只看「TCP 连得上」——扫到之后仍然要点「端口测试」，那一步才会发真正的
// PXC 探测帧（`0x70000010`）并等车机应答。
//
// 只扫本机所在的那个 /24（车机热点都是 /24；掩码更大也只扫自己那一格，
// 否则 /16 会变成六万次连接）。64 个并发、非阻塞 connect + poll，全程约 1–3 秒。

import Darwin
import Foundation

enum LanPortScanner {
    struct Outcome {
        /// 扫的是哪个网段，如 192.168.123.0/24。
        var network = ""
        /// 开着端口的地址，按数值升序。
        var open: [String] = []
        /// 实际尝试过的地址数。
        var scanned = 0
        /// 连都连不上（EHOSTUNREACH/ENETUNREACH）的地址数：全是这种就说明大概率没有本地网络权限。
        var unreachable = 0
        var seconds: TimeInterval = 0
        /// 没能开扫的原因（没 Wi-Fi 地址等）。
        var failure: String?
    }

    /// 一批地址的探测结果。
    private struct BatchResult {
        var open: [UInt32] = []
        var unreachable = 0
    }

    private static let queue = DispatchQueue(label: "TDSCarKit.lanScan", qos: .userInitiated)
    private static let stateLock = NSLock()
    private static var running = false

    static var isRunning: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return running
    }

    /// 扫完在**主线程**回调；同一时刻只允许一次扫描，重复调用直接忽略。
    static func scan(port: UInt16, timeout: TimeInterval = 0.4,
                     completion: @escaping (Outcome) -> Void) {
        stateLock.lock()
        let busy = running
        if !busy { running = true }
        stateLock.unlock()
        guard !busy else { return }
        queue.async {
            let started = Date()
            var outcome = perform(port: port, timeout: timeout)
            outcome.seconds = Date().timeIntervalSince(started)
            stateLock.lock(); running = false; stateLock.unlock()
            DispatchQueue.main.async { completion(outcome) }
        }
    }

    // MARK: - 扫描本体

    private static func perform(port: UInt16, timeout: TimeInterval) -> Outcome {
        var outcome = Outcome()
        guard let local = localIPv4() else {
            outcome.failure = "没有 Wi-Fi 地址：先连上车机热点或同一局域网"
            return outcome
        }
        let base = local & 0xFFFF_FF00
        outcome.network = "\(InterfaceAddresses.format(base))/24"
        var targets: [UInt32] = []
        targets.reserveCapacity(254)
        for host in UInt32(1)...UInt32(254) {
            let candidate = base | host
            if candidate != local { targets.append(candidate) }
        }
        outcome.scanned = targets.count
        var open: [UInt32] = []
        var index = 0
        let batch = 64
        while index < targets.count {
            let end = min(index + batch, targets.count)
            let chunk = probe(Array(targets[index..<end]), port: port, timeout: timeout)
            open += chunk.open
            outcome.unreachable += chunk.unreachable
            index = end
        }
        outcome.open = open.sorted().map { InterfaceAddresses.format($0) }
        return outcome
    }

    /// 一批地址并发连一次：非阻塞 connect 后统一 poll，`SO_ERROR == 0` 即端口有人监听。
    private static func probe(_ hosts: [UInt32], port: UInt16, timeout: TimeInterval) -> BatchResult {
        var batch = BatchResult()
        var live: [(host: UInt32, fd: Int32)] = []
        defer { for entry in live { close(entry.fd) } }
        for host in hosts {
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            guard fd >= 0 else { continue }
            var on: Int32 = 1
            _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            let flags = fcntl(fd, F_GETFL, 0)
            if flags >= 0 { _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK) }
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = port.bigEndian
            address.sin_addr.s_addr = host.bigEndian
            let status = withUnsafePointer(to: &address) { raw in
                raw.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            if status == 0 || errno == EINPROGRESS {
                live.append((host, fd))
            } else {
                // 整个网段都是 EHOSTUNREACH/ENETUNREACH，通常是 iOS 没给「本地网络」权限。
                if errno == EHOSTUNREACH || errno == ENETUNREACH || errno == EACCES {
                    batch.unreachable += 1
                }
                close(fd)
            }
        }
        guard !live.isEmpty else { return batch }
        var sockets = live.map { pollfd(fd: $0.fd, events: Int16(POLLOUT), revents: 0) }
        let milliseconds = Int32(max(50, min(3000, timeout * 1000)))
        guard poll(&sockets, nfds_t(sockets.count), milliseconds) > 0 else { return batch }
        for (index, entry) in sockets.enumerated() where entry.revents != 0 {
            var error: Int32 = 0
            var length = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(entry.fd, SOL_SOCKET, SO_ERROR, &error, &length) == 0 else { continue }
            if error == 0 {
                batch.open.append(live[index].host)
            } else if error == EHOSTUNREACH || error == ENETUNREACH {
                batch.unreachable += 1
            }
        }
        return batch
    }

    // MARK: - 本机地址

    private static func localIPv4() -> UInt32? {
        guard let wifi = ReceiverConfiguration.wifiIPv4Address() else { return nil }
        return InterfaceAddresses.parseIPv4(wifi)
    }
}
