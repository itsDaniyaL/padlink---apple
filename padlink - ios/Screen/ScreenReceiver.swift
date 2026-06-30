import Foundation
import Network
import AVFoundation
import Combine

/// Receives the macOS screen stream: opens a UDP socket to the receiver's
/// `videoPort`, announces its address (so the Mac knows where to send frames),
/// reassembles chunks, and decodes them onto `displayLayer`. The controller UI
/// is composited on top of that layer (PROTOCOL.md §4.5, §6).
final class ScreenReceiver: ObservableObject {
    @Published private(set) var isRunning = false

    /// The layer the SwiftUI `ScreenView` displays; the decoder enqueues frames here.
    let displayLayer = AVSampleBufferDisplayLayer()

    private var connection: NWConnection?
    private let reassembler = FrameReassembler()
    private let decoder: H264Decoder

    init() {
        displayLayer.videoGravity = .resizeAspect
        decoder = H264Decoder(displayLayer: displayLayer)
    }

    func start(host: String, port: UInt16, width: Int, height: Int) {
        stop()
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return }
        let conn = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .udp)
        connection = conn
        conn.stateUpdateHandler = { [weak self] state in
            if case .ready = state {
                // A one-byte hello reveals our source address/port to the sender.
                conn.send(content: Data([0x01]), completion: .idempotent)
                self?.setRunning(true)
            }
        }
        conn.start(queue: .global(qos: .userInteractive))
        receive(conn)
    }

    func stop() {
        connection?.cancel()
        connection = nil
        reassembler.reset()
        setRunning(false)
    }

    private func receive(_ conn: NWConnection) {
        conn.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if let data, let (frame, _) = self.reassembler.onChunk(data) {
                self.decoder.decode(frame)
            }
            if error == nil { self.receive(conn) }
        }
    }

    private func setRunning(_ value: Bool) {
        DispatchQueue.main.async { self.isRunning = value }
    }
}
