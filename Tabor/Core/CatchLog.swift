import Foundation

/// The catch log on ME: every catch in the order it was made, newest first and grouped by day,
/// each marked as the first of its model, the first of its vehicle, or a vehicle seen again.
/// The book is sorted by model; this is the diary (asked for in TestFlight feedback).
public enum CatchLog {
    public enum Mark: Equatable, Sendable {
        /// `newForm`: a vehicle you had, caught in an event wrap for the first time.
        case newModel, newVehicle, newForm, again
    }

    /// One mark per record, in the order given, judged by what was caught before it.
    public static func marks(_ records: [SightingRecord]) -> [Mark] {
        var vehicles = Set<String>(), models = Set<String>(), forms = Set<String>()
        var out = Array(repeating: Mark.again, count: records.count)
        for i in records.indices.sorted(by: { (records[$0].date, $0) < (records[$1].date, $1) }) {
            let r = records[i]
            if models.insert(r.modelId).inserted {
                out[i] = .newModel
            } else if vehicles.insert("\(r.modelId)#\(r.number)").inserted {
                out[i] = .newVehicle
            } else if let wrap = r.wrap, !forms.contains("\(r.modelId)#\(r.number)#\(wrap)") {
                out[i] = .newForm
            }
            vehicles.insert("\(r.modelId)#\(r.number)")
            if let wrap = r.wrap { forms.insert("\(r.modelId)#\(r.number)#\(wrap)") }
        }
        return out
    }

    /// Indices grouped by calendar day: the newest day first, the newest catch first in each.
    public static func days(_ dates: [Date], calendar: Calendar = .current) -> [(day: Date, indices: [Int])] {
        Dictionary(grouping: dates.indices) { calendar.startOfDay(for: dates[$0]) }
            .map { (day: $0.key, indices: $0.value.sorted { dates[$0] > dates[$1] }) }
            .sorted { $0.day > $1.day }
    }
}
