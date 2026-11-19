import Foundation
import Testing
@testable import TaborCore

// Vehicles that leave Warsaw stay in the book as retired (build/drafts/retired-vehicles.md).

private let bundled: FleetCatalog = {
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Tabor/Resources/fleet.json")
    return try! FleetCatalog(json: Data(contentsOf: url))
}()

/// A six-bus model: 2018's 9061–9063 have all gone, 2019's 9064–9066 one of three.
private func going(retired: Set<Int> = [9061, 9062, 9063, 9064]) -> VehicleModel {
    VehicleModel(id: "bus-going", name: "Otokar Vectio C", make: "Otokar", kind: .bus, operators: ["ReloBus"],
                 fleet: 6, firstYear: 2018, lastYear: 2019, batches: [
                     Batch(year: 2018, depotCode: "", depotName: "Estrady", operator: "ReloBus", numbers: [9061, 9062, 9063]),
                     Batch(year: 2019, depotCode: "", depotName: "Estrady", operator: "ReloBus", numbers: [9064, 9065, 9066]),
                 ], retired: retired, leaving: [Leaving(until: "2026-11-30", numbers: [9065, 9066])])
}

private func catalog(_ models: [VehicleModel]) -> FleetCatalog {
    FleetCatalog(data: FleetData(source: "", fetched: "2026-11-19 12:00 UTC", models: models, depots: []))
}

private func catch_(_ n: Int, _ id: String = "bus-going") -> SightingRecord {
    SightingRecord(number: n, modelId: id, date: Date(timeIntervalSince1970: 1_790_000_000 + Double(n)))
}

@Test func retiredVehiclesStayInTheBookButLeaveTodaysFleet() {
    let m = going()
    // The tier goes by every vehicle it had: six is LEGENDARY, whatever's left.
    #expect(m.tier == .legendary)
    #expect(m.inService == 2 && m.numbersInService == [9065, 9066])
    #expect(m.has(9061) && m.isRetired(9061) && !m.isRetired(9065))
    #expect(!m.retiredOut && m.regular && m.progressFleet == 2)
    #expect(m.batch(containing: 9061)?.year == 2018)  // its page still knows its batch
    #expect(catalog([m]).totalFleet == 2)
    // The fleet % counts what's in service: a retired catch doesn't inflate it.
    let stats = CollectionStats(sightings: [catch_(9061), catch_(9065)])
    #expect(stats.fleetCaught(catalog: catalog([m])) == 1)
    #expect(stats.progress(model: m) == 1)
    #expect(stats.ownedCount(modelId: m.id) == 2)
}

@Test func aModelThatHasAllLeftIsOffTheSetsButKeepsItsColour() {
    let m = going(retired: [9061, 9062, 9063, 9064, 9065, 9066])
    #expect(m.retiredOut && !m.regular && m.serviceStock)
    #expect(m.tier == .legendary)
    #expect(m.progressFleet == 6 && m.counts(9061))
    #expect(m.whereToFind != nil)
    let c = catalog([m])
    #expect(c.totalFleet == 0)
    #expect(CollectionStats(sightings: [catch_(9061)]).fleetCaught(catalog: c) == 0)
    // Not in "All n legendary": there's nothing left to catch.
    #expect(Achievements.evaluate([], catalog: c).first { $0.id == "legendary-all" } == nil)
}

@Test func aRetiredNumberMatchesOnlyWhenNothingInServiceHasIt() {
    let old = going()
    let tram = VehicleModel(id: "tram-x", name: "Tram", make: "Pesa", kind: .tram, operators: ["TW"], fleet: 1,
                            firstYear: 2020, lastYear: 2020,
                            batches: [Batch(year: 2020, depotCode: "R-1", depotName: "Wola", numbers: [9061])])
    let c = catalog([old, tram])
    // A bus that has left isn't the tram in front of you...
    #expect(c.match(number: 9061) == .certain(tram))
    // ...but a catch on its last day still finds its model.
    #expect(c.match(number: 9062) == .certain(old))
}

@Test func setsGoByWhatsInServicePlusWhatYouCaught() {
    let m = going()
    // Missed the ones that left: the in-service two complete the model.
    #expect(m.needed(m.numbers, mine: [9065, 9066]) == [9065, 9066])
    // Caught one before it left: it stays part of your set, so a retirement never undoes it.
    #expect(m.needed(m.numbers, mine: [9061, 9065, 9066]) == [9061, 9065, 9066])
    // A batch that has all gone needs every one of it: two last-day catches aren't the batch.
    #expect(m.needed([9061, 9062, 9063], mine: [9061, 9062]) == [9061, 9062, 9063])
    let c = catalog([m])
    let complete = Achievements.evaluate([catch_(9065), catch_(9066)], catalog: c).first { $0.id == "model-complete" }!
    #expect(complete.earned)
}

@Test func leavingBatchesRankWithTheLegendariesOnHunt() {
    let m = going()
    let v = LiveVehicle(number: 9065, kind: .bus, line: "157", latitude: 52.23, longitude: 21.01, time: Date())
    let pin = WantedPin(vehicle: v, model: m, kind: .newVehicle, distance: 100)
    #expect(pin.leaving == "2026-11-30")
    #expect(Leaving.isPast("2026-11-30", now: Wrap.parse("2026-12-01")!))
    #expect(!Leaving.isPast("2026-11-30", now: Wrap.parse("2026-11-30")!))
    #expect(Wanted.huntRank(pin) == Tier.legendary.rank)
}

@Test func theBundledFleetKeepsItsRetiredVehicles() {
    // ReloBus's 2018 Vectio Cs: ten have left, and the model still has all 34.
    let vectio = bundled.model(id: "bus-otokar-la16sr2bx")!
    #expect(vectio.fleet == 34 && vectio.isRetired(9061) && vectio.tier == .gold)
    #expect(vectio.leaving(of: 9073) == "2026-10-25")
    #expect(bundled.model(id: "bus-solaris-urbino-18cng")?.leaving(of: 9914) == "2026-11-30")
    // Decoded back into their batches, so a retired bus's page knows its year and depot.
    #expect(bundled.models.allSatisfy { m in m.retired.allSatisfy(m.has) })
}

@Test func retiredVehiclesComeApartSoOlderAppsNeverSeeThem() throws {
    // fleet.json keeps today's fleet where older apps read it, and retired vehicles under keys
    // only newer ones know: "retiredBatches" on a model, "retiredModels" for one that has all gone.
    let json = """
    {"source": "", "fetched": "2026-11-19 12:00 UTC", "depots": [],
     "models": [{"id": "bus-a", "name": "A", "make": "A", "kind": "BUS", "operators": ["ReloBus"], "fleet": 2,
                 "firstYear": 2018, "lastYear": 2018,
                 "batches": [{"year": 2018, "depotCode": "", "depotName": "Estrady", "operator": "ReloBus", "numbers": [9073, 9074]}],
                 "retiredBatches": [{"year": 2018, "depotCode": "", "depotName": "Estrady", "operator": "ReloBus", "numbers": [9061]},
                                    {"year": 2017, "depotCode": "", "depotName": "Estrady", "operator": "ReloBus", "numbers": [9050]}]}],
     "retiredModels": [{"id": "bus-b", "name": "B", "make": "B", "kind": "BUS", "operators": ["PKS"], "fleet": 0,
                        "firstYear": 2014, "lastYear": 2014, "batches": [],
                        "retiredBatches": [{"year": 2014, "depotCode": "", "depotName": "", "operator": "PKS", "numbers": [35531, 39532]}]}]}
    """
    let c = try FleetCatalog(json: Data(json.utf8))
    let a = try #require(c.model(id: "bus-a"))
    #expect(a.fleet == 4 && a.inService == 2 && a.retired == [9061, 9050])
    #expect(a.batch(containing: 9061)?.numbers == [9061, 9073, 9074])  // back in its own batch
    #expect(a.batch(containing: 9050)?.year == 2017)                    // or one of its own
    let b = try #require(c.model(id: "bus-b"))
    #expect(b.retiredOut && b.fleet == 2 && !b.regular)
    #expect(c.match(number: 35531) == .certain(b))
    #expect(c.totalFleet == 2)
    #expect(FleetCatalog.validated(json: Data(json.utf8)) != nil)
}
