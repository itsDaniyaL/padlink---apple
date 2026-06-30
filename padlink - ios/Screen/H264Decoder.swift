import Foundation
import AVFoundation
import VideoToolbox
import CoreMedia

/// Decodes the Annex-B H.264 stream produced by the macOS encoder and enqueues
/// decoded frames onto an `AVSampleBufferDisplayLayer`. SPS/PPS (sent inline on
/// keyframes) build the format description; VCL slices become CMSampleBuffers
/// flagged for immediate display.
final class H264Decoder {
    private weak var displayLayer: AVSampleBufferDisplayLayer?
    private var formatDesc: CMVideoFormatDescription?
    private var sps: [UInt8]?
    private var pps: [UInt8]?

    init(displayLayer: AVSampleBufferDisplayLayer) {
        self.displayLayer = displayLayer
    }

    /// Feed one reassembled Annex-B access unit.
    func decode(_ annexB: Data) {
        var vcl: [[UInt8]] = []
        for nal in Self.splitNALUnits(annexB) {
            guard let header = nal.first else { continue }
            switch header & 0x1F {
            case 7: sps = nal; rebuildFormat()
            case 8: pps = nal; rebuildFormat()
            case 1, 5: vcl.append(nal)   // non-IDR / IDR slice
            default: break
            }
        }
        guard let fmt = formatDesc else { return }
        for nal in vcl { enqueue(nal, fmt: fmt) }
    }

    private func rebuildFormat() {
        guard let sps, let pps else { return }
        sps.withUnsafeBufferPointer { spsBuf in
            pps.withUnsafeBufferPointer { ppsBuf in
                guard let spsBase = spsBuf.baseAddress, let ppsBase = ppsBuf.baseAddress else { return }
                let pointers = [spsBase, ppsBase]
                let sizes = [sps.count, pps.count]
                pointers.withUnsafeBufferPointer { pp in
                    sizes.withUnsafeBufferPointer { ss in
                        var fmt: CMFormatDescription?
                        let status = CMVideoFormatDescriptionCreateFromH264ParameterSets(
                            allocator: kCFAllocatorDefault,
                            parameterSetCount: 2,
                            parameterSetPointers: pp.baseAddress!,
                            parameterSetSizes: ss.baseAddress!,
                            nalUnitHeaderLength: 4,
                            formatDescriptionOut: &fmt)
                        if status == noErr { formatDesc = fmt }
                    }
                }
            }
        }
    }

    private func enqueue(_ nal: [UInt8], fmt: CMVideoFormatDescription) {
        // Annex-B → AVCC: replace the (implicit) start code with a 4-byte length.
        var avcc = Data(capacity: nal.count + 4)
        var len = UInt32(nal.count).bigEndian
        withUnsafeBytes(of: &len) { avcc.append(contentsOf: $0) }
        avcc.append(contentsOf: nal)

        let dataPtr = UnsafeMutableRawPointer.allocate(byteCount: avcc.count, alignment: 1)
        avcc.copyBytes(to: dataPtr.assumingMemoryBound(to: UInt8.self), count: avcc.count)

        var blockBuffer: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: dataPtr,
            blockLength: avcc.count,
            blockAllocator: kCFAllocatorDefault,   // frees dataPtr when released
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: avcc.count,
            flags: 0,
            blockBufferOut: &blockBuffer)
        guard status == kCMBlockBufferNoErr, let blockBuffer else { dataPtr.deallocate(); return }

        var sampleSize = avcc.count
        var sampleBuffer: CMSampleBuffer?
        status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: fmt,
            sampleCount: 1,
            sampleTimingEntryCount: 0,
            sampleTimingArray: nil,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer)
        guard status == noErr, let sampleBuffer else { return }

        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(
                dict,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }

        DispatchQueue.main.async { [weak self] in
            guard let layer = self?.displayLayer else { return }
            if layer.status == .failed { layer.flush() }
            layer.enqueue(sampleBuffer)
        }
    }

    /// Split an Annex-B buffer into NAL units (strips 3- or 4-byte start codes).
    static func splitNALUnits(_ data: Data) -> [[UInt8]] {
        let bytes = [UInt8](data)
        let n = bytes.count
        var nals: [[UInt8]] = []
        var i = 0
        var start = -1

        func startCodeLen(at p: Int) -> Int? {
            if p + 3 <= n, bytes[p] == 0, bytes[p + 1] == 0, bytes[p + 2] == 1 { return 3 }
            if p + 4 <= n, bytes[p] == 0, bytes[p + 1] == 0, bytes[p + 2] == 0, bytes[p + 3] == 1 { return 4 }
            return nil
        }

        while i < n {
            if let sc = startCodeLen(at: i) {
                if start >= 0, start < i { nals.append(Array(bytes[start..<i])) }
                i += sc
                start = i
            } else {
                i += 1
            }
        }
        if start >= 0, start < n { nals.append(Array(bytes[start..<n])) }
        return nals
    }
}
