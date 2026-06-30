import Foundation
import Network
import Combine

/// Hosts the PadLink receiver: advertises via Bonjour, accepts a TCP control
/// connection (pairing + heartbeats), and listens for UDP input datagrams.
/// Decoded input is forwarded to the VirtualController.
@MainActor
final class ReceiverServer: ObservableObject {

    // Published state for the SwiftUI dashboard.
    @Published private(set) var status: String = "Idle"
    @Published private(set) var connectedDevice: String?
    @Published private(set) var lastInput: InputState?
    @Published private(set) var pin: String = ReceiverServer.makePin()
    @Published private(set) var isRunning = false
    @Published private(set) var screenSharingRequested = false
    /// The controller format the connected phone is presenting (PROTOCOL.md §4.1).
    @Published private(set) var connectedLayout: ControllerLayout = .xbox

    var qrPayload: String {
        // Use the resolvable .local hostname (not the friendly localizedName) so
        // the phone can actually connect from the QR payload.
        let host = ProcessInfo.processInfo.hostName   // e.g. "Daniyals-Mac.local"
        return "padlink://connect?host=\(host)&in=\(inputPort)&ctrl=\(controlPort)&v=1&pin=\(pin)"
    }

    private let controller: VirtualController
    private let screen: ScreenShareController

    private var tcpListener: NWListener?
    private var udpListener: NWListener?
    private var tcpInputListener: NWListener?
    private var controlConnection: NWConnection?

    @Published private(set) var controlPort: UInt16 = 0
    @Published private(set) var inputPort: UInt16 = 0
    /// TCP input port for wired/reliable transport (PROTOCOL.md §4.4, §5).
    @Published private(set) var tcpInputPort: UInt16 = 0

    // Session/auth.
    private var sessionId: UInt16 = 0
    private var sessionToken: [UInt8] = []
    private var paired = false
    private var lastSeenInput = Date.distantPast
    private var heartbeatTimer: Timer?

    init(controller: VirtualController, screen: ScreenShareController) {
        self.controller = controller
        self.screen = screen
    }

    // MARK: - Lifecycle

    func start() {
        guard !isRunning else { return }
        do {
            try startUDP()
            try startTCP()
            try startTCPInput()
            isRunning = true
            status = "Advertising as \(Host.current().localizedName ?? "Mac") — PIN \(pin)"
            startHeartbeatMonitor()
        } catch {
            status = "Failed to start: \(error.localizedDescription)"
        }
    }

    func stop() {
        heartbeatTimer?.invalidate()
        controlConnection?.cancel()
        tcpListener?.cancel()
        udpListener?.cancel()
        tcpInputListener?.cancel()
        controlConnection = nil
        tcpListener = nil
        udpListener = nil
        tcpInputListener = nil
        paired = false
        connectedDevice = nil
        isRunning = false
        status = "Idle"
    }

    // MARK: - UDP input listener

    private func startUDP() throws {
        let params = NWParameters.udp
        params.allowLocalEndpointReuse = true
        let listener = try NWListener(using: params, on: .any)
        listener.newConnectionHandler = { [weak self] conn in
            conn.start(queue: .global(qos: .userInteractive))
            Task { @MainActor in self?.receiveUDP(on: conn) }
        }
        listener.stateUpdateHandler = { [weak self] state in
            if case .ready = state, let port = listener.port {
                Task { @MainActor in
                    self?.inputPort = port.rawValue
                    self?.advertiseBonjour()   // advertises once both ports are known
                }
            }
        }
        listener.start(queue: .main)
        udpListener = listener
    }

    private func receiveUDP(on conn: NWConnection) {
        conn.receiveMessage { [weak self] data, _, _, error in
            if let data, let state = InputState.decode(data) {
                Task { @MainActor in self?.handleInput(state) }
            }
            if error == nil { self?.receiveUDP(on: conn) }
        }
    }

    // MARK: - TCP input listener (wired / reliable transport)

    /// Accepts 32-byte input packets back-to-back over a reliable TCP stream — the
    /// path used over USB (`adb reverse` / usbmux) or flaky Wi-Fi. Authentication
    /// is identical to UDP (sessionId + token in each packet).
    private func startTCPInput() throws {
        let listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { [weak self] conn in
            conn.start(queue: .global(qos: .userInteractive))
            self?.receiveTCPInput(conn, buffer: Data())
        }
        listener.stateUpdateHandler = { [weak self] state in
            if case .ready = state, let port = listener.port {
                Task { @MainActor in self?.tcpInputPort = port.rawValue }
            }
        }
        listener.start(queue: .main)
        tcpInputListener = listener
    }

    nonisolated private func receiveTCPInput(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buf = buffer
            if let data { buf.append(data) }
            let size = PadLinkProtocol.inputPacketSize
            while buf.count >= size {
                let frame = Data(buf.prefix(size))
                buf.removeFirst(size)
                if let state = InputState.decode(frame) {
                    Task { @MainActor in self.handleInput(state) }
                }
            }
            if isComplete || error != nil { return }
            self.receiveTCPInput(conn, buffer: buf)
        }
    }

    private func handleInput(_ state: InputState) {
        guard paired, state.sessionId == sessionId else { return }
        // Cheap UDP auth: first 8 bytes of token must match.
        guard Array(sessionToken.prefix(8)) == state.token else { return }
        lastSeenInput = Date()
        lastInput = state
        controller.apply(state)
    }

    // MARK: - TCP control listener

    private func startTCP() throws {
        let listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { [weak self] conn in
            Task { @MainActor in self?.acceptControl(conn) }
        }
        listener.stateUpdateHandler = { [weak self] state in
            if case .ready = state, let port = listener.port {
                Task { @MainActor in
                    self?.controlPort = port.rawValue
                    self?.advertiseBonjour()   // advertises once both ports are known
                }
            }
        }
        listener.start(queue: .main)
        tcpListener = listener
    }

    private func acceptControl(_ conn: NWConnection) {
        // One controller at a time: replace any previous connection.
        controlConnection?.cancel()
        controlConnection = conn
        conn.start(queue: .main)
        readControlLine(conn, buffer: Data())
    }

    private func readControlLine(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buf = buffer
            if let data { buf.append(data) }
            // Split on newlines.
            while let nl = buf.firstIndex(of: 0x0A) {
                let line = buf.subdata(in: buf.startIndex..<nl)
                buf.removeSubrange(buf.startIndex...nl)
                if let msg = ControlCodec.decodeLine(line) {
                    Task { @MainActor in self.handleControl(msg, on: conn) }
                }
            }
            if isComplete || error != nil {
                Task { @MainActor in self.handleDisconnect() }
            } else {
                self.readControlLine(conn, buffer: buf)
            }
        }
    }

    private func handleControl(_ msg: ControlMessage, on conn: NWConnection) {
        switch msg.type {
        case .hello:
            connectedDevice = msg.device
            screenSharingRequested = msg.wantsScreen ?? false
            connectedLayout = ControllerLayout(wireId: msg.layout)
            var ack = ControlMessage(type: .helloAck)
            ack.v = 1
            ack.host = Host.current().localizedName ?? "Mac"
            ack.requiresPin = true
            ack.screenAvailable = true
            send(ack, on: conn)

        case .pair:
            if msg.pin == pin {
                sessionId = UInt16.random(in: 1...UInt16.max)
                sessionToken = (0..<16).map { _ in UInt8.random(in: 0...255) }
                paired = true
                var ok = ControlMessage(type: .pairOk)
                ok.sessionId = sessionId
                ok.token = sessionToken.map { String(format: "%02x", $0) }.joined()
                ok.inputPort = Int(inputPort)
                ok.inputTcpPort = Int(tcpInputPort)
                send(ok, on: conn)
                controller.connect()
                status = "Connected: \(connectedDevice ?? "device")"
            } else {
                var fail = ControlMessage(type: .pairFail)
                fail.reason = "bad_pin"
                send(fail, on: conn)
            }

        case .screenStart:
            screen.start(maxWidth: msg.maxWidth ?? 1280, maxFps: msg.maxFps ?? 60) { [weak self] videoPort, w, h in
                guard let self else { return }
                var ready = ControlMessage(type: .screenReady)
                ready.videoPort = Int(videoPort)
                ready.width = w
                ready.height = h
                ready.codec = "h264"
                self.send(ready, on: conn)
            }

        case .layout:
            connectedLayout = ControllerLayout(wireId: msg.layout)

        case .screenStop:
            screen.stop()

        case .heartbeat:
            var hb = ControlMessage(type: .heartbeat)
            hb.t = Int64(Date().timeIntervalSince1970 * 1000)
            send(hb, on: conn)

        case .bye:
            handleDisconnect()

        default:
            break
        }
    }

    private func send(_ msg: ControlMessage, on conn: NWConnection) {
        conn.send(content: ControlCodec.encodeLine(msg), completion: .idempotent)
    }

    private func handleDisconnect() {
        paired = false
        connectedDevice = nil
        lastInput = nil
        controller.disconnect()
        screen.stop()
        status = isRunning ? "Advertising — PIN \(pin)" : "Idle"
    }

    // MARK: - Bonjour

    /// The Bonjour service is published on the **TCP control port** so a sender's
    /// first connection (control/pairing) resolves to the right endpoint. The UDP
    /// input port travels in the `in` TXT record (and is re-sent in PAIR_OK).
    /// Needs both ports bound; called from each listener's ready handler.
    private func advertiseBonjour() {
        guard let tcpListener, controlPort != 0, inputPort != 0 else { return }
        let txt = NWTXTRecord([
            "v": "1",
            "in": String(inputPort),
            "name": Host.current().localizedName ?? "Mac",
            "screen": "1"
        ])
        tcpListener.service = NWListener.Service(
            name: Host.current().localizedName ?? "PadLink Mac",
            type: PadLinkProtocol.serviceType,
            txtRecord: txt.data
        )
    }

    // MARK: - Heartbeat / timeout

    private func startHeartbeatMonitor() {
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.paired else { return }
                if Date().timeIntervalSince(self.lastSeenInput) > 3.0 {
                    self.handleDisconnect()
                }
            }
        }
    }

    private static func makePin() -> String {
        String(format: "%04d", Int.random(in: 0...9999))
    }
}
