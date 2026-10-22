import SwiftUI

/// The ask itself: a short sheet after a catch worth celebrating (`SupportAsk`), or from ME's
/// card. What TABOR costs, the three tips, what a tip gives, and a way out.
struct TipSheet: View {
    let reason: SupportAsk.Reason
    @Environment(\.dismiss) private var dismiss
    @State private var checkout = TipCheckout()
    @State private var height: CGFloat = 480

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "heart.fill")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(Palette.bg)
                    .frame(width: 40, height: 40)
                    .background(Palette.yellow, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Mono(kicker, size: 10, weight: 700, spacing: 0.12, color: Palette.yellow)
                    Text("Keep TABOR going")
                        .font(TaborFont.grotesk(22, 700))
                        .em(-0.02, size: 22)
                        .foregroundStyle(Palette.ink)
                }
            }
            Text(SupportCopy.cost)
                .font(TaborFont.grotesk(14.5))
                .foregroundStyle(Palette.routeInk)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 14)
            VStack(spacing: 8) {
                TipRows(checkout: checkout, cards: true)
            }
            .padding(.top, 16)
            Text(SupportCopy.perks)
                .font(TaborFont.grotesk(12.5))
                .foregroundStyle(Palette.sub)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 12)
            Button {
                dismiss()
            } label: {
                Mono("NOT NOW", size: 11.5, weight: 600, spacing: 0.12, color: Palette.sub)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.top, 6)
        }
        .padding(.horizontal, 22)
        .padding(.top, 26)
        .padding(.bottom, 4)
        // As tall as it needs: half a screen in English, a little more in Polish.
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
        .presentationDetents([.height(height)])
        .presentationDragIndicator(.visible)
        .presentationBackground(Palette.bg)
        .environment(\.colorScheme, .dark)
        .task { await TipJar.shared.load() }
        .tipAlert(checkout) { dismiss() }
    }

    private var kicker: String {
        switch reason {
        case .firstLegendary: String(localized: "YOUR FIRST LEGENDARY")
        case .newBadge: String(localized: "NEW BADGE")
        case .milestone(let n): String(localized: "\(n) CATCHES")
        case .meCard: String(localized: "ENJOYING TABOR?")
        }
    }
}

/// How many times TABOR has asked, and when it last did (`SupportAsk`'s limits).
enum SupportAsks {
    static let countKey = "supportAsks"
    static let dateKey = "supportAskedAt"

    static var count: Int { UserDefaults.standard.integer(forKey: countKey) }

    @MainActor static var due: Bool {
        let last = UserDefaults.standard.object(forKey: dateKey) as? Double
        return SupportAsk.due(asks: count, lastAsked: last.map(Date.init(timeIntervalSince1970:)), now: Date(),
                              tipped: TipJar.shared.tipped)
    }

    static func record() {
        UserDefaults.standard.set(count + 1, forKey: countKey)
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: dateKey)
    }
}

extension SupportAsk.Reason: Identifiable {
    public var id: String {
        switch self {
        case .firstLegendary: "legendary"
        case .newBadge: "badge"
        case .milestone(let n): "milestone-\(n)"
        case .meCard: "me"
        }
    }
}
