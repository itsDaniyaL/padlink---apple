import SwiftUI

/// A real-time mirror of the gamepad input the receiver is decoding from the
/// phone. Buttons light up, sticks move, triggers fill, and the d-pad highlights
/// — so you can *see* that macOS is recognizing each key live. Face buttons are
/// labelled in the format the phone reports (PROTOCOL.md §4.1).
struct LiveControllerView: View {
    let input: InputState?
    let layout: ControllerLayout
    let active: Bool

    private var s: InputState { input ?? InputState() }

    var body: some View {
        VStack(spacing: 16) {
            // Shoulders + triggers
            HStack(alignment: .top) {
                VStack(spacing: 6) {
                    pill("LB", pressed: s.buttons.contains(.lb))
                    triggerBar(value: s.leftTrigger, label: "LT")
                }
                Spacer()
                VStack(spacing: 6) {
                    pill("RB", pressed: s.buttons.contains(.rb))
                    triggerBar(value: s.rightTrigger, label: "RT")
                }
            }

            HStack(alignment: .center, spacing: 18) {
                stick("L", x: s.leftX, y: s.leftY, clicked: s.buttons.contains(.ls))
                dpad
                centerButtons
                faceButtons
                stick("R", x: s.rightX, y: s.rightY, clicked: s.buttons.contains(.rs))
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(white: 0.10)))
        .opacity(active ? 1 : 0.45)
        .overlay {
            if !active {
                Text("Waiting for a paired device…")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .animation(.easeOut(duration: 0.05), value: s.seq)
    }

    // MARK: - Face buttons (diamond, labelled per recognized layout)

    private var faceButtons: some View {
        ZStack {
            face(layout.faceTop, pressed: s.buttons.contains(.y)).offset(y: -30)
            face(layout.faceLeft, pressed: s.buttons.contains(.x)).offset(x: -30)
            face(layout.faceRight, pressed: s.buttons.contains(.b)).offset(x: 30)
            face(layout.faceBottom, pressed: s.buttons.contains(.a)).offset(y: 30)
        }
        .frame(width: 96, height: 96)
    }

    private func face(_ f: ControllerLayout.Face, pressed: Bool) -> some View {
        Circle()
            .fill(pressed ? f.color : f.color.opacity(0.28))
            .frame(width: 34, height: 34)
            .overlay(Text(f.glyph).font(.subheadline.bold()).foregroundStyle(.white))
            .scaleEffect(pressed ? 1.12 : 1)
    }

    // MARK: - D-pad

    private var dpad: some View {
        let code = Int(s.dpad)
        let n = [8, 1, 2].contains(code)
        let e = [2, 3, 4].contains(code)
        let so = [4, 5, 6].contains(code)
        let w = [6, 7, 8].contains(code)
        return ZStack {
            arrow("arrowtriangle.up.fill", on: n).offset(y: -26)
            arrow("arrowtriangle.down.fill", on: so).offset(y: 26)
            arrow("arrowtriangle.left.fill", on: w).offset(x: -26)
            arrow("arrowtriangle.right.fill", on: e).offset(x: 26)
        }
        .frame(width: 80, height: 80)
    }

    private func arrow(_ symbol: String, on: Bool) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 18))
            .foregroundStyle(on ? Color.accentColor : Color(white: 0.30))
    }

    // MARK: - Center (Back / Guide / Start)

    private var centerButtons: some View {
        VStack(spacing: 8) {
            miniPill("⧉", pressed: s.buttons.contains(.back))
            miniPill("◉", pressed: s.buttons.contains(.guide))
            miniPill("☰", pressed: s.buttons.contains(.start))
        }
    }

    // MARK: - Sticks

    private func stick(_ label: String, x: Int16, y: Int16, clicked: Bool) -> some View {
        let r: CGFloat = 30
        let dx = CGFloat(x) / 32767 * r
        let dy = -CGFloat(y) / 32767 * r   // up is positive Y
        return VStack(spacing: 4) {
            ZStack {
                Circle().fill(Color(white: 0.16)).frame(width: 72, height: 72)
                Circle().stroke(Color(white: 0.3), lineWidth: 1).frame(width: 72, height: 72)
                Circle()
                    .fill(clicked ? Color.accentColor : Color.blue)
                    .frame(width: 24, height: 24)
                    .offset(x: dx, y: dy)
            }
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }

    // MARK: - Small widgets

    private func pill(_ label: String, pressed: Bool) -> some View {
        Text(label)
            .font(.caption.bold())
            .padding(.horizontal, 14).padding(.vertical, 6)
            .background(Capsule().fill(pressed ? Color.accentColor : Color(white: 0.20)))
            .foregroundStyle(.white)
    }

    private func miniPill(_ glyph: String, pressed: Bool) -> some View {
        Text(glyph)
            .font(.caption)
            .frame(width: 30, height: 22)
            .background(Capsule().fill(pressed ? Color.accentColor : Color(white: 0.18)))
            .foregroundStyle(.white)
    }

    private func triggerBar(value: UInt16, label: String) -> some View {
        let frac = CGFloat(min(value, 1023)) / 1023
        return VStack(spacing: 2) {
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 4).fill(Color(white: 0.18)).frame(width: 22, height: 44)
                RoundedRectangle(cornerRadius: 4).fill(Color.accentColor).frame(width: 22, height: max(2, 44 * frac))
            }
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }
}
