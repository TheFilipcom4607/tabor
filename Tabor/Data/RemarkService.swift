import Foundation

/// czynaczas.pl's remark on one vehicle ("Autobus testowy odkupiony od Solarisa…"), shown on the
/// vehicle page with its credit. Partner data: the proxy hands it out one vehicle at a time and
/// keeps no list, so this asks only when a page opens. Most vehicles have none.
struct VehicleRemark: Hashable {
    /// As czynaczas.pl wrote it.
    let text: String
    /// Translated by hand for TABOR (czynaczas allows it, credited); nil until someone has.
    let english: String?
    /// Set when the remark is the coupled set's, filed under the other car.
    let fromCar: Int?
}

enum RemarkService {
    /// Asked once per vehicle per launch.
    @MainActor private static var known: [String: Note?] = [:]
    private struct Note: Decodable, Hashable {
        let remark: String?
        let remarkEn: String?
    }

    /// The vehicle's own remark, else (for a coupled tram) its set's, filed under the other car.
    @MainActor
    static func remark(kind: VehicleKind, number: Int, model: VehicleModel?) async -> VehicleRemark? {
        if let note = await fetch(kind: kind, number: number) { return remark(note, fromCar: nil) }
        // A fixed set (KMKM's 1252+1251) even in a model that isn't coupled; else the usual partner.
        guard let model,
              let partner = model.fixedPartner(of: number) ?? (model.coupled ? model.usualPartners(of: number).first : nil),
              let note = await fetch(kind: kind, number: partner) else { return nil }
        return remark(note, fromCar: partner)
    }

    private static func remark(_ note: Note, fromCar: Int?) -> VehicleRemark? {
        let text = note.remark?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        let english = note.remarkEn?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        return text.map { VehicleRemark(text: $0, english: english, fromCar: fromCar) }
    }

    @MainActor
    private static func fetch(kind: VehicleKind, number: Int) async -> Note? {
        let key = "\(kind == .tram ? "tram" : "bus")/\(number)"
        if let hit = known[key] { return hit }
        guard !FleetNumber.isCoded(number),
              let url = LiveFleetService.proxy?.deletingLastPathComponent().appendingPathComponent("remarks/\(key)") else { return nil }
        // Fresh each launch rather than from the URL cache: a day-old copy would hide a new translation.
        let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let reply = try? JSONDecoder().decode(Note.self, from: data) else { return nil }
        // Only real answers are kept: a 429 or a dropped connection asks again next time.
        let note = reply.remark == nil ? nil : reply
        known[key] = .some(note)
        return note
    }
}
