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

    var counters: String {
        lock.lock(); defer { lock.unlock() }
        return "CarPlay \(inbound) · 解码 \(decodedCount) · 编码 \(encodedCount) · 拉帧 \(pulls) · 送出 \(servedCount)"
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
        guard codec == .h264 else { return }
        lock.lock(); inbound += 1; lock.unlock()
        lock.lock()
        let reject = stopped || pending >= 6
        if reject { skipping = !skipping }
        if !reject { pending += 1 }
        let needIDR = skipping
        lock.unlock()
        if needIDR { onKeyframeRequest?() }
        guard !reject else { return }

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
        guard let frame = encode(image, canvas: canvas) else { return }
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
        var decoded: CVPixelBuffer?
        var failure: Error?

        do {
            for unit in try AnnexB.units(in: data) {
                if VideoCodec.h264.parameterSet(unit) != nil {
                    if parameters.absorb(unit) { lock.lock(); waitingForIDR = true; lock.unlock() }
                } else {
                    picture.append(unit)
                }
            }
            let needsRebuild = lock.withLock { waitingForIDR }
            if needsRebuild {
                guard parameters.isComplete, keyframe, !picture.isEmpty else { return nil }
                guard ProcessInfo.processInfo.systemUptime - lastCodecFailure >= 0.5 else {
                    onKeyframeRequest?()
                    return nil
                }
                lock.lock()
                decoder?.invalidate()
                decoder = try TailingH264Decoder(configuration: parameters.decoderConfigurationRecord(),
                    output: { image in decoded = image },
                    failure: { failure = $0 })
                waitingForIDR = false
                lock.unlock()
            }
            guard let decoder, !picture.isEmpty else { return nil }
            try decoder.decode(AnnexB.lengthPrefixed(picture),
                               presentationTimeMicroseconds: Int64(ProcessInfo.processInfo.systemUptime * 1_000_000),
                               isKeyframe: keyframe)
            decoder.waitForFrames()
            if let failure { throw failure }
            return decoded
        } catch {
            lock.lock()
            decoder?.invalidate()
            decoder = nil
            waitingForIDR = true
            lock.unlock()
            lastCodecFailure = ProcessInfo.processInfo.systemUptime
            log?("CFMOTO decode failed: \(error.localizedDescription)")
            onKeyframeRequest?()
            return nil
        }
    }

    // MARK: - Encode

    private func encode(_ image: CVPixelBuffer, canvas: VideoCanvas) -> H264EncodedFrame? {
        let now = ProcessInfo.processInfo.systemUptime
        var result: Result<H264EncodedFrame, Error>?

        do {
            lock.lock()
            if encoder == nil {
                guard now - lastCodecFailure >= 0.5 else { lock.unlock(); return nil }
                let settings = encoderSettings
                encoder = try H264Encoder(width: canvas.width, height: canvas.height,
                                          fps: settings.frameRate, bitrate: settings.bitrate) { outcome in
                    result = outcome
                }
                lock.unlock()
            } else {
                lock.unlock()
            }
            guard let encoder else { return nil }
            let force = lock.withLock { waitingForIDR }
            try encoder.encode(try fitted(image, width: canvas.width, height: canvas.height),
                               presentationTime: CMTime(seconds: now, preferredTimescale: 1_000_000),
                               forceKeyframe: force)
            encoder.complete()
            if force { lock.lock(); waitingForIDR = false; lock.unlock() }
            return try result?.get()
        } catch H264EncoderError.frameDropped {
            return nil
        } catch {
            lock.lock()
            encoder?.invalidate()
            encoder = nil
            waitingForIDR = true
            lock.unlock()
            lastCodecFailure = ProcessInfo.processInfo.systemUptime
            log?("CFMOTO encode failed: \(error.localizedDescription)")
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
