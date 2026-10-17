import SwiftUI

// MARK: - Event wraps

extension Palette {
    /// Event wraps wear holographic foil: the one thing in the book no tier colour stands for.
    static let foil: [Color] = [0xFF7AD9, 0xB98CFF, 0x7FD4FF, 0x8CF5CF, 0xFFE58A, 0xFF7AD9].map { Color(hex: $0) }
    /// Foil in one colour, where a gradient won't do (text, a map pin's ring).
    static let foilInk = Color(hex: 0xFF8BE0)
    static let foilDeep = Color(hex: 0x2A0F2E)
}

extension Wrap {
    /// The event's symbol on tags and pins.
    var symbol: String {
        switch event {
        case "christmas": "snowflake"
        case "valentines": "heart.fill"
        case "summer": "sun.max.fill"
        case "chopin": "music.note"
        case "halloween": "moon.stars.fill"
        default: "sparkles"
        }
    }
}

/// Holographic foil: a slow-turning rainbow sheen. Still in lists, where a page of them
/// turning would be noise and work; turning on the reveal and the vehicle page.
struct Foil: View {
    var animated = false

    var body: some View {
        if animated {
            TimelineView(.animation(minimumInterval: 1 / 30)) { ctx in
                gradient(ctx.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 6) / 6 * 360)
            }
        } else {
            gradient(30)
        }
    }

    private func gradient(_ angle: Double) -> some View {
        AngularGradient(colors: Palette.foil, center: .center, angle: .degrees(angle))
            .allowsHitTesting(false)
    }
}

/// "❄ CHRISTMAS 2025" on foil: the wrap a catch wore.
struct WrapTag: View {
    let wrap: Wrap
    var size: CGFloat = 10.5
    var animated = false

    var body: some View {
        HStack(spacing: size * 0.45) {
            Image(systemName: wrap.symbol).font(.system(size: size * 0.95, weight: .bold))
            Mono(wrap.nameDisplay, size: size, weight: 700, spacing: 0.1, color: Palette.foilDeep)
                .lineLimit(1)
        }
        .foregroundStyle(Palette.foilDeep)
        .fixedSize()
        .padding(.vertical, size * 0.38)
        .padding(.horizontal, size * 0.85)
        .background { Foil(animated: animated).clipShape(Capsule()) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Event wrap: \(wrap.nameDisplay.lowercased())"))
    }
}

extension View {
    /// A foil rim around a die-cut sticker (`image` is the same picture this view shows,
    /// scaled to fit), and a faint rainbow over the vehicle.
    func foilEdge(_ image: Image, width: CGFloat = 4, animated: Bool = false) -> some View {
        background {
            Foil(animated: animated)
                .mask { image.resizable().scaledToFit().padding(-width) }
                .blur(radius: width * 0.25)
        }
        .overlay {
            Foil(animated: animated)
                .opacity(0.22)
                .blendMode(.overlay)
                .mask { image.resizable().scaledToFit() }
        }
    }

    /// The same rim around a rectangular photo card.
    func foilFrame(cornerRadius: CGFloat, width: CGFloat = 3, animated: Bool = false) -> some View {
        padding(width)
            .background { Foil(animated: animated).clipShape(RoundedRectangle(cornerRadius: cornerRadius + width, style: .continuous)) }
    }
}

/// `foilFrame` only when on.
struct FoilFrameIf: ViewModifier {
    let on: Bool
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        if on { content.foilFrame(cornerRadius: cornerRadius, width: 2) } else { content }
    }
}
