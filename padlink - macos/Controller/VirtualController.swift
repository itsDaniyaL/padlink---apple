import Foundation
import os
import Combine

/// Bridges decoded PadLink input onto a system-level virtual game controller so
/// that games see a real Xbox-style gamepad and switch to controller prompts.
///
/// On macOS the only robust way to present a *system-wide* HID gamepad (visible
/// to every game via IOHIDManager / GameController.framework) is a **DriverKit
/// virtual HID device** running as a signed System Extension. This class is the
/// app-side bridge to that extension; see `README-driverkit.md`.
///
/// Until the DriverKit extension is installed, `backend` falls back to an
/// in-process logger so the rest of the pipeline can be developed and tested.
@MainActor
final class VirtualController: ObservableObject {

    @Published private(set) var isConnected = false
    @Published private(set) var backendName = "none"

    private let log = Logger(subsystem: "com.stackfinity.padlink.macos", category: "VirtualController")
    private var backend: VirtualControllerBackend

    init() {
        // Prefer the DriverKit HID backend; fall back to logging if unavailable.
        if let driver = DriverKitHIDBackend() {
            backend = driver
        } else {
            backend = LoggingBackend()
        }
        backendName = backend.name
    }

    func connect() {
        backend.open()
        isConnected = true
        log.info("Virtual controller connected via \(self.backend.name, privacy: .public)")
    }

    func disconnect() {
        backend.close()
        isConnected = false
    }

    /// Translate a PadLink InputState into a HID gamepad report and submit it.
    func apply(_ state: InputState) {
        var report = HIDGamepadReport()

        report.buttons = state.buttons.rawValue
        report.hat = state.dpad                       // 0..8 8-way hat

        // Sticks: PadLink is signed 16-bit centered at 0. Xbox HID is the same range.
        report.leftX = state.leftX
        report.leftY = state.leftY
        report.rightX = state.rightX
        report.rightY = state.rightY

        // Triggers: PadLink 0..1023 → HID 0..1023 (10-bit) kept as-is.
        report.leftTrigger = state.leftTrigger
        report.rightTrigger = state.rightTrigger

        backend.submit(report)
    }
}

/// The HID input report layout the DriverKit descriptor expects. Mirrors a
/// standard Xbox-style gamepad: 16 buttons, an 8-way hat, two sticks, two
/// analog triggers.
struct HIDGamepadReport: Equatable {
    var buttons: UInt16 = 0
    var hat: UInt8 = 0
    var leftX: Int16 = 0
    var leftY: Int16 = 0
    var rightX: Int16 = 0
    var rightY: Int16 = 0
    var leftTrigger: UInt16 = 0
    var rightTrigger: UInt16 = 0
}

protocol VirtualControllerBackend {
    var name: String { get }
    func open()
    func close()
    func submit(_ report: HIDGamepadReport)
}

/// Development fallback: logs reports instead of injecting them. Logs only when
/// the report actually changes (the sender streams a 50 ms keep-alive, so the
/// raw rate is constant) — so the log reads as a clean stream of live input.
final class LoggingBackend: VirtualControllerBackend {
    let name = "logging (no driver)"
    private let log = Logger(subsystem: "com.stackfinity.padlink.macos", category: "LoggingBackend")
    private var last = HIDGamepadReport()
    func open() { log.info("LoggingBackend open") }
    func close() { log.info("LoggingBackend close") }
    func submit(_ report: HIDGamepadReport) {
        guard report != last else { return }
        last = report
        log.info("""
        input buttons=0x\(String(report.buttons, radix: 16), privacy: .public) \
        hat=\(report.hat, privacy: .public) \
        L=(\(report.leftX),\(report.leftY)) R=(\(report.rightX),\(report.rightY)) \
        LT=\(report.leftTrigger) RT=\(report.rightTrigger)
        """)
    }
}
