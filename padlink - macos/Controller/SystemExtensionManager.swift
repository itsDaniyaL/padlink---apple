import Foundation
import SystemExtensions
import Combine
import os

/// Requests installation/activation of the PadLink DriverKit extension via
/// `OSSystemExtensionManager`. The user approves it once in System Settings →
/// Privacy & Security; afterwards `DriverKitHIDBackend` can open the driver and
/// games see a real gamepad. Until the dext target exists/approved, activation
/// fails gracefully and the receiver keeps using the logging backend.
@MainActor
final class SystemExtensionManager: NSObject, ObservableObject {
    @Published private(set) var status = "Virtual controller not installed"
    @Published private(set) var isActivating = false

    private let dextIdentifier = "com.stackfinity.padlink.macos.PadLinkVirtualGamepad"
    private let log = Logger(subsystem: "com.stackfinity.padlink.macos", category: "SystemExtension")

    func activate() {
        guard !isActivating else { return }
        isActivating = true
        status = "Requesting activation…"
        let request = OSSystemExtensionRequest.activationRequest(
            forExtensionWithIdentifier: dextIdentifier, queue: .main)
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
    }
}

extension SystemExtensionManager: OSSystemExtensionRequestDelegate {
    nonisolated func request(_ request: OSSystemExtensionRequest,
                             actionForReplacingExtension existing: OSSystemExtensionProperties,
                             withExtension ext: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction {
        .replace
    }

    nonisolated func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        Task { @MainActor in
            self.status = "Approve PadLink in System Settings → Privacy & Security"
        }
    }

    nonisolated func request(_ request: OSSystemExtensionRequest,
                             didFinishWithResult result: OSSystemExtensionRequest.Result) {
        Task { @MainActor in
            self.isActivating = false
            self.status = result == .completed
                ? "Virtual controller installed ✓"
                : "Installed — reboot to finish"
        }
    }

    nonisolated func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        Task { @MainActor in
            self.isActivating = false
            self.status = "Activation failed: \(error.localizedDescription)"
        }
    }
}
