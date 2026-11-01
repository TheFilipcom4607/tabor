import SwiftUI

/// Rapid fire and the Lock Screen camera (#107): a page in the intro for new people, and for
/// everyone who had TABOR before, a card in CATCH's tip slot, once.
enum RapidTip {
    static let seenKey = "rapidTipSeen"
    static var kicker: String { String(localized: "RAPID FIRE") }
    static var title: String { String(localized: "Shoot first, look later.") }
    static var text: String {
        String(localized: "Turn on RAPID and fire away: the shots pile up while TABOR reads them, then you flip them over like cards, the rarest last. Put the Catch button on your Lock Screen and the camera opens without unlocking; unlock to reveal what you caught.")
    }
}

/// A locked phone fires three shots onto a stack, the cards are dealt face down and turned
/// over one by one, the rarest glowing last. Loops while `active`.
struct RapidArt: View {
    let active: Bool
    @State private var shots = 0
    @State private var dealt = false
    @State private var flipped = 0
    @State private var flash = false
    /// The round is over: the cards fade where they lie rather than fly back into the phone.
    @State private var cleared = false

    /// Laid out on a 340 × 230 board, scaled down to whatever room there is.
    private static let board = CGSize(width: 340, height: 230)
    private static let phoneAt = CGPoint(x: 92, y: 115)
    /// The developer's own catches: a common Urbino 18 (#8517), a rare Solcity 12 (#1075), and
    /// the Irizar that was on trial last, as the rarest.
    private static let stickers = ["IntroStickerCommon", "IntroStickerRare", "IntroStickerTest"]

    var body: some View {
        GeometryReader { g in
            let scale = min(1, g.size.width / Self.board.width, g.size.height / Self.board.height)
            ZStack {
                phone
                    .position(Self.phoneAt)
                    .opacity(dealt ? 0 : 1)
                    .scaleEffect(dealt ? 0.9 : 1)
                ForEach(0..<3, id: \.self) { i in
                    card(i)
                        .position(position(i))
                        .opacity(shots > i && !cleared ? 1 : 0)
                        .scaleEffect(shots > i ? (dealt ? 1 : 0.82) : 0.3)
                        .zIndex(Double(i))
                }
            }
            .frame(width: Self.board.width, height: Self.board.height)
            .scaleEffect(scale)
            .frame(width: g.size.width, height: g.size.height)
        }
        .accessibilityHidden(true)
        // Only once it's on screen: a TabView builds its neighbours early.
        .task(id: active) {
            guard active else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(700))
                for i in 0..<3 {
                    guard !Task.isCancelled else { return }
                    withAnimation(.easeOut(duration: 0.06)) { flash = true }
                    Haptics.shared.tick()
                    try? await Task.sleep(for: .milliseconds(90))
                    withAnimation(.easeOut(duration: 0.3)) { flash = false }
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.75)) { shots = i + 1 }
                    try? await Task.sleep(for: .milliseconds(520))
                }
                try? await Task.sleep(for: .milliseconds(500))
                withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) { dealt = true }
                try? await Task.sleep(for: .milliseconds(750))
                for i in 0..<3 {
                    guard !Task.isCancelled else { return }
                    withAnimation(.spring(response: 0.45, dampingFraction: 0.7)) { flipped = i + 1 }
                    if i == 2 { Haptics.shared.stick() } else { Haptics.shared.tick() }
                    try? await Task.sleep(for: .milliseconds(i == 2 ? 2400 : 650))
                }
                withAnimation(.easeOut(duration: 0.35)) { cleared = true }
                try? await Task.sleep(for: .milliseconds(400))
                var reset = Transaction()
                reset.disablesAnimations = true
                withTransaction(reset) { shots = 0; flipped = 0; cleared = false }
                withAnimation(.easeOut(duration: 0.3)) { dealt = false }
            }
        }
    }

    private func position(_ i: Int) -> CGPoint {
        if dealt { return CGPoint(x: 70 + CGFloat(i) * 100, y: 118) }
        if shots > i { return CGPoint(x: 248 + CGFloat(i) * 5, y: 118 - CGFloat(i) * 6) }
        return Self.phoneAt
    }

    /// The Lock Screen camera, small: a padlock, a clock, brackets, a shutter.
    private var phone: some View {
        let body = RoundedRectangle(cornerRadius: 22, style: .continuous)
        return ZStack {
            body.fill(Palette.card).overlay(body.stroke(Color.white.opacity(0.14), lineWidth: 1.5))
            VStack(spacing: 6) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Palette.sub)
                    .padding(.top, 16)
                Text(verbatim: "10:43")
                    .font(TaborFont.grotesk(22, 600))
                    .foregroundStyle(Palette.ink)
                Spacer()
                RoundedRectangle(cornerRadius: 4)
                    .stroke(Palette.yellow, style: StrokeStyle(lineWidth: 1.5, dash: [8, 30]))
                    .frame(width: 70, height: 46)
                Spacer()
                Circle().fill(Palette.red)
                    .frame(width: 26, height: 26)
                    .overlay(Circle().stroke(.white.opacity(0.9), lineWidth: 2).padding(-4))
                    .scaleEffect(flash ? 0.85 : 1)
                    .padding(.bottom, 16)
            }
            body.fill(Color.white.opacity(flash ? 0.6 : 0))
        }
        .frame(width: 104, height: 196)
    }

    /// Face down, a yellow back with a question mark; face up, its sticker.
    private func card(_ i: Int) -> some View {
        let up = flipped > i
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        let rarest = i == 2
        return ZStack {
            shape.fill(Palette.yellow)
                .overlay(Mono("?", size: 30, weight: 700, spacing: 0, color: Palette.bg))
                .opacity(up ? 0 : 1)
            shape.fill(Palette.card)
                .overlay(shape.stroke(rarest ? Palette.yellow : Color.white.opacity(0.18), lineWidth: rarest ? 2 : 1))
                .overlay(Image(Self.stickers[i]).resizable().scaledToFit().padding(9))
                .rotation3DEffect(.degrees(180), axis: (x: 0, y: 1, z: 0))
                .opacity(up ? 1 : 0)
        }
        .frame(width: 88, height: 112)
        .shadow(color: rarest && up ? Palette.yellow.opacity(0.55) : .black.opacity(0.45), radius: rarest && up ? 16 : 8, y: 4)
        .rotation3DEffect(.degrees(up ? 180 : 0), axis: (x: 0, y: 1, z: 0))
        .overlay { if rarest && up { SparkleBurst(color: Palette.yellow) } }
    }
}

/// In CATCH's tip slot, once, for people who had TABOR before rapid fire.
struct RapidTipCard: View {
    var open: () -> Void
    var dismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: open) {
                HStack(spacing: 11) {
                    Image(systemName: "square.stack.3d.down.right.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Palette.bg)
                        .frame(width: 34, height: 34)
                        .background(Palette.yellow, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    VStack(alignment: .leading, spacing: 3) {
                        Mono("NEW: RAPID FIRE", size: 9.5, weight: 700, spacing: 0.12, color: Palette.yellow)
                        Text("Shoot a bunch, flip them like cards")
                            .font(TaborFont.grotesk(13.5, 600))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white.opacity(0.5))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white.opacity(0.6))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
        .padding(.vertical, 9)
        .padding(.leading, 9)
        .padding(.trailing, 6)
        .glass(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

/// The intro page's art and words, from the card: with a button that turns rapid fire on, and
/// the way to the Lock Screen button.
struct RapidTipSheet: View {
    @AppStorage("rapidFire") private var rapid = false
    @State private var howTo = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Capsule().fill(Palette.track).frame(width: 36, height: 4)
                .frame(maxWidth: .infinity)
                .padding(.top, 10)
            RapidArt(active: true)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Mono(RapidTip.kicker, size: 11, weight: 600, spacing: 0.16, color: Palette.yellow)
            Text(RapidTip.title)
                .font(TaborFont.grotesk(28, 700))
                .em(-0.03, size: 28)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 10)
            Text(RapidTip.text)
                .font(TaborFont.grotesk(15))
                .foregroundStyle(Palette.sub)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 10)
            Button {
                Haptics.shared.tick()
                rapid = true
                dismiss()
            } label: {
                Mono(rapid ? "IT'S ON" : "TURN ON RAPID FIRE", size: 13, weight: 700, spacing: 0.14, color: Palette.bg)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 17)
                    .background(Palette.yellow, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .buttonStyle(StickerPressStyle())
            .padding(.top, 22)
            Button { howTo = true } label: {
                Mono("PUT CATCH ON THE LOCK SCREEN", size: 12, color: Palette.sub)
                    .frame(maxWidth: .infinity)
                    .padding(14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 12)
        .foregroundStyle(Palette.ink)
        .presentationDetents([.large])
        .presentationBackground(Palette.bg)
        .sheet(isPresented: $howTo) { CatchControlHowTo() }
    }
}
