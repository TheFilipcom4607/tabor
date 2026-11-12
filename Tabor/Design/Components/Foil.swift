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
            TurningFoil()
        } else {
            AngularGradient(colors: Palette.foil, center: .center, angle: .degrees(30))
                .allowsHitTesting(false)
        }
    }
}

/// The turning foil as a layer the system spins: turning it through SwiftUI redrew it every
/// frame (about 5% CPU for one, and HUNT's wrap banner is up all December). Share cards use
/// the still one: `ImageRenderer` can't draw a UIView.
private struct TurningFoil: UIViewRepresentable {
    @Environment(\.tabActive) private var tabActive
    @Environment(\.lowPower) private var lowPower

    func makeUIView(context: Context) -> FoilView { FoilView() }

    func updateUIView(_ view: FoilView, context: Context) {
        view.turning = tabActive && !lowPower
    }

    final class FoilView: UIView {
        private static let turn = 6.0
        private let wheel = CAGradientLayer()
        var turning = false {
            didSet { if turning != oldValue { restart() } }
        }

        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
            clipsToBounds = true
            wheel.type = .conic
            wheel.colors = Palette.foil.map { UIColor($0).cgColor }
            wheel.startPoint = CGPoint(x: 0.5, y: 0.5)
            wheel.endPoint = CGPoint(x: 1, y: 0.5)
            layer.addSublayer(wheel)
            // The system drops a layer's animations when the app leaves the screen.
            NotificationCenter.default.addObserver(self, selector: #selector(restart), name: UIApplication.didBecomeActiveNotification, object: nil)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }

        override func layoutSubviews() {
            super.layoutSubviews()
            // A square that still covers the corners at any angle.
            let side = hypot(bounds.width, bounds.height)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            wheel.bounds = CGRect(x: 0, y: 0, width: side, height: side)
            wheel.position = CGPoint(x: bounds.midX, y: bounds.midY)
            CATransaction.commit()
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            restart()
        }

        @objc private func restart() {
            wheel.removeAnimation(forKey: "turn")
            guard turning, window != nil else { return }
            let spin = CABasicAnimation(keyPath: "transform.rotation.z")
            spin.fromValue = 0
            spin.toValue = 2 * Double.pi
            spin.duration = Self.turn
            spin.repeatCount = .infinity
            // As far into its turn as the clock says, so a sticker's rim and the sheen over it
            // (two foils) turn as one.
            let into = Date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: Self.turn)
            spin.beginTime = wheel.convertTime(CACurrentMediaTime(), from: nil) - into
            spin.preferredFrameRateRange = CAFrameRateRange(minimum: 15, maximum: 30, preferred: 30)
            wheel.add(spin, forKey: "turn")
        }
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
