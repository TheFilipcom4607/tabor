import Foundation

/// When TABOR asks for a tip: right after a catch worth celebrating, never more than three
/// times, and two weeks apart at least, so a supporter-to-be gets asked at a happy moment and
/// everyone else is left alone.
public enum SupportAsk {
    public enum Reason: Hashable, Sendable {
        case firstLegendary
        case newBadge
        /// The catch that reached this many.
        case milestone(Int)
        /// The card on ME.
        case meCard
    }

    public static let milestones = [50, 150, 500]
    public static let maxAsks = 3
    public static let gap: TimeInterval = 14 * 24 * 3600

    /// What makes this catch worth asking on, if anything. `catches` leave second cars out,
    /// as the stats do; the other vehicles in a shot count.
    public static func reason(catchesBefore: Int, catchesAfter: Int, firstLegendary: Bool) -> Reason? {
        if firstLegendary { return .firstLegendary }
        return milestones.first { catchesBefore < $0 && $0 <= catchesAfter }.map(Reason.milestone)
    }

    /// The first legendary: one in this catch, none in the book before it.
    public static func isFirstLegendary(before: CollectionStats, caught modelIds: [String], catalog: FleetCatalog) -> Bool {
        let legendary = { (id: String) in catalog.model(id: id)?.tier == .legendary }
        return modelIds.contains(where: legendary) && !before.vehicles.contains { legendary($0.modelId) }
    }

    /// `tipped` is a real tip, not debug builds' stand-in supporter, so they still get asked.
    public static func due(asks: Int, lastAsked: Date?, now: Date, tipped: Bool) -> Bool {
        guard !tipped, asks < maxAsks else { return false }
        return lastAsked.map { now.timeIntervalSince($0) >= gap } ?? true
    }
}
