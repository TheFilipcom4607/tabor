import Testing
@testable import TaborCore

private func shot(_ index: Int, _ number: Int?, _ tier: Tier? = .common, model: String? = nil, score: Double = 1,
                  sticker: Bool = true, needsYou: Bool = false, new: Bool = false, wrap: Bool = false) -> Burst.Shot {
    Burst.Shot(index: index, number: number, modelId: number == nil ? nil : model ?? "m\(number!)", tier: tier,
               score: score, hasSticker: sticker, needsYou: needsYou, isNew: new, mayWearWrap: wrap)
}

@Test func rarestComesLast() {
    let cards = Burst.cards([shot(0, 1996, .legendary), shot(1, 8300, .common), shot(2, 3001, .gold), shot(3, 9001, .rare)])
    #expect(cards == [1, 3, 2, 0])
}

@Test func oddTiersRankWithLegendaries() {
    let cards = Burst.cards([shot(0, 959, .onTest), shot(1, 1996, .legendary), shot(2, 3001, .gold)])
    #expect(cards == [2, 0, 1])
}

@Test func cardsThatAskComeFirst() {
    let cards = Burst.cards([shot(0, 1996, .legendary), shot(1, nil, nil, score: 0, needsYou: true),
                             shot(2, 2021, nil, needsYou: true)])
    #expect(cards == [1, 2, 0])
}

@Test func repeatsBeforeNewWithinATier() {
    let cards = Burst.cards([shot(0, 8301, new: true), shot(1, 8302), shot(2, 8303, new: true)])
    #expect(cards == [1, 0, 2])
}

@Test func wrapsAtTheVeryEnd() {
    let cards = Burst.cards([shot(0, 5887, .common, wrap: true), shot(1, 1996, .legendary)])
    #expect(cards == [1, 0])
}

@Test func oneCardPerVehicleFromItsBestShot() {
    let cards = Burst.cards([shot(0, 8300, score: 0.6), shot(1, 8300, score: 0.9, sticker: false),
                             shot(2, 8300, score: 0.9), shot(3, 1996, .legendary)])
    #expect(cards == [2, 3])
}

@Test func equalShotsKeepTheFirst() {
    #expect(Burst.cards([shot(0, 8300), shot(1, 8300)]) == [0])
}

@Test func shotsThatReadNothingStaySeparate() {
    let cards = Burst.cards([shot(0, nil, nil, score: 0, needsYou: true), shot(1, nil, nil, score: 0, needsYou: true)])
    #expect(cards == [0, 1])
}

@Test func sameNumberDifferentModelsStaySeparate() {
    // Bus 2021 and tram 2021 in one burst are two vehicles.
    let cards = Burst.cards([shot(0, 2021, model: "bus"), shot(1, 2021, model: "tram")])
    #expect(cards == [0, 1])
}
