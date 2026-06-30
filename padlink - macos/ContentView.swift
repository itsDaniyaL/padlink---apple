import SwiftUI
import CoreImage.CIFilterBuiltins

/// macOS receiver dashboard: status, pairing PIN + QR, and virtual-controller state.
struct DashboardView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 20) {
            header
            statusCard
            if model.server.isRunning { pairingCard }
            controllerCard
            if model.server.isRunning {
                LiveControllerView(
                    input: model.server.lastInput,
                    layout: model.server.connectedLayout,
                    active: model.controller.isConnected
                )
            }
            Spacer()
            Button(model.server.isRunning ? "Stop" : "Start Receiver") {
                model.server.isRunning ? model.server.stop() : model.server.start()
            }
            .keyboardShortcut(.defaultAction)
            .controlSize(.large)
        }
        .padding(24)
    }

    private var header: some View {
        HStack {
            Image(systemName: "gamecontroller.fill").font(.largeTitle)
            VStack(alignment: .leading) {
                Text("PadLink").font(.title.bold())
                Text("Use your phone as a controller").foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var statusCard: some View {
        GroupBox {
            HStack {
                Circle()
                    .fill(model.server.connectedDevice != nil ? .green : (model.server.isRunning ? .yellow : .gray))
                    .frame(width: 10, height: 10)
                Text(model.server.status)
                Spacer()
            }.padding(6)
        }
    }

    private var pairingCard: some View {
        GroupBox("Pair a device") {
            HStack(spacing: 20) {
                VStack(alignment: .leading) {
                    Text("PIN").font(.caption).foregroundStyle(.secondary)
                    Text(model.server.pin)
                        .font(.system(size: 34, weight: .bold, design: .monospaced))
                    Text("Scan the QR in the phone app, or enter the PIN.")
                        .font(.caption).foregroundStyle(.secondary).frame(maxWidth: 220)
                    if model.server.tcpInputPort != 0 {
                        Text("Wired (USB): ctrl \(model.server.controlPort) · input \(model.server.tcpInputPort)")
                            .font(.caption2).foregroundStyle(.tertiary).textSelection(.enabled)
                    }
                }
                Spacer()
                if let qr = Self.qrImage(from: model.server.qrPayload) {
                    Image(nsImage: qr).interpolation(.none).resizable().frame(width: 120, height: 120)
                }
            }.padding(6)
        }
    }

    private var controllerCard: some View {
        GroupBox("Virtual controller") {
            HStack {
                Image(systemName: model.controller.isConnected ? "gamecontroller.fill" : "gamecontroller")
                    .foregroundStyle(model.controller.isConnected ? .green : .secondary)
                VStack(alignment: .leading) {
                    Text(model.controller.isConnected ? "Active" : "Idle")
                    Text("Backend: \(model.controller.backendName)")
                        .font(.caption).foregroundStyle(.secondary)
                    if model.server.connectedDevice != nil {
                        Text("Layout: \(model.server.connectedLayout.displayName)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if let s = model.server.lastInput {
                    Text("seq \(s.seq)").font(.caption.monospaced()).foregroundStyle(.secondary)
                }
            }.padding(6)
        }
    }

    static func qrImage(from string: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        guard let ci = filter.outputImage else { return nil }
        let scaled = ci.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        let rep = NSCIImageRep(ciImage: scaled)
        let img = NSImage(size: rep.size)
        img.addRepresentation(rep)
        return img
    }
}
