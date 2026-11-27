// SPDX-License-Identifier: AGPL-3.0-only
//
// File-backed log for the EasyConn output, built for testing at the bike.
//
// Why a file: the in-memory view dies with the app (or with a crash), and the interesting part of a
// field test is usually the moment before it died. Every line is timestamped, appended to
// Documents/CarWithin-easyconn.log, and the same text feeds the settings screen plus the :10950
// endpoint, so all three agree.
//
// The file is rotated once at 1 MB (one previous file is kept), which is many hours of riding.

import Foundation
import UIKit

final class CfMotoLogStore {
    /// Lines kept in memory for the settings screen. The file keeps everything until rotation.
    private let capacity = 800
    private let maximumFileBytes = 1_000_000

    private let lock = NSLock()
    private var lines: [String] = []
    /// Index of lines[0] in the stream since the app started. Trimmed lines bump it, so a reader
    /// that remembers an index keeps getting exactly the lines it has not seen.
    private var firstIndex = 0
    private var handle: FileHandle?
    private let fileURL: URL?

    private static let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    init() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        fileURL = documents?.appendingPathComponent("CarWithin-easyconn.log")
        guard let fileURL else { return }

        // Rotate once so a long ride cannot fill the phone.
        if let size = try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int,
           size > maximumFileBytes {
            let previous = fileURL.deletingPathExtension().appendingPathExtension("log.1")
            try? FileManager.default.removeItem(at: previous)
            try? FileManager.default.moveItem(at: fileURL, to: previous)
        }
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        }
        handle = try? FileHandle(forWritingTo: fileURL)
        handle?.seekToEndOfFile()
        append("==== 会话开始 ====")
        append(Self.environment())
        // A crash from the previous run is the most useful thing in the file.
        if let crash = CrashCatcher.previousException() {
            append("上次闪退: \(crash)")
            CrashCatcher.clear()
        }
    }

    deinit { try? handle?.close() }

    /// Device and build context, so a log sent from a phone identifies itself.
    static func environment() -> String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        let device = "\(UIDevice.current.model) / iOS \(UIDevice.current.systemVersion)"
        let presetSSID = WiFiPresetStore.selected()?.ssid ?? "未设置"
        return "版本 \(version) (\(build)) · \(device) · 本地IP \(ReceiverConfiguration.wifiIPv4Address() ?? "-")" +
            " · Wi-Fi 预设 \(presetSSID)"
    }

    func append(_ message: String) {
        let line = "\(Self.stamp.string(from: Date())) \(message)"
        lock.lock()
        lines.append(line)
        if lines.count > capacity {
            let drop = lines.count - capacity
            lines.removeFirst(drop)
            firstIndex += drop
        }
        if let data = (line + "\n").data(using: .utf8) { try? handle?.write(contentsOf: data) }
        lock.unlock()
    }

    /// Total lines appended since launch, including those already dropped from memory.
    var totalLines: Int { lock.lock(); defer { lock.unlock() }; return firstIndex + lines.count }

    /// Lines from `index` onwards, and the index to ask for next time. Reading from memory keeps a
    /// remote viewer in step with what is on screen; anything older is only in the file.
    func lines(from index: Int, limit: Int = 400) -> (next: Int, lines: [String]) {
        lock.lock(); defer { lock.unlock() }
        let start = max(index - firstIndex, 0)
        guard start < lines.count else { return (firstIndex + lines.count, []) }
        let end = min(start + limit, lines.count)
        return (firstIndex + end, Array(lines[start..<end]))
    }

    var text: String {
        lock.lock(); defer { lock.unlock() }
        return lines.joined(separator: "\n")
    }

    func clear() {
        lock.lock()
        lines.removeAll()
        if let handle { try? handle.truncate(atOffset: 0) }
        lock.unlock()
        append("==== 日志已清空 ====")
    }

    /// Flushes and returns the file, for the share sheet.
    func fileForSharing() -> URL? {
        lock.lock()
        try? handle?.synchronize()
        lock.unlock()
        return fileURL
    }
}
