import Foundation

/// Reassembles chunked video frames (PROTOCOL.md §6). Each datagram has a 12-byte
/// little-endian header (frameId, chunkIndex, chunkCount, flags) followed by an
/// encoded slice. A frame is dropped if a newer frameId arrives before it's
/// complete. Returns the full Annex-B access unit once every chunk is in.
final class FrameReassembler {
    private var frameId: UInt32 = .max
    private var chunks: [Data?] = []
    private var received = 0
    private var expected = 0
    private var keyframe = false

    func onChunk(_ data: Data) -> (frame: Data, keyframe: Bool)? {
        guard data.count >= 12 else { return nil }
        let b = [UInt8](data.prefix(12))
        let fid = UInt32(b[0]) | (UInt32(b[1]) << 8) | (UInt32(b[2]) << 16) | (UInt32(b[3]) << 24)
        let idx = Int(UInt16(b[4]) | (UInt16(b[5]) << 8))
        let count = Int(UInt16(b[6]) | (UInt16(b[7]) << 8))
        let key = (b[8] & 0x01) != 0
        let payload = data.subdata(in: 12..<data.count)

        if fid != frameId {
            frameId = fid
            chunks = Array(repeating: nil, count: count)
            received = 0
            expected = count
            keyframe = key
        }
        guard count > 0, idx < chunks.count, chunks[idx] == nil else { return nil }
        chunks[idx] = payload
        received += 1

        guard received == expected else { return nil }
        var out = Data()
        for c in chunks { if let c { out.append(c) } }
        received = 0; expected = 0
        return (out, keyframe)
    }

    func reset() {
        frameId = .max; received = 0; expected = 0; chunks = []
    }
}
