import Testing
@testable import TaborCore

@Test func cameraSlowsThenSleeps() {
    #expect(RestPlan.level(idle: 0, lowPower: false) == .awake)
    #expect(RestPlan.level(idle: 19, lowPower: false) == .awake)
    #expect(RestPlan.level(idle: 20, lowPower: false) == .slow)
    #expect(RestPlan.level(idle: 89, lowPower: false) == .slow)
    #expect(RestPlan.level(idle: 90, lowPower: false) == .asleep)
}

@Test func lowPowerNeverRunsFlatOut() {
    #expect(RestPlan.level(idle: 0, lowPower: true) == .slow)
    #expect(RestPlan.level(idle: 44, lowPower: true) == .slow)
    #expect(RestPlan.level(idle: 45, lowPower: true) == .asleep)
}

@Test func aLiftCountsASwayDoesNot() {
    let upright = RestPlan.Gravity(x: 0, y: -1, z: 0)
    // Flat on a desk, then picked up.
    #expect(RestPlan.moved(from: RestPlan.Gravity(x: 0, y: 0, z: -1), to: upright))
    // A few degrees of sway, and the sensor's noise.
    #expect(!RestPlan.moved(from: upright, to: RestPlan.Gravity(x: 0.08, y: -0.99, z: 0.05)))
    #expect(!RestPlan.moved(from: upright, to: RestPlan.Gravity(x: 0, y: -1.3, z: 0)))
    // Swung to follow a bus: a quarter turn about the vertical doesn't change gravity, but
    // tipping the phone 15° does.
    #expect(RestPlan.moved(from: upright, to: RestPlan.Gravity(x: 0.26, y: -0.97, z: 0)))
    #expect(!RestPlan.moved(from: upright, to: RestPlan.Gravity(x: 0, y: 0, z: 0)))
}
