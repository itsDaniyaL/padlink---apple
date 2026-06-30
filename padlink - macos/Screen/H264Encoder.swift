import Foundation
import VideoToolbox
import CoreMedia
import os

/// Hardware H.264 encoder using VideoToolbox. Emits Annex-B NAL units (with SPS/PPS
/// prepended on keyframes) via the `onEncoded` callback.
final class H264Encoder {

    private let log = Logger(subsystem: "com.stackfinity.padlink.macos", category: "H264Encoder")
    private var session: VTCompressionSession?
    private let onEncoded: (Data, Bool) -> Void
    private let width: Int
    private let height: Int

    init(width: Int, height: Int, fps: Int, onEncoded: @escaping (Data, Bool) -> Void) {
        self.width = width
        self.height = height
        self.onEncoded = onEncoded
        setup(fps: fps)
    }

    private func setup(fps: Int) {
        var session: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(width), height: Int32(height),
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: nil, refcon: nil,
            compressionSessionOut: &session)
        guard status == noErr, let session else {
            log.error("VTCompressionSessionCreate failed: \(status)")
            return
        }
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_Baseline_AutoLevel)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: NSNumber(value: fps * 2))
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: NSNumber(value: fps))
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: NSNumber(value: 6_000_000))
        VTCompressionSessionPrepareToEncodeFrames(session)
        self.session = session
    }

    func encode(_ pixelBuffer: CVPixelBuffer, pts: CMTime) {
        guard let session else { return }
        VTCompressionSessionEncodeFrame(
            session, imageBuffer: pixelBuffer, presentationTimeStamp: pts,
            duration: .invalid, frameProperties: nil, infoFlagsOut: nil
        ) { [weak self] status, _, sampleBuffer in
            guard status == noErr, let sampleBuffer, let self else { return }
            self.handleEncoded(sampleBuffer)
        }
    }

    /// Convert AVCC-formatted sample buffer to Annex-B NAL units.
    private func handleEncoded(_ sampleBuffer: CMSampleBuffer) {
        let isKeyframe = !(CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
            .flatMap { ($0 as? [[CFString: Any]])?.first }
            .map { ($0[kCMSampleAttachmentKey_NotSync] as? Bool) ?? false } ?? false)

        var out = Data()
        let startCode: [UInt8] = [0, 0, 0, 1]

        // On keyframes, prepend SPS/PPS from the format description.
        if isKeyframe, let fmt = CMSampleBufferGetFormatDescription(sampleBuffer) {
            var count = 0
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fmt, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil, parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil)
            for i in 0..<count {
                var ptr: UnsafePointer<UInt8>?
                var size = 0
                if CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fmt, parameterSetIndex: i, parameterSetPointerOut: &ptr, parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil) == noErr, let ptr {
                    out.append(contentsOf: startCode)
                    out.append(ptr, count: size)
                }
            }
        }

        guard let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        var lengthAtOffset = 0, totalLength = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: &lengthAtOffset, totalLengthOut: &totalLength, dataPointerOut: &dataPointer) == noErr, let dataPointer else { return }

        // AVCC: 4-byte big-endian length prefixes. Replace each with a start code.
        var offset = 0
        while offset < totalLength - 4 {
            var nalLength: UInt32 = 0
            memcpy(&nalLength, dataPointer + offset, 4)
            nalLength = CFSwapInt32BigToHost(nalLength)
            out.append(contentsOf: startCode)
            let nalStart = offset + 4
            out.append(Data(bytes: dataPointer + nalStart, count: Int(nalLength)))
            offset = nalStart + Int(nalLength)
        }

        onEncoded(out, isKeyframe)
    }

    deinit {
        if let session { VTCompressionSessionInvalidate(session) }
    }
}
