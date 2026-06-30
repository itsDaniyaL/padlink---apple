import UIKit

/// Lightweight haptic feedback for the on-screen controller. Buttons give a crisp
/// tap, the d-pad a lighter tick, and pairing a success notification. Generators
/// are re-prepared after each fire so latency stays low during rapid play.
enum Haptics {
    /// Toggled by the user (persisted in `LayoutStore`).
    static var enabled = true

    private static let impact = UIImpactFeedbackGenerator(style: .rigid)
    private static let light = UIImpactFeedbackGenerator(style: .light)
    private static let notify = UINotificationFeedbackGenerator()

    static func prepare() {
        impact.prepare(); light.prepare()
    }

    /// A button press.
    static func button() {
        guard enabled else { return }
        impact.impactOccurred(intensity: 0.85)
        impact.prepare()
    }

    /// A lighter tick (d-pad direction change).
    static func tick() {
        guard enabled else { return }
        light.impactOccurred(intensity: 0.5)
        light.prepare()
    }

    /// Pairing / connection succeeded.
    static func success() {
        guard enabled else { return }
        notify.notificationOccurred(.success)
    }
}
