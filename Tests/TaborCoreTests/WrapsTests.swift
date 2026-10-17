import Foundation
import Testing
@testable import TaborCore

private let catalog: FleetCatalog = {
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Tabor/Resources/fleet.json")
    return try! FleetCatalog(json: Data(contentsOf: url))
}()

private func day(_ s: String, hour: Int = 12) -> Date {
    var c = DateComponents(year: Int(s.prefix(4)), month: Int(s.dropFirst(5).prefix(2)), day: Int(s.suffix(2)), hour: hour)
    c.timeZone = TimeZone(identifier: "Europe/Warsaw")
    return Calendar(identifier: .gregorian).date(from: c)!
}

/// Shares (in %) measured on 2026-10-17: Vision cut-outs (`masked`) and photos' middles.
private func shares(_ masked: Bool, red: Double = 0, orange: Double = 0, yellow: Double, green: Double = 0,
                    blue: Double = 0, navy: Double = 0, purple: Double = 0, pink: Double = 0) -> HueShares {
    HueShares([.red: red / 100, .orange: orange / 100, .yellow: yellow / 100, .green: green / 100,
               .blue: blue / 100, .navy: navy / 100, .purple: purple / 100, .pink: pink / 100], masked: masked)
}

private func wrap(_ id: String) -> Wrap { catalog.wrap(id: id)! }

@Test func fleetJsonCarriesTheSourcedWraps() {
    #expect(catalog.wraps.count >= 10)
    for w in catalog.wraps {
        #expect(catalog.match(number: w.number, kind: w.kind) != .unknown, "\(w.id)")
        #expect(w.from <= w.to)
    }
    #expect(catalog.wraps(kind: .bus, number: 5887).map(\.event) == ["chopin", "christmas", "summer"])
}

@Test func aWrapCoversItsWindowByWarsawDays() {
    #expect(catalog.wraps(kind: .bus, number: 5887, on: day("2025-12-20")).map(\.id) == ["bus-5887-xmas-2025"])
    // The last day counts until midnight in Warsaw, not UTC.
    #expect(catalog.wraps(kind: .bus, number: 5887, on: day("2026-01-06", hour: 23)).count == 1)
    #expect(catalog.wraps(kind: .bus, number: 5887, on: day("2026-01-07", hour: 0)).isEmpty)
    #expect(catalog.wraps(kind: .bus, number: 5887, on: day("2026-10-17")).isEmpty)
    // Tram 3148's wrap isn't the bus's.
    #expect(catalog.wraps(kind: .bus, number: 3148, on: day("2025-12-20")).isEmpty)
}

@Test func wrapsOnTheirCutOutsAreDressed() {
    let cases: [(String, HueShares)] = [
        ("bus-4323-xmas-2021", shares(true, red: 9.7, orange: 1.0, yellow: 2.1, green: 9.2, navy: 4.6)),
        ("bus-1915-valentines-2026", shares(true, red: 15.8, yellow: 3.3, blue: 0.8, navy: 1.1, purple: 3.0, pink: 5.6)),
        ("bus-1919-gifts-2025", shares(true, red: 10.8, orange: 1.4, yellow: 4.0, blue: 12.5, navy: 1.2, pink: 2.9)),
        ("bus-5887-chopin-2025", shares(true, red: 0.6, yellow: 0.1, blue: 0.4, navy: 5.8, purple: 0.3, pink: 12.2)),
        ("bus-5887-xmas-2025", shares(true, red: 25.5, orange: 0.8, yellow: 0.2, navy: 4.8, pink: 0.8)),
        ("bus-5887-summer-2026", shares(true, orange: 6.1, yellow: 1.5, green: 9.6, blue: 10.6, navy: 5.8)),
        ("bus-5887-summer-2026", shares(true, orange: 5.7, yellow: 1.2, green: 10.4, blue: 11.5, navy: 1.3)),
        ("bus-5919-xmas-2024", shares(true, red: 0.4, yellow: 0.3, blue: 9.1, navy: 5.0, pink: 0.7)),
        ("bus-5919-xmas-2024", shares(true, red: 6.2, yellow: 0.3, blue: 12.9, navy: 4.5, purple: 1.1, pink: 8.2)),
    ]
    for (id, s) in cases {
        #expect(WrapCheck.verdict(wrap: wrap(id), colours: s, texts: [], line: nil) == .dressed(.colours), "\(id)")
    }
}

@Test func halloweenKeptItsYellowSoItsUnsure() {
    let cut = shares(true, red: 2.4, orange: 4.8, yellow: 8.5, blue: 0.5, navy: 10.7, purple: 13.0, pink: 3.2)
    let photo = shares(false, red: 2.5, orange: 4.3, yellow: 6.0, blue: 0.3, navy: 7.2, purple: 9.1, pink: 3.6)
    #expect(WrapCheck.verdict(wrap: wrap("bus-1976-halloween-2025"), colours: cut, texts: [], line: nil) == .unsure)
    #expect(WrapCheck.verdict(wrap: wrap("bus-1976-halloween-2025"), colours: photo, texts: [], line: nil) == .unsure)
}

@Test func plainBusesAreNeverDressed() {
    // Cut-outs of plain buses: #5887, #5853, #5898, #1901, #1941, #1949, #1976, #9904.
    let cuts = [
        shares(true, red: 7.4, orange: 3.1, yellow: 19.0, green: 2.7, blue: 0.3, navy: 0.5),
        shares(true, red: 6.0, orange: 8.7, yellow: 10.7, navy: 0.3),
        shares(true, red: 5.4, orange: 3.5, yellow: 14.2, green: 1.6, blue: 3.1, navy: 9.1),
        shares(true, red: 4.6, orange: 5.3, yellow: 29.5),
        shares(true, red: 5.7, orange: 6.6, yellow: 10.4, blue: 0.6, navy: 1.9),
        shares(true, red: 2.5, orange: 1.3, yellow: 7.1, navy: 2.5),
        shares(true, red: 8.6, orange: 4.1, yellow: 18.9, navy: 2.6),
        shares(true, red: 9.4, orange: 2.6, yellow: 20.3, blue: 0.5, navy: 0.6),
    ]
    // Photos' middles: far, at night, blue sky, a person in red (#1943, #4221, #1946, #5893, #5887).
    let photos = [
        shares(false, red: 0.4, yellow: 1.4, green: 2.5),
        shares(false, red: 0.2, yellow: 0.3, blue: 0.1, navy: 5.8),
        shares(false, red: 0.8, orange: 2.8, yellow: 1.9, blue: 4.5, navy: 0.2),
        shares(false, red: 5.2, orange: 11.1, yellow: 2.0, green: 1.2, blue: 0.2, navy: 4.4),
        shares(false, red: 3.9, orange: 1.7, yellow: 9.8, green: 1.3, blue: 8.8, navy: 1.1),
    ]
    for w in catalog.wraps {
        for s in cuts + photos {
            #expect(WrapCheck.verdict(wrap: w, colours: s, texts: [], line: nil) != .dressed(.colours), "\(w.id)")
        }
        for s in cuts where !w.signature.isEmpty && w.event != "halloween" {
            #expect(WrapCheck.verdict(wrap: w, colours: s, texts: [], line: nil) != .unsure || w.id == "bus-5887-xmas-2025",
                    "\(w.id)")
        }
    }
    // The plain #5887 against its own Christmas and summer wraps.
    #expect(WrapCheck.verdict(wrap: wrap("bus-5887-xmas-2025"), colours: cuts[0], texts: [], line: nil) == .plain)
    #expect(WrapCheck.verdict(wrap: wrap("bus-5887-summer-2026"), colours: photos[4], texts: [], line: nil) == .plain)
}

@Test func photosWithoutACutOutClaimOnlyOnStrongColours() {
    let summer = shares(false, orange: 3.6, yellow: 1.9, green: 19.8, blue: 5.9, navy: 4.4)
    let christmas = shares(false, red: 18.8, orange: 0.6, yellow: 0.1, navy: 6.2, pink: 0.5)
    let chopin = shares(false, red: 0.6, yellow: 0.5, green: 4.4, navy: 3.4, pink: 6.9)
    #expect(WrapCheck.verdict(wrap: wrap("bus-5887-summer-2026"), colours: summer, texts: [], line: nil) == .dressed(.colours))
    #expect(WrapCheck.verdict(wrap: wrap("bus-5887-xmas-2025"), colours: christmas, texts: [], line: nil) == .dressed(.colours))
    // Too little pink in a whole frame to be sure: the chip.
    #expect(WrapCheck.verdict(wrap: wrap("bus-5887-chopin-2025"), colours: chopin, texts: [], line: nil) == .unsure)
}

@Test func wordsAndLinesProveAWrap() {
    let summer = wrap("bus-5887-summer-2026")
    #expect(WrapCheck.verdict(wrap: summer, colours: nil, texts: ["MILO WAS WIDZIEC"], line: nil) == .dressed(.words))
    #expect(WrapCheck.verdict(wrap: summer, colours: nil, texts: ["TLO WAS WIDZIEĆ", "MAKACIE"], line: nil) == .dressed(.words))
    #expect(WrapCheck.verdict(wrap: summer, colours: nil, texts: [], line: "wakacje") == .dressed(.line))
    let valentines = wrap("bus-1915-valentines-2026")
    #expect(WrapCheck.verdict(wrap: valentines, colours: nil, texts: ["W26 TAUTOBUSŚÍŚ", "W26", "1915"], line: nil) == .dressed(.line))
    // One letter on a display proves nothing; the feed's line does.
    let gifts = wrap("bus-1919-gifts-2025")
    #expect(WrapCheck.verdict(wrap: gifts, colours: nil, texts: ["M", "1919"], line: nil) == .unsure)
    #expect(WrapCheck.verdict(wrap: gifts, colours: nil, texts: [], line: "M") == .dressed(.line))
    // A wrap with no colours on file can't be called plain.
    let tram = wrap("tram-3148-xmas-2025")
    #expect(WrapCheck.verdict(wrap: tram, colours: shares(true, red: 8, yellow: 25), texts: [], line: nil) == .unsure)
    #expect(WrapCheck.folded("Miło was widzieć!") == "MILOWASWIDZIEC")
}

// MARK: - Around the app

private let christmas = day("2025-12-20")

private func bus(_ number: Int, line: String = "158", lat: Double = 52.23, lon: Double = 21.01) -> LiveVehicle {
    LiveVehicle(number: number, kind: .bus, line: line, latitude: lat, longitude: lon, time: christmas)
}

@Test func aWrappedBusLeadsTheHuntUntilCaughtInIt() {
    let urbino = catalog.match(number: 5887, kind: .bus).suggested!
    let legendary = catalog.models.first { $0.tier == .legendary && $0.kind == .bus && $0.regular }!
    let snapshot = LiveSnapshot(vehicles: [bus(legendary.numbers[0], lat: 52.2301), bus(5887, lat: 52.235)], fetched: christmas)
    // Already in the book, but plain: wanted again, and ahead of a legendary model you don't have.
    let plain = CollectionStats(sightings: [SightingRecord(number: 5887, modelId: urbino.id, date: day("2025-06-01"))])
    let pins = Wanted.pins(snapshot: snapshot, catalog: catalog, caught: plain, lat: 52.23, lon: 21.01)
    #expect(pins.first?.vehicle.number == 5887)
    #expect(pins.first?.wrap?.id == "bus-5887-xmas-2025")
    #expect(pins.first?.kind == .newVehicle)
    #expect(Wanted.wrapsOut(snapshot: snapshot, catalog: catalog, caught: plain, lat: 52.23, lon: 21.01).map(\.vehicle.number) == [5887])
    // Caught in it: an ordinary caught bus again.
    let dressed = CollectionStats(sightings: [SightingRecord(number: 5887, modelId: urbino.id, date: christmas, wrap: "bus-5887-xmas-2025")])
    #expect(!Wanted.pins(snapshot: snapshot, catalog: catalog, caught: dressed, lat: 52.23, lon: 21.01).contains { $0.vehicle.number == 5887 })
    #expect(Wanted.wrapsOut(snapshot: snapshot, catalog: catalog, caught: dressed, lat: 52.23, lon: 21.01).isEmpty)
    // Out of its window, nothing special.
    let later = LiveSnapshot(vehicles: [bus(5887)], fetched: day("2026-10-17"))
    #expect(Wanted.pins(snapshot: later, catalog: catalog, caught: plain, lat: 52.23, lon: 21.01).isEmpty)
}

@Test func wrapsAreFormsInTheBadgesLogAndStats() {
    let urbino = catalog.match(number: 5887, kind: .bus).suggested!.id
    let u12 = catalog.match(number: 1915, kind: .bus).suggested!.id
    let yutong = catalog.match(number: 1976, kind: .bus).suggested!.id
    let records = [
        SightingRecord(number: 5887, modelId: urbino, date: day("2025-06-01")),
        SightingRecord(number: 5887, modelId: urbino, date: day("2025-10-15"), wrap: "bus-5887-chopin-2025"),
        SightingRecord(number: 5887, modelId: urbino, date: christmas, wrap: "bus-5887-xmas-2025"),
        SightingRecord(number: 5887, modelId: urbino, date: day("2025-12-21"), wrap: "bus-5887-xmas-2025"),
        SightingRecord(number: 1915, modelId: u12, date: day("2026-02-14"), wrap: "bus-1915-valentines-2026"),
        SightingRecord(number: 1976, modelId: yutong, date: day("2025-10-25"), wrap: "bus-1976-halloween-2025"),
    ]
    let stats = CollectionStats(sightings: records)
    #expect(stats.vehicle(number: 5887, modelId: urbino)?.wraps == ["bus-5887-chopin-2025", "bus-5887-xmas-2025"])
    #expect(stats.wrapForms == 4)
    #expect(stats.rarest(catalog: catalog, limit: 1).first?.wraps.isEmpty == false)

    let badges = Dictionary(uniqueKeysWithValues: Achievements.evaluate(records, catalog: catalog).map { ($0.id, $0) })
    #expect(badges["wrap-christmas"]?.earned == true)
    #expect(badges["every-occasion"]?.earned == true)
    #expect(badges["special-livery"]?.progress == 4)
    let noneYet = Dictionary(uniqueKeysWithValues: Achievements.evaluate(Array(records.prefix(1)), catalog: catalog).map { ($0.id, $0) })
    #expect(noneYet["wrap-christmas"]?.earned == false)
    #expect(noneYet["every-occasion"]?.missing.count == Set(catalog.wraps.map(\.event)).count)

    #expect(CatchLog.marks(records) == [.newModel, .newForm, .newForm, .again, .newModel, .newModel])
    #expect(PeriodStats(records, period: .all, catalog: catalog).wraps == 4)
}
