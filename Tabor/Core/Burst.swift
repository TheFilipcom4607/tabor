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
        /// No number, or a number shared by models the reveal has to ask about.
        public var needsYou = false
        /// Not in the book before the burst.
        public var isNew = false
        /// Due out in an event wrap that day: the photo may show it.
        public var mayWearWrap = false

        public init(index: Int, number: Int?, modelId: String?, tier: Tier?, score: Double = 0, hasSticker: Bool = false,
                    needsYou: Bool = false, isNew: Bool = false, mayWearWrap: Bool = false) {
            self.index = index
            self.number = number
            self.modelId = modelId
            self.tier = tier
            self.score = score
            self.hasSticker = hasSticker
            self.needsYou = needsYou
            self.isNew = isNew
            self.mayWearWrap = mayWearWrap
        }
    }

    /// The shots to show, by `index`, in the order to show them.
    ///
    /// Shots of one vehicle become one card, from the clearest read (then the one with a
    /// sticker, then the first): holding the shutter on a bus is more tries at its number.
    /// Shots that read nothing stay a card each. Cards you have to answer come first, so they
    /// don't spoil the end; then commons up to legendaries, a vehicle already in the book
    /// before a new one, and a vehicle that may be in a wrap at the very end.
    public static func cards(_ shots: [Shot]) -> [Int] {
        var best: [String: Shot] = [:]
        var loose: [Shot] = []
        for shot in shots {
            guard let number = shot.number else { loose.append(shot); continue }
            let key = "\(number)|\(shot.modelId ?? "?")"
            if let kept = best[key], !better(shot, than: kept) { continue }
            best[key] = shot
        }
        return (Array(best.values) + loose).sorted { order($0) < order($1) }.map(\.index)
    }

    private static func better(_ a: Shot, than b: Shot) -> Bool {
        (a.score, a.hasSticker ? 1 : 0, -a.index) > (b.score, b.hasSticker ? 1 : 0, -b.index)
    }

    private static func order(_ s: Shot) -> (Int, Int, Int, Int, Int) {
        // Vintage, test and works stock rank with the legendaries, as on HUNT.
        let rarity = s.tier.map(Wanted.huntRank) ?? Tier.common.rank
        return (s.needsYou ? 0 : 1, s.mayWearWrap ? 1 : 0, -rarity, s.isNew ? 1 : 0, s.index)
    }
}
