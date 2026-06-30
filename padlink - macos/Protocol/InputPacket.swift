import Foundation

/// Implements the 32-byte UDP input packet defined in PROTOCOL.md §5.
/// Byte-for-byte identical to the iOS and Android implementations.
enum PadLinkProtocol {
    static let version: UInt8 = 1
    static let magic: UInt8 = 0x50            // 'P'
    static let inputPacketSize = 32
    static let serviceType = "_padlink._udp"   // Network.framework form (no trailing dot)
    static let heartbeatIntervalMs = 1000
    static let connectionTimeoutMs = 3000
}

/// Button bitmask (PROTOCOL.md §5.1).
struct PadButtons: OptionSet {
    let rawValue: UInt16
    static let a       = PadButtons(rawValue: 1 << 0)
    static let b       = PadButtons(rawValue: 1 << 1)
    static let x       = PadButtons(rawValue: 1 << 2)
    static let y       = PadButtons(rawValue: 1 << 3)
    static let lb      = PadButtons(rawValue: 1 << 4)
    static let rb      = PadButtons(rawValue: 1 << 5)
    static let ls      = PadButtons(rawValue: 1 << 6)
    static let rs      = PadButtons(rawValue: 1 << 7)
    static let start   = PadButtons(rawValue: 1 << 8)
    static let back    = PadButtons(rawValue: 1 << 9)
    static let guide   = PadButtons(rawValue: 1 << 10)
    static let ltDigital = PadButtons(rawValue: 1 << 11)
    static let rtDigital = PadButtons(rawValue: 1 << 12)
}

/// Decoded representation of one input packet.
struct InputState {
    var sessionId: UInt16 = 0
    var seq: UInt32 = 0
    var buttons: PadButtons = []
    var dpad: UInt8 = 0          // 0=none, 1=N..8=NW (8-way)
    var leftX: Int16 = 0
    var leftY: Int16 = 0
    var rightX: Int16 = 0
    var rightY: Int16 = 0
    var leftTrigger: UInt16 = 0  // 0..1023
    var rightTrigger: UInt16 = 0 // 0..1023
    var token: [UInt8] = Array(repeating: 0, count: 8)

    /// Parse a raw datagram. Returns nil if it isn't a valid PadLink packet.
    static func decode(_ data: Data) -> InputState? {
        guard data.count >= PadLinkProtocol.inputPacketSize else { return nil }
        let b = [UInt8](data)
        guard b[0] == PadLinkProtocol.magic, b[1] == PadLinkProtocol.version else { return nil }

        func u16(_ o: Int) -> UInt16 { UInt16(b[o]) | (UInt16(b[o + 1]) << 8) }
        func i16(_ o: Int) -> Int16 { Int16(bitPattern: u16(o)) }
        func u32(_ o: Int) -> UInt32 {
            UInt32(b[o]) | (UInt32(b[o+1]) << 8) | (UInt32(b[o+2]) << 16) | (UInt32(b[o+3]) << 24)
        }

        var s = InputState()
        s.sessionId   = u16(2)
        s.seq         = u32(4)
        s.buttons     = PadButtons(rawValue: u16(8))
        s.dpad        = b[10]
        s.leftX       = i16(12)
        s.leftY       = i16(14)
        s.rightX      = i16(16)
        s.rightY      = i16(18)
        s.leftTrigger = u16(20)
        s.rightTrigger = u16(22)
        s.token       = Array(b[24..<32])
        return s
    }
}
