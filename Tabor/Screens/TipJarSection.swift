import StoreKit
import SwiftUI

/// Once you've caught a fair few, ME asks once whether you'd like to leave a tip: a card that
/// opens the tip sheet or goes away for good. Never to anyone who has tipped, and never in the
/// middle of a catch. It counts as one of `SupportAsk`'s three asks.
enum SupportTip {
    static let seenKey = "supportTipSeen"
    static let afterCatches = 25
}

/// What it costs and what a tip gives, said the same way on the tip sheet and in Settings.
enum SupportCopy {
    static var cost: String {
        String(localized: "TABOR costs about 55 zł a month to run: the server behind HUNT's live map and Apple's developer fee. It's free with no ads, so tips are what keep it going.")
    }
    static var perks: String {
        String(localized: "Any tip puts a heart next to ME, unlocks three extra app icons and a gold rim on the cards you share.")
    }
}

/// Buying a tip and what's said after, for whichever screen shows the tips: the alert hangs
/// off the screen (`tipAlert`), the rows (`TipRows`) just buy.
@MainActor @Observable
final class TipCheckout {
    var message: String?
    /// "Thank you" only heads the alert when a tip went through or a restore found one.
    var thanks = false

    func buy(_ product: Product) async {
        let jar = TipJar.shared
        let wasSupporter = jar.isSupporter
        let outcome = await jar.buy(product)
        thanks = outcome == .thanks
        switch outcome {
        case .thanks:
            Haptics.shared.completed()
            message = wasSupporter ? String(localized: "Thanks for the tip! 💛")
                : String(localized: "You're a supporter now. Thank you! 💛")
        case .pending:
            message = String(localized: "Waiting for approval. The heart appears once it goes through.")
        case .failed:
            message = String(localized: "That didn't go through. You weren't charged.")
        case .cancelled: break
        }
    }

    func restore() async {
        let jar = TipJar.shared
        switch await jar.restore() {
        case .done:
            thanks = jar.isSupporter
            message = jar.isSupporter ? String(localized: "You're a supporter. Thank you! 💛")
                : String(localized: "No tips found on this Apple account.")
        case .failed:
            thanks = false
            message = String(localized: "Couldn't reach the App Store. Try again later.")
        case .cancelled: break
        }
    }
}

extension View {
    /// The checkout's alert. `afterThanks` runs once a thank-you is closed.
    func tipAlert(_ checkout: TipCheckout, afterThanks: @escaping () -> Void = {}) -> some View {
        alert(checkout.thanks ? "Thank you" : "Support TABOR",
              isPresented: Binding(get: { checkout.message != nil }, set: { if !$0 { checkout.message = nil } })) {
            Button("OK") { if checkout.thanks { afterThanks() } }
        } message: {
            Text(checkout.message ?? "")
        }
    }
}

/// The three tips, cheapest first: list rows in Settings, cards on the tip sheet.
struct TipRows: View {
    let checkout: TipCheckout
    var cards = false
    private var jar: TipJar { .shared }

    var body: some View {
        if jar.products.isEmpty {
            HStack {
                Text(jar.loadFailed ? "Tips aren't available right now." : "Loading…")
                    .foregroundStyle(Palette.sub)
                Spacer()
                if !jar.loadFailed { ProgressView().controlSize(.small) }
            }
            .modifier(CardRow(on: cards))
        }
        ForEach(jar.products) { product in
            row(product)
        }
    }

    private func row(_ product: Product) -> some View {
        let owned = product.id == TipJar.supporterID && jar.ownsSupporter
        return Button {
            Task { await checkout.buy(product) }
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(product.displayName).foregroundStyle(Palette.ink)
                    Text(product.description).font(.footnote).foregroundStyle(Palette.sub)
                }
                // Wrapped, not cut off: the sheet takes its height from what's in it.
                .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                if jar.buying == product.id {
                    ProgressView().controlSize(.small)
                } else if owned {
                    Image(systemName: "checkmark").foregroundStyle(Palette.green)
                } else {
                    Text(product.displayPrice)
                        .font(TaborFont.mono(13, 700))
                        .foregroundStyle(Palette.bg)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        // One width for all three, so the prices line up.
                        .frame(minWidth: 104)
                        .background(Palette.yellow, in: Capsule())
                }
            }
            .contentShape(Rectangle())
            .modifier(CardRow(on: cards))
        }
        .buttonStyle(.plain)
        .disabled(owned || jar.buying != nil)
    }

    private struct CardRow: ViewModifier {
        let on: Bool

        func body(content: Content) -> some View {
            if on {
                content
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                    .background(Palette.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            } else {
                content
            }
        }
    }
}

/// Settings › Support TABOR: three tips. Any tip unlocks three extra app icons (#62); badges and
/// everything else stay free.
struct TipJarSection: View {
    @State private var checkout = TipCheckout()
    @State private var restoring = false

    var body: some View {
        Section {
            TipRows(checkout: checkout)
            Button(restoring ? "Restoring…" : "Restore purchases") {
                restoring = true
                Task {
                    await checkout.restore()
                    restoring = false
                }
            }
            .disabled(restoring)
        } header: {
            Text("Support TABOR")
        } footer: {
            Text(SupportCopy.cost) + Text(" ") + Text(SupportCopy.perks)
                + Text(" ") + Text("Badges and everything else stay free.")
        }
        .task { await TipJar.shared.load() }
        .tipAlert(checkout)
    }
}
