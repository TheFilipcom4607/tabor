import SwiftUI

/// Turns a photo into a catch draft: the number, the model, the line and the sticker. Shared by
/// CATCH's single shots, rapid fire and the Lock Screen camera's shots.
@MainActor
enum CatchReader {
    /// Reads the number, matches it and starts the sticker: everything in a draft that comes
    /// from the photo itself.
    static func read(_ data: Data, fromCamera: Bool, record: DebugRecord?, nearby: [NearbyVehicle],
                     mode: CatchMode, manual: [Int: String]) async -> CatchDraft {
        let live = LiveFleetService.shared, catalog = Fleet.catalog
        record?.attach(photo: data)
        // The read also says where the number is, so the sticker keeps the object it's on.
        let ocr = Task.detached(priority: .userInitiated) {
            await TextReader.read(data, mode: mode, nearby: nearby)
        }
        // Lift the subjects at once (quicker than OCR), then cut once the number's box is known.
        let sticker = Task.detached(priority: .userInitiated) { () -> StickerCut? in
            var spent: TimeInterval = 0
            var start = Date()
            let lifted = StickerMaker.lift(data)
            spent += Date().timeIntervalSince(start)
            var box: CGRect?
            var result: Result<StickerCut, StickerMaker.Failure>
            switch lifted {
            case .failure(let f):
                result = .failure(f)
            case .success(let lift):
                box = await ocr.value.numberBox
                start = Date()
                result = StickerCut.make(lift, numberBox: box)
                spent += Date().timeIntervalSince(start)
            }
            let cut = try? result.get()
            if let record {
                let ms = Int(spent * 1000)
                let failure: String? = if case .failure(let f) = result { f.description } else { nil }
                record.update {
                    $0.sticker = .init(ok: cut != nil, durationMs: ms, failure: failure, pickedBy: cut?.reason.rawValue,
                                       subjects: cut?.order.count, numberBox: box.map(DebugRecord.describe))
                }
                if let png = cut?.png { record.attach(sticker: png) }
            }
            return cut
        }
        var liveInfo = DebugRecord.Live(status: "\(live.status)",
                                        snapshotAge: live.snapshot.map { Int(Date().timeIntervalSince($0.fetched)) },
                                        nearby: nearby.map { "\($0.vehicle.kind.rawValue) \($0.vehicle.number) · line \($0.vehicle.line) · \(Int($0.distance)) m" })
        let report = await ocr.value
        let number = report.number
        let photoNumbers = report.candidates.sorted { $0.score > $1.score }.map(\.number)
        liveInfo.boosted = report.live.boosted
        liveInfo.rescued = report.live.rescued
        liveInfo.partners = report.live.partners
        record?.update { $0.ocr = DebugRecord.ocr(report) }
        var d = CatchDraft(photo: data, number: number, fromCamera: fromCamera, sticker: sticker, debug: record)
        d.nearby = nearby
        d.mode = mode
        d.photoNumbers = Task { photoNumbers }
        d.photoRead = ocr
        if let n = number {
            let plain = catalog.match(number: n, preferring: mode.kind, manual: manual)
            let match = lookup(n, mode: mode, nearby: nearby, manual: manual)
            if match != plain { liveInfo.resolved = "\(DebugRecord.describe(plain)) → \(DebugRecord.describe(match))" }
            // An import never has the feed to settle bus 2021 vs tram 2021, and a guess showed a
            // bus as a tram with full confidence (#66).
            if case .ambiguous(let ms) = match { d.choices = ms }
            let picked = d.choices.isEmpty ? match.suggested : nil
            d.modelId = picked?.id
            if fromCamera, let model = picked {
                let snapshot = live.snapshot
                d.line = LiveHints.line(for: n, kind: model.kind, snapshot: snapshot, at: d.date, model: model, nearby: nearby,
                                        catalog: catalog)
                d.autoLine = d.line
                // "set": borrowed from the coupled car the feed reports instead.
                liveInfo.lineSource = d.line == nil ? "none" : snapshot?.vehicle(number: n, kind: model.kind) == nil ? "set" : "live"
            }
            if let model = picked {
                d.partnerSuggestions = CoupledSet.suggestions(for: n, model: model, photoNumbers: photoNumbers, nearby: nearby,
                                                              catalog: catalog)
            }
            let described = DebugRecord.describe(match), suggested = d.modelId
            record?.update {
                $0.match = described
                $0.suggestedModel = suggested
            }
        }
        if fromCamera {
            let info = liveInfo
            record?.update { $0.live = info }
        }
        return d
    }

    /// The database match, settled by the live feed when only one kind with that number is
    /// running nearby. A model you picked by hand for this number always wins.
    static func lookup(_ n: Int, mode: CatchMode, nearby: [NearbyVehicle], manual: [Int: String]) -> ModelMatch {
        let catalog = Fleet.catalog
        let m = catalog.match(number: n, preferring: mode.kind, manual: manual)
        guard manual[n] == nil else { return m }
        return LiveHints.resolve(m, number: n, nearby: nearby, catalog: catalog)
    }

    /// A screen-sized copy, for the reveal and the thumbnails.
    nonisolated static func preview(_ data: Data) async -> UIImage? {
        await Task.detached(priority: .userInitiated) {
            PhotoStore.downsample(data, maxPixel: 900).map(UIImage.init(cgImage:))
        }.value
    }
}
