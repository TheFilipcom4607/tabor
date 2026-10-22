import Foundation

/// The book as a spreadsheet (#97): one row per catch, newest first. Shaped for Excel in
/// Polish, which is what most people will open it in: UTF-8 with a BOM (without it Excel reads
/// "Mokotów" as mojibake), `;` between fields (a comma is the Polish decimal mark) and decimals
/// written the way this phone's region writes them.
public enum CatchCSV {
    public static func make(records: [SightingRecord], catalog: FleetCatalog,
                            timeZone: TimeZone = .current, decimal: String = Locale.current.decimalSeparator ?? ".") -> String {
        let day = formatter("yyyy-MM-dd", timeZone), time = formatter("HH:mm", timeZone)
        let coordinate = { (x: Double?) in
            x.map { String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), $0)
                .replacingOccurrences(of: ".", with: decimal) } ?? ""
        }
        var rows = [[
            String(localized: "Date"), String(localized: "Time"), String(localized: "Fleet number"),
            String(localized: "Make"), String(localized: "Model"), String(localized: "Type"),
            String(localized: "Rarity"), String(localized: "Operator"), String(localized: "Line"),
            String(localized: "District"), String(localized: "Street"), String(localized: "Latitude"),
            String(localized: "Longitude"), String(localized: "Event wrap"), String(localized: "Second car of"),
        ]]
        for r in records.sorted(by: { $0.date > $1.date }) {
            let model = catalog.model(id: r.modelId)
            let place = r.latitude.flatMap { lat in r.longitude.flatMap { Districts.at(lat, $0) } }
            rows.append([
                day.string(from: r.date), time.string(from: r.date), FleetNumber.label(r.number),
                model?.make ?? "", model?.name ?? "", model?.kind.name ?? "", model?.tier.name ?? "",
                model.flatMap { $0.batch(containing: r.number)?.operator ?? ($0.operators.count == 1 ? $0.operators[0] : nil) } ?? "",
                r.line ?? "", place ?? r.district ?? "", r.street ?? "",
                coordinate(r.latitude), coordinate(r.longitude),
                r.wrap.map { catalog.wrap(id: $0)?.nameDisplay ?? $0 } ?? "",
                r.pairedWith.map(FleetNumber.label) ?? "",
            ])
        }
        return "\u{FEFF}" + rows.map { $0.map(field).joined(separator: ";") }.joined(separator: "\r\n") + "\r\n"
    }

    /// Quoted only when it must be: a separator, a quote or a line break inside.
    static func field(_ s: String) -> String {
        guard s.contains(where: { $0 == ";" || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else { return s }
        return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    private static func formatter(_ format: String, _ zone: TimeZone) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = zone
        f.dateFormat = format
        return f
    }
}
