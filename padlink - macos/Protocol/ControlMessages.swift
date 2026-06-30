import Foundation

/// Newline-delimited JSON control messages (PROTOCOL.md §4).
/// Encoded/decoded with Codable; `type` discriminates.

enum ControlType: String, Codable {
    case hello = "HELLO"
    case helloAck = "HELLO_ACK"
    case pair = "PAIR"
    case pairOk = "PAIR_OK"
    case pairFail = "PAIR_FAIL"
    case screenStart = "SCREEN_START"
    case screenStop = "SCREEN_STOP"
    case screenReady = "SCREEN_READY"
    case layout = "LAYOUT"
    case heartbeat = "HEARTBEAT"
    case bye = "BYE"
}

/// A permissive envelope. We decode `type` first, then re-decode the specific
/// payload. Fields are optional so one struct covers every message.
struct ControlMessage: Codable {
    var type: ControlType
    var v: Int?
    var device: String?
    var platform: String?
    var wantsScreen: Bool?
    var layout: String?
    var host: String?
    var requiresPin: Bool?
    var screenAvailable: Bool?
    var pin: String?
    var sessionId: UInt16?
    var token: String?
    var inputPort: Int?
    var inputTcpPort: Int?
    var reason: String?
    var maxWidth: Int?
    var maxFps: Int?
    var codec: String?
    var videoPort: Int?
    var width: Int?
    var height: Int?
    var t: Int64?

    init(type: ControlType) { self.type = type }
}

enum ControlCodec {
    static let encoder = JSONEncoder()
    static let decoder = JSONDecoder()

    /// Encode a message to a single newline-terminated line.
    static func encodeLine(_ msg: ControlMessage) -> Data {
        var data = (try? encoder.encode(msg)) ?? Data()
        data.append(0x0A) // '\n'
        return data
    }

    static func decodeLine(_ line: Data) -> ControlMessage? {
        try? decoder.decode(ControlMessage.self, from: line)
    }
}
