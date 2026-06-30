import Foundation
import IOKit
import os

/// App-side client for the PadLink DriverKit virtual-HID System Extension.
///
/// The DriverKit extension (a separate target — see README-driverkit.md) creates
/// a virtual `IOUserHIDDevice` exposing an Xbox-style gamepad descriptor. This
/// class connects to that user client and forwards HID input reports.
///
/// `init?` returns nil if the extension isn't installed/approved yet, allowing
/// VirtualController to gracefully fall back to the logging backend.
final class DriverKitHIDBackend: VirtualControllerBackend {

    let name = "DriverKit HID"
    private let log = Logger(subsystem: "com.stackfinity.padlink.macos", category: "DriverKitHIDBackend")
    private var connection: io_connect_t = 0
    private var service: io_service_t = 0

    /// Matches the dext by its IOService class name. Adjust to match the dext's
    /// `IOClass` / `IOUserClass` once the extension target is finalized.
    private static let serviceName = "PadLinkVirtualGamepad"

    // User-client selector indices — must match the dext's externalMethod table.
    private enum Selector: UInt32 { case submitReport = 0 }

    init?() {
        let matching = IOServiceMatching(Self.serviceName)
        let svc = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard svc != 0 else {
            // Extension not present/approved. Fall back.
            return nil
        }
        service = svc
        var conn: io_connect_t = 0
        let kr = IOServiceOpen(service, mach_task_self_, 0, &conn)
        guard kr == KERN_SUCCESS else {
            IOObjectRelease(service)
            return nil
        }
        connection = conn
    }

    func open() {
        log.info("DriverKit user client opened")
    }

    func close() {
        if connection != 0 { IOServiceClose(connection); connection = 0 }
        if service != 0 { IOObjectRelease(service); service = 0 }
    }

    func submit(_ report: HIDGamepadReport) {
        guard connection != 0 else { return }
        // 16-byte submit struct the dext's PadLinkUserClient parses (little-endian):
        //   u16 buttons | u8 dpad | u8 pad | i16 lx,ly,rx,ry | u16 lt | u16 rt
        var bytes = [UInt8](repeating: 0, count: 16)
        func putU16(_ v: UInt16, _ o: Int) { bytes[o] = UInt8(v & 0xFF); bytes[o+1] = UInt8(v >> 8) }
        func putI16(_ v: Int16, _ o: Int) { putU16(UInt16(bitPattern: v), o) }

        putU16(report.buttons, 0)
        bytes[2] = report.hat
        bytes[3] = 0
        putI16(report.leftX, 4); putI16(report.leftY, 6)
        putI16(report.rightX, 8); putI16(report.rightY, 10)
        putU16(report.leftTrigger, 12)
        putU16(report.rightTrigger, 14)

        bytes.withUnsafeBufferPointer { buf in
            _ = IOConnectCallStructMethod(
                connection,
                Selector.submitReport.rawValue,
                buf.baseAddress, buf.count,
                nil, nil
            )
        }
    }
}
