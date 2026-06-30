import Foundation

/// Newline-delimited JSON control messages (PROTOCOL.md §4). Shared shape with
/// the macOS receiver's ControlMessage.
enum ControlType: String, Codable {
    case hello = "HELLO", helloAck = "HELLO_ACK"
    case pair = "PAIR", pairOk = "PAIR_OK", pairFail = "PAIR_FAIL"
    case screenStart = "SCREEN_START", screenStop = "SCREEN_STOP", screenReady = "SCREEN_READY"
    case layout = "LAYOUT"
    case heartbeat = "HEARTBEAT", bye = "BYE"
}

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
    static func encodeLine(_ m: ControlMessage) -> Data {
        var d = (try? JSONEncoder().encode(m)) ?? Data()
        d.append(0x0A)
        return d
    }
    static func decodeLine(_ d: Data) -> ControlMessage? {
        try? JSONDecoder().decode(ControlMessage.self, from: d)
    }
}
