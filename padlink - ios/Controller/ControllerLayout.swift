import SwiftUI
import Combine

/// The on-screen controller **format** the pad mimics. This is purely cosmetic:
/// glyphs, colors and default element positions change, but the wire protocol
/// always sends position-based, Xbox-style button bits (PROTOCOL.md §4.1, §5),
/// so the receiver sees a standard pad no matter which format is selected.
enum ControllerStyle: String, CaseIterable, Codable, Identifiable {
    case xbox
    case playstation
    case switchPro = "switch"

    var id: String { rawValue }

    /// Identifier sent over the wire (matches PROTOCOL.md valid values).
    var wireId: String { rawValue }

    var displayName: String {
        switch self {
        case .xbox: return "Xbox"
        case .playstation: return "PlayStation"
        case .switchPro: return "Switch Pro"
        }
    }

    /// Glyph + tint for one face-button position.
    struct Face { let glyph: String; let color: Color }

    // Face positions are fixed by ergonomics; only the glyph/color changes.
    // top / right / bottom / left correspond to the diamond corners and always
    // map to the Y / B / A / X protocol bits respectively.
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

    var startLabel: String {
        switch self {
        case .xbox: return "☰"
        case .playstation: return "OPTIONS"
        case .switchPro: return "+"
        }
    }
    var backLabel: String {
        switch self {
        case .xbox: return "⧉"
        case .playstation: return "SHARE"
        case .switchPro: return "−"
        }
    }
}

/// A placeable element of the on-screen pad. Positions are stored normalized
/// (0...1) so the layout scales to any device/orientation.
enum PadElement: String, CaseIterable, Codable {
    case dpad, leftStick, rightStick, faceButtons, lb, rb, start, back
}

/// Holds the active style and the (editable, persisted) element positions.
@MainActor
final class LayoutStore: ObservableObject {
    @Published private(set) var style: ControllerStyle
    @Published private(set) var positions: [PadElement: CGPoint]
    @Published var editing = false
    @Published var hapticsEnabled: Bool {
        didSet {
            defaults.set(hapticsEnabled, forKey: hapticsKey)
            Haptics.enabled = hapticsEnabled
        }
    }

    /// Notified when the user picks a different style, so the connection can
    /// inform the receiver.
    var onStyleChange: ((ControllerStyle) -> Void)?

    private let defaults = UserDefaults.standard
    private let styleKey = "padlink.style"
    private let hapticsKey = "padlink.haptics"

    init() {
        let s = ControllerStyle(rawValue: defaults.string(forKey: styleKey) ?? "") ?? .xbox
        self.style = s
        self.positions = LayoutStore.load(s, defaults) ?? LayoutStore.defaultPositions(for: s)
        let haptics = defaults.object(forKey: hapticsKey) as? Bool ?? true
        self.hapticsEnabled = haptics
        Haptics.enabled = haptics
    }

    func selectStyle(_ s: ControllerStyle) {
        guard s != style else { return }
        style = s
        defaults.set(s.rawValue, forKey: styleKey)
        positions = LayoutStore.load(s, defaults) ?? LayoutStore.defaultPositions(for: s)
        onStyleChange?(s)
    }

    func setPosition(_ e: PadElement, _ p: CGPoint) {
        positions[e] = CGPoint(x: min(max(p.x, 0.06), 0.94), y: min(max(p.y, 0.10), 0.90))
        save()
    }

    func resetPositions() {
        positions = LayoutStore.defaultPositions(for: style)
        save()
    }

    // MARK: - Defaults

    static func defaultPositions(for s: ControllerStyle) -> [PadElement: CGPoint] {
        let common: [PadElement: CGPoint] = [
            .lb: CGPoint(x: 0.12, y: 0.16),
            .rb: CGPoint(x: 0.88, y: 0.16),
            .back: CGPoint(x: 0.43, y: 0.16),
            .start: CGPoint(x: 0.57, y: 0.16),
        ]
        switch s {
        case .playstation:
            // DualSense: symmetric sticks low-center, d-pad & face high on the sides.
            return common.merging([
                .dpad: CGPoint(x: 0.16, y: 0.46),
                .faceButtons: CGPoint(x: 0.84, y: 0.46),
                .leftStick: CGPoint(x: 0.38, y: 0.80),
                .rightStick: CGPoint(x: 0.62, y: 0.80),
            ]) { _, new in new }
        case .xbox, .switchPro:
            // Asymmetric: left stick high-left, d-pad low-left.
            return common.merging([
                .leftStick: CGPoint(x: 0.17, y: 0.46),
                .dpad: CGPoint(x: 0.33, y: 0.80),
                .faceButtons: CGPoint(x: 0.83, y: 0.46),
                .rightStick: CGPoint(x: 0.67, y: 0.80),
            ]) { _, new in new }
        }
    }

    // MARK: - Persistence

    private func save() {
        let dict = positions.reduce(into: [String: [Double]]()) {
            $0[$1.key.rawValue] = [Double($1.value.x), Double($1.value.y)]
        }
        if let data = try? JSONEncoder().encode(dict) {
            defaults.set(data, forKey: Self.posKey(style))
        }
    }

    private static func posKey(_ s: ControllerStyle) -> String { "padlink.positions.\(s.rawValue)" }

    private static func load(_ s: ControllerStyle, _ d: UserDefaults) -> [PadElement: CGPoint]? {
        guard let data = d.data(forKey: posKey(s)),
              let dict = try? JSONDecoder().decode([String: [Double]].self, from: data) else { return nil }
        var out: [PadElement: CGPoint] = [:]
        for (k, v) in dict where v.count == 2 {
            if let e = PadElement(rawValue: k) { out[e] = CGPoint(x: v[0], y: v[1]) }
        }
        return out.isEmpty ? nil : out
    }
}
