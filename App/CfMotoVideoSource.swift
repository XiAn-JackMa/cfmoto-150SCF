// SPDX-License-Identifier: AGPL-3.0-only
//
// Feeds the EasyConn link from CarPlay's own H.264.
//
// The dashboard demands a fixed canvas (a CFMOTO 150SC asks for 1024x515, rounded to 1024x512) while
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
    private var encoder: H264Encoder?
    private var canvas: VideoCanvas?
    private var encoderSettings = EncoderParameters()

    private var waitingForIDR = true
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
    private var dropNoCallback = 0
    private var decodeErrors = 0
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

    var counters: String {
        lock.lock(); defer { lock.unlock() }
        let format = nonH264 > 0 ? "H.265×\(nonH264)" : (parametersReady ? "H.264 就绪" : "H.264 等 SPS")
        let drops = "丢弃[等IDR \(dropWaitingIDR)/冷却 \(dropCooldown)/无解码器 \(dropNoDecoder)/无画面 \(dropNoPicture)/无回调 \(dropNoCallback)/异常 \(decodeErrors)]"
        return "CarPlay \(inbound) · \(format) · SPS×\(paramSets) · 解码 \(decodedCount) · 编码 \(encodedCount) · 拉帧 \(pulls) · 送出 \(servedCount) · \(drops)"
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
        }
        lock.unlock()

        log?("CFMOTO canvas \(canvas.width)x\(canvas.height) (dash asked \(canvas.requestedWidth)x\(canvas.requestedHeight)) " +
             "bitrate=\(parameters.bitrate) fps=\(parameters.frameRate)")
        if sizeChanged {
            // A keyframe of the previous canvas must never answer a pull for this one.
            queue.invalidateKeyframe()
            queue.resynchronize()
        }
    }

    func resynchronize() {
        lock.lock()
        waitingForIDR = true
        lock.unlock()
        queue.resynchronize()
    }

    func nextFrame(timeout: TimeInterval) async -> EncodedFrame? {
        lock.lock(); pulls += 1; lock.unlock()
        let frame = await queue.next(timeout: timeout)
        if frame != nil { lock.lock(); servedCount += 1; lock.unlock() }
        return frame
    }

    func mediaStopped() {
        queue.flush()
    }

    func shutdown() {
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
        guard codec == .h264 else {
            // CarPlay negotiated HEVC: EasyConn carries H.264, so nothing can be sent.
            lock.lock(); nonH264 += 1; lock.unlock()
            return
        }
        lock.lock(); inbound += 1; lock.unlock()
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

        guard let image = decode(data, keyframe: keyframe) else {
            let waiting = lock.withLock { waitingForIDR }
            diagnose("decode returned nil (keyframe=\(keyframe) waitingIDR=\(waiting) sps=\(paramSets))")
            return
        }
        lock.lock(); decodedCount += 1; lock.unlock()
        guard let frame = encode(image, canvas: canvas) else {
            diagnose("encode returned nil")
            return
        }
        lock.lock(); encodedCount += 1; lock.unlock()

        lock.lock()
        sequence &+= 1
        let seq = sequence
        lock.unlock()
        queue.push(EncodedFrame(accessUnit: frame.data, isKeyframe: frame.isKeyframe,
                                presentationTime: ProcessInfo.processInfo.systemUptime, sequence: seq))
    }

    // MARK: - Decode

    private func decode(_ data: Data, keyframe: Bool) -> CVPixelBuffer? {
        var picture: [Data] = []
        // The decoder's callbacks land on its own thread, so hand the result back through a box
        // instead of locals captured by escaping closures: reading a local right after
        // waitForFrames() can see nil while the picture arrives a moment later, which dropped
        // every frame after the first.
        let box = DecodeBox()

        do {
            for unit in try AnnexB.units(in: data) {
                if VideoCodec.h264.parameterSet(unit) != nil {
                    if parameters.absorb(unit) {
                        lock.lock(); waitingForIDR = true; paramSets += 1
                        parametersReady = parameters.isComplete; lock.unlock()
                    }
                } else {
                    picture.append(unit)
                }
            }
            let needsRebuild = lock.withLock { waitingForIDR }
            if needsRebuild {
                guard parameters.isComplete, keyframe, !picture.isEmpty else {
                    lock.lock(); dropWaitingIDR += 1; lock.unlock()
                    return nil
                }
                guard ProcessInfo.processInfo.systemUptime - lastCodecFailure >= 0.5 else {
                    lock.lock(); dropCooldown += 1; lock.unlock()
                    onKeyframeRequest?()
                    return nil
                }
                // Build outside the lock: a throwing initialiser must not leave it held.
                let rebuilt = try TailingH264Decoder(configuration: parameters.decoderConfigurationRecord(),
                    output: { box.set(image: $0) },
                    failure: { box.set(error: $0) })
                lock.lock()
                decoder?.invalidate()
                decoder = rebuilt
                waitingForIDR = false
                lock.unlock()
            }
            guard let decoder else {
                lock.lock(); dropNoDecoder += 1; lock.unlock()
                return nil
            }
            guard !picture.isEmpty else {
                lock.lock(); dropNoPicture += 1; lock.unlock()
                return nil
            }
            try decoder.decode(AnnexB.lengthPrefixed(picture),
                               presentationTimeMicroseconds: Int64(ProcessInfo.processInfo.systemUptime * 1_000_000),
                               isKeyframe: keyframe)
            decoder.waitForFrames()
            if let image = box.take() { return image }
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

    private func encode(_ image: CVPixelBuffer, canvas: VideoCanvas) -> H264EncodedFrame? {
        let now = ProcessInfo.processInfo.systemUptime

        do {
            lock.lock()
            if encoder == nil {
                guard now - lastCodecFailure >= 0.5 else { lock.unlock(); return nil }
                let settings = encoderSettings
                // The VideoToolbox callback runs on its own thread, so hand the result back through
                // the lock instead of a local variable captured by the escaping closure.
                encoder = try H264Encoder(width: canvas.width, height: canvas.height,
                                          fps: settings.frameRate, bitrate: settings.bitrate) { [weak self] outcome in
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
            let force = lock.withLock { waitingForIDR } || stale
            try encoder.encode(try fitted(image, width: canvas.width, height: canvas.height),
                               presentationTime: CMTime(seconds: now, preferredTimescale: 1_000_000),
                               forceKeyframe: force)
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
            if frame?.isKeyframe == true {
                lastKeyframe = now
                lock.lock(); waitingForIDR = false; lock.unlock()
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
            lock.lock(); let value = image; lock.unlock()
            if let value { return value }
            if ProcessInfo.processInfo.systemUptime >= deadline { return nil }
            Thread.sleep(forTimeInterval: 0.002)
        }
    }
}