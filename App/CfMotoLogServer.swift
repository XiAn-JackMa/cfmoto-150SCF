// SPDX-License-Identifier: AGPL-3.0-only
//
// Serves the EasyConn log over Wi-Fi so it can be read from a PC instead of copied by hand from the
// phone. Same wire format as the broadcast-extension log in the CFMoto Link project (0.7): on connect,
// `[length u32 little-endian][UTF-8 text]`, then the connection is closed.
//
//   curl --output - http://192.168.123.222:10950/    (any HTTP request works: the body is ignored)
//
// or from PowerShell:
//
//   $c = [Net.Sockets.TcpClient]::new("192.168.123.222", 10950); $s = $c.GetStream()
//   $h = New-Object byte[] 4; $s.Read($h,0,4) | Out-Null
//   $n = [BitConverter]::ToInt32($h,0); $b = New-Object byte[] $n; $s.Read($b,0,$n) | Out-Null
//   [Text.Encoding]::UTF8.GetString($b)

import Foundation
import Network

final class CfMotoLogServer {
    static let defaultPort: UInt16 = 10950

    private let queue = DispatchQueue(label: "cfmoto.logserver")
    private var listener: NWListener?
    private var text: () -> String = { "" }

    /// Starts serving `text` on `port`. Safe to call again: the previous listener is replaced.
    func start(port: UInt16 = CfMotoLogServer.defaultPort, text: @escaping () -> String) {
        stop()
        self.text = text
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return }
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        guard let listener = try? NWListener(using: parameters, on: nwPort) else { return }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.stateUpdateHandler = { state in
            if case .failed = state { /* port busy: the phone still has the log on screen */ }
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        let body = Data(text().utf8)
        var header = Data()
        let length = UInt32(truncatingIfNeeded: body.count)
        withUnsafeBytes(of: length.littleEndian) { header.append(contentsOf: $0) }
        connection.send(content: header + body, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}
