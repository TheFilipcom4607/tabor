import SwiftUI

/// What a RETIRED, LEAVING or LAST RUNS tag means, in a popover: tap the tag. Why the batch is
/// leaving comes from fleet.json (`Leaving.about`, a sourced line from fetch_fleet.py's LEAVING).
struct DepartureInfo: View {
    let title: String
    let color: Color
    let paragraphs: [String]
    var source: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Mono(title, size: 11, weight: 700, spacing: 0.12, color: color)
            ForEach(paragraphs, id: \.self) { p in
                Text(p)
                    .font(TaborFont.grotesk(14))
                    .foregroundStyle(Palette.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let source {
                Mono(String(localized: "SOURCE: \(source.uppercased(with: .app))"), size: 9.5, spacing: 0.08, color: Palette.faint)
            }
        }
        .padding(18)
        .frame(width: 300, alignment: .leading)
        .presentationCompactAdaptation(.popover)
        .presentationBackground(Palette.card)
    }

    /// For one vehicle: retired, leaving on a day, or out on its last runs. Nil for one that
    /// isn't going anywhere.
    static func vehicle(_ model: VehicleModel, number: Int) -> DepartureInfo? {
        let why = model.departure(of: number)
        if model.isRetired(number) {
            return DepartureInfo(title: String(localized: "vehicle.retired", defaultValue: "RETIRED", comment: "Vehicle page tag: it has left Warsaw"),
                                 color: Palette.sub,
                                 paragraphs: [why?.aboutDisplay, String(localized: "#\(FleetNumber.label(number)) is gone from the city's list of vehicles in service: it has left Warsaw. It stays in your book for good.")].compactMap { $0 }
                                    + [keeps],
                                 source: why?.source)
        }
        guard let why else { return nil }
        return leaving(why, past: Leaving.isPast(why.until))
    }

    /// For a batch leaving on a day, or past it and on its last runs.
    static func leaving(_ why: Leaving, past: Bool) -> DepartureInfo {
        let day = Leaving.date(why.until).map { $0.formatted(.dateTime.day().month(.wide).locale(.app)) } ?? why.until
        let now = past
            ? String(localized: "Some are still out on their last runs. Catch one while you can: once it's gone, it stays in your book, marked retired.")
            : String(localized: "Until \(day) they still run on their lines. Catch one while you can: once it's gone, it stays in your book, marked retired.")
        let tag = Leaving.date(why.until).map { $0.formatted(.dateTime.day().month(.abbreviated).locale(.app)).uppercased(with: .app) } ?? why.until
        return DepartureInfo(title: past ? String(localized: "LAST RUNS") : String(localized: "LEAVING \(tag)"),
                             color: Palette.hiVis, paragraphs: [why.aboutDisplay, now].compactMap { $0 }, source: why.source)
    }

    /// The model page's RETIRED section.
    static func retiredSection(_ model: VehicleModel) -> DepartureInfo {
        let why = model.retired.lazy.compactMap { model.departure(of: $0) }.first
        return DepartureInfo(title: String(localized: "RETIRED"), color: Palette.sub,
                             paragraphs: [why?.aboutDisplay,
                                          String(localized: "These have gone from the city's list of vehicles in service: they've left Warsaw. The ones you caught stay in your book for good; the rest are hidden.")].compactMap { $0 }
                                + [keeps],
                             source: why?.source)
    }

    private static var keeps: String {
        String(localized: "The fleet % and the sets count only what's still running, so you can still complete the model without the ones that left. Its rarity doesn't change.")
    }
}

/// Anything that opens a `DepartureInfo` when tapped.
struct DepartureInfoButton<Label: View>: View {
    let info: DepartureInfo
    @ViewBuilder let label: Label
    @State private var shown = false

    var body: some View {
        Button {
            Haptics.shared.tick()
            shown = true
        } label: {
            label.contentShape(Rectangle())
        }
        // Plain, or a List row fires every button in it on any tap.
        .buttonStyle(.plain)
        .popover(isPresented: $shown, arrowEdge: .top) { info }
    }
}
