import Foundation

/// 32-byte UDP input packet encoder (PROTOCOL.md §5). Byte-for-byte identical to
/// the macOS and Android implementations. iOS is a *sender*, so it encodes.
enum PadLinkProtocol {
    static let version: UInt8 = 1
    static let magic: UInt8 = 0x50
    static let inputPacketSize = 32
    static let serviceType = "_padlink._udp"   // Network.framework form (no trailing dot)
    static let heartbeatIntervalMs = 1000
    static let keepAliveMs = 50
    static let connectionTimeoutMs = 3000
}

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
}

/// Mutable controller state the UI updates; serialized to the wire format.
final class InputState {
    var sessionId: UInt16 = 0
    var seq: UInt32 = 0
    var buttons: PadButtons = []
    var dpad: UInt8 = 0
    var leftX: Int16 = 0
    var leftY: Int16 = 0
    var rightX: Int16 = 0
    var rightY: Int16 = 0
    var leftTrigger: UInt16 = 0
    var rightTrigger: UInt16 = 0
    var token: [UInt8] = Array(repeating: 0, count: 8)

    func setButton(_ b: PadButtons, _ pressed: Bool) {
        if pressed { buttons.insert(b) } else { buttons.remove(b) }
    }

    func encode() -> Data {
        var d = Data(count: PadLinkProtocol.inputPacketSize)
        d.withUnsafeMutableBytes { raw in
            let p = raw.bindMemory(to: UInt8.self)
            p[0] = PadLinkProtocol.magic
            p[1] = PadLinkProtocol.version
            func putU16(_ v: UInt16, _ o: Int) { p[o] = UInt8(v & 0xFF); p[o+1] = UInt8(v >> 8) }
            func putI16(_ v: Int16, _ o: Int) { putU16(UInt16(bitPattern: v), o) }
            func putU32(_ v: UInt32, _ o: Int) {
                p[o] = UInt8(v & 0xFF); p[o+1] = UInt8((v >> 8) & 0xFF)
                p[o+2] = UInt8((v >> 16) & 0xFF); p[o+3] = UInt8((v >> 24) & 0xFF)
            }
            putU16(sessionId, 2)
            putU32(seq, 4)
            putU16(buttons.rawValue, 8)
            p[10] = dpad
            p[11] = 0
            putI16(leftX, 12); putI16(leftY, 14)
            putI16(rightX, 16); putI16(rightY, 18)
            putU16(leftTrigger, 20); putU16(rightTrigger, 22)
            for i in 0..<8 { p[24 + i] = token[i] }
        }
        return d
    }
}
