// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

/// Manual overrides for the EasyConn video path, persisted in UserDefaults.
///
/// The defaults are what the production MOTO-HUB Android app uses for a TFT dash - 2.5 Mbit/s,
/// 30 fps, a keyframe every second - and they are what the 150SCF runs well on. The overrides
/// exist for the cases those defaults do not cover:
///
/// - a 2:1 dash showing a busy CarPlay map wants more bitrate than a self-drawn dashboard does,
///   and 5 GHz has the room;
/// - a weak link wants less, and fewer keyframes;
/// - a dash that renegotiates its canvas oddly can be pinned.
///
/// Everything here is read when a session prepares the encoder, so a change applies to the next
/// session and - for the encoder keys - immediately, because the encoder is rebuilt.
enum CfMotoTuning {
    private static var defaults: UserDefaults { .standard }

    // MARK: Bitrate

    /// 0.6 ... 12 Mbit/s.
    static var bitrateMbps: Double {
        get { clamp(double(for: .bitrate, fallback: 2.5), 0.6, 12) }
        set { defaults.set(clamp(newValue, 0.6, 12), forKey: Key.bitrate) }
    }

    static var bitrate: Int { Int((bitrateMbps * 1_000_000).rounded()) }

    // MARK: Frame rate

    /// 10 ... 30 fps. This is a ceiling passed to the encoder, not a producer rate: frames are
    /// encoded when the dash pulls, so the dash still decides the real rate.
    static var frameRate: Int {
        get { Int(clamp(Double(int(for: .frameRate, fallback: 30)), 10, 30)) }
        set { defaults.set(Int(clamp(Double(newValue), 10, 30)), forKey: Key.frameRate) }
    }

    // MARK: Keyframes

    /// 0.2 ... 5 s between forced IDRs. Shorter recovers faster on a lossy link and costs bitrate;
    /// longer is leaner but a dropped frame smears until the next one.
    static var keyframeSeconds: Double {
        get { clamp(double(for: .keyframe, fallback: 1.0), 0.2, 5) }
        set { defaults.set(clamp(newValue, 0.2, 5), forKey: Key.keyframe) }
    }

    // MARK: Profile

    /// Baseline@3.1 keeps old dash decoders happy. Turning it off lets VideoToolbox pick a higher
    /// level, which is only worth trying when a dash refuses the stream.
    static var forceBaseline: Bool {
        get { defaults.object(forKey: Key.baseline) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.baseline) }
    }

    // MARK: Start-up

    /// How long the start waits for the dash to report its canvas before using the remembered size.
    static var canvasWaitSeconds: Double {
        get { clamp(double(for: .canvasWait, fallback: 4), 0, 15) }
        set { defaults.set(clamp(newValue, 0, 15), forKey: Key.canvasWait) }
    }

    /// "1024x512" pins the canvas and the CarPlay render size; nil follows the dash.
    static var canvasOverride: String? {
        get {
            let raw = (defaults.string(forKey: Key.canvasOverride) ?? "").trimmingCharacters(in: .whitespaces)
            return raw.isEmpty ? nil : raw
        }
        set {
            let raw = (newValue ?? "").trimmingCharacters(in: .whitespaces)
            defaults.set(raw, forKey: Key.canvasOverride)
        }
    }

    /// The parsed override, or nil when it is absent or malformed.
    static var canvasOverrideSize: (width: Int, height: Int)? {
        guard let raw = canvasOverride else { return nil }
        let parts = raw.lowercased().split(separator: "x")
        guard parts.count == 2, let w = Int(parts[0]), let h = Int(parts[1]), w >= 320, h >= 320 else { return nil }
        return (w / 2 * 2, h / 2 * 2)
    }

    // MARK: Housekeeping

    /// One line for the log and the settings screen.
    static var summary: String {
        String(format: "%.1f Mbps · %d fps · 关键帧 %.1f 秒 · %@ · 等待画布 %.0f 秒%@",
               bitrateMbps, frameRate, keyframeSeconds,
               forceBaseline ? "Baseline 3.1" : "自动 profile",
               canvasWaitSeconds,
               canvasOverrideSize.map { " · 固定画布 \($0.width)×\($0.height)" } ?? "")
    }

    static func reset() {
        for key in Key.all { defaults.removeObject(forKey: key) }
    }

    /// True when every key still holds its default, so the UI can say so.
    static var isDefault: Bool { Key.all.allSatisfy { defaults.object(forKey: $0) == nil } }

    // MARK: Internals

    private enum Key {
        static let bitrate = "cfmotoTuningBitrate"
        static let frameRate = "cfmotoTuningFPS"
        static let keyframe = "cfmotoTuningKeyframe"
        static let baseline = "cfmotoTuningBaseline"
        static let canvasWait = "cfmotoTuningCanvasWait"
        static let canvasOverride = "cfmotoTuningCanvasOverride"
        static let all = [bitrate, frameRate, keyframe, baseline, canvasWait, canvasOverride]
    }

    private enum Field { case bitrate, frameRate, keyframe, baseline, canvasWait }

    private static func double(for field: Field, fallback: Double) -> Double {
        switch field {
        case .bitrate: return defaults.object(forKey: Key.bitrate) as? Double ?? fallback
        case .keyframe: return defaults.object(forKey: Key.keyframe) as? Double ?? fallback
        case .canvasWait: return defaults.object(forKey: Key.canvasWait) as? Double ?? fallback
        default: return fallback
        }
    }

    private static func int(for field: Field, fallback: Int) -> Int {
        switch field {
        case .frameRate: return defaults.object(forKey: Key.frameRate) as? Int ?? fallback
        default: return fallback
        }
    }

    private static func clamp(_ value: Double, _ low: Double, _ high: Double) -> Double {
        min(max(value, low), high)
    }
}
