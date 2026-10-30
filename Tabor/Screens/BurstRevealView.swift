import SwiftData
import SwiftUI

/// One card of a burst, handed to its `RevealView`.
struct BurstStep {
    let index: Int
    let count: Int
    /// The catch as it went into the book, or nil when it was skipped.
    let done: (CatchDraft?) -> Void
}

/// A burst's shots, read, grouped and ordered (`BurstQueue.finish`), ready to deal out.
struct BurstCards: Identifiable {
    let id = UUID()
    let drafts: [CatchDraft]
}

/// Rapid fire's shots (or the Lock Screen camera's) dealt out one card at a time, rarest last,
/// then what the lot added up to.
struct BurstRevealView: View {
    let cards: BurstCards
    var reread: (CatchDraft, Data) async -> CatchDraft
    @State private var current: [CatchDraft]
    @State private var index = 0
    @State private var stuck: [CatchDraft] = []
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(Router.self) private var router

    init(cards: BurstCards, reread: @escaping (CatchDraft, Data) async -> CatchDraft) {
        self.cards = cards
        self.reread = reread
        _current = State(initialValue: cards.drafts)
    }

    var body: some View {
        ZStack {
            Palette.bg.ignoresSafeArea()
            if index < current.count {
                RevealView(draft: current[index], reread: reread,
                           step: BurstStep(index: index, count: current.count, done: next))
                    .id(index)
                    .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .opacity))
            } else {
                BurstSummary(before: cards.drafts.first?.book.stats ?? CollectionStats(sightings: []), stuck: stuck) {
                    dismiss()
                } openBook: { modelId in
                    router.openModel(modelId)
                }
                .transition(.opacity)
            }
        }
        .onAppear { router.revealShown() }
        .onDisappear { router.revealGone() }
    }

    private func next(_ draft: CatchDraft?) {
        if let draft { stuck.append(draft) }
        let n = index + 1
        guard n < current.count || !stuck.isEmpty else { return dismiss() }
        // The book moved on with the last card: "NEW MODEL" and "your 3rd" count from where it is now.
        if n < current.count, draft != nil {
            let all = (try? context.fetch(FetchDescriptor<Sighting>())) ?? []
            current[n].book = BookBefore(stats: all.stats, streak: Streak.days(all.map(\.date) + [current[n].date]))
        }
        withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) { index = n }
    }
}

/// The end of a burst: how many went in, what was new, and the rarest.
private struct BurstSummary: View {
    let before: CollectionStats
    let stuck: [CatchDraft]
    let done: () -> Void
    let openBook: (String) -> Void
    /// Each catch's sticker, or its photo where none was cut.
    @State private var cards: [(image: UIImage, sticker: Bool)] = []
    @State private var shown = false

    private let catalog = Fleet.catalog

    var body: some View {
        let models = stuck.compactMap { $0.modelId.flatMap(catalog.model(id:)) }
        let newVehicles = Set(stuck.compactMap { d in
            d.number.flatMap { n in d.modelId.flatMap { before.vehicle(number: n, modelId: $0) == nil ? "\($0)#\(n)" : nil } }
        }).count
        let newModels = Set(models.map(\.id).filter { before.ownedCount(modelId: $0) == 0 }).count
        let rarest = models.min { Wanted.huntRank($0.tier) < Wanted.huntRank($1.tier) }

        VStack(alignment: .leading, spacing: 0) {
            Mono("\(stuck.count) CAUGHT", size: 12, spacing: 0.16, color: Palette.yellow)
                .padding(.top, 34)
            Text("All in the book")
                .font(TaborFont.grotesk(30, 700))
                .em(-0.03, size: 30)
                .padding(.top, 7)

            fan
                .frame(maxWidth: .infinity)
                .frame(height: 250)
                .padding(.top, 12)

            HStack(spacing: 10) {
                StatTile(label: String(localized: "burst.new", defaultValue: "NEW", comment: "Burst summary tile: vehicles new to the book"),
                         value: "\(newVehicles)", valueColor: newVehicles > 0 ? Palette.yellow : Palette.ink,
                         caption: PluralCaption.vehicles(newVehicles), stretch: true)
                StatTile(label: String(localized: "MODEL"), value: "\(newModels)",
                         valueColor: newModels > 0 ? Palette.green : Palette.ink,
                         caption: PluralCaption.newModels(newModels), stretch: true)
                if let rarest {
                    StatTile(label: String(localized: "RAREST", comment: "Burst summary tile: the rarest catch"),
                             value: rarest.tier.name, valueColor: rarest.tier == .common ? Palette.ink : rarest.tier.color,
                             valueSize: 16, caption: rarest.name, stretch: true)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : 14)

            Spacer(minLength: 16)

            VStack(spacing: 10) {
                Button(action: done) {
                    Text("Done")
                        .font(TaborFont.grotesk(16, 700))
                        .frame(maxWidth: .infinity)
                        .padding(17)
                        .foregroundStyle(Palette.bg)
                        .background(Palette.yellow, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .buttonStyle(StickerPressStyle())
                if let rarest {
                    Button { openBook(rarest.id) } label: {
                        Mono("SEE IT IN THE BOOK", size: 12.5, color: Palette.sub)
                            .frame(maxWidth: .infinity)
                            .padding(14)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.bottom, 20)
        }
        .foregroundStyle(Palette.ink)
        .padding(.horizontal, 26)
        .task {
            var found: [(UIImage, Bool)] = []
            for d in stuck {
                if let png = await d.sticker?.value?.png, let img = UIImage(data: png) { found.append((img, true)) }
                else if let preview = d.preview { found.append((preview, false)) }
            }
            cards = found
            Haptics.shared.completed()
            withAnimation(.spring(response: 0.5, dampingFraction: 0.65)) { shown = true }
        }
    }

    /// The burst's stickers fanned out like a hand of cards, the rarest (dealt last) on top.
    private var fan: some View {
        let hand = Array(cards.suffix(7))
        let mid = Double(hand.count - 1) / 2
        return ZStack {
            ForEach(Array(hand.enumerated()), id: \.offset) { i, card in
                let spread = Double(i) - mid
                Group {
                    if card.sticker {
                        Image(uiImage: card.image).resizable().scaledToFit().frame(maxWidth: 210, maxHeight: 130)
                    } else {
                        // No cut-out: the photo as a card, like the reveal shows it.
                        Image(uiImage: card.image).resizable().scaledToFill()
                            .frame(width: 168, height: 115)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(.white, lineWidth: 3))
                    }
                }
                .shadow(color: .black.opacity(0.5), radius: 10, y: 10)
                .rotationEffect(.degrees(shown ? spread * 7 : 0), anchor: .bottom)
                .offset(x: shown ? spread * 26 : 0, y: shown ? abs(spread) * 8 : 40)
                .opacity(shown ? 1 : 0)
                .animation(.spring(response: 0.5, dampingFraction: 0.7).delay(0.06 * Double(i)), value: shown)
            }
        }
    }
}
