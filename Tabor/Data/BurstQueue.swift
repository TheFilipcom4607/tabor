import SwiftUI

/// Rapid fire's shots (and the Lock Screen camera's), read one at a time in the background
/// while you carry on shooting, then dealt out as cards (`Burst`) once you're done.
@Observable @MainActor
final class BurstQueue {
    struct Shot: Identifiable {
        let id = UUID()
        var thumb: UIImage?
        var draft: CatchDraft?
    }

    private(set) var shots: [Shot] = []
    /// Reads one shot after another, so a long burst doesn't heat the phone.
    @ObservationIgnored private var tail: Task<Void, Never>?

    /// Made with the `Router`, which isn't tied to the main actor.
    nonisolated init() {}

    var count: Int { shots.count }
    var isEmpty: Bool { shots.isEmpty }
    /// Shots still being read.
    var reading: Int { shots.count { $0.draft == nil } }

    /// Everything about the shot that was true at the shutter goes in with it: the place being
    /// worked out, the vehicles around, the date.
    func add(_ data: Data, fromCamera: Bool, date: Date, mode: CatchMode, nearby: [NearbyVehicle],
             geotag: Task<Geotag?, Never>?, record: DebugRecord?, manual: [Int: String]) {
        let shot = Shot()
        let id = shot.id
        shots.append(shot)
        Task {
            let thumb = await CatchReader.preview(data)
            update(id) { $0.thumb = thumb }
        }
        let previous = tail
        tail = Task {
            await previous?.value
            var d = await CatchReader.read(data, fromCamera: fromCamera, date: date, record: record, nearby: nearby, mode: mode,
                                           manual: manual)
            d.date = date
            d.geotag = geotag
            d.preview = await CatchReader.preview(data)
            update(id) { $0.draft = d }
        }
    }

    /// The cards to show, in order, once every shot is read and cut; the queue starts over.
    /// `book` is everything caught before these.
    func finish(book: [Sighting]) async -> [CatchDraft] {
        await tail?.value
        let drafts = shots.compactMap(\.draft)
        shots = []
        tail = nil
        guard !drafts.isEmpty else { return [] }
        let catalog = Fleet.catalog
        let stats = book.stats
        var order: [Burst.Shot] = []
        for (i, d) in drafts.enumerated() {
            let model = d.modelId.flatMap(catalog.model(id:))
            let score = await d.photoRead?.value.candidates.first { $0.number == d.number }?.score ?? 0
            let sticker = await d.sticker?.value != nil
            order.append(Burst.Shot(
                index: i, number: d.number, modelId: d.modelId, tier: model?.tier, score: score, hasSticker: sticker,
                needsYou: d.number == nil || model == nil,
                isNew: d.number.map { n in model.map { stats.vehicle(number: n, modelId: $0.id) == nil } ?? true } ?? true,
                mayWearWrap: d.number.map { n in model.map { !catalog.wraps(kind: $0.kind, number: n, on: d.date).isEmpty } ?? false } ?? false))
        }
        let dates = book.map(\.date)
        return Burst.cards(order).map { i in
            var d = drafts[i]
            d.book = BookBefore(stats: stats, streak: Streak.days(dates + [d.date]))
            return d
        }
    }

    /// Thrown away: the shots aren't caught.
    func discard() {
        tail?.cancel()
        tail = nil
        shots = []
    }

    private func update(_ id: UUID, _ change: (inout Shot) -> Void) {
        guard let i = shots.firstIndex(where: { $0.id == id }) else { return }
        change(&shots[i])
    }
}
