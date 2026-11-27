// SPDX-License-Identifier: AGPL-3.0-or-later
// Ported from OpenCfMoto (Android) EasyConnProber.kt (probeTarget) and EasyConnDiscovery.kt
// (scanOpenPorts)
//
// One :10930 probe attempt and the last-resort port scan (docs/spec/control-plane.md §4,
// session-network.md §5.2–§5.3). The attempt loop, retry sleeps and the discovery ladder live in
// the session engine.

import Foundation

enum LinkIO {
    /// Runs `operation`; if it has not finished after `seconds`, closes `stream` (which makes a
    /// pending read throw, per the `ByteStream` contract) and throws `TransportError.timeout`.
    static func withDeadline<T: Sendable>(_ seconds: TimeInterval, closing stream: any ByteStream,
                                          _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        let timedOut = Locked(false)
        let timer = Task {
            try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            timedOut.set(true)
            stream.close()
        }
        defer { timer.cancel() }
        do {
            return try await operation()
        } catch {
            if timedOut.current { throw TransportError.timeout }
            throw error
        }
    }

    /// Cancellation-aware sleep; false if the task was cancelled (callers then exit).
    static func sleep(_ seconds: TimeInterval) async -> Bool {
        if Task.isCancelled { return false }
        if seconds <= 0 { return true }
        do {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            return true
        } catch {
            return false
        }
    }
}

/// Performs single probe attempts and port checks over a `NetworkProvider`.
struct DashProbeClient: Sendable {
    enum Outcome: Sendable, Equatable {
        /// `0x70000011` with "true" in the body.
        case accepted
        /// A reply that is not an acceptance (body text).
        case rejected(String)
        /// The dash closed before replying.
        case noReply
        /// Connected, but no reply within the read timeout.
        case unanswered
        /// Connect / write / read / frame error.
        case failed(String)
        /// The provider reported `LinkFailure.localNetworkDenied` (the system dropped the connect).
        case localNetworkDenied

        /// The TCP connection to the dash was established, so Local Network access works.
        var connected: Bool {
            switch self {
            case .accepted, .rejected, .noReply, .unanswered: return true
            case .failed, .localNetworkDenied: return false
            }
        }

        /// Short kind for the discovery summary (review LOG-1): "timed out", "refused", "unreachable",
        /// "connected, no reply", "closed without a reply", "not accepted", "blocked by the system"…
        var summaryKind: String {
            switch self {
            case .accepted: return "accepted"
            case .rejected: return "not accepted"
            case .noReply: return "closed without a reply"
            case .unanswered: return "connected, no reply"
            case .localNetworkDenied: return "blocked by the system"
            case let .failed(message):
                let m = message.lowercased()
                if m.contains("timed out") || m.contains("etimedout") { return "timed out" }
                if m.contains("refused") { return "refused" }
                if ["ehostunreach", "enetunreach", "ehostdown", "enetdown"].contains(where: { m.contains($0) }) {
                    return "unreachable"
                }
                return "failed"
            }
        }
    }

    let network: NetworkProvider
    let connectTimeout: TimeInterval
    let readTimeout: TimeInterval
    /// Registers an in-flight stream so a session shutdown can close it; false = session dead.
    let track: @Sendable (any ByteStream) -> Bool
    let untrack: @Sendable (any ByteStream) -> Void

    /// One probe attempt (Android `probeTarget` body): connect, send the fixed frame, read one
    /// frame, close the socket in all cases.
    func probeOnce(host: String, port: UInt16, attempt: Int) async -> Outcome {
        Log.i("LINK", "[探测] 第 \(attempt) 次连接 \(host):\(port)")
        let stream: any ByteStream
        do {
            stream = try await network.connect(host: host, port: port, timeout: connectTimeout)
        } catch {
            if DashProbeClient.isLocalNetworkDenied(error) {
                Log.e("LINK", "[探测] !! 系统丢弃了连接（本地网络权限没开，或 VPN / 数据限制 / 过滤器）")
                return .localNetworkDenied
            }
            Log.i("LINK", "[探测] 失败：\(error)")
            return .failed("\(error)")
        }
        guard track(stream) else {
            stream.close()
            return .failed("session stopped")
        }
        defer {
            stream.close()
            untrack(stream)
        }
        do {
            Log.i("LINK", "[探测] → 发探测帧 MDNS_RESPOND (0x70000010) \(PxcProbe.payloadJSON)")
            try await stream.write(PxcProbe.frameBytes)
            let reply = try await LinkIO.withDeadline(readTimeout, closing: stream) {
                try await PxcFrame.read(from: stream)
            }
            let body = reply.payloadText
            Log.i("LINK", "[探测] ← 收到 cmd=\(reply.cmdHex) \(body)")
            if PxcProbe.isAccepted(reply) {
                Log.i("LINK", "[探测] *** 已通过——车机现在应该回连我们的端口 ***")
                return .accepted
            }
            Log.w("LINK", "[探测] !! 车机没接受：\(body)")
            return .rejected(body)
        } catch TransportError.closed {
            Log.i("LINK", "[探测] 车机还没应答就关了连接")
            return .noReply
        } catch TransportError.timeout {
            Log.i("LINK", "[探测] 连上了，但 \(readTimeout) 秒内没收到应答")
            return .unanswered
        } catch {
            Log.i("LINK", "[探测] 失败：\(error)")
            return .failed("\(error)")
        }
    }

    /// Local Network privacy denial as reported by a transport: `LinkFailure.localNetworkDenied`, or
    /// `PlatformTransportErrors.localNetworkDeniedError` (the POSIX and NW providers' form).
    static func isLocalNetworkDenied(_ error: Error) -> Bool {
        if let f = error as? LinkFailure, f == .localNetworkDenied { return true }
        if case let .failed(message)? = error as? TransportError,
           message.hasPrefix(PlatformTransportErrors.localNetworkDenied) { return true }
        return false
    }

    /// TCP connect check used by the port scan (connect, then close immediately).
    func isPortOpen(host: String, port: UInt16, timeout: TimeInterval) async -> Bool {
        guard let s = try? await network.connect(host: host, port: port, timeout: timeout) else { return false }
        s.close()
        return true
    }

    /// Sequential connect scan (Android `scanOpenPorts`), result ordered with 10930 first.
    func scanOpenPorts(host: String, ports: ClosedRange<UInt16>, timeout: TimeInterval,
                       shouldContinue: @Sendable () -> Bool) async -> [UInt16] {
        Log.i("LINK", "[扫描] 正在扫 \(host) 的 \(ports.lowerBound)–\(ports.upperBound) 端口…")
        var open: [UInt16] = []
        for port in ports {
            guard shouldContinue() else { break }
            if await isPortOpen(host: host, port: port, timeout: timeout) { open.append(port) }
        }
        Log.i("LINK", open.isEmpty ? "[扫描] 没扫到开着的端口" : "[扫描] 开着的端口：\(open)")
        return open.sorted { a, b in (a == PxcProbe.port ? 0 : 1, a) < (b == PxcProbe.port ? 0 : 1, b) }
    }
}

/// Serializes probe attempts across concurrently running discovery paths and remembers whether one
/// was accepted, so no second probe is ever sent after an acceptance (control-plane.md §18.5).
actor ProbeGate {
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var accepted = false

    /// Waits for the gate; returns false (without holding it) if a probe was already accepted.
    func acquire() async -> Bool {
        if accepted { return false }
        if busy {
            await withCheckedContinuation { waiters.append($0) }
        } else {
            busy = true
        }
        if accepted {
            release(accepted: false)
            return false
        }
        return true
    }

    func release(accepted wasAccepted: Bool) {
        if wasAccepted { accepted = true }
        if waiters.isEmpty {
            busy = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}

/// FIFO async mutex: serializes the writers of one connection (the reply path and the heartbeat
/// task on :10922) so frames are written whole and in order whatever the transport guarantees.
actor LinkWriteLock {
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if busy {
            await withCheckedContinuation { waiters.append($0) }
        } else {
            busy = true
        }
    }

    func release() {
        if waiters.isEmpty {
            busy = false
        } else {
            waiters.removeFirst().resume()
        }
    }

    /// Writes `data` on `stream` while holding the lock.
    func write(_ data: Data, to stream: any ByteStream) async throws {
        await acquire()
        do {
            try await stream.write(data)
        } catch {
            release()
            throw error
        }
        release()
    }
}

