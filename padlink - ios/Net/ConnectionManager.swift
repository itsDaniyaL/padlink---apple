import Foundation
import Network
import UIKit
import Combine

enum ConnState { case disconnected, connecting, needsPin, paired, error }

/// Manages TCP control (pairing + heartbeats) and the UDP input stream to one
/// receiver. Mirrors the Android ConnectionManager.
@MainActor
final class ConnectionManager: ObservableObject {
    @Published private(set) var state: ConnState = .disconnected
    @Published private(set) var errorMessage: String?
    /// Non-nil while the macOS screen is being streamed to this device.
    @Published private(set) var screen: ScreenReceiver?
    /// Use the reliable TCP input transport (USB / poor Wi-Fi) instead of UDP.
    @Published var useWiredInput = false

    let current = InputState()

    private var control: NWConnection?
    private var udp: NWConnection?
    private var tcpInput: NWConnection?
    private var target: DiscoveredReceiver?
    private var sessionToken: [UInt8] = []
    private var inputPort: UInt16 = 0
    private var inputTcpPort: UInt16 = 0
    private var seq: UInt32 = 0
    private var senderTimer: DispatchSourceTimer?
    private var heartbeatTimer: DispatchSourceTimer?
    private var controlBuffer = Data()

    private let deviceName = UIDevice.current.name

    /// Controller format the sender is presenting; sent in HELLO and on change.
    var currentLayout: String = ControllerStyle.xbox.wireId

    func connect(_ receiver: DiscoveredReceiver, wantsScreen: Bool) {
        disconnect()
        target = receiver
        state = .connecting

        let conn = NWConnection(to: receiver.endpoint, using: .tcp)
        control = conn
        conn.stateUpdateHandler = { [weak self] st in
            Task { @MainActor in
                switch st {
                case .ready: self?.sendHello(wantsScreen: wantsScreen)
                case .failed(let e): self?.fail(e.localizedDescription)
                default: break
                }
            }
        }
        conn.start(queue: .main)
        receiveControl(conn)
    }

    private func sendHello(wantsScreen: Bool) {
        var hello = ControlMessage(type: .hello)
        hello.v = 1
        hello.device = deviceName
        hello.platform = "ios"
        hello.wantsScreen = wantsScreen
        hello.layout = currentLayout
        control?.send(content: ControlCodec.encodeLine(hello), completion: .idempotent)
    }

    /// Update the active controller format and, if connected, notify the receiver.
    func setLayout(_ id: String) {
        currentLayout = id
        guard control != nil else { return }
        var m = ControlMessage(type: .layout)
        m.layout = id
        control?.send(content: ControlCodec.encodeLine(m), completion: .idempotent)
    }

    func submitPin(_ pin: String) {
        var p = ControlMessage(type: .pair)
        p.pin = pin
        control?.send(content: ControlCodec.encodeLine(p), completion: .idempotent)
    }

    func requestScreen(maxWidth: Int, maxFps: Int) {
        var s = ControlMessage(type: .screenStart)
        s.maxWidth = maxWidth; s.maxFps = maxFps; s.codec = "h264"
        control?.send(content: ControlCodec.encodeLine(s), completion: .idempotent)
    }

    /// Toggle the macOS screen stream on/off from the controller UI.
    func toggleScreen() {
        if screen == nil {
            requestScreen(maxWidth: 1280, maxFps: 60)
        } else {
            control?.send(content: ControlCodec.encodeLine(ControlMessage(type: .screenStop)),
                          completion: .idempotent)
            screen?.stop()
            screen = nil
        }
    }

    // MARK: - Control receive loop

    private func receiveControl(_ conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, complete, error in
            guard let self else { return }
            if let data { Task { @MainActor in self.ingest(data) } }
            if complete || error != nil {
                Task { @MainActor in self.disconnect() }
            } else {
                self.receiveControl(conn)
            }
        }
    }

    private func ingest(_ data: Data) {
        controlBuffer.append(data)
        while let nl = controlBuffer.firstIndex(of: 0x0A) {
            let line = controlBuffer.subdata(in: controlBuffer.startIndex..<nl)
            controlBuffer.removeSubrange(controlBuffer.startIndex...nl)
            if let msg = ControlCodec.decodeLine(line) { handle(msg) }
        }
    }

    private func handle(_ msg: ControlMessage) {
        switch msg.type {
        case .helloAck:
            if msg.requiresPin ?? true { state = .needsPin } else { state = .paired }
        case .pairOk:
            current.sessionId = msg.sessionId ?? 0
            sessionToken = hexToBytes(msg.token ?? "")
            for i in 0..<min(8, sessionToken.count) { current.token[i] = sessionToken[i] }
            inputPort = UInt16(msg.inputPort ?? Int(target?.inputPort ?? 0))
            inputTcpPort = UInt16(msg.inputTcpPort ?? 0)
            onPaired()
        case .pairFail:
            errorMessage = "Wrong PIN"; state = .needsPin
        case .screenReady:
            guard let host = target?.host, let vp = msg.videoPort,
                  let port = UInt16(exactly: vp) else { break }
            let receiver = ScreenReceiver()
            receiver.start(host: host, port: port,
                           width: msg.width ?? 1280, height: msg.height ?? 720)
            screen = receiver
        case .bye:
            disconnect()
        default:
            break
        }
    }

    private func onPaired() {
        guard let target else { return }
        let host = NWEndpoint.Host(target.host)
        // Wired/reliable: stream 32-byte packets over TCP; otherwise UDP.
        if useWiredInput, inputTcpPort != 0, let p = NWEndpoint.Port(rawValue: inputTcpPort) {
            let conn = NWConnection(host: host, port: p, using: .tcp)
            conn.start(queue: .main)
            tcpInput = conn
        } else if let p = NWEndpoint.Port(rawValue: inputPort) {
            let conn = NWConnection(host: host, port: p, using: .udp)
            conn.start(queue: .main)
            udp = conn
        }
        state = .paired
        Haptics.success()
        startSender()
        startHeartbeat()
    }

    private func sendInput(_ data: Data) {
        if let tcpInput {
            tcpInput.send(content: data, completion: .idempotent)
        } else {
            udp?.send(content: data, completion: .idempotent)
        }
    }

    // MARK: - Streaming

    private func startSender() {
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .userInteractive))
        timer.schedule(deadline: .now(), repeating: .milliseconds(PadLinkProtocol.keepAliveMs))
        timer.setEventHandler { [weak self] in
            Task { @MainActor in
                guard let self, self.state == .paired else { return }
                self.seq &+= 1
                self.current.seq = self.seq
                self.sendInput(self.current.encode())
            }
        }
        timer.resume()
        senderTimer = timer
    }

    private func startHeartbeat() {
        let timer = DispatchSource.makeTimerSource(queue: .global())
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in
            Task { @MainActor in
                guard let self, self.state == .paired else { return }
                var hb = ControlMessage(type: .heartbeat)
                hb.t = Int64(Date().timeIntervalSince1970 * 1000)
                self.control?.send(content: ControlCodec.encodeLine(hb), completion: .idempotent)
            }
        }
        timer.resume()
        heartbeatTimer = timer
    }

    func disconnect() {
        senderTimer?.cancel(); heartbeatTimer?.cancel()
        senderTimer = nil; heartbeatTimer = nil
        screen?.stop(); screen = nil
        control?.send(content: ControlCodec.encodeLine(ControlMessage(type: .bye)), completion: .idempotent)
        control?.cancel(); udp?.cancel(); tcpInput?.cancel()
        control = nil; udp = nil; tcpInput = nil
        if state != .error { state = .disconnected }
    }

    private func fail(_ message: String) { errorMessage = message; state = .error }

    private func hexToBytes(_ hex: String) -> [UInt8] {
        var out: [UInt8] = []
        var idx = hex.startIndex
        while idx < hex.endIndex, let next = hex.index(idx, offsetBy: 2, limitedBy: hex.endIndex) {
            if let b = UInt8(hex[idx..<next], radix: 16) { out.append(b) }
            idx = next
        }
        return out
    }
}
