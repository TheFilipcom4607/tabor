import Foundation

/// How BOOK lists its models (#99). Stored under `bookOrder`, so the raw values stay.
public enum BookOrder: String, CaseIterable, Sendable {
    /// Models you've started first, most complete first; then the rest, rarest first.
    case progress
    /// Caught models first, rarest first; then the rest, rarest first.
    case rarity
    /// The model of your latest catch first; then the rest, rarest first.
    case newest

    public var name: String {
        switch self {
        case .progress: String(localized: "Progress", comment: "Book order: most complete first")
        case .rarity: String(localized: "Rarity", comment: "Book order: rarest first")
        case .newest: String(localized: "Latest catch", comment: "Book order: newest catch first")
        }
    }

    public func sort(_ models: [VehicleModel], stats: CollectionStats) -> [VehicleModel] {
        // Each model's newest catch, worked out once rather than in every comparison.
        let latest = self == .newest
            ? Dictionary(uniqueKeysWithValues: models.compactMap { m in
                stats.owned(modelId: m.id).map(\.lastSeen).max().map { (m.id, $0) }
            })
            : [:]
        return models.sorted { a, b in
            let oa = stats.ownedCount(modelId: a.id), ob = stats.ownedCount(modelId: b.id)
            if (oa > 0) != (ob > 0) { return oa > 0 }
            if oa > 0 {
                switch self {
                case .progress:
                    let pa = Double(oa) / Double(a.fleet), pb = Double(ob) / Double(b.fleet)
                    if pa != pb { return pa > pb }
                case .newest:
                    if let la = latest[a.id], let lb = latest[b.id], la != lb { return la > lb }
                case .rarity:
                    break
                }
            }
            return Self.rarer(a, b)
        }
    }

    /// Legendary to common, then the smaller fleet. Vintage, on test and works sit after
    /// common, though BOOK lists them in sections of their own anyway.
    static func rarer(_ a: VehicleModel, _ b: VehicleModel) -> Bool {
        let ta = Tier.allCases.firstIndex(of: a.tier)!, tb = Tier.allCases.firstIndex(of: b.tier)!
        if ta != tb { return ta < tb }
        if a.fleet != b.fleet { return a.fleet < b.fleet }
        return a.name < b.name
    }
}
