// SPDX-License-Identifier: AGPL-3.0-only
//
// Feeds the EasyConn link from CarPlay's own H.264.
//
// The dashboard demands a fixed canvas (a CFMOTO 150SCF asks for 1024x515, rounded to 1024x512) while
// CarPlay delivers whatever picture size it negotiated. So every access unit is decoded, letterboxed
// into the canvas and re-encoded — the same shape as ZeehoOutput, except frames are served on demand
// (the dash pulls with REQ_RV_DATA_NEXT) instead of on a fixed timer.

import AVFoundation


import CoreImage
import Foundation
import UIKit
import VideoToolbox

struct CfMotoLiveStats {
    /// Size of the picture CarPlay produced.
    var carPlaySize = "—"
    /// Size of the canvas the dash negotiated, which is what we encode into.
    var canvasSize = "—"
    /// "1:1" when no rescaling happens, otherwise the factor applied before encoding.
    var scaleText = "—"
    /// Frames handed to the dash over the last two seconds, divided by two.
    var servedFPS: Double = 0
    /// Pictures CarPlay delivered over the last two seconds, divided by two. Compare with
    /// servedFPS: a gap means the dash is pulling faster than CarPlay produces, and the difference
    /// is answered from the cache.
    var sourceFPS: Double = 0
    /// Mbit/s CarPlay itself produced over the last two seconds.
    var sourceMbps: Double = 0
    /// Mbit/s actually put on the wire over the last two seconds.
    var bitrateMbps: Double = 0
    /// Share of served frames that were re-sent from the cache.
    var paddedRatio: Double = 0
    /// Share of served frames that were keyframes.
    var keyframeRatio: Double = 0
    var averageFrameKB: Double = 0
    var counters = ""
    /// Latest static-pad outcome, shown under the bitrate when the pad is enabled.
    var staticPadNote = ""
    /// Times the current pad has been sent since it was generated; 0 means no pad in use.
    var padReuses = 0
    /// False until a picture has actually been served, which is what separates "CarPlay has
    /// nothing new to show" from "CarPlay never started".
    var hasPicture = false

    /// "1024×512 · 19.8 fps · 1:1" - the one line both readouts show.
    var summary: String {
        String(format: "%@ · %.1f fps · 缩放 %@", canvasSize, servedFPS, scaleText)
    }
}

final class CfMotoVideoSource: VideoFrameSource, @unchecked Sendable {
    private let queue: FrameQueue
    private let work = DispatchQueue(label: "CarWithin.cfmoto.codec", qos: .userInitiated)
    private let lock = NSLock()
    private let context = CIContext(options: [.useSoftwareRenderer: true, .cacheIntermediates: false])

    private var parameters = VideoParameterSets(codec: .h264)
    private var decoder: TailingH264Decoder?
    /// One box per decoder: the decoder's output closure captures it for its whole lifetime, so a
    /// per-call box would receive every picture after the first into a box nobody reads.
    private var decodeBox = DecodeBox()
    /// Latest decoded picture. CarPlay drops to 1-2 fps on a static screen while the pull path
    /// keeps serving at the configured rate, so idle pulls re-encode this picture instead of
    /// returning nothing.
    private var latestImage: CVPixelBuffer?
    /// The last picture already letterboxed to the canvas. Scaling runs on the CPU (CIContext with
    /// the software renderer), which cost ~100 ms per pull when idle repeats re-scaled the same
    /// picture; do it once per new picture instead.
    private var fittedBuffer: CVPixelBuffer?
    /// Last keyframe access unit, resent when a pull finds nothing new: no encoding, and a dash
    /// that lost its reference frames can always resume on it.
    private var lastKeyframeAU: Data?
    /// A new picture arrived that has not been encoded yet. Encoding the same picture twice can
    /// yield byte-identical P-frames, which §15.2 forbids (re-applying one corrupts the picture),
    /// so an unchanged picture is answered with the cached IDR instead.
    private var pictureDirty = true
    /// Whether the last access unit handed to the dash was a keyframe. Only a keyframe may be sent
    /// again, so this decides whether an unchanged picture can be answered from the cache.
    private var lastServedWasKeyframe = false
    /// Last time CarPlay handed us a picture. A long silence means the black frames the dash is
    /// seeing come from CarPlay, not from the EasyConn output, and the log should say so.
    /// Seeded at construction so the readout never subtracts distantPast - it printed
    /// 63931217258 seconds before the first session had prepared a canvas.
    private var lastInboundAt = Date()

    /// Synthetic colour-bar source: validates the whole EasyConn path (canvas, encoder, framing,
    /// pulls, repeats) without waiting for CarPlay, on the bench or on the bike.
    var testPattern = false
    private var patternTask: Task<Void, Never>?
    /// VideoToolbox encodes are serialized: the work queue and the pull path both encode.
    private let encodeLock = NSLock()
    private var encoder: H264Encoder?
    private var canvas: VideoCanvas?
    private var encoderSettings = EncoderParameters()

    /// Encoder hint: the next encode should be forced to an IDR.
    private var waitingForIDR = true
    /// Decoder gate, kept separate on purpose. Padding a pull re-encodes the current picture as an
    /// IDR every few milliseconds, and clearing one shared flag there would tell a *dead decoder*
    /// that it no longer needs a keyframe - the exact state (decoder nil, flag false) that froze the
    /// dash before.
    private var decoderNeedsKeyframe = true
    /// When the decoder started waiting for a keyframe. A long wait means the link died while the
    /// app was in the background, and repeating the last picture would freeze the dash for good.
    private var decoderWaitingSince = Date.distantPast
    /// How long a pull may keep being answered from the cached picture before CarPlay is asked for
    /// a keyframe. Configured by CfMotoTuning.idrWaitSeconds.
    private var idrGiveUpAfter: TimeInterval = 2.0
    private var sequence: UInt64 = 0
    private var lastCodecFailure = -Double.infinity
    private var lastKeyframe = -Double.infinity
    /// Result of the in-flight encode, written by the VideoToolbox callback under `lock`.
    private var encodedResult: Result<H264EncodedFrame, Error>?
    private var pending = 0
    private var skipping = false
    private var stopped = false

    /// Asks CarPlay for a fresh keyframe (the dash just resynchronised its decoder).
    var onKeyframeRequest: (() -> Void)?
    /// When the last keyframe request went out, so a struggling decoder cannot spam the channel.
    private var lastKeyframeRequestAt = Date.distantPast
    /// Set while the app is backgrounded. Only used to decide that the encoder must be rebuilt: the
    /// keyframe gate looks at whether frames are arriving, because CarPlay keeps sending while
    /// backgrounded whenever something is actually playing or changing on screen.
    /// True while the app is backgrounded. CarPlay suspends its video there, so a keyframe request
    /// cannot be answered - each one is an encrypted write on the event channel, and a failed write
    /// closes that channel. Better not to ask at all.
    private var isBackgrounded = false
    var log: ((String) -> Void)?

    /// Counters for the status card: where a pull stalls is what the rider needs to see.
    private var inbound = 0        // access units arriving from CarPlay
    private var decodedCount = 0   // decoded to a picture
    private var encodedCount = 0   // re-encoded into an access unit
    private var pulls = 0          // REQ_RV_DATA_NEXT (114) served or timed out
    private var servedCount = 0    // frames actually handed to the link
    private var nonH264 = 0        // access units dropped because CarPlay sent H.265
    private var paramSets = 0      // SPS/PPS absorbed from the stream
    // Why decode() returned nothing, counted per reason: this is what pinpoints a stuck gate.
    private var dropWaitingIDR = 0
    private var dropCooldown = 0
    private var dropNoDecoder = 0
    private var dropNoPicture = 0
    /// AUs that carried only SPS/PPS. CarPlay splits them off about 40% of the time; skipping them is
    /// correct (the decoder is configured from `parameters`), so they must not look like lost frames.
    private var parameterSetOnly = 0
    private var dropNoCallback = 0
    private var decodeErrors = 0
    /// Idle pulls answered by re-encoding the last picture.
    private var repeatedCount = 0
    /// Rolling window of (when, how many bytes) for the live rate readout. Bytes are kept because
    /// the bitrate shown on screen has to be what is actually being sent now, not since the session
    /// started, which is what the cumulative counters would give.
    private var servedWindow: [(at: TimeInterval, bytes: Int)] = []
    /// Arrival times of pictures from CarPlay, for the source-side readout.
    private var sourceWindow: [(at: TimeInterval, bytes: Int)] = []

    /// A second encoder that compresses the still picture at a low bitrate, used to answer idle
    /// pulls when that is enabled. Separate from the main encoder so its rate control is never
    /// disturbed: the main one keeps producing full-quality frames the moment anything moves.
    private var padEncoder: H264Encoder?
    private var padCanvasKey = ""
    private var padEncodedResult: Result<H264EncodedFrame, Error>?
    /// Serialises pad encodes. The pad path is on the pull thread and must not block the main
    /// encode lock, which the work queue needs.
    private let padLock = NSLock()
    /// The pad access unit, valid only while the picture has not changed since it was made.
    private var padKeyframeAU: Data?
    private var padGeneration = -1
    /// The picture generation whose pad came out no smaller than the normal keyframe. Remembered so
    /// a rejected pad is not re-attempted on every pull for the same picture.
    private var padRejectedGeneration = -1
    /// When the last fresh picture arrived. The pad only makes sense once the picture has really
    /// stopped: between two frames of live video there is a 40 ms gap, and treating that as "static"
    /// cost one wasted pad encode per picture and filled the log with rejections.
    private var lastPictureUptime: TimeInterval = 0
    /// Last time the rejection was explained, so a screen that keeps changing says it once.
    private var lastPadRejectLog: TimeInterval = 0

    /// How long the picture must have been unchanged before a pad is worth making.
    /// Seconds the picture must be unchanged before the static pad applies (CfMotoTuning).
    private var staticIdleSeconds: TimeInterval = 0.35
    /// Bumped for every freshly decoded picture, so a cached pad can be checked for staleness.
    private var pictureGeneration = 0
    private var padCount = 0
    /// Cached copy of CfMotoTuning.staticPadEnabled: the pull path runs many times a second and a
    /// UserDefaults read per pull is not free. Refreshed whenever the tuning is applied.
    private var staticPadOn = false
    /// Latest static-pad outcome, for the line under the bitrate readout.
    private var lastPadNote = ""
    /// How many times the current pad has been served since it was generated.
    private var padReuses = 0
    /// Cached copies of the pull-path tuning values, read once when the tuning is applied instead
    /// of on every pull.
    private var bufferDepth = 6
    /// Every frame is a keyframe: no repeat can reference a picture the dash lost, and no pull
    /// ever waits for a keyframe. Costs roughly double the bitrate.
    private var allIntraOn = false
    /// Minimum time between two served frames, from the configured frame rate.
    ///
    /// The dash keeps no cadence of its own, so without this the serve rate is whatever our reply
    /// latency allows (measured 51-116 pulls/s on a real 150SCF).
    private var serveInterval: TimeInterval = 0.05
    /// Uptime of the last frame handed to the dash; the pacing above measures from here.
    private var lastServeAt: TimeInterval = 0

    /// One line per session describing the stream CarPlay actually produces. It is the first thing
    /// to look at when the picture is wrong: profile, level and reorder depth decide whether a
    /// stream can be handed anywhere else untouched.
    private var loggedCarPlaySPS = false
    /// Cumulative bytes and keyframes handed to the dash, for the average frame size and IDR share.
    private var servedBytes = 0
    private var servedKeyframes = 0
    /// Size of the picture CarPlay actually produced, and of the canvas we encode into: the pair
    /// that decides whether `fitted()` scales (blurring the dash text) or passes the picture through.
    private var sourceWidth = 0
    private var sourceHeight = 0
    /// `parameters` is mutated on the work queue; this flag is the lock-protected view of it.
    private var parametersReady = false
    /// Throttles per-frame diagnostics so a stalled pipeline says why once, not 30 times a second.
    private var lastDiagnostic = -Double.infinity

    /// Logs at most once every two seconds.
    private func diagnose(_ message: @autoclosure () -> String) {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastDiagnostic >= 2 else { return }
        lastDiagnostic = now
        log?("CFMOTO \(message())")
    }

    /// Seconds since CarPlay last produced a picture (large values mean CarPlay itself is silent).
    var inboundIdle: TimeInterval {
        lock.lock(); defer { lock.unlock() }
        // lastInboundAt is reset when a session prepares, so this is "seconds this session has
        // gone without a picture" - not a subtraction from distantPast, which printed 63931202261.
        return Date().timeIntervalSince(lastInboundAt)
    }

    var counters: String {
        lock.lock(); defer { lock.unlock() }
        return countersLocked()
    }

    /// Same string, for callers that already hold the lock.
    private func countersLocked() -> String {
        let format = nonH264 > 0
            ? "CarPlay 发的是 H.265（车机只认 H.264，已丢弃 \(nonH264) 帧）"
            : (parametersReady ? "画面格式：H.264 已就绪" : "画面格式：还在等 CarPlay 的参数")
        // Plain words on purpose: this line is read at the bike, where "拉帧" and "重发" mean nothing.
        var parts = [
            // CarPlay sends SPS/PPS as their own access unit about 40% of the time; those never
            // become a picture, and leaving them out made the counts look like lost frames
            // (1753 in, 946 decoded) when the difference was entirely parameter sets.
            "CarPlay 送来 \(inbound) 帧（其中 \(parameterSetOnly) 帧只是参数包）",
            format,
            "解出画面 \(decodedCount) 帧",
            "重新压缩 \(encodedCount) 帧",
            "车机索要 \(pulls) 次",
            "成功交付 \(servedCount) 帧",
            (padCount > 0 ? "其中重复上一帧 \(repeatedCount) 次（轻量包生成 \(padCount) 个）" : "其中重复上一帧 \(repeatedCount) 次"),
        ]
        var problems: [String] = []
        if dropWaitingIDR > 0 { problems.append("等关键帧丢了 \(dropWaitingIDR)") }
        if dropCooldown > 0 { problems.append("重建太频繁跳过 \(dropCooldown)") }
        if dropNoDecoder > 0 { problems.append("没有解码器 \(dropNoDecoder)") }
        if dropNoPicture > 0 { problems.append("空画面 \(dropNoPicture)") }
        if dropNoCallback > 0 { problems.append("解码器没回应 \(dropNoCallback)") }
        if decodeErrors > 0 { problems.append("解码出错 \(decodeErrors)") }
        if !problems.isEmpty { parts.append("异常：" + problems.joined(separator: "、")) }
        return parts.joined(separator: " · ")
    }

    /// Applies the manual overrides from the EasyConn page on top of the profile's suggestion.
    /// A dash profile proposes values tuned for a self-drawn dashboard; a mirrored CarPlay map has
    /// more detail, so the bitrate is worth raising when the link can carry it.
    static func tuned(_ parameters: EncoderParameters) -> EncoderParameters {
        var tuned = parameters
        tuned.bitrate = CfMotoTuning.bitrate
        tuned.frameRate = CfMotoTuning.frameRate
        tuned.keyframeIntervalSeconds = CfMotoTuning.keyframeSeconds
        tuned.forceBaseline = CfMotoTuning.forceBaseline
        return tuned
    }

    /// Rebuilds the encoder after a settings change, so a new bitrate or profile applies to the
    /// running session instead of waiting for the next one. The next frame is forced to an IDR,
    /// which is what a rebuilt encoder needs anyway.
    func reloadTuning() {
        lock.lock()
        let old = encoder
        encoder = nil
        waitingForIDR = true
        encoderSettings = CfMotoVideoSource.tuned(encoderSettings)
        let stalePadForTuning = padEncoder
        staticPadOn = CfMotoTuning.staticPadEnabled
        bufferDepth = CfMotoTuning.bufferDepth
        idrGiveUpAfter = CfMotoTuning.idrWaitSeconds
        staticIdleSeconds = CfMotoTuning.staticIdleSeconds
        serveInterval = 1.0 / Double(max(1, CfMotoTuning.frameRate))
        allIntraOn = CfMotoTuning.allIntra
        padEncoder = nil; padCanvasKey = ""; padKeyframeAU = nil; padGeneration = -1
        lock.unlock()
        old?.invalidate()
        stalePadForTuning?.invalidate()
        log?("CFMOTO 画面参数已应用：\(CfMotoTuning.fullSummary)（编码器已重建）")
    }

    init(queueCapacity: Int = 3) {
        queue = FrameQueue(capacity: queueCapacity)
        queue.onKeyframeNeeded = { [weak self] in self?.requestKeyframeIfUseful() }
    }

    // MARK: - VideoFrameSource

    func prepare(canvas: VideoCanvas, parameters: EncoderParameters) {
        lock.lock()
        let previous = self.canvas
        self.canvas = canvas
        self.encoderSettings = CfMotoVideoSource.tuned(parameters)
        self.staticPadOn = CfMotoTuning.staticPadEnabled
        self.bufferDepth = CfMotoTuning.bufferDepth
        self.idrGiveUpAfter = CfMotoTuning.idrWaitSeconds
        self.staticIdleSeconds = CfMotoTuning.staticIdleSeconds
        self.serveInterval = 1.0 / Double(max(1, CfMotoTuning.frameRate))
        self.allIntraOn = CfMotoTuning.allIntra
        let sizeChanged = previous == nil || previous!.width != canvas.width || previous!.height != canvas.height
        var retired: H264Encoder?
        if sizeChanged {
            retired = encoder
            encoder = nil
            waitingForIDR = true
            decoderNeedsKeyframe = true
            decoderWaitingSince = Date()
        }
        lock.unlock()
        // Outside the lock: invalidate waits for the encoder's in-flight frame, and the callback that
        // completes it needs this same lock.
        retired?.invalidate()

        // Report the settings actually applied, not the profile default: the EasyConn page can
        // override the bitrate, and printing the raw value made a 6 Mbit/s session read as 2.5.
        let effective = encoderSettings
        log?("CFMOTO canvas \(canvas.width)x\(canvas.height)（车机请求 \(canvas.requestedWidth)x\(canvas.requestedHeight)）" +
             String(format: " · 实际编码 %.1f Mbps @ %d fps · 关键帧 %.1f 秒 · %@",
                    Double(effective.bitrate) / 1_000_000, effective.frameRate,
                    effective.keyframeIntervalSeconds,
                    effective.forceBaseline ? "Baseline 3.1" : "Main profile"))
        if sizeChanged {
            // A keyframe of the previous canvas must never answer a pull for this one: a cached
            // access unit from the old size would decode as garbage on the dash.
            lock.lock(); fittedBuffer = nil; lastKeyframeAU = nil; lock.unlock()
            lock.lock()
            let stalePad = padEncoder
            padEncoder = nil; padCanvasKey = ""; padKeyframeAU = nil; padGeneration = -1
            lock.unlock()
            stalePad?.invalidate()
            queue.invalidateKeyframe()
            queue.resynchronize()
        }
        // Seed a hint picture so the very first pull has an answer. Without it the dash's first
        // 114 finds nothing, waits out its 9 s timeout and drops the link - twice in a row after a
        // restart, which is what made "start CarPlay" appear to hang on 正在连接 until the simulator
        // was restarted too. CarPlay replaces this the moment it produces a frame.
        lock.lock(); lastInboundAt = Date(); lock.unlock()
        if lock.withLock({ fittedBuffer == nil }) {
            if let hint = hintFrame(width: canvas.width, height: canvas.height) {
                lock.lock(); fittedBuffer = hint; lock.unlock()
            }
        }
        // After the queue reset above, so the pattern's first keyframe is not flushed by it.
        startPatternIfNeeded()
    }

    /// A cheap access unit for an idle pull: the still picture re-compressed at a low bitrate.
    ///
    /// A static screen means no fresh picture, and the link still wants an answer twenty times a
    /// second, so the full-quality keyframe goes out twenty times - 63 KB each at 6 Mbit/s, about
    /// 10 Mbit/s for a screen that is not moving. Compressing that same still at a quarter of the
    /// bitrate makes the repeat roughly six times cheaper. The picture softens, which is why the
    /// rider turns this on deliberately.
    ///
    /// Returns nil when a pad cannot be produced, so the caller falls back to the full-quality
    /// cached keyframe.
    private func staticPadAccessUnit(_ image: CVPixelBuffer, canvas: VideoCanvas) -> Data? {
        let generation = lock.withLock { pictureGeneration }
        if lock.withLock({ padGeneration == generation }), let cached = lock.withLock({ padKeyframeAU }) {
            return cached
        }
        padLock.lock()
        defer { padLock.unlock() }
        // Another pull may have produced it while this one waited; a rejected pad is remembered
        // so the same picture is not re-encoded on every idle pull.
        if lock.withLock({ padGeneration == generation }), let cached = lock.withLock({ padKeyframeAU }) {
            return cached
        }
        if lock.withLock({ padRejectedGeneration == generation }) { return nil }
        let key = "\(canvas.width)x\(canvas.height)"
        lock.lock()
        var retiredPad: H264Encoder?
        if padEncoder == nil || padCanvasKey != key {
            // Take it out of the field under the lock, invalidate it after releasing: its callback
            // stores the result under this same lock, so invalidating while holding it would hang
            // exactly the way the main encoder used to.
            retiredPad = padEncoder
            padEncoder = nil
            do {
                padEncoder = try H264Encoder(
                    width: canvas.width, height: canvas.height,
                    fps: encoderSettings.frameRate, bitrate: CfMotoTuning.staticPadBitrate,
                    profileLevel: CfMotoTuning.forceBaseline ? .baseline31 : .mainAuto,
                    // Bias quantisation directly: a lone keyframe after idle would otherwise ignore
                    // the bitrate target entirely.
                    quality: CfMotoTuning.staticPadQuality,
                    keyframeSeconds: encoderSettings.keyframeIntervalSeconds
                ) { [weak self] outcome in
                    guard let self else { return }
                    self.lock.lock(); self.padEncodedResult = outcome; self.lock.unlock()
                }
                padCanvasKey = key
            } catch {
                padEncoder = nil
                lock.unlock()
                retiredPad?.invalidate()
                log?("静止补帧：低码率编码器建不起来，改用正常关键帧（\(error.localizedDescription)）")
                return nil
            }
        }
        padEncodedResult = nil
        let encoder = padEncoder
        lock.unlock()
        retiredPad?.invalidate()
        guard let encoder else { return nil }
        do {
            try encoder.encode(image,
                               presentationTime: CMTime(seconds: ProcessInfo.processInfo.systemUptime,
                                                        preferredTimescale: 1_000_000),
                               forceKeyframe: true)
            encoder.complete()
            var outcome: Result<H264EncodedFrame, Error>?
            let deadline = ProcessInfo.processInfo.systemUptime + 0.25
            repeat {
                outcome = lock.withLock { padEncodedResult }
                if outcome != nil { break }
            } while ProcessInfo.processInfo.systemUptime < deadline
            lock.lock(); padEncodedResult = nil; lock.unlock()
            guard let frame = try outcome?.get() else { return nil }
            lock.lock()
            let padSize = frame.data.count
            let fullSize = lastKeyframeAU?.count ?? 0
            // A pad that is not clearly smaller is not worth a second encode: reuse the normal
            // keyframe instead, and do not try again for this picture. "Clearly smaller" is the
            // user-tunable minimum saving, because a simple screen's normal keyframe is already
            // small and a too-strict gate just encodes the normal frame again after the pad.
            let minSaving = CfMotoTuning.staticPadMinSavingPct
            let useful = fullSize == 0 || padSize * 100 <= fullSize * (100 - minSaving)
            lastPadNote = useful
                ? "轻量包 \(padSize / 1024) KB（正常关键帧 \(fullSize / 1024) KB）"
                : "轻量包 \(padSize / 1024) KB 未省 \(minSaving)%（正常 \(fullSize / 1024) KB）"
            padKeyframeAU = useful ? frame.data : nil
            padGeneration = generation
            if !useful { padRejectedGeneration = generation }
            padReuses = 0
            padCount += 1
            lock.unlock()
            guard useful else {
                // Reported once per picture; the caller then reuses the normal keyframe.
                let now = ProcessInfo.processInfo.systemUptime
                if now - lastPadRejectLog >= 10 {
                    lastPadRejectLog = now
                    log?("静止补帧：轻量包 \(padSize / 1024) KB 未比正常关键帧 \(fullSize / 1024) KB 小 \(minSaving)%，改用正常帧（每 10 秒最多提示一次）")
                }
                return nil
            }
            log?("静止补帧：轻量包 \(padSize / 1024) KB" +
                 (fullSize > 0 ? "（正常关键帧 \(fullSize / 1024) KB）" : "") +
                 String(format: " · 补帧码率 %.1f Mbps", CfMotoTuning.staticPadMbps))
            return frame.data
        } catch {
            lock.lock()
            let brokenPad = padEncoder
            padEncoder = nil
            padCanvasKey = ""
            padGeneration = -1
            lock.unlock()
            brokenPad?.invalidate()
            log?("静止补帧失败，改用正常关键帧：\(error.localizedDescription)")
            return nil
        }
    }

    /// Appends one arrival to the source-side window. Call with the lock held.
    private func noteSourceLocked(bytes: Int) {
        let now = ProcessInfo.processInfo.systemUptime
        sourceWindow.append((now, bytes))
        while let first = sourceWindow.first, now - first.at > 3 { sourceWindow.removeFirst() }
    }

    /// True when the access unit carries a coded picture rather than only parameter sets. Used to
    /// report what CarPlay actually produces, which is the number the wire rate has to be compared
    /// against when the dash looks slow.
    private func carriesPicture(_ data: Data) -> Bool {
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return false }
            let count = raw.count
            var index = 0
            while index + 3 < count {
                if base[index] == 0, base[index + 1] == 0, base[index + 2] == 1 {
                    let type = base[index + 3] & 0x1F
                    if type == 1 || type == 5 { return true }
                    index += 3
                } else {
                    index += 1
                }
            }
            return false
        }
    }

    /// Reports CarPlay's own stream parameters once per session.
    private func logCarPlayStreamOnce(_ data: Data) {
        guard !loggedCarPlaySPS, let info = H264SPS.parse(accessUnit: data) else { return }
        loggedCarPlaySPS = true
        var text = "CarPlay 原始流：\(info.summary)"
        if info.levelIdc > 41 { text += " ← level 偏高，老车机解码器可能不接受" }
        if let reorder = info.maxNumReorderFrames, reorder > 0 { text += " ← 含 B 帧重排" }
        log?(text)
    }

    /// Asks CarPlay for a keyframe when the request can actually be answered, at most once a second.
    private func requestKeyframeIfUseful() {
        let now = Date()
        lock.lock()
        // The test is "frames are still arriving", not "the app is foreground": with music playing
        // or a screen that keeps changing, CarPlay keeps delivering while backgrounded, and a
        // keyframe request can be answered there - it is the only way back for a decoder that iOS
        // revoked on the way out. When nothing has arrived for five seconds the request cannot be
        // answered, and asking anyway is a write on the event channel whose failure closes it.
        let flowing = now.timeIntervalSince(lastInboundAt) <= 5
        let tooSoon = now.timeIntervalSince(lastKeyframeRequestAt) < 1
        let send = flowing && !tooSoon
        if send { lastKeyframeRequestAt = now }
        lock.unlock()
        guard send else { return }
        onKeyframeRequest?()
    }

    /// Called when the app leaves or returns to the foreground.
    ///
    /// Backgrounding revokes the hardware encoder: the session handle stays non-nil but
    /// VTCompressionSessionEncodeFrame then fails with -12903 (kVTInvalidSessionErr). Dropping it
    /// here turns that failed encode into a clean rebuild on the next pull, which also falls back to
    /// the software encoder when the hardware one refuses to come back.
    func setBackgrounded(_ value: Bool) {
        lock.lock()
        let changed = isBackgrounded != value
        isBackgrounded = value
        let retired = value ? encoder : nil
        let retiredPad = value ? padEncoder : nil
        if value {
            encoder = nil; waitingForIDR = true
            padEncoder = nil; padCanvasKey = ""; padKeyframeAU = nil; padGeneration = -1
        }
        lock.unlock()
        guard changed else { return }
        retired?.invalidate()
        retiredPad?.invalidate()
        log?("App 进入后台：已释放编码器，下次需要时自动重建")
    }

    /// Hard reset, the equivalent of the reference client's `restartStream()`: drop the decoder and
    /// the queued frames, mark that the next frame must be a keyframe, and ask CarPlay for one.
    ///
    /// Used when the app comes back from the background, where the decompression session is the part
    /// that does not survive. Dropping it is what makes the rebuild deterministic; keeping a decoder
    /// that has silently stopped delivering is what froze the dash (decoder nil while waitingForIDR
    /// stayed false, so nothing ever rebuilt it).
    func resynchronize() {
        lock.lock()
        let retired = decoder
        decoder = nil
        decodeBox = DecodeBox()
        waitingForIDR = true
        decoderNeedsKeyframe = true
        decoderWaitingSince = Date()
        lock.unlock()
        // Outside the lock: invalidate waits for the decoder to drain, and the frame callbacks it
        // waits on take this lock.
        retired?.invalidate()
        queue.invalidateKeyframe()
        queue.resynchronize()
        requestKeyframeIfUseful()
    }

    /// Serves one pull, paced to the configured frame rate.
    ///
    /// The dash has no cadence of its own: it sends the next REQ_RV_DATA_NEXT the moment a frame
    /// arrives, so our reply latency *is* its frame rate. Measured on a real 150SCF - 92-116 pulls
    /// per second when a P-frame reply took ~10 ms, 51-87 when an all-intra one took ~18 ms - and
    /// nothing throttled it. That was the root of three separate complaints:
    ///
    /// - the picture was soft, because 3 Mbit/s spread over 100 fps is 3.7 KB per frame, 0.06
    ///   bit/pixel, and no encoder can render text at that rate;
    /// - stripes flickered in, because VideoToolbox has to drop or crush frames to stay inside its
    ///   byte limit, and a dropped frame breaks the reference chain the dash is still decoding;
    /// - the wire carried 13-26 Mbit/s for a 1024x512 picture while the readout said 70 fps, which
    ///   is more frames than the panel can show and more than the link needs to carry.
    ///
    /// Pacing fixes all three at once: every frame gets the bit budget the setting promised, the
    /// encoder is never squeezed, and the dash still receives every picture it can actually show.
    func nextFrame(timeout: TimeInterval) async -> EncodedFrame? {
        let frame = await serveFrame(timeout: timeout)
        lock.lock()
        let interval = serveInterval
        let last = lastServeAt
        lock.unlock()
        // Pace even an empty answer: a dash that gets nothing retries immediately, which would
        // spin the link at full speed through the first moments of a session.
        if interval > 0, last > 0 {
            let wait = interval - (ProcessInfo.processInfo.systemUptime - last)
            if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
        }
        lock.lock()
        lastServeAt = ProcessInfo.processInfo.systemUptime
        lock.unlock()
        return frame
    }

    /// One pull answered from the picture in hand. `nextFrame` paces the result.
    private func serveFrame(timeout: TimeInterval) async -> EncodedFrame? {
        lock.lock()
        pulls += 1
        let prepared = fittedBuffer
        let canvas = self.canvas
        let waiting = decoderNeedsKeyframe
        let since = decoderWaitingSince
        lock.unlock()

        // One pull, one encode of the picture in hand: the dash is lock-step, so a queue in between
        // only adds staleness and overflow. Nothing to encode yet means CarPlay has not produced a
        // picture at all, which only happens in the first moments of a session.
        lock.lock()
        let dirty = pictureDirty
        let cacheIsCurrent = lastServedWasKeyframe
        let cachedKeyframe = lastKeyframeAU
        let pictureIdle = ProcessInfo.processInfo.systemUptime - lastPictureUptime
        lock.unlock()
        // Only reuse the cache when the frame already sent *was* a keyframe: then the cache and the
        // current picture agree. If the last frame was a P, the cached IDR is older than the picture
        // in hand, and resending it is how the progress bar walked backwards (52 s, 51 s, 52 s).
        if !dirty, staticPadOn, pictureIdle >= staticIdleSeconds, let prepared, let canvas,
           let pad = staticPadAccessUnit(prepared, canvas: canvas) {
            // The still picture, re-compressed small: same content, a fraction of the bytes.
            lock.lock()
            servedCount += 1; repeatedCount += 1; padReuses += 1
            noteServed(pad.count, keyframe: true)
            sequence &+= 1
            let seq = sequence
            lock.unlock()
            if waiting, Date().timeIntervalSince(since) > idrGiveUpAfter { requestKeyframeIfUseful() }
            return EncodedFrame(accessUnit: pad, isKeyframe: true,
                                presentationTime: ProcessInfo.processInfo.systemUptime, sequence: seq)
        }

        if !dirty, cacheIsCurrent, let keyframe = cachedKeyframe {
            // The picture has not changed since the last encode, so the cached IDR is exactly what
            // the dash should see; re-encoding identical content risks a byte-identical P-frame.
            lock.lock()
            servedCount += 1; repeatedCount += 1
            noteServed(keyframe.count, keyframe: true)
            sequence &+= 1
            let seq = sequence
            lock.unlock()
            if waiting, Date().timeIntervalSince(since) > idrGiveUpAfter { requestKeyframeIfUseful() }
            return EncodedFrame(accessUnit: keyframe, isKeyframe: true,
                                presentationTime: ProcessInfo.processInfo.systemUptime, sequence: seq)
        }
        if let prepared, let canvas {
            if waiting, Date().timeIntervalSince(since) > idrGiveUpAfter {
                // The decoder cannot use the stream; keep the link alive while CarPlay is asked for
                // a keyframe. Answering nothing would park a lock-step dash until its 9 s timeout.
                diagnose("等关键帧 \(Int(Date().timeIntervalSince(since)))s，先用当前画面维持会话")
                requestKeyframeIfUseful()
            }
            if let frame = encode(prepared, canvas: canvas, force: !dirty) {
                lock.lock()
                servedCount += 1
                encodedCount += 1
                pictureDirty = false
                lastServedWasKeyframe = frame.isKeyframe
                noteServed(frame.data.count, keyframe: frame.isKeyframe)
                sequence &+= 1
                let seq = sequence
                lock.unlock()
                return EncodedFrame(accessUnit: frame.data, isKeyframe: frame.isKeyframe,
                                    presentationTime: ProcessInfo.processInfo.systemUptime, sequence: seq)
            }
        }

        // No picture, or the encoder is momentarily unavailable: the cached keyframe is stale, so it
        // is a last resort and the log says so. It beats stalling the link.
        lock.lock()
        let keyframe = lastKeyframeAU
        lock.unlock()
        if let keyframe {
            if prepared != nil { diagnose("编码不可用，暂用旧关键帧补帧") }
            lock.lock()
            servedCount += 1; repeatedCount += 1
            noteServed(keyframe.count, keyframe: true)
            sequence &+= 1
            let seq = sequence
            lock.unlock()
            return EncodedFrame(accessUnit: keyframe, isKeyframe: true,
                                presentationTime: ProcessInfo.processInfo.systemUptime, sequence: seq)
        }

        diagnose("无任何可发画面（CarPlay 尚未产出），本次拉帧回空")
        return nil
    }


    /// Caller holds `lock`. Feeds the rolling window used by the live readout and by diagnostics.
    private func noteServed(_ bytes: Int, keyframe: Bool) {
        let now = ProcessInfo.processInfo.systemUptime
        servedWindow.append((now, bytes))
        servedWindow.removeAll { now - $0.at > 3 }
        servedBytes += bytes
        if keyframe { servedKeyframes += 1 }
    }

    private func nextSequence() -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        sequence &+= 1
        return sequence
    }

    func mediaStopped() {
        queue.flush()
    }

    func shutdown() {
        patternTask?.cancel(); patternTask = nil
        lock.lock()
        stopped = true
        let oldDecoder = decoder; decoder = nil
        let oldEncoder = encoder; encoder = nil
        let oldPad = padEncoder; padEncoder = nil
        padEncodedResult = nil; padKeyframeAU = nil; padGeneration = -1
        lock.unlock()
        // Invalidate OUTSIDE the lock. VTCompressionSessionInvalidate waits for the in-flight frame,
        // and the callback that finishes it stores the result under this same lock - so invalidating
        // while holding it deadlocks. shutdown() runs on the receiver's serial queue, so that
        // deadlock wedged every later start: no listener, no CarPlay session, nothing in the log.
        oldDecoder?.invalidate()
        oldEncoder?.invalidate()
        oldPad?.invalidate()
        queue.close()
    }

    // MARK: - CarPlay input

    /// Called by the receiver for every access unit CarPlay produces. Never blocks the caller.
    func append(_ data: Data, codec: VideoCodec, keyframe: Bool) {
        if testPattern { return }
        guard codec == .h264 else {
            // CarPlay negotiated HEVC: EasyConn carries H.264, so nothing can be sent.
            lock.lock(); nonH264 += 1; lock.unlock()
            return
        }
        let isPicture = carriesPicture(data)
        lock.lock()
        inbound += 1
        lastInboundAt = Date()
        if isPicture { noteSourceLocked(bytes: data.count) }
        lock.unlock()
        logCarPlayStreamOnce(data)
        lock.lock()
        let reject = stopped || pending >= bufferDepth
        if reject { skipping = !skipping }
        if !reject { pending += 1 }
        let needIDR = skipping
        lock.unlock()
        if needIDR { requestKeyframeIfUseful() }
        guard !reject else { diagnose("input dropped by backpressure (pending=\(pending))"); return }

        work.async { [weak self] in
            guard let self else { return }
            defer { self.lock.lock(); self.pending -= 1; self.lock.unlock() }
            self.process(data, keyframe: keyframe)
        }
    }

    private func process(_ data: Data, keyframe: Bool) {
        lock.lock(); let alive = !stopped; let canvas = self.canvas; lock.unlock()
        guard alive, let canvas else { return }

        guard let image = decode(data, keyframe: keyframe) else { return }
        lock.lock(); decodedCount += 1; lock.unlock()
        noteSourceSize(CVPixelBufferGetWidth(image), CVPixelBufferGetHeight(image), canvas: canvas)
        guard let prepared = try? fitted(image, width: canvas.width, height: canvas.height) else {
            diagnose("letterbox failed")
            return
        }
        // Only decode and letterbox here. Encoding happens on the pull, because this link is
        // lock-step: the dash asks for one frame and waits. A free-running encoder pushed 20-24
        // frames/s into a 3-deep queue while the dash consumed 15/s, so the queue overflowed
        // several times a second; FrameQueue's overflow policy flushes and closes its keyframe gate,
        // which left the queue empty and gated essentially always (measured: 100% of pulls were
        // padded, not one queued frame ever served).
        lock.lock()
        fittedBuffer = prepared; pictureDirty = true; pictureGeneration += 1
        lastPictureUptime = ProcessInfo.processInfo.systemUptime
        lock.unlock()
    }


    /// Records the size CarPlay actually produced and reports the scale factor once per change.
    /// A 1:1 match is what makes `fitted()` a pass-through; anything else resamples every frame and
    /// softens the dash text, so it has to be visible in the log.
    private func noteSourceSize(_ width: Int, _ height: Int, canvas: VideoCanvas) {
        lock.lock()
        let changed = width != sourceWidth || height != sourceHeight
        sourceWidth = width; sourceHeight = height
        lock.unlock()
        guard changed else { return }
        let scaleX = Double(canvas.width) / Double(max(width, 1))
        let scaleY = Double(canvas.height) / Double(max(height, 1))
        let factor = min(scaleX, scaleY)
        let verdict: String
        if abs(scaleX - 1) < 0.01 && abs(scaleY - 1) < 0.01 {
            verdict = "1:1，不再缩放"
        } else if factor > 1.01 {
            verdict = String(format: "放大 %.2f×（画面会变糊）", factor)
        } else if factor < 0.99 {
            verdict = String(format: "缩小 %.2f×", factor)
        } else {
            verdict = "比例不一致，留黑边"
        }
        log?("CFMOTO CarPlay 画面 \(width)x\(height) → 画布 \(canvas.width)x\(canvas.height) · \(verdict)")
    }

    /// Everything the UI and the periodic diagnostic line need, read under one lock.
    var liveStats: CfMotoLiveStats {
        lock.lock(); defer { lock.unlock() }
        let now = ProcessInfo.processInfo.systemUptime
        let window: TimeInterval = 2.0
        let recent = servedWindow.filter { now - $0.at <= window }
        let fps = Double(recent.count) / window
        // Bits actually put on the wire over the last two seconds, not the session average: the
        // point of showing it is to compare against the configured cap right now.
        let bytesPerSecond = Double(recent.reduce(0) { $0 + $1.bytes }) / window
        let recentSource = sourceWindow.filter { now - $0.at <= window }
        let sourceFPS = Double(recentSource.count) / window
        let sourceMbps = Double(recentSource.reduce(0) { $0 + $1.bytes }) / window * 8 / 1_000_000
        let canvasText = canvas.map { "\($0.width)×\($0.height)" } ?? "—"
        let sourceText = sourceWidth > 0 ? "\(sourceWidth)×\(sourceHeight)" : "—"
        var scaleText = "—"
        if let canvas, sourceWidth > 0, sourceHeight > 0 {
            let sx = Double(canvas.width) / Double(sourceWidth)
            let sy = Double(canvas.height) / Double(sourceHeight)
            if abs(sx - 1) < 0.01 && abs(sy - 1) < 0.01 { scaleText = "1:1" }
            else { scaleText = String(format: "%.2f×", min(sx, sy)) }
        }
        return CfMotoLiveStats(
            carPlaySize: sourceText, canvasSize: canvasText, scaleText: scaleText,
            servedFPS: fps,
            sourceFPS: sourceFPS, sourceMbps: sourceMbps,
            bitrateMbps: bytesPerSecond * 8 / 1_000_000,
            paddedRatio: servedCount > 0 ? Double(repeatedCount) / Double(servedCount) : 0,
            keyframeRatio: servedCount > 0 ? Double(servedKeyframes) / Double(servedCount) : 0,
            averageFrameKB: servedCount > 0 ? Double(servedBytes) / Double(servedCount) / 1024 : 0,
            counters: countersLocked(),
            staticPadNote: lastPadNote,
            padReuses: padReuses,
            hasPicture: servedCount > 0)
    }

    // MARK: - Decode

    private func decode(_ data: Data, keyframe: Bool) -> CVPixelBuffer? {
        var picture: [Data] = []
        var sawParameterSet = false

        do {
            for unit in try AnnexB.units(in: data) {
                if VideoCodec.h264.parameterSet(unit) != nil {
                    sawParameterSet = true
                    if parameters.absorb(unit) {
                        lock.lock(); waitingForIDR = true; decoderWaitingSince = Date(); paramSets += 1
                        parametersReady = parameters.isComplete; lock.unlock()
                    }
                } else {
                    picture.append(unit)
                }
            }
            // A missing decoder must always mean "rebuild needed". The field log showed the two can
            // disagree (decoder nil while the gate was false), and then the rebuild branch is skipped
            // for every frame: 2579 frames were counted as "no decoder" and the dash stayed frozen on
            // the last cached picture with the link healthy.
            lock.lock()
            if decoder == nil, !decoderNeedsKeyframe {
                decoderNeedsKeyframe = true
                if decoderWaitingSince == .distantPast { decoderWaitingSince = Date() }
            }
            let needsRebuild = decoderNeedsKeyframe
            let waitedLong = Date().timeIntervalSince(decoderWaitingSince)
            lock.unlock()

            if needsRebuild {
                guard parameters.isComplete, !picture.isEmpty else {
                    lock.lock(); dropWaitingIDR += 1; lock.unlock()
                    requestKeyframeIfUseful()
                    return nil
                }
                // Normally a rebuild waits for a keyframe. But if none arrives for this long, build
                // anyway and feed what we have: one garbled frame that the next frame repairs beats
                // a dash frozen until the rider restarts the app.
                let forceWithoutKeyframe = !keyframe && waitedLong > 3.0
                guard keyframe || forceWithoutKeyframe else {
                    lock.lock(); dropWaitingIDR += 1; lock.unlock()
                    requestKeyframeIfUseful()
                    return nil
                }
                guard ProcessInfo.processInfo.systemUptime - lastCodecFailure >= 0.5 else {
                    lock.lock(); dropCooldown += 1; lock.unlock()
                    requestKeyframeIfUseful()
                    return nil
                }
                if forceWithoutKeyframe {
                    diagnose("等关键帧 \(Int(waitedLong))s，用非关键帧强行重建解码器")
                }
                // Build outside the lock: a throwing initialiser must not leave it held.
                let freshBox = DecodeBox()
                let rebuilt = try TailingH264Decoder(configuration: parameters.decoderConfigurationRecord(),
                    output: { freshBox.set(image: $0) },
                    failure: { freshBox.set(error: $0) })
                lock.lock()
                let previousDecoder = decoder
                decoder = rebuilt
                decodeBox = freshBox
                decoderNeedsKeyframe = false
                decoderWaitingSince = .distantPast
                // A brand-new decoder starts from an IDR, so the encoder's next frame should be one
                // too: the dash's decoder is being rebuilt from the same stream.
                waitingForIDR = true
                lock.unlock()
                previousDecoder?.invalidate()
            }
            guard let decoder else {
                lock.lock(); dropNoDecoder += 1; lock.unlock()
                requestKeyframeIfUseful()
                diagnose("解码器缺失，已请求关键帧（本帧丢弃）")
                return nil
            }
            guard !picture.isEmpty else {
                lock.lock()
                if sawParameterSet {
                    // CarPlay sends SPS/PPS as their own access unit; skipping them is correct, so
                    // this must not look like a decode failure in the log.
                    parameterSetOnly += 1
                } else {
                    dropNoPicture += 1
                }
                let key = decoderNeedsKeyframe
                lock.unlock()
                // Outside the lock: diagnose() must not run while it is held.
                if !sawParameterSet { diagnose("空访问单元（无图像片，waitingIDR=\(key)）") }
                return nil
            }
            try decoder.decode(AnnexB.lengthPrefixed(picture),
                               presentationTimeMicroseconds: Int64(ProcessInfo.processInfo.systemUptime * 1_000_000),
                               isKeyframe: keyframe)
            decoder.waitForFrames()
            // Read the box after the rebuild above, so it is the one this decoder writes to.
            let box = lock.withLock { decodeBox }
            if let image = box.take() {
                lock.lock(); latestImage = image; lock.unlock()
                return image
            }
            if let failure = box.error { throw failure }
            lock.lock(); dropNoCallback += 1; lock.unlock()
            diagnose("decoder produced no picture (keyframe=\(keyframe) units=\(picture.count))")
            return nil
        } catch {
            lock.lock()
            let broken = decoder
            decoder = nil
            waitingForIDR = true
            lock.unlock()
            broken?.invalidate()
            lastCodecFailure = ProcessInfo.processInfo.systemUptime
            lock.lock(); decodeErrors += 1; lock.unlock()
            diagnose("decode failed: \(error.localizedDescription)")
            requestKeyframeIfUseful()
            return nil
        }
    }

    // MARK: - Encode

    /// - Parameter force: force an IDR even if one is not due. The pull path uses it to pad a pull
    ///   with the *current* picture: only an IDR may be sent more than once (§15.2), and the dash
    ///   must not be shown a picture older than the one it already has.
    private func encode(_ image: CVPixelBuffer, canvas: VideoCanvas, force: Bool = false) -> H264EncodedFrame? {
        // The work queue encodes new pictures while an idle pull may encode the last one.
        encodeLock.lock()
        defer { encodeLock.unlock() }
        let now = ProcessInfo.processInfo.systemUptime

        do {
            lock.lock()
            if encoder == nil {
                guard now - lastCodecFailure >= 0.5 else { lock.unlock(); return nil }
                let settings = encoderSettings
                // The VideoToolbox callback runs on its own thread, so hand the result back through
                // the lock instead of a local variable captured by the escaping closure.
                encoder = try H264Encoder(width: canvas.width, height: canvas.height,
                                          fps: settings.frameRate, bitrate: settings.bitrate,
                                          profileLevel: CfMotoTuning.forceBaseline ? .baseline31 : .mainAuto,
                                          keyframeSeconds: settings.keyframeIntervalSeconds) { [weak self] outcome in
                    guard let self else { return }
                    self.lock.lock(); self.encodedResult = outcome; self.lock.unlock()
                }
                encodedResult = nil
                lock.unlock()
            } else {
                lock.unlock()
            }
            guard let encoder else { return nil }

            // The dash decodes a clean IDR at least once per second (a real dash runs GOP 1 s), and
            // its pull loop can start mid-stream, so force one instead of waiting for a keyframe that
            // may never come from CarPlay.
            let stale = now - lastKeyframe >= max(0.2, encoderSettings.keyframeIntervalSeconds)
            let keyframeWanted = force || allIntraOn || lock.withLock { waitingForIDR } || stale
            try encoder.encode(try fitted(image, width: canvas.width, height: canvas.height),
                               presentationTime: CMTime(seconds: now, preferredTimescale: 1_000_000),
                               forceKeyframe: keyframeWanted)
            encoder.complete()

            // complete() returns when VideoToolbox has finished, but the callback that carries the
            // access unit runs on its own thread and may land a moment later. Reading the box once,
            // immediately, lost every frame after the first: the late result was then consumed by the
            // *next* encode, so each read saw nil. Wait for it, briefly.
            var outcome = lock.withLock { encodedResult }
            if outcome == nil {
                let deadline = ProcessInfo.processInfo.systemUptime + 0.25
                while outcome == nil, ProcessInfo.processInfo.systemUptime < deadline {
                    Thread.sleep(forTimeInterval: 0.002)
                    outcome = lock.withLock { encodedResult }
                }
            }
            lock.lock(); encodedResult = nil; lock.unlock()
            let frame = try outcome?.get()
            if let frame, frame.isKeyframe {
                lastKeyframe = now
                lock.lock(); lastKeyframeAU = frame.data; waitingForIDR = false; lock.unlock()
            }
            return frame
        } catch H264EncoderError.frameDropped {
            return nil
        } catch {
            lock.lock()
            let broken = encoder
            encoder = nil
            waitingForIDR = true
            lock.unlock()
            broken?.invalidate()
            lastCodecFailure = ProcessInfo.processInfo.systemUptime
            diagnose("encode failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Draws a black frame with a short hint telling the rider the phone-side CarPlay has not
    /// produced a picture yet. CarPlay replaces this the moment it delivers its first frame.
    private func hintFrame(width: Int, height: Int) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
                                  attributes, &buffer) == kCVReturnSuccess, let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let bitmap = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard let context = CGContext(data: base, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: bitmap) else { return nil }

        let w = CGFloat(width), h = CGFloat(height)
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: w, height: h))

        // UIKit draws with the origin at the top-left; flip the context so NSString.draw lands
        // right side up in this bottom-left CVPixelBuffer.
        UIGraphicsPushContext(context)
        context.translateBy(x: 0, y: h)
        context.scaleBy(x: 1, y: -1)

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineSpacing = 18
        let attrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.boldSystemFont(ofSize: 52),
            .foregroundColor: UIColor.white,
            .paragraphStyle: paragraph
        ]
        let text = "手机 CarPlay 未启动成功\n请检查 iPhone 上的 CarPlay" as NSString
        text.draw(in: CGRect(x: 40, y: h * 0.34, width: w - 80, height: h * 0.34), withAttributes: attrs)
        UIGraphicsPopContext()

        return buffer
    }

    /// Letterboxes the CarPlay picture into the exact canvas the dash negotiated.
    private func fitted(_ image: CVPixelBuffer, width: Int, height: Int) throws -> CVPixelBuffer {
        if CVPixelBufferGetWidth(image) == width, CVPixelBufferGetHeight(image) == height { return image }
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
                                         [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
        guard status == kCVReturnSuccess, let buffer else {
            throw ConfigurationError("CFMOTO: cannot allocate \(width)x\(height) canvas (\(status))")
        }
        let source = CIImage(cvPixelBuffer: image)
        let scale = min(CGFloat(width) / source.extent.width, CGFloat(height) / source.extent.height)
        let scaled = source.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let placed = scaled.transformed(by: CGAffineTransform(
            translationX: (CGFloat(width) - scaled.extent.width) / 2,
            y: (CGFloat(height) - scaled.extent.height) / 2))
        context.render(placed, to: buffer, bounds: CGRect(x: 0, y: 0, width: width, height: height),
                       colorSpace: CGColorSpaceCreateDeviceRGB())
        return buffer
    }
}
/// Carries one decoder output from VideoToolbox's callback thread back to the caller.
///
/// Reading a captured local right after `waitForFrames()` is not enough: the callback can land a
/// moment later, which silently dropped almost every frame. `take` waits briefly for it.
private final class DecodeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var image: CVPixelBuffer?
    private var failure: Error?

    func set(image: CVPixelBuffer) {
        lock.lock(); if self.image == nil { self.image = image }; lock.unlock()
    }

    func set(error: Error) {
        lock.lock(); if failure == nil { failure = error }; lock.unlock()
    }

    var error: Error? { lock.lock(); defer { lock.unlock() }; return failure }

    func take(timeout: TimeInterval = 0.05) -> CVPixelBuffer? {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while true {
            lock.lock()
            let value = image
            if value != nil { image = nil }   // consume: one picture answers one frame
            lock.unlock()
            if let value { return value }
            if ProcessInfo.processInfo.systemUptime >= deadline { return nil }
            Thread.sleep(forTimeInterval: 0.002)
        }
    }
}

// MARK: - Test pattern

extension CfMotoVideoSource {
    /// Turns the synthetic source on or off while the link is live, not just at start.
    func setTestPattern(_ on: Bool) {
        testPattern = on
        if on {
            startPatternIfNeeded()
        } else {
            patternTask?.cancel(); patternTask = nil
            log?("CFMOTO 测试图案已停止")
        }
    }

    /// Starts the synthetic source once a canvas is known. Idempotent.
    fileprivate func startPatternIfNeeded() {
        guard testPattern, patternTask == nil else { return }
        if lock.withLock({ canvas == nil }) {
            // The canvas only exists after the dash asks for it (REQ 16); say so instead of
            // looking broken when nothing happens yet.
            log?("CFMOTO 测试图案已开启，等车机请求画布后开始发送")
        } else {
            log?("CFMOTO 测试图案开始发送")
        }
        patternTask = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                guard let self else { return }
                self.emitPattern(tick)
                tick &+= 1
                try? await Task.sleep(nanoseconds: 66_000_000)   // ~15 fps
            }
        }
    }

    /// Draws colour bars with a moving marker and pushes them through the normal encode path.
    fileprivate func emitPattern(_ tick: Int) {
        lock.lock()
        let canvas = self.canvas
        let alive = !stopped
        lock.unlock()
        guard alive, let canvas else { return }

        guard let buffer = drawPattern(width: canvas.width, height: canvas.height, tick: tick) else { return }
        // Same shape as a real picture: hand it to the pull path instead of encoding here, so the
        // test pattern travels the exact code the dash sees in normal use.
        lock.lock()
        decodedCount += 1
        fittedBuffer = buffer
        pictureDirty = true
        pictureGeneration += 1
        lastPictureUptime = ProcessInfo.processInfo.systemUptime
        lock.unlock()
    }

    fileprivate func drawPattern(width: Int, height: Int, tick: Int) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
                                  attributes, &buffer) == kCVReturnSuccess, let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let bitmap = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard let context = CGContext(data: base, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: bitmap) else { return nil }

        let w = CGFloat(width), h = CGFloat(height)
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: w, height: h))

        // SMPTE-ish bars: a swapped colour channel is immediately visible on the dash.
        let bars: [(CGFloat, CGFloat, CGFloat)] = [
            (0.75, 0.75, 0.75), (0.75, 0.75, 0), (0, 0.75, 0.75), (0, 0.75, 0),
            (0.75, 0, 0.75), (0.75, 0, 0), (0, 0, 0.75), (0.1, 0.1, 0.1)
        ]
        let barW = w / CGFloat(bars.count)
        let barH = h * 0.72
        for (index, colour) in bars.enumerated() {
            context.setFillColor(CGColor(red: colour.0, green: colour.1, blue: colour.2, alpha: 1))
            context.fill(CGRect(x: CGFloat(index) * barW, y: h - barH, width: barW + 1, height: barH))
        }

        // Corner markers: red top-left, green top-right. Rotated or flipped output shows up here.
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: h - 40, width: 40, height: 40))
        context.setFillColor(CGColor(red: 0, green: 1, blue: 0, alpha: 1))
        context.fill(CGRect(x: w - 40, y: h - 40, width: 40, height: 40))

        // Moving bar: proves frames are arriving, and at what rate.
        let travel = w - 60
        let x = CGFloat(tick % 90) / 90 * travel
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: x, y: h * 0.80, width: 60, height: 16))

        // Progress bar on the bottom edge fills once per 90 ticks (~6 s), a coarse clock.
        context.setFillColor(CGColor(red: 0.2, green: 0.8, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: w * CGFloat(tick % 90) / 90, height: 10))

        return buffer
    }
}




