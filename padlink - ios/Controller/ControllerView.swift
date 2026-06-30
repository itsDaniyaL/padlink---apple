import SwiftUI
import UIKit

/// On-screen gamepad for iOS. The layout (which buttons, where, and in which
/// console *format*) is driven by `LayoutStore`; in edit mode the user drags
/// elements to reposition them. Touches update the shared InputState that the
/// ConnectionManager streams over UDP. (iOS has no physical-button remapping —
/// that's Android-only by design.)
struct ControllerView: View {
    @EnvironmentObject var connection: ConnectionManager
    @EnvironmentObject var layout: LayoutStore

    var body: some View {
        GeometryReader { geo in
            ZStack {
                if let screen = connection.screen {
                    ScreenView(layer: screen.displayLayer).ignoresSafeArea()
                } else {
                    Color(red: 0.06, green: 0.07, blue: 0.09).ignoresSafeArea()
                }

                ForEach(PadElement.allCases, id: \.self) { el in
                    elementView(el)
                        .position(point(for: el, in: geo.size))
                        .modifier(EditDrag(enabled: layout.editing, element: el, canvas: geo.size, store: layout))
                }

                topBar
            }
        }
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .onAppear {
            Haptics.prepare()
            UIApplication.shared.isIdleTimerDisabled = true   // don't dim mid-game
        }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
    }

    private func point(for el: PadElement, in size: CGSize) -> CGPoint {
        let p = layout.positions[el] ?? CGPoint(x: 0.5, y: 0.5)
        return CGPoint(x: p.x * size.width, y: p.y * size.height)
    }

    // MARK: - Top bar / editor toolbar

    private var topBar: some View {
        VStack {
            HStack(spacing: 12) {
                if layout.editing {
                    Button("Reset") { layout.resetPositions() }
                        .buttonStyle(.bordered)
                    Button {
                        layout.hapticsEnabled.toggle()
                    } label: {
                        Image(systemName: layout.hapticsEnabled ? "hand.tap.fill" : "hand.tap")
                    }
                    .buttonStyle(.bordered)
                    Spacer()
                    stylePicker
                    Button("Done") { layout.editing = false }
                        .buttonStyle(.borderedProminent)
                } else {
                    Button("Disconnect") { connection.disconnect() }
                        .foregroundStyle(.white)
                    Spacer()
                    Text(layout.style.displayName)
                        .font(.caption).foregroundStyle(.secondary)
                    Button { connection.toggleScreen() } label: {
                        Image(systemName: connection.screen == nil ? "tv" : "tv.fill")
                    }
                    .foregroundStyle(.white)
                    Button { layout.editing = true } label: {
                        Image(systemName: "slider.horizontal.3")
                    }
                    .foregroundStyle(.white)
                }
            }
            .padding(.horizontal)
            .padding(.top, 8)
            Spacer()
        }
    }

    private var stylePicker: some View {
        Picker("Format", selection: Binding(
            get: { layout.style },
            set: { layout.selectStyle($0) }
        )) {
            ForEach(ControllerStyle.allCases) { s in
                Text(s.displayName).tag(s)
            }
        }
        .pickerStyle(.segmented)
        .frame(maxWidth: 320)
    }

    // MARK: - Elements

    @ViewBuilder
    private func elementView(_ el: PadElement) -> some View {
        let editing = layout.editing
        switch el {
        case .leftStick:
            AnalogStick(interactive: !editing) { x, y in
                connection.current.leftX = x; connection.current.leftY = y
            }
        case .rightStick:
            AnalogStick(interactive: !editing) { x, y in
                connection.current.rightX = x; connection.current.rightY = y
            }
        case .dpad:
            DPadView(interactive: !editing) { connection.current.dpad = UInt8($0) }
        case .faceButtons:
            FaceButtons(style: layout.style, interactive: !editing) { btn, pressed in
                connection.current.setButton(btn, pressed)
            }
        case .lb:
            HoldButton(label: "LB", interactive: !editing) { connection.current.setButton(.lb, $0) }
        case .rb:
            HoldButton(label: "RB", interactive: !editing) { connection.current.setButton(.rb, $0) }
        case .start:
            HoldButton(label: layout.style.startLabel, size: 56, interactive: !editing) { connection.current.setButton(.start, $0) }
        case .back:
            HoldButton(label: layout.style.backLabel, size: 56, interactive: !editing) { connection.current.setButton(.back, $0) }
        }
    }
}

/// In edit mode, overlays a drag handle on an element and writes the new
/// normalized position back to the store. Disabled (pass-through) when not editing.
private struct EditDrag: ViewModifier {
    let enabled: Bool
    let element: PadElement
    let canvas: CGSize
    @ObservedObject var store: LayoutStore
    @State private var base: CGPoint?

    func body(content: Content) -> some View {
        if enabled {
            content
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6]))
                        .foregroundStyle(.white.opacity(0.6))
                        .padding(-6)
                )
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { v in
                            let start = base ?? store.positions[element] ?? CGPoint(x: 0.5, y: 0.5)
                            if base == nil { base = start }
                            store.setPosition(element, CGPoint(
                                x: start.x + v.translation.width / canvas.width,
                                y: start.y + v.translation.height / canvas.height
                            ))
                        }
                        .onEnded { _ in base = nil }
                )
        } else {
            content
        }
    }
}

struct HoldButton: View {
    let label: String
    var size: CGFloat = 70
    var interactive: Bool = true
    var onChange: (Bool) -> Void = { _ in }
    @State private var pressed = false

    var body: some View {
        Circle()
            .fill(pressed ? Color.blue : Color(white: 0.18))
            .frame(width: size, height: size)
            .overlay(Text(label).foregroundStyle(.white).font(.headline).minimumScaleFactor(0.5).padding(6))
            .modifier(PressGesture(interactive: interactive, pressed: $pressed, onChange: onChange))
    }
}

/// Diamond of four face buttons, styled per the selected console format.
struct FaceButtons: View {
    let style: ControllerStyle
    var interactive: Bool = true
    let onButton: (PadButtons, Bool) -> Void

    var body: some View {
        ZStack {
            faceButton(style.faceTop, .y).offset(y: -60)
            faceButton(style.faceLeft, .x).offset(x: -60)
            faceButton(style.faceRight, .b).offset(x: 60)
            faceButton(style.faceBottom, .a).offset(y: 60)
        }
        .frame(width: 190, height: 190)
    }

    private func faceButton(_ face: ControllerStyle.Face, _ bit: PadButtons) -> some View {
        FaceButton(face: face, interactive: interactive) { onButton(bit, $0) }
    }
}

private struct FaceButton: View {
    let face: ControllerStyle.Face
    var interactive: Bool
    let onChange: (Bool) -> Void
    @State private var pressed = false

    var body: some View {
        Circle()
            .fill(pressed ? face.color : face.color.opacity(0.85))
            .frame(width: 64, height: 64)
            .overlay(Circle().strokeBorder(.white.opacity(0.25), lineWidth: 1))
            .overlay(Text(face.glyph).font(.title2.bold()).foregroundStyle(.white))
            .scaleEffect(pressed ? 0.92 : 1)
            .modifier(PressGesture(interactive: interactive, pressed: $pressed, onChange: onChange))
    }
}

/// Shared press/release gesture; a no-op when `interactive` is false (edit mode).
private struct PressGesture: ViewModifier {
    let interactive: Bool
    @Binding var pressed: Bool
    let onChange: (Bool) -> Void

    func body(content: Content) -> some View {
        if interactive {
            content.gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in if !pressed { pressed = true; Haptics.button(); onChange(true) } }
                    .onEnded { _ in pressed = false; onChange(false) }
            )
        } else {
            content
        }
    }
}

/// 8-way D-pad emitting codes 0=none,1=N..8=NW.
struct DPadView: View {
    var interactive: Bool = true
    let onDir: (Int) -> Void

    var body: some View {
        ZStack {
            Circle().fill(Color(white: 0.12)).frame(width: 150, height: 150)
            Image(systemName: "plus").font(.system(size: 36, weight: .light)).foregroundStyle(.white.opacity(0.5))
        }
        .frame(width: 150, height: 150)
        .modifier(DPadGesture(interactive: interactive, onDir: onDir))
    }
}

private struct DPadGesture: ViewModifier {
    let interactive: Bool
    let onDir: (Int) -> Void
    @State private var lastDir = 0

    func body(content: Content) -> some View {
        if interactive {
            content.gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        let d = Self.direction(dx: v.location.x - 75, dy: v.location.y - 75)
                        if d != lastDir { lastDir = d; if d != 0 { Haptics.tick() } }
                        onDir(d)
                    }
                    .onEnded { _ in lastDir = 0; onDir(0) }
            )
        } else {
            content
        }
    }

    static func direction(dx: CGFloat, dy: CGFloat) -> Int {
        let dead: CGFloat = 18
        if hypot(dx, dy) < dead { return 0 }
        let angle = (atan2(-dy, dx) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
        switch angle {
        case ..<22.5, 337.5...: return 3   // E
        case ..<67.5: return 2             // NE
        case ..<112.5: return 1            // N
        case ..<157.5: return 8            // NW
        case ..<202.5: return 7            // W
        case ..<247.5: return 6            // SW
        case ..<292.5: return 5            // S
        default: return 4                  // SE
        }
    }
}

/// Analog stick → signed 16-bit X/Y (up is positive Y).
struct AnalogStick: View {
    var interactive: Bool = true
    let onMove: (Int16, Int16) -> Void
    @State private var knob: CGSize = .zero
    private let radius: CGFloat = 80

    var body: some View {
        ZStack {
            Circle().fill(Color(white: 0.12)).frame(width: 160, height: 160)
            Circle().fill(Color.blue).frame(width: 56, height: 56).offset(knob)
        }
        .frame(width: 160, height: 160)
        .modifier(StickGesture(interactive: interactive, radius: radius, knob: $knob, onMove: onMove))
    }
}

private struct StickGesture: ViewModifier {
    let interactive: Bool
    let radius: CGFloat
    @Binding var knob: CGSize
    let onMove: (Int16, Int16) -> Void

    func body(content: Content) -> some View {
        if interactive {
            content.gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        var v = value.translation
                        let dist = sqrt(v.width * v.width + v.height * v.height)
                        if dist > radius { v.width *= radius / dist; v.height *= radius / dist }
                        knob = v
                        let nx = max(-1, min(1, v.width / radius))
                        let ny = max(-1, min(1, -v.height / radius))
                        onMove(Int16(nx * 32767), Int16(ny * 32767))
                    }
                    .onEnded { _ in knob = .zero; onMove(0, 0) }
            )
        } else {
            content
        }
    }
}
