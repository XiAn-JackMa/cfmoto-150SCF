// SPDX-License-Identifier: AGPL-3.0-only
//
// 春风 EasyConn 专用 H.264 编码器：1.0.83 的 App/NinebotH264Encoder.swift 原样搬入，
// 只把类型名加上 EasyConn 前缀，避免与 1.0.6 的 H264Encoder（其它输出在用）冲突。
// 行为与 1.0.83 完全一致：ProfileLevel 三档、quality、keyframeSeconds、NSLock 序列化、
// 硬件失败回退软件编码。

// Adapted from xmz28/ninebot_pro.
import AVFoundation
import Foundation
import VideoToolbox

struct EasyConnEncodedFrame {
    let data: Data
    let isKeyframe: Bool
    let presentationTime: CMTime
}

private final class EasyConnCallbackBox {
    /// `invalidate()` nils the handler from one thread while VideoToolbox may be calling it from
    /// another; the lock keeps that swap safe, and `deliver` copies the closure before calling it
    /// so the call itself never runs with the box lock held.
    private let lock = NSLock()
    private var stored: ((Result<EasyConnEncodedFrame, Error>) -> Void)?

    var handler: ((Result<EasyConnEncodedFrame, Error>) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }

    func deliver(_ result: Result<EasyConnEncodedFrame, Error>) {
        let handler = self.handler
        handler?(result)
    }
}

private let h264CompressionCallback: VTCompressionOutputCallback = { reference, _, status, infoFlags, sampleBuffer in
    guard let reference else { return }
    let box = Unmanaged<EasyConnCallbackBox>.fromOpaque(reference).takeUnretainedValue()
    guard status == noErr else {
        box.deliver(.failure(EasyConnH264EncoderError.compression(status)))
        return
    }
    // RealTime + 码率上限下，VideoToolbox 会主动丢帧并回调空 sampleBuffer，这是正常行为
    if infoFlags.contains(.frameDropped) || sampleBuffer == nil {
        box.deliver(.failure(EasyConnH264EncoderError.frameDropped))
        return
    }
    guard let sampleBuffer, CMSampleBufferDataIsReady(sampleBuffer) else {
        box.deliver(.failure(EasyConnH264EncoderError.missingSampleBuffer))
        return
    }

    do {
        // NotSync 位于"样本附件数组"中，不是 CMSampleBuffer 级附件；
        // 用 CMGetAttachment 读永远是 nil，会把每个 P 帧都当成关键帧发给仪表
        var notSync = false
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
            as? [[CFString: Any]],
           let first = attachments.first {
            notSync = (first[kCMSampleAttachmentKey_NotSync] as? Bool) ?? false
        }
        let isKeyframe = !notSync

        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
            throw EasyConnH264EncoderError.missingBlockBuffer
        }
        let length = CMBlockBufferGetDataLength(blockBuffer)
        var avcc = Data(count: length)
        let copyStatus = avcc.withUnsafeMutableBytes { bytes in
            guard let destination = bytes.baseAddress else { return kCMBlockBufferBadCustomBlockSourceErr }
            return CMBlockBufferCopyDataBytes(
                blockBuffer,
                atOffset: 0,
                dataLength: length,
                destination: destination
            )
        }
        guard copyStatus == kCMBlockBufferNoErr else { throw EasyConnH264EncoderError.blockCopy(copyStatus) }
        var annexB = try H264AnnexB.convertFromAVCC(avcc)

        if isKeyframe, let format = CMSampleBufferGetFormatDescription(sampleBuffer) {
            var parameterSets = Data()
            var parameterSetCount = 0
            var nalHeaderLength: Int32 = 0
            for index in 0..<2 {
                var pointer: UnsafePointer<UInt8>?
                var size = 0
                let parameterStatus = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                    format,
                    parameterSetIndex: index,
                    parameterSetPointerOut: &pointer,
                    parameterSetSizeOut: &size,
                    parameterSetCountOut: &parameterSetCount,
                    nalUnitHeaderLengthOut: &nalHeaderLength
                )
                if parameterStatus == noErr, let pointer, size > 0 {
                    parameterSets.append(contentsOf: [0, 0, 0, 1])
                    parameterSets.append(pointer, count: size)
                }
            }
            if !H264AnnexB.containsNAL(type: 7, in: annexB) || !H264AnnexB.containsNAL(type: 8, in: annexB) {
                annexB = parameterSets + annexB
            }
        }

        guard !isKeyframe || (
            H264AnnexB.containsNAL(type: 7, in: annexB) &&
            H264AnnexB.containsNAL(type: 8, in: annexB)
        ) else {
            throw EasyConnH264EncoderError.missingParameterSets
        }
        box.deliver(.success(EasyConnEncodedFrame(
            data: annexB,
            isKeyframe: isKeyframe,
            presentationTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        )))
    } catch {
        box.deliver(.failure(error))
    }
}

final class EasyConnH264Encoder {
    private var session: VTCompressionSession?
    private let callbackBox = EasyConnCallbackBox()
    /// Serialises encode / complete / invalidate. VTCompressionSessionInvalidate waits for the
    /// frames still in flight, so calling it while another thread is inside CompleteFrames hangs:
    /// that wedged the receiver queue and left the app stuck on "starting CarPlay".
    private let lock = NSLock()
    private let fps: Int
    private let profileLevel: ProfileLevel
    /// Optional compression-quality bias (0 = smallest, 1 = best). Used by the static-picture pad
    /// encoder: AverageBitRate alone does not cap a lone keyframe after an idle period, but Quality
    /// biases quantisation directly, so one frame comes out small without rate-control history.
    private let quality: Double?
    /// Seconds between forced IDRs, passed straight to VideoToolbox.
    ///
    /// It used to be hard-wired to one second here while the settings page claimed to control it,
    /// so raising the interval changed nothing: VideoToolbox still emitted an IDR every second and
    /// the keyframe share never moved.
    private let keyframeSeconds: Double
    /// True when the session fell back to the software encoder (App in the background).
    private(set) var usingSoftware = false

    /// Which H.264 profile/level to declare.
    ///
    /// `auto` keeps Baseline with an automatic level (the safe default for Ninebot/Zeeho).
    /// `mainAuto` switches to Main profile for better compression, for dashes that decode Main.
    /// `baseline31` pins Baseline 3.1, which the official CFMOTO app and the Android reference
    /// client emit; some dash decoders validate the level, so callers can pin it.
    enum ProfileLevel {
        case auto
        case mainAuto
        case baseline31
    }

    init(width: Int, height: Int, fps: Int, bitrate: Int, profileLevel: ProfileLevel = .auto,
         quality: Double? = nil, keyframeSeconds: Double = 1.0,
         output: @escaping (Result<EasyConnEncodedFrame, Error>) -> Void) throws {
        self.fps = fps
        self.profileLevel = profileLevel
        self.quality = quality
        self.keyframeSeconds = keyframeSeconds
        callbackBox.handler = output

        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            kCVPixelBufferMetalCompatibilityKey: true
        ]
        func create(_ specification: CFDictionary?) -> (OSStatus, VTCompressionSession?) {
            var created: VTCompressionSession?
            let status = VTCompressionSessionCreate(
                allocator: kCFAllocatorDefault,
                width: Int32(width),
                height: Int32(height),
                codecType: kCMVideoCodecType_H264,
                encoderSpecification: specification,
                imageBufferAttributes: attributes as CFDictionary,
                compressedDataAllocator: nil,
                outputCallback: h264CompressionCallback,
                refcon: Unmanaged.passUnretained(callbackBox).toOpaque(),
                compressionSessionOut: &created
            )
            return (status, created)
        }
        // 不使用 kVTVideoEncoderSpecification_EnableLowLatencyRateControl：实测它把 SPS 改成
        // max_num_ref_frames=5 并带 VUI，与官方 iOS 码流（refs=1、无 VUI）不同，且手机端编码耗时没有下降
        //
        // 先要硬件编码器，再退到软件：iOS 在 App 进入后台后会作废硬件编码器，锁屏骑行时必须有人接上。
        var (status, created) = create(nil)
        if status != noErr || created == nil {
            // The kVTVideoEncoderSpecification_* constant for this key is iOS 17.4+, and this app
            // targets 16.0, so name the key the way the constant does.
            let software = ["EnableHardwareAcceleratedVideoEncoder": false] as CFDictionary
            (status, created) = create(software)
            usingSoftware = true
        }
        guard status == noErr, let created else { throw EasyConnH264EncoderError.create(status) }
        session = created
        do {
            try configure(created, bitrate: bitrate)
        } catch {
            VTCompressionSessionInvalidate(created)
            session = nil
            // The session can be created and still refuse to start - which is what the hardware
            // encoder does once the app has been in the background. Falling back only on
            // creation failure left the dash with no picture at all, so try software here too.
            let software = ["EnableHardwareAcceleratedVideoEncoder": false] as CFDictionary
            let (retryStatus, retried) = create(software)
            if retryStatus == noErr, let retried {
                do {
                    try configure(retried, bitrate: bitrate)
                    session = retried
                    usingSoftware = true
                    return
                } catch {
                    VTCompressionSessionInvalidate(retried)
                    session = nil
                }
            }
            throw error
        }
    }

    private func configure(_ created: VTCompressionSession, bitrate: Int) throws {
        do {
            try set(kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
            try set(kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
            let level: CFString
            switch profileLevel {
            case .baseline31: level = kVTProfileLevel_H264_Baseline_3_1
            case .mainAuto:   level = kVTProfileLevel_H264_Main_AutoLevel
            case .auto:       level = kVTProfileLevel_H264_Baseline_AutoLevel
            }
            try set(kVTCompressionPropertyKey_ProfileLevel, value: level)
            // Best effort: not every encoder honours Quality, and a rejected property must not
            // cost us the session.
            if let quality { try? set(kVTCompressionPropertyKey_Quality, value: quality as CFNumber) }
            try set(kVTCompressionPropertyKey_AverageBitRate, value: bitrate as CFNumber)
            try set(kVTCompressionPropertyKey_ExpectedFrameRate, value: fps as CFNumber)
            // Honour the configured interval: both the frame count and the duration, so a 3 s
            // setting really is 3 s instead of whatever fps implied.
            let intervalFrames = max(1, Int((keyframeSeconds * Double(fps)).rounded()))
            try set(kVTCompressionPropertyKey_MaxKeyFrameInterval, value: intervalFrames as CFNumber)
            try set(kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, value: keyframeSeconds as CFNumber)
            // When the hard limit equals the average bitrate, one keyframe per second eats the
            // budget and the frames right after it get dropped, seen as a stutter every second;
            // 1.5x leaves room for the keyframe peak.
            let byteLimit = max(1, bitrate * 3 / 2 / 8)
            try set(kVTCompressionPropertyKey_DataRateLimits, value: [byteLimit, 1] as CFArray)
            // 低延迟：不缓存帧，尽量优先编码速度。部分设备不支持，失败时忽略。
            try? set(kVTCompressionPropertyKey_MaxFrameDelayCount, value: 0 as CFNumber)
            try? set(kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality, value: kCFBooleanTrue)
            let prepareStatus = VTCompressionSessionPrepareToEncodeFrames(created)
            guard prepareStatus == noErr else { throw EasyConnH264EncoderError.prepare(prepareStatus) }
        }
    }

    deinit { invalidate() }

    func encode(_ pixelBuffer: CVPixelBuffer, presentationTime: CMTime, forceKeyframe: Bool) throws {
        lock.lock(); defer { lock.unlock() }
        guard let session else { throw EasyConnH264EncoderError.invalidated }
        var flags = VTEncodeInfoFlags()
        let properties: CFDictionary? = forceKeyframe
            ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary
            : nil
        let status = VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: presentationTime,
            duration: CMTime(value: 1, timescale: CMTimeScale(fps)),
            frameProperties: properties,
            sourceFrameRefcon: nil,
            infoFlagsOut: &flags
        )
        guard status == noErr else { throw EasyConnH264EncoderError.encode(status) }
    }

    func complete() {
        lock.lock(); defer { lock.unlock() }
        guard let session else { return }
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
    }

    func invalidate() {
        // Detach the callback and drop the session UNDER the lock, but drain and invalidate OUTSIDE
        // it. `VTCompressionSessionInvalidate` blocks until the in-flight frame has been delivered,
        // and that delivery wants the frame source's lock — which `encode()` holds while it takes
        // this one. Holding this lock across the invalidate is exactly the ABBA pair that made rapid
        // start/stop wedge the app. With `handler` already nil the in-flight callback is a no-op, so
        // it can no longer reach the source lock at all.
        lock.lock()
        guard let session else { lock.unlock(); return }
        self.session = nil
        callbackBox.handler = nil
        lock.unlock()
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        VTCompressionSessionInvalidate(session)
    }

    private func set(_ key: CFString, value: CFTypeRef) throws {
        lock.lock(); defer { lock.unlock() }
        guard let session else { throw EasyConnH264EncoderError.invalidated }
        let status = VTSessionSetProperty(session, key: key, value: value)
        guard status == noErr else { throw EasyConnH264EncoderError.property(key as String, status) }
    }
}

enum EasyConnH264EncoderError: LocalizedError {
    case create(OSStatus)
    case property(String, OSStatus)
    case prepare(OSStatus)
    case encode(OSStatus)
    case compression(OSStatus)
    case blockCopy(OSStatus)
    case missingSampleBuffer
    case missingBlockBuffer
    case missingParameterSets
    case frameDropped
    case invalidated

    var errorDescription: String? {
        switch self {
        case .frameDropped: "编码器丢弃了一帧"
        case .create(let code): "无法创建 H.264 编码器（\(code)）"
        case .property(let key, let code): "编码器不接受参数 \(key)（\(code)）"
        case .prepare(let code): "H.264 编码器准备失败（\(code)）"
        case .encode(let code): "提交 H.264 帧失败（\(code)）"
        case .compression(let code): "H.264 压缩失败（\(code)）"
        case .blockCopy(let code): "读取 H.264 输出失败（\(code)）"
        case .missingSampleBuffer: "编码器没有返回有效帧"
        case .missingBlockBuffer: "编码器输出缺少数据块"
        case .missingParameterSets: "H.264 关键帧缺少 SPS/PPS"
        case .invalidated: "H.264 编码器已停止"
        }
    }
}

