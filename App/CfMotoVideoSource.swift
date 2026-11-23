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
import VideoToolbox

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
    /// Latest decoded picture. CarPlay drops to 1-2 fps on a static screen while the dash pulls at
    /// ~20 fps, so idle pulls are answered by re-encoding this picture instead of returning nothing.
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
    private var lastInboundAt = Date.distantPast

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
    private let idrGiveUpAfter: TimeInterval = 2.0
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
        guard inbound > 0 else { return Date().timeIntervalSince(lastInboundAt) }
        return Date().timeIntervalSince(lastInboundAt)
    }

    var counters: String {
        lock.lock(); defer { lock.unlock() }
        let format = nonH264 > 0 ? "H.265×\(nonH264)" : (parametersReady ? "H.264 就绪" : "H.264 等 SPS")
        let drops = "丢弃[等IDR \(dropWaitingIDR)/冷却 \(dropCooldown)/无解码器 \(dropNoDecoder)/空帧 \(dropNoPicture)/无回调 \(dropNoCallback)/异常 \(decodeErrors)]" +
            " · 参数集 \(parameterSetOnly)"
        return "CarPlay \(inbound) · \(format) · SPS×\(paramSets) · 解码 \(decodedCount) · 编码 \(encodedCount) · 拉帧 \(pulls) · 送出 \(servedCount) · 重发 \(repeatedCount) · \(drops)"
    }

    init(queueCapacity: Int = 3) {
        queue = FrameQueue(capacity: queueCapacity)
        queue.onKeyframeNeeded = { [weak self] in self?.onKeyframeRequest?() }
    }

    // MARK: - VideoFrameSource

    func prepare(canvas: VideoCanvas, parameters: EncoderParameters) {
        lock.lock()
        let previous = self.canvas
        self.canvas = canvas
        self.encoderSettings = parameters
        let sizeChanged = previous == nil || previous!.width != canvas.width || previous!.height != canvas.height
        if sizeChanged {
            encoder?.invalidate()
            encoder = nil
            waitingForIDR = true
            decoderNeedsKeyframe = true
            decoderWaitingSince = Date()
        }
        lock.unlock()

        log?("CFMOTO canvas \(canvas.width)x\(canvas.height) (dash asked \(canvas.requestedWidth)x\(canvas.requestedHeight)) " +
             "bitrate=\(parameters.bitrate) fps=\(parameters.frameRate)")
        if sizeChanged {
            // A keyframe of the previous canvas must never answer a pull for this one: a cached
            // access unit from the old size would decode as garbage on the dash.
            lock.lock(); fittedBuffer = nil; lastKeyframeAU = nil; lock.unlock()
            queue.invalidateKeyframe()
            queue.resynchronize()
        }
        // Seed a black picture so the very first pull has an answer. Without it the dash's first
        // 114 finds nothing, waits out its 9 s timeout and drops the link - twice in a row after a
        // restart, which is what made "start CarPlay" appear to hang on 正在连接 until the simulator
        // was restarted too. CarPlay replaces this the moment it produces a frame.
        if lock.withLock({ fittedBuffer == nil }) {
            if let black = blackFrame(width: canvas.width, height: canvas.height) {
                lock.lock(); fittedBuffer = black; lock.unlock()
            }
        }
        // After the queue reset above, so the pattern's first keyframe is not flushed by it.
        startPatternIfNeeded()
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
        decoder?.invalidate()
        decoder = nil
        decodeBox = DecodeBox()
        waitingForIDR = true
        decoderNeedsKeyframe = true
        decoderWaitingSince = Date()
        lock.unlock()
        queue.invalidateKeyframe()
        queue.resynchronize()
        onKeyframeRequest?()
    }

    func nextFrame(timeout: TimeInterval) async -> EncodedFrame? {
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
        let dirty = lock.withLock { pictureDirty }
        let cacheIsCurrent = lock.withLock { lastServedWasKeyframe }
        let cachedKeyframe = lock.withLock { lastKeyframeAU }
        // Only reuse the cache when the frame already sent *was* a keyframe: then the cache and the
        // current picture agree. If the last frame was a P, the cached IDR is older than the picture
        // in hand, and resending it is how the progress bar walked backwards (52 s, 51 s, 52 s).
        if !dirty, cacheIsCurrent, let keyframe = cachedKeyframe {
            // The picture has not changed since the last encode, so the cached IDR is exactly what
            // the dash should see; re-encoding identical content risks a byte-identical P-frame.
            lock.lock()
            servedCount += 1; repeatedCount += 1
            sequence &+= 1
            let seq = sequence
            lock.unlock()
            if waiting, Date().timeIntervalSince(since) > idrGiveUpAfter { onKeyframeRequest?() }
            return EncodedFrame(accessUnit: keyframe, isKeyframe: true,
                                presentationTime: ProcessInfo.processInfo.systemUptime, sequence: seq)
        }
        if let prepared, let canvas {
            if waiting, Date().timeIntervalSince(since) > idrGiveUpAfter {
                // The decoder cannot use the stream; keep the link alive while CarPlay is asked for
                // a keyframe. Answering nothing would park a lock-step dash until its 9 s timeout.
                diagnose("等关键帧 \(Int(Date().timeIntervalSince(since)))s，先用当前画面维持会话")
                onKeyframeRequest?()
            }
            if let frame = encode(prepared, canvas: canvas, force: !dirty) {
                lock.lock()
                servedCount += 1
                encodedCount += 1
                pictureDirty = false
                lastServedWasKeyframe = frame.isKeyframe
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
            sequence &+= 1
            let seq = sequence
            lock.unlock()
            return EncodedFrame(accessUnit: keyframe, isKeyframe: true,
                                presentationTime: ProcessInfo.processInfo.systemUptime, sequence: seq)
        }

        diagnose("无任何可发画面（CarPlay 尚未产出），本次拉帧回空")
        return nil
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
        decoder?.invalidate(); decoder = nil
        encoder?.invalidate(); encoder = nil
        lock.unlock()
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
        lock.lock(); inbound += 1; lastInboundAt = Date(); lock.unlock()
        lock.lock()
        let reject = stopped || pending >= 6
        if reject { skipping = !skipping }
        if !reject { pending += 1 }
        let needIDR = skipping
        lock.unlock()
        if needIDR { onKeyframeRequest?() }
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
        lock.lock(); fittedBuffer = prepared; pictureDirty = true; lock.unlock()
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
                    onKeyframeRequest?()
                    return nil
                }
                // Normally a rebuild waits for a keyframe. But if none arrives for this long, build
                // anyway and feed what we have: one garbled frame that the next frame repairs beats
                // a dash frozen until the rider restarts the app.
                let forceWithoutKeyframe = !keyframe && waitedLong > 3.0
                guard keyframe || forceWithoutKeyframe else {
                    lock.lock(); dropWaitingIDR += 1; lock.unlock()
                    onKeyframeRequest?()
                    return nil
                }
                guard ProcessInfo.processInfo.systemUptime - lastCodecFailure >= 0.5 else {
                    lock.lock(); dropCooldown += 1; lock.unlock()
                    onKeyframeRequest?()
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
                decoder?.invalidate()
                decoder = rebuilt
                decodeBox = freshBox
                decoderNeedsKeyframe = false
                decoderWaitingSince = .distantPast
                // A brand-new decoder starts from an IDR, so the encoder's next frame should be one
                // too: the dash's decoder is being rebuilt from the same stream.
                waitingForIDR = true
                lock.unlock()
            }
            guard let decoder else {
                lock.lock(); dropNoDecoder += 1; lock.unlock()
                onKeyframeRequest?()
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
            decoder?.invalidate()
            decoder = nil
            waitingForIDR = true
            lock.unlock()
            lastCodecFailure = ProcessInfo.processInfo.systemUptime
            lock.lock(); decodeErrors += 1; lock.unlock()
            diagnose("decode failed: \(error.localizedDescription)")
            onKeyframeRequest?()
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
                                          profileLevel: .baseline31) { [weak self] outcome in
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
            let stale = now - lastKeyframe >= 1.0
            let keyframeWanted = force || lock.withLock { waitingForIDR } || stale
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
            encoder?.invalidate()
            encoder = nil
            waitingForIDR = true
            lock.unlock()
            lastCodecFailure = ProcessInfo.processInfo.systemUptime
            diagnose("encode failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// A black picture at the canvas size, used to answer the first pulls of a session.
    private func blackFrame(width: Int, height: Int) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
                                  attributes, &buffer) == kCVReturnSuccess, let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        if let base = CVPixelBufferGetBaseAddress(buffer) {
            memset(base, 0, CVPixelBufferGetDataSize(buffer))
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
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