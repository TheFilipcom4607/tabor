import Foundation

/// czynaczas.pl's remark on one vehicle ("Autobus testowy odkupiony od Solarisa…"), shown on the
/// vehicle page with its credit. Partner data: the proxy hands it out one vehicle at a time and
/// keeps no list, so this asks only when a page opens. Most vehicles have none.
struct VehicleRemark: Hashable {
    let text: String
    /// Set when the remark is the coupled set's, filed under the other car.
    let fromCar: Int?
}

enum RemarkService {
    /// Asked once per vehicle per launch; the proxy's day-long Cache-Control covers relaunches.
    @MainActor private static var known: [String: String?] = [:]

    /// The vehicle's own remark, else (for a coupled tram) its set's, filed under the other car.
    @MainActor
    static func remark(kind: VehicleKind, number: Int, model: VehicleModel?) async -> VehicleRemark? {
        if let text = await fetch(kind: kind, number: number) { return VehicleRemark(text: text, fromCar: nil) }
        // A fixed set (KMKM's 1252+1251) even in a model that isn't coupled; else the usual partner.
        guard let model,
              let partner = model.fixedPartner(of: number) ?? (model.coupled ? model.usualPartners(of: number).first : nil),
              let text = await fetch(kind: kind, number: partner) else { return nil }
        return VehicleRemark(text: text, fromCar: partner)
    }

    @MainActor
    private static func fetch(kind: VehicleKind, number: Int) async -> String? {
        let key = "\(kind == .tram ? "tram" : "bus")/\(number)"
        if let hit = known[key] { return hit }
        guard !FleetNumber.isCoded(number),
              let url = LiveFleetService.proxy?.deletingLastPathComponent().appendingPathComponent("remarks/\(key)") else { return nil }
        struct Reply: Decodable { let remark: String? }
        guard let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let reply = try? JSONDecoder().decode(Reply.self, from: data) else { return nil }
        // Only real answers are kept: a 429 or a dropped connection asks again next time.
        let text = reply.remark?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        known[key] = .some(text)
        return text
    }
}
