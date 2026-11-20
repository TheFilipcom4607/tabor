import Testing
@testable import TaborCore

/// A w×h mask with `filled` saying which pixels are the cut-out.
private func mask(_ w: Int, _ h: Int, _ filled: (Int, Int) -> Bool) -> [UInt8] {
    (0..<(w * h)).map { filled($0 % w, $0 / w) ? 255 : 0 }
}

@Test func aWholeBusFillsItsHull() {
    // A bus side in perspective: a quadrilateral, nearer end taller.
    let m = mask(200, 120) { x, y in x >= 20 && x < 180 && Double(y) >= 30 - Double(x - 20) * 0.08 && y < 90 }
    let s = CutShape.measure(m, width: 200, height: 120)!
    #expect(s.solidity > 0.95)
    #expect(s.edges == 0)
}

@Test func bushesChewingTheBottomLeaveItHollow() {
    // The same box, its lower half bitten away in ragged teeth.
    let m = mask(200, 120) { x, y in
        guard x >= 20, x < 180, y >= 30, y < 90 else { return false }
        return y < 60 || (x / 8) % 3 == 0
    }
    let s = CutShape.measure(m, width: 200, height: 120)!
    #expect(s.solidity < 0.75)
}

@Test func aCarInFrontBitesANotch() {
    let whole = CutShape.measure(mask(200, 120) { x, y in x >= 20 && x < 180 && y >= 30 && y < 90 }, width: 200, height: 120)!
    let bitten = CutShape.measure(mask(200, 120) { x, y in
        x >= 20 && x < 180 && y >= 30 && y < 90 && !(x >= 70 && x < 140 && y >= 60)
    }, width: 200, height: 120)!
    #expect(bitten.quality < whole.quality - 0.1)
}

@Test func runningOffTheFrameCounts() {
    let m = mask(200, 120) { x, y in x >= 60 && y >= 30 && y < 90 }
    let s = CutShape.measure(m, width: 200, height: 120)!
    #expect(s.edges == 1)
    #expect(s.quality < s.solidity)
}

@Test func anEmptyMaskHasNoShape() {
    #expect(CutShape.measure([UInt8](repeating: 0, count: 100), width: 10, height: 10) == nil)
}
