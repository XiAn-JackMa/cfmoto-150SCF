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

    /// 10 ... 40 fps, and now a real ceiling: the pull path waits `1 / frameRate` between frames.
    ///
    /// Before that, the dash kept no cadence of its own and asked for the next frame the instant
    /// one arrived, so the serve rate was set by our reply latency (51-116 pulls/s measured) and
    /// this value only told the encoder what to expect.
    static var frameRate: Int {
        get { Int(clamp(Double(int(for: .frameRate, fallback: 30)), 10, 40)) }
        set { defaults.set(Int(clamp(Double(newValue), 10, 40)), forKey: Key.frameRate) }
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
    // MARK: Static picture

    /// Answer an idle pull with a smaller keyframe instead of the full-quality one.
    ///
    /// A still picture means every pull is answered with the same keyframe, so the wire carries
    /// pull-rate x keyframe-size: 63 KB at 20 fps is 10 Mbit/s for a screen that is not even
    /// changing. Re-encoding that still picture at
    /// a quarter of the bitrate makes the repeat six times cheaper, at the cost of a softer still
    /// image - which is exactly the picture a rider reads, so it is off by default.
    static var staticPadEnabled: Bool {
        get { defaults.object(forKey: Key.staticPad) as? Bool ?? false }
        set { defaults.set(newValue, forKey: Key.staticPad) }
    }

    /// Bitrate used for those pads, as a share of the configured one.
    static var staticPadBitrate: Int {
        let main = bitrateMbps * 1_000_000
        // 800 kbit/s is the ceiling that actually made a lone keyframe small; tying the pad to the
        // main bitrate only made the pad grow with it (a 6 Mbit/s session produced 40 KB pads).
        // Never above three quarters of the main rate, so the pad is always the cheaper frame.
        return max(400_000, min(800_000, min(Int(main * 0.25), Int(main * 0.75))))
    }

    static var staticPadMbps: Double { Double(staticPadBitrate) / 1_000_000 }

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
        let extras = canvasOverrideSize.map { " · 固定画布 \($0.width)×\($0.height)" } ?? ""
        let pad = staticPadEnabled ? String(format: " · 静止补帧 %.1f Mbps", staticPadMbps) : ""
        let intra = allIntra ? " · 全关键帧" : ""
        return String(format: "%.1f Mbps · %d fps · 关键帧 %.1f 秒 · %@ · 等待画布 %.0f 秒",
                      bitrateMbps, frameRate, keyframeSeconds,
                      forceBaseline ? "Baseline 3.1" : "自动 profile",
                      canvasWaitSeconds) + extras + pad + intra
    }

    static func reset() {
        for key in Key.all { defaults.removeObject(forKey: key) }
    }

    /// True when every key still holds its default, so the UI can say so.
    static var isDefault: Bool { Key.all.allSatisfy { defaults.object(forKey: $0) == nil } }

    // MARK: Pull path

    /// 2 ... 20 access units CarPlay may get ahead of the dash before frames are dropped.
    ///
    /// Pulls are capped at the configured frame rate but CarPlay may still deliver faster, so
    /// whatever it produces beyond that rate is either held (smoother, later) or dropped
    /// (current, earlier). This is that trade-off as one number.
    static var bufferDepth: Int {
        get { Int(clamp(Double((defaults.object(forKey: Key.bufferDepth) as? Int) ?? 6), 2, 20)) }
        set { defaults.set(Int(clamp(Double(newValue), 2, 20)), forKey: Key.bufferDepth) }
    }

    /// 0.5 ... 10 s to keep answering pulls with the cached picture while a keyframe is missing.
    ///
    /// Short asks CarPlay for a new keyframe sooner; long leaves it alone. Either way the dash is
    /// answered, because a locked-step pull that gets nothing parks for nine seconds.
    static var idrWaitSeconds: Double {
        get { clamp((defaults.object(forKey: Key.idrWait) as? Double) ?? 2.0, 0.5, 10) }
        set { defaults.set(clamp(newValue, 0.5, 10), forKey: Key.idrWait) }
    }

    // MARK: Static detection

    /// 0.15 ... 2 s the picture must be unchanged before the static pad is used.
    ///
    /// Shorter reacts sooner but treats the gap between two frames of live video as "static";
    /// longer is conservative. Only matters while the pad is on.
    static var staticIdleSeconds: Double {
        get { clamp((defaults.object(forKey: Key.staticIdle) as? Double) ?? 0.35, 0.15, 2) }
        set { defaults.set(clamp(newValue, 0.15, 2), forKey: Key.staticIdle) }
    }

    // MARK: All-intra

    /// Encode every frame as a keyframe.
    ///
    /// Roughly doubles the bitrate and removes two whole classes of trouble: a repeat can never
    /// reference a picture the dash lost, and no pull ever waits for a keyframe. What it costs is
    /// bandwidth, which is why it is off by default.
    static var allIntra: Bool {
        get { defaults.object(forKey: Key.allIntra) as? Bool ?? false }
        set { defaults.set(newValue, forKey: Key.allIntra) }
    }

    // MARK: Internals

    private enum Key {
        static let bitrate = "cfmotoTuningBitrate"
        static let frameRate = "cfmotoTuningFPS"
        static let keyframe = "cfmotoTuningKeyframe"
        static let baseline = "cfmotoTuningBaseline"
        static let canvasWait = "cfmotoTuningCanvasWait"
        static let canvasOverride = "cfmotoTuningCanvasOverride"
        static let staticPad = "cfmotoTuningStaticPad"
        static let bufferDepth = "cfmotoTuningBufferDepth"
        static let idrWait = "cfmotoTuningIDRWait"
        static let staticIdle = "cfmotoTuningStaticIdle"
        static let allIntra = "cfmotoTuningAllIntra"
        static let all = [bitrate, frameRate, keyframe, baseline, canvasWait, canvasOverride, staticPad,
                          bufferDepth, idrWait, staticIdle, allIntra]
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




