import Foundation

/// Shots taken one after another (rapid fire, or the Lock Screen camera), dealt out as cards
/// once you're done: one per vehicle, and the rarest last, so the best is saved for the end.
public enum Burst {
    /// What the order needs to know about a shot once it's been read.
    public struct Shot: Sendable, Equatable {
        /// When it was taken among the others.
        public var index: Int
        public var number: Int?
        /// Nil when nothing settled it (nothing read, or "Which one is it?").
        public var modelId: String?
        public var tier: Tier?
        /// The read's best candidate score; 0 when nothing was read.
        public var score: Double = 0
        public var hasSticker = false
        /// How whole the sticker's vehicle looks (`CutShape.quality`), when a sticker was cut.
        public var cut: Double?
        /// No number, or a number shared by models the reveal has to ask about.
        public var needsYou = false
        /// Not in the book before the burst.
        public var isNew = false
        /// Due out in an event wrap that day: the photo may show it.
        public var mayWearWrap = false

        public init(index: Int, number: Int?, modelId: String?, tier: Tier?, score: Double = 0, hasSticker: Bool = false,
                    cut: Double? = nil, needsYou: Bool = false, isNew: Bool = false, mayWearWrap: Bool = false) {
            self.index = index
            self.number = number
            self.modelId = modelId
            self.tier = tier
            self.score = score
            self.hasSticker = hasSticker
            self.cut = cut
            self.needsYou = needsYou
            self.isNew = isNew
            self.mayWearWrap = mayWearWrap
        }
    }

    /// One card: the shots of one vehicle, in the order they were taken, and the one it shows.
    public struct Card: Sendable, Equatable {
        public var shown: Int
        public var shots: [Int]

        public init(shown: Int, shots: [Int]) {
            self.shown = shown
            self.shots = shots
        }
    }

    /// The cards to deal, in the order to deal them, by `index`.
    ///
    /// Shots of one vehicle become one card, showing the most whole sticker of it (see `best`):
    /// holding the shutter on a bus is more tries at it, and the card can still switch to the
    /// others. Shots that read nothing stay a card each. Cards you have to answer come first,
    /// so they don't spoil the end; then commons up to legendaries, a vehicle already in the
    /// book before a new one, and a vehicle that may be in a wrap at the very end.
    public static func deal(_ shots: [Shot]) -> [Card] {
        var groups: [String: [Shot]] = [:]
        var keys: [String] = []
        var loose: [Shot] = []
        for shot in shots {
            guard let number = shot.number else { loose.append(shot); continue }
            let key = "\(number)|\(shot.modelId ?? "?")"
            if groups[key] == nil { keys.append(key) }
            groups[key, default: []].append(shot)
        }
        let cards = keys.map { key in
            let group = groups[key]!.sorted { $0.index < $1.index }
            return (shown: best(of: group), shots: group.map(\.index))
        } + loose.map { (shown: $0, shots: [$0.index]) }
        return cards.sorted { order($0.shown) < order($1.shown) }.map { Card(shown: $0.shown.index, shots: $0.shots) }
    }

    /// The shots to show, by `index`, in the order to show them: each card's own.
    public static func cards(_ shots: [Shot]) -> [Int] { deal(shots).map(\.shown) }

    /// Cut-outs this close in `CutShape.quality` count as equally whole; the number's read
    /// settles it then.
    static let cutMargin = 0.03

    /// The shot a card shows. The read used to decide alone, and the biggest, clearest number
    /// won even when bushes had eaten half the bus. Now the most whole sticker does, and among
    /// those about as whole, the clearest read (then a sticker at all, then the first).
    static func best(of group: [Shot]) -> Shot {
        let whole = group.compactMap(\.cut).max()
        let fair = whole.map { q in group.filter { ($0.cut ?? -.infinity) >= q - cutMargin } } ?? group
        return fair.max { a, b in
            (a.score, a.hasSticker ? 1 : 0, -a.index) < (b.score, b.hasSticker ? 1 : 0, -b.index)
        }!
    }

    private static func order(_ s: Shot) -> (Int, Int, Int, Int, Int) {
        // Vintage, test and works stock rank with the legendaries, as on HUNT.
        let rarity = s.tier.map(Wanted.huntRank) ?? Tier.common.rank
        return (s.needsYou ? 0 : 1, s.mayWearWrap ? 1 : 0, -rarity, s.isNew ? 1 : 0, s.index)
    }
}
