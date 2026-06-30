import SwiftUI
import UIKit
import AVFoundation

/// Hosts the receiver's `AVSampleBufferDisplayLayer` full-bleed behind the
/// on-screen controller. The controller overlay is drawn on top of this in
/// `ControllerView`.
struct ScreenView: UIViewRepresentable {
    let layer: AVSampleBufferDisplayLayer

    func makeUIView(context: Context) -> ScreenHostView {
        let view = ScreenHostView()
        view.backgroundColor = .black
        view.attach(layer)
        return view
    }

    func updateUIView(_ uiView: ScreenHostView, context: Context) {
        uiView.attach(layer)
    }
}

final class ScreenHostView: UIView {
    private weak var videoLayer: AVSampleBufferDisplayLayer?

    func attach(_ newLayer: AVSampleBufferDisplayLayer) {
        guard videoLayer !== newLayer else { return }
        videoLayer?.removeFromSuperlayer()
        layer.addSublayer(newLayer)
        videoLayer = newLayer
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        videoLayer?.frame = bounds
    }
}
