import SwiftUI

/// The on-screen controller **format** a paired phone is presenting. The macOS
/// receiver only needs to *recognize and display* it — input is always decoded
/// as a standard Xbox-style pad regardless of layout (see PROTOCOL.md §4.1).
enum ControllerLayout: String, CaseIterable {
    case xbox
    case playstation
    case switchPro = "switch"

    /// Map an over-the-wire `layout` string to a case (defaults to `.xbox`).
    init(wireId: String?) {
        self = ControllerLayout(rawValue: wireId ?? "") ?? .xbox
    }

    var displayName: String {
        switch self {
        case .xbox: return "Xbox"
        case .playstation: return "PlayStation (DualSense)"
        case .switchPro: return "Nintendo Switch Pro"
        }
    }

    /// SF Symbol hint for the dashboard badge.
    var symbol: String { "gamecontroller.fill" }

    /// Glyph + tint for a face-button position. Used by the live input view so
    /// the on-screen pad reads in the format the phone is presenting.
    struct Face { let glyph: String; let color: Color }

    // top / right / bottom / left always correspond to the Y / B / A / X bits.
    var faceTop: Face {
        switch self {
        case .xbox: return Face(glyph: "Y", color: Color(red: 0.95, green: 0.77, blue: 0.06))
        case .playstation: return Face(glyph: "△", color: Color(red: 0.30, green: 0.85, blue: 0.78))
        case .switchPro: return Face(glyph: "X", color: Color(white: 0.92))
        }
    }
    var faceRight: Face {
        switch self {
        case .xbox: return Face(glyph: "B", color: Color(red: 0.86, green: 0.20, blue: 0.18))
        case .playstation: return Face(glyph: "○", color: Color(red: 0.92, green: 0.34, blue: 0.40))
        case .switchPro: return Face(glyph: "A", color: Color(white: 0.92))
        }
    }
    var faceBottom: Face {
        switch self {
        case .xbox: return Face(glyph: "A", color: Color(red: 0.27, green: 0.70, blue: 0.30))
        case .playstation: return Face(glyph: "✕", color: Color(red: 0.45, green: 0.66, blue: 0.95))
        case .switchPro: return Face(glyph: "B", color: Color(white: 0.92))
        }
    }
    var faceLeft: Face {
        switch self {
        case .xbox: return Face(glyph: "X", color: Color(red: 0.20, green: 0.50, blue: 0.90))
        case .playstation: return Face(glyph: "□", color: Color(red: 0.90, green: 0.55, blue: 0.85))
        case .switchPro: return Face(glyph: "Y", color: Color(white: 0.92))
        }
    }
}
