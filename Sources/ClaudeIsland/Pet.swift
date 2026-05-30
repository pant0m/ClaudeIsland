import Foundation
import SwiftUI

// MARK: - Cody, the notch slime
//
// A tiny SwiftUI creature that lives in the notch and emotes Claude's state.
// Pure shapes — no image assets — so it stays crisp at any size and tints to
// match the current state colour (blue=working, orange=attention, green=done).

struct PetView: View {
    let kind: IslandKind
    let tint: Color
    var size: CGFloat = 22
    var asleep: Bool = false          // post-done nap: melt flat and snore Zzz
    var fatness: CGFloat = 0          // 0…1 from context-window fill: chonkier = fuller
    var workingSince: Date?           // start of the current turn -> tiredness ramp
    var staticPose: Bool = false      // freeze a clean, grounded frame (for the app icon)
    var boopAt: Date?                 // a click "boops" Cody: one-shot happy + heart
    var style: PetStyle = .slime      // skin from config: slime / cat / ghost

    @State private var look: CGVector = .zero   // eyes glance toward the cursor on hover
    @State private var hovering = false
    private let ink = Color(white: 0.13)

    var body: some View {
        Group {
            if staticPose {
                frame(t: 0, tired: 0)     // t=0 -> grounded, happy, no bob
            } else {
                // Same continuous clock the spinner used, so the pet bobs live.
                TimelineView(.animation) { ctx in
                    frame(t: ctx.date.timeIntervalSinceReferenceDate,
                          tired: tiredness(at: ctx.date))
                }
            }
        }
        // Cody notices you: track the pointer, perk up while it's near.
        .onContinuousHover(coordinateSpace: .local) { phase in
            switch phase {
            case .active(let p):
                let half = max(1, size / 2)
                look = CGVector(dx: max(-1, min(1, (p.x - half) / half)),
                                dy: max(-1, min(1, (p.y - half) / half)))
                hovering = true
            case .ended:
                hovering = false
                look = .zero
            }
        }
    }

    private func frame(t: TimeInterval, tired: CGFloat) -> some View {
        let boop = boopAmount(at: t)
        let eff = hovering ? tired * 0.3 : tired       // a visit perks Cody up
        let m = Motion(kind: kind, t: t, asleep: asleep, tired: eff)
        return ZStack { core(m, t: t, tired: eff, boop: boop) }
            .frame(width: size, height: size)
            .overlay { reaction(t) }                   // floats independently of the bob
            .overlay { if boop > 0 { heart(boop) } }   // petting reward
    }

    /// A long-running turn wears Cody out, ramping to max weariness over ~5 min.
    private func tiredness(at date: Date) -> CGFloat {
        guard kind == .working, !asleep, let since = workingSince else { return 0 }
        let secs = date.timeIntervalSince1970 - since.timeIntervalSince1970
        return min(1, max(0, CGFloat(secs / 300)))
    }

    /// Body + face, driven by squash / tilt / bob from `Motion`, plus live
    /// cursor-glance (`look`) and the one-shot petting pop (`boop`).
    private func core(_ m: Motion, t: TimeInterval, tired: CGFloat, boop: CGFloat) -> some View {
        let bodyW = size * 0.82 * (1 + fatness * 0.42)   // fuller context -> wider slime
        let eyeX = size * 0.13 * (1 + fatness * 0.28)    // spread eyes on a fat face
        let lx = look.dx * size * 0.045                  // eyes glance toward the cursor
        let ly = look.dy * size * 0.04
        let pop: CGFloat = boop > 0 ? CGFloat(sin(Double(1 - boop) * .pi)) * 0.12 : 0
        let eStyle = boop > 0 ? EyeStyle.happy : m.eyeStyle   // petting makes him happy
        let bodyFill = LinearGradient(colors: [tint.opacity(0.95), tint.opacity(0.6)],
                                      startPoint: .top, endPoint: .bottom)
        return ZStack {
            ears()                                        // ears poke up from behind
            Group {
                if style == .ghost { GhostShape().fill(bodyFill) }
                else { BlobShape().fill(bodyFill) }
            }
            .overlay(alignment: .topLeading) {
                Ellipse().fill(.white.opacity(0.35))      // glossy sheen
                    .frame(width: size * 0.16, height: size * 0.10)
                    .offset(x: size * 0.16, y: size * 0.12)
            }
            accessory()                                   // belly / beak

            eye(style: eStyle, blink: m.blink).offset(x: -eyeX + lx, y: -size * 0.03 + ly)
            eye(style: eStyle, blink: m.blink).offset(x:  eyeX + lx, y: -size * 0.03 + ly)
            mouth.offset(y: size * 0.13)
            if tired > 0.35 { sweat(t) }                 // 💧 when worn out
        }
        .frame(width: bodyW, height: size * 0.74)
        .scaleEffect(x: m.squashX, y: m.squashY, anchor: .bottom)
        .rotationEffect(.degrees(m.tilt + Double(look.dx) * 5))   // lean toward the cursor
        .offset(x: m.dx * size, y: m.dy * size - pop * size)
    }

    /// A bead of sweat that wells up at the temple and rolls down, on a loop.
    private func sweat(_ t: TimeInterval) -> some View {
        let p = (t * 0.8).truncatingRemainder(dividingBy: 1)   // 0…1 fall cycle
        return Ellipse()
            .fill(Color(red: 0.55, green: 0.8, blue: 1).opacity(0.85 * (1 - p)))
            .frame(width: size * 0.09, height: size * 0.13)
            .offset(x: size * 0.20, y: -size * 0.16 + p * size * 0.30)
    }

    /// Ears that poke up from behind the head, per animal.
    @ViewBuilder
    private func ears() -> some View {
        switch style {
        case .cat:   ear(EarShape(), w: 0.20, h: 0.22, x: 0.20, y: -0.30)
        case .fox:   ear(EarShape(), w: 0.20, h: 0.30, x: 0.22, y: -0.34)
        case .bunny: ear(Capsule(),  w: 0.12, h: 0.36, x: 0.13, y: -0.36)
        case .bear:  ear(Circle(),   w: 0.22, h: 0.22, x: 0.22, y: -0.26)
        default:     EmptyView()
        }
    }

    private func ear<S: Shape>(_ shape: S, w: CGFloat, h: CGFloat, x: CGFloat, y: CGFloat) -> some View {
        ZStack {
            shape.fill(tint).frame(width: size * w, height: size * h).offset(x: -size * x, y: size * y)
            shape.fill(tint).frame(width: size * w, height: size * h).offset(x:  size * x, y: size * y)
        }
    }

    /// Belly patch (penguin) or beak (chick), drawn on the body.
    @ViewBuilder
    private func accessory() -> some View {
        switch style {
        case .penguin:
            Ellipse().fill(.white.opacity(0.88))
                .frame(width: size * 0.42, height: size * 0.5).offset(y: size * 0.1)
        case .chick:
            BeakShape().fill(Color.orange)
                .frame(width: size * 0.16, height: size * 0.13).offset(y: size * 0.08)
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private func eye(style: EyeStyle, blink: CGFloat) -> some View {
        let w = size * 0.11
        let h = size * 0.16
        switch style {
        case .open:
            Capsule().fill(ink).frame(width: w, height: h * max(0.12, blink))
        case .happy:
            ArchShape().stroke(ink, style: .init(lineWidth: size * 0.05, lineCap: .round))
                .frame(width: w * 1.7, height: h * 0.7)
        case .worried:
            Circle().fill(ink).frame(width: w * 1.35, height: w * 1.35)
        case .sleep:
            Capsule().fill(ink).frame(width: w * 1.5, height: max(1.2, size * 0.03))
        }
    }

    /// A pink heart that wells up and floats off when you click (pet) Cody.
    private func heart(_ boop: CGFloat) -> some View {
        Image(systemName: "heart.fill")
            .font(.system(size: size * 0.26))
            .foregroundStyle(.pink)
            .opacity(Double(boop))
            .scaleEffect(0.6 + Double(boop) * 0.5)
            .offset(x: size * 0.22, y: -size * 0.20 - (1 - boop) * size * 0.30)
    }

    /// 1 at the instant of a click, decaying to 0 over the next second.
    private func boopAmount(at t: TimeInterval) -> CGFloat {
        guard let b = boopAt else { return 0 }
        let age = Date(timeIntervalSinceReferenceDate: t).timeIntervalSince(b)
        return (age >= 0 && age < 1) ? CGFloat(1 - age) : 0
    }

    @ViewBuilder
    private var mouth: some View {
        if asleep {
            EmptyView()                                   // mouth closed while napping
        } else {
            switch kind {
            case .done:
                SmileShape().stroke(ink, style: .init(lineWidth: size * 0.045, lineCap: .round))
                    .frame(width: size * 0.18, height: size * 0.09)
            case .attention:
                Circle().fill(ink).frame(width: size * 0.09, height: size * 0.11)
            case .working:
                Capsule().fill(ink).frame(width: size * 0.10, height: size * 0.035)
            case .none:
                EmptyView()
            }
        }
    }

    /// Three drifting z's for the post-done nap.
    private func zzz(_ t: TimeInterval) -> some View {
        ZStack {
            ForEach(0..<3) { i in
                let fi = CGFloat(i)
                let p = (t * 0.7 + Double(i) * 0.34).truncatingRemainder(dividingBy: 1)   // 0…1
                Text("z")
                    .font(.system(size: size * (0.20 + fi * 0.06), weight: .bold))
                    .foregroundStyle(.white.opacity(0.65 * (1 - p)))
                    .offset(x: size * (0.20 + fi * 0.05 + p * 0.16),
                            y: -size * (0.14 + fi * 0.06 + p * 0.32))
            }
        }
    }

    /// Mood bubble above the head: Zzz / ! / sparkle.
    @ViewBuilder
    private func reaction(_ t: TimeInterval) -> some View {
        if asleep {
            zzz(t)
        } else {
            switch kind {
            case .none:
            let p = t.truncatingRemainder(dividingBy: 2) / 2          // 0…1 drift
            Text("z")
                .font(.system(size: size * 0.30, weight: .bold))
                .foregroundStyle(.white.opacity(0.55 * (1 - p)))
                .offset(x: size * 0.30, y: -size * 0.28 - p * size * 0.22)
        case .attention:
            let bob = abs(sin(t * 6))
            Text("!")
                .font(.system(size: size * 0.42, weight: .heavy))
                .foregroundStyle(.orange)
                .offset(x: size * 0.33, y: -size * 0.32 - bob * size * 0.06)
        case .done:
            let tw = abs(sin(t * 3))
            Image(systemName: "sparkle")
                .font(.system(size: size * 0.28))
                .foregroundStyle(.yellow.opacity(0.55 + 0.45 * tw))
                .scaleEffect(0.7 + 0.5 * tw)
                .offset(x: size * 0.30, y: -size * 0.30)
            case .working:
                EmptyView()
            }
        }
    }
}

// MARK: - Motion: maps (state, time) -> animation parameters

private enum EyeStyle { case open, happy, worried, sleep }

private struct Motion {
    var dx: CGFloat = 0          // horizontal offset (fraction of size)
    var dy: CGFloat = 0          // vertical offset
    var squashX: CGFloat = 1
    var squashY: CGFloat = 1
    var tilt: Double = 0
    var blink: CGFloat = 1       // eye openness 0…1 (only for .open)
    var eyeStyle: EyeStyle = .open

    init(kind: IslandKind, t: TimeInterval, asleep: Bool = false, tired: CGFloat = 0) {
        if asleep {
            // Melt into a flat puddle and breathe slowly (anchored to the floor).
            let breathe = sin(t * 1.4)
            squashX = 1.16 + breathe * 0.03
            squashY = 0.60 + breathe * 0.03
            eyeStyle = .sleep
            return
        }

        // Shared occasional blink for the awake states.
        let openness: CGFloat = t.truncatingRemainder(dividingBy: 3.4) > 3.2 ? 0.1 : 1

        switch kind {
        case .working:
            // Tiredness slows the trudge and lowers the eyelids.
            let f = 6 - tired * 2.5              // heavier, slower steps when weary
            let hop = abs(sin(t * f)) * (1 - tired * 0.5)
            dy = -hop * 0.10
            squashY = 1 + hop * 0.10
            squashX = 1 - hop * 0.07
            tilt = sin(t * f) * 5 * (1 - tired * 0.4)
            blink = openness * (1 - tired * 0.55)
            eyeStyle = .open

        case .attention:
            dx = sin(t * 22) * 0.035             // worried shiver
            dy = -abs(sin(t * 4)) * 0.03
            tilt = sin(t * 22) * 3
            eyeStyle = .worried

        case .done:
            let hop = abs(sin(t * 4))            // celebratory hop
            dy = -hop * 0.13
            squashY = 1 + hop * 0.09
            squashX = 1 - hop * 0.06
            eyeStyle = .happy

        case .none:
            let breathe = sin(t * 1.6)           // sleeping
            squashY = 1 + breathe * 0.03
            squashX = 1 - breathe * 0.03
            blink = 0.12
            eyeStyle = .sleep
        }
    }
}

// MARK: - Shapes

/// Rounded top, plump bottom — a slime/blob silhouette.
private struct BlobShape: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        let foot = r.maxY - r.height * 0.10
        p.move(to: CGPoint(x: r.minX, y: foot))
        p.addQuadCurve(to: CGPoint(x: r.midX, y: r.minY),
                       control: CGPoint(x: r.minX, y: r.minY))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: foot),
                       control: CGPoint(x: r.maxX, y: r.minY))
        p.addQuadCurve(to: CGPoint(x: r.minX, y: foot),
                       control: CGPoint(x: r.midX, y: r.maxY + r.height * 0.12))
        p.closeSubpath()
        return p
    }
}

/// ∩ arch — a happy squinting eye.
private struct ArchShape: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.maxY))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.maxY),
                       control: CGPoint(x: r.midX, y: r.minY - r.height * 0.5))
        return p
    }
}

/// ‿ smile.
private struct SmileShape: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY),
                       control: CGPoint(x: r.midX, y: r.maxY + r.height * 0.6))
        return p
    }
}

/// ▼ beak (triangle pointing down).
private struct BeakShape: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
        p.addLine(to: CGPoint(x: r.midX, y: r.maxY))
        p.closeSubpath()
        return p
    }
}

/// ▲ cat ear (triangle pointing up).
private struct EarShape: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.midX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
        p.closeSubpath()
        return p
    }
}

/// Rounded top, scalloped (wavy) bottom — a ghost.
private struct GhostShape: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        let h = r.height, w = r.width
        let foot = r.maxY
        p.move(to: CGPoint(x: r.minX, y: foot))
        p.addLine(to: CGPoint(x: r.minX, y: r.minY + h * 0.45))
        p.addQuadCurve(to: CGPoint(x: r.midX, y: r.minY), control: CGPoint(x: r.minX, y: r.minY))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY + h * 0.45), control: CGPoint(x: r.maxX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: foot))
        let bumps = 3
        let bw = w / CGFloat(bumps)
        for i in 0..<bumps {
            let x0 = r.maxX - CGFloat(i) * bw
            let x1 = x0 - bw
            p.addQuadCurve(to: CGPoint(x: x1, y: foot),
                           control: CGPoint(x: (x0 + x1) / 2, y: foot - h * 0.13))
        }
        p.closeSubpath()
        return p
    }
}

// MARK: - App icon
//
// The icon is Cody himself (a frozen happy frame) on a navy squircle, so the
// dock/Finder artwork always matches the notch creature. Rendered to .icns by
// `ClaudeIsland --icon` at install time.

struct IconView: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 230, style: .continuous)
                .fill(LinearGradient(colors: [Color(red: 0.16, green: 0.22, blue: 0.42),
                                              Color(red: 0.05, green: 0.07, blue: 0.14)],
                                     startPoint: .top, endPoint: .bottom))
            RoundedRectangle(cornerRadius: 230, style: .continuous)
                .fill(LinearGradient(colors: [.white.opacity(0.14), .clear],
                                     startPoint: .top, endPoint: .center))      // top sheen
            PetView(kind: .done, tint: Color(red: 0.36, green: 0.66, blue: 1.0),
                    size: 600, staticPose: true)
                .offset(y: 22)
        }
        .frame(width: 1024, height: 1024)
    }
}
