// SPDX-License-Identifier: AGPL-3.0-only
//
// Serves the EasyConn log over Wi-Fi so it can be read from a PC while the bike is running.
//
// Two things are served on the same port:
//
// * A live page, for a browser:      http://<phone-ip>:10950/
//   It polls `/log?since=N` twice a second and appends only the new lines, so it tails the log
//   without reloading and without copying anything off the phone.
// * The original one-shot format, for scripts: on connect, `[length u32 little-endian][UTF-8 text]`
//   and the connection closes. Any request that is not recognised falls back to this, so the
//   PowerShell snippet below keeps working.
//
//   $c = [Net.Sockets.TcpClient]::new("192.168.123.222", 10950); $s = $c.GetStream()
//   $h = New-Object byte[] 4; $s.Read($h,0,4) | Out-Null
//   $n = [BitConverter]::ToInt32($h,0); $b = New-Object byte[] $n; $s.Read($b,0,$n) | Out-Null
//   [Text.Encoding]::UTF8.GetString($b)
//
// The HTTP side is deliberately tiny: plain `GET`, `Connection: close`, no chunked encoding, no
// keep-alive. A viewer polls; that is one small request per half second and it cannot wedge.

import Foundation
import Network

final class CfMotoLogServer {
    static let defaultPort: UInt16 = 10950

    /// Snapshot of the whole log, used by the legacy format and by `/log` with no cursor.
    var text: () -> String = { "" }
    /// Incremental read: index -> (next index, new lines). Backed by the in-memory ring.
    var page: (Int) -> (next: Int, lines: [String]) = { ($0, []) }
    var onLog: ((String) -> Void)?

    private let queue = DispatchQueue(label: "cfmoto.logserver")
    private var listener: NWListener?
    private var port: UInt16 = CfMotoLogServer.defaultPort

    /// Starts serving on `port`. Safe to call again: the previous listener is replaced.
    func start(port: UInt16 = CfMotoLogServer.defaultPort) {
        stop()
        self.port = port
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return }
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        guard let listener = try? NWListener(using: parameters, on: nwPort) else {
            onLog?("日志服务：端口 \(port) 无法监听")
            return
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.onLog?("日志服务已在 \(port) 就绪：浏览器打开 http://<本机IP>:\(port)/")
            case .failed(let error):
                self?.onLog?("日志服务失败：\(error.localizedDescription)")
            default:
                break
            }
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    // MARK: - Connections

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        // Read just enough to see the request line. A legacy client sends nothing at all, so a
        // timeout is the signal to answer with the snapshot instead of waiting for ever.
        var received = Data()
        // Everything here runs on `queue`, so a plain flag is enough to answer exactly once: the
        // read callback and the timeout can otherwise both fire.
        var finished = false
        let deadline = DispatchTime.now() + .milliseconds(600)

        func finish() {
            guard !finished else { return }
            finished = true
            dispatchRequest(received, on: connection)
        }

        func readMore() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, isComplete, error in
                if let data, !data.isEmpty {
                    received.append(data)
                    if received.count > 8192 || received.firstRange(of: Data("\r\n\r\n".utf8)) != nil {
                        finish()
                        return
                    }
                }
                if isComplete || error != nil {
                    finish()
                    return
                }
                readMore()
            }
        }

        // One deadline for every connection: it answers even a client that says nothing (the legacy
        // snapshot case) and cannot leave a half-read request hanging.
        self.queue.asyncAfter(deadline: deadline) { finish() }
        readMore()
    }

    private func dispatchRequest(_ data: Data, on connection: NWConnection) {
        let head = String(data: data.prefix(2048), encoding: .utf8) ?? ""
        guard head.hasPrefix("GET ") || head.hasPrefix("HEAD "),
              let target = head.split(separator: " ").dropFirst().first else {
            // Legacy: length-prefixed snapshot, then close.
            let body = Data(text().utf8)
            var header = Data()
            let length = UInt32(truncatingIfNeeded: body.count)
            withUnsafeBytes(of: length.littleEndian) { header.append(contentsOf: $0) }
            send(header + body, on: connection)
            return
        }

        let path = String(target)
        if path == "/" || path.hasPrefix("/?") {
            send(html(), on: connection, contentType: "text/html; charset=utf-8")
        } else if path.hasPrefix("/log") {
            let since = cursor(from: path)
            let result = page(since)
            let payload: [String: Any] = ["next": result.next, "lines": result.lines]
            let body = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data("{}".utf8)
            send(body, on: connection, contentType: "application/json; charset=utf-8")
        } else if path.hasPrefix("/health") {
            send(Data("ok".utf8), on: connection, contentType: "text/plain; charset=utf-8")
        } else {
            send(Data("not found".utf8), on: connection, status: "404 Not Found",
                 contentType: "text/plain; charset=utf-8")
        }
    }

    private func cursor(from path: String) -> Int {
        guard let question = path.firstIndex(of: "?") else { return 0 }
        let query = path[path.index(after: question)...]
        for pair in query.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1)
            if parts.count == 2, parts[0] == "since" { return Int(parts[1]) ?? 0 }
        }
        return 0
    }

    private func send(_ body: Data, on connection: NWConnection, status: String = "200 OK",
                      contentType: String = "application/octet-stream") {
        var head = "HTTP/1.1 \(status)\r\n"
        head += "Content-Type: \(contentType)\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Cache-Control: no-store\r\n"
        head += "Connection: close\r\n\r\n"
        var payload = Data(head.utf8)
        payload.append(body)
        connection.send(content: payload, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    // MARK: - Page

    private func html() -> Data {
        let address = ReceiverConfiguration.wifiIPv4Address() ?? "本机IP"
        let page = """
        <!doctype html>
        <html lang="zh"><head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>CarWithin 日志 \(address):\(port)</title>
        <style>
          :root { color-scheme: light dark; }
          body { margin: 0; font: 13px/1.45 ui-monospace, Consolas, monospace;
                 background: #111; color: #e8e8e8; }
          header { position: sticky; top: 0; padding: 10px 14px; background: #1c1c1e;
                   border-bottom: 1px solid #333; display: flex; gap: 14px; align-items: center;
                   flex-wrap: wrap; }
          header b { font-weight: 600; color: #7fd1ff; }
          #dot { width: 9px; height: 9px; border-radius: 50%; background: #666; }
          #dot.live { background: #34d058; }
          label { color: #9aa0a6; }
          button { font: inherit; padding: 3px 10px; border-radius: 6px; border: 1px solid #444;
                   background: #2c2c2e; color: #e8e8e8; }
          #log { padding: 10px 14px 40vh; white-space: pre-wrap; word-break: break-word; }
          .warn { color: #ffd479; }
          .err  { color: #ff7b72; }
        </style></head>
        <body>
        <header>
          <span id="dot"></span><b>CarWithin EasyConn</b>
          <span id="meta">连接中…</span>
          <label><input type="checkbox" id="follow" checked> 跟随</label>
          <button id="clear">清屏</button>
          <button id="bottom">到底部</button>
        </header>
        <div id="log"></div>
        <script>
          let cursor = 0;
          const log = document.getElementById('log');
          const dot = document.getElementById('dot');
          const meta = document.getElementById('meta');
          const follow = document.getElementById('follow');
          let lastCount = 0;

          function classify(node, text) {
            if (text.includes('[警告]')) node.className = 'warn';
            if (text.includes('失败') || text.includes('错误')) node.className = 'err';
          }

          async function poll() {
            try {
              const response = await fetch('/log?since=' + cursor, { cache: 'no-store' });
              const data = await response.json();
              if (data.lines && data.lines.length) {
                for (const line of data.lines) {
                  const node = document.createElement('div');
                  node.textContent = line;
                  classify(node, line);
                  log.appendChild(node);
                }
                lastCount = log.childElementCount;
                cursor = data.next;
                if (follow.checked) window.scrollTo(0, document.body.scrollHeight);
              }
              dot.className = 'live';
              meta.textContent = new Date().toLocaleTimeString() + ' · 已收 ' + lastCount + ' 行';
            } catch (error) {
              dot.className = '';
              meta.textContent = '连接断开，重试中…';
            }
          }
          document.getElementById('clear').onclick = () => { log.textContent = ''; };
          document.getElementById('bottom').onclick = () => window.scrollTo(0, document.body.scrollHeight);
          poll();
          setInterval(poll, 500);
        </script>
        </body></html>
        """
        return Data(page.utf8)
    }
}
