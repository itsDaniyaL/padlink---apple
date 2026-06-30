import Foundation
import ScreenCaptureKit
import VideoToolbox
import Network
import CoreMedia
import os
import Combine

/// Captures the Mac screen with ScreenCaptureKit, encodes to H.264 with
/// VideoToolbox, and streams encoded frames as chunked UDP datagrams
/// (PROTOCOL.md §6) to the connected phone.
///
/// This is a working skeleton: capture + encoder wiring are real; the network
/// send path is implemented for chunking. Bitrate adaptation and HEVC are
/// Phase 2.
@MainActor
final class ScreenShareController: NSObject, ObservableObject {

    @Published private(set) var isStreaming = false

    private let log = Logger(subsystem: "com.stackfinity.padlink.macos", category: "ScreenShare")
    private var stream: SCStream?
    private var encoder: H264Encoder?
    private var videoConnection: NWConnection?
    private var videoListener: NWListener?
    private var frameId: UInt32 = 0

    /// Remote endpoint is learned from the first inbound video keep-alive, or
    /// you can pass the phone's address from the control channel. For the
    /// skeleton we listen and reply to the sender's address.
    private var remoteEndpoint: NWEndpoint?

    /// Start capturing. Calls `ready(videoPort,width,height)` once the video
    /// socket is bound and capture is running.
    func start(maxWidth: Int, maxFps: Int, ready: @escaping (UInt16, Int, Int) -> Void) {
        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let display = content.displays.first else {
                    log.error("No display to capture")
                    return
                }

                let scale = min(1.0, Double(maxWidth) / Double(display.width))
                let outW = Int(Double(display.width) * scale)
                let outH = Int(Double(display.height) * scale)

                let filter = SCContentFilter(display: display, excludingWindows: [])
                let config = SCStreamConfiguration()
                config.width = outW
                config.height = outH
                config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(maxFps))
                config.pixelFormat = kCVPixelFormatType_32BGRA
                config.queueDepth = 5

                let encoder = H264Encoder(width: outW, height: outH, fps: maxFps) { [weak self] nal, isKeyframe in
                    self?.sendEncodedFrame(nal, isKeyframe: isKeyframe)
                }
                self.encoder = encoder

                let stream = SCStream(filter: filter, configuration: config, delegate: self)
                try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: .global(qos: .userInteractive))
                try await stream.startCapture()
                self.stream = stream

                // Bind the video socket and only report SCREEN_READY once the
                // listener is actually .ready and its port is known (PROTOCOL.md
                // §4.5 — the phone connects to this exact port).
                try self.bindVideoSocket { [weak self] port in
                    guard let self else { return }
                    self.isStreaming = true
                    ready(port, outW, outH)
                    self.log.info("Screen sharing started \(outW)x\(outH)@\(maxFps), videoPort \(port)")
                }
            } catch {
                self.log.error("Screen start failed: \(error.localizedDescription)")
            }
        }
    }

    func stop() {
        Task {
            try? await stream?.stopCapture()
            stream = nil
            encoder = nil
            videoConnection?.cancel()
            videoListener?.cancel()
            isStreaming = false
        }
    }

    // MARK: - Networking

    private func bindVideoSocket(_ onReady: @escaping (UInt16) -> Void) throws {
        let params = NWParameters.udp
        params.allowLocalEndpointReuse = true
        let listener = try NWListener(using: params, on: .any)
        listener.newConnectionHandler = { [weak self] conn in
            conn.start(queue: .global())
            // The phone sends a small "hello" to reveal its address; keep draining
            // so the connection stays the receiver's send target for video.
            conn.receiveMessage { _, _, _, _ in }
            Task { @MainActor in self?.videoConnection = conn }
        }
        listener.stateUpdateHandler = { state in
            if case .ready = state, let port = listener.port {
                Task { @MainActor in onReady(port.rawValue) }
            }
        }
        listener.start(queue: .main)
        videoListener = listener
    }

    /// Chunk one encoded frame and send it (PROTOCOL.md §6).
    private func sendEncodedFrame(_ nal: Data, isKeyframe: Bool) {
        guard let conn = videoConnection else { return }
        let id = frameId; frameId &+= 1
        let maxPayload = 1200
        let count = max(1, Int(ceil(Double(nal.count) / Double(maxPayload))))
        for i in 0..<count {
            let start = i * maxPayload
            let end = min(start + maxPayload, nal.count)
            var header = Data(count: 12)
            header.withUnsafeMutableBytes { raw in
                let p = raw.bindMemory(to: UInt8.self)
                p[0] = UInt8(id & 0xFF); p[1] = UInt8((id >> 8) & 0xFF)
                p[2] = UInt8((id >> 16) & 0xFF); p[3] = UInt8((id >> 24) & 0xFF)
                p[4] = UInt8(i & 0xFF); p[5] = UInt8((i >> 8) & 0xFF)
                p[6] = UInt8(count & 0xFF); p[7] = UInt8((count >> 8) & 0xFF)
                p[8] = isKeyframe ? 1 : 0
            }
            var packet = header
            packet.append(nal.subdata(in: start..<end))
            conn.send(content: packet, completion: .idempotent)
        }
    }
}

extension ScreenShareController: SCStreamOutput, SCStreamDelegate {
    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let pixelBuffer = sampleBuffer.imageBuffer else { return }
        Task { @MainActor in self.encoder?.encode(pixelBuffer, pts: sampleBuffer.presentationTimeStamp) }
    }
}
