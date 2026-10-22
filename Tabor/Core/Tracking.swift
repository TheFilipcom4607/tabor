import Foundation

/// What a Live Activity follows (#42): a vehicle coming your way, from where it is to the stop
/// where its route passes you. The server tracks it along `path` and pushes how far it has left.
public struct TrackPlan: Sendable {
    /// Your stop, or nil when the route passes you between stops.
    public let stop: String?
    /// Where it meets you: your stop, or the point on its route nearest you.
    public let target: (latitude: Double, longitude: Double)
    /// Metres along the route from the vehicle to you.
    public let distance: Double
    /// Stops it calls at before it reaches you, yours included.
    public let stops: Int
    /// The stop it's at or last passed.
    public let at: String?
    /// The route from a little behind the vehicle to a little past you, for the server to place
    /// it on each time the feed moves it.
    public let path: [(latitude: Double, longitude: Double)]
    /// The stops on that path.
    public let pathStops: [RouteStop]

    /// A stop this close to where the route passes you is the one you'd wait at.
    public static let stopReach = 200.0
    /// The path runs this far past each end, so a late fix or a GPS wobble still lands on it.
    public static let margin = 400.0

    /// The plan for a vehicle placed on its route, if that route comes within `near` metres of
    /// you somewhere ahead (as `RouteMatch.motion` decides COMING).
    public static func make(match: RouteMatch, lat: Double, lon: Double, near: Double = 150) -> TrackPlan? {
        guard let (yours, fit) = match.yourStop(lat: lat, lon: lon, near: near) else { return nil }
        return make(match: match, yours: yours, targetAlong: yours?.along ?? fit)
    }

    /// The plan to a stop picked from its stop list (#96): you may not be there yet, so neither
    /// where you are nor COMING matters, only that the stop is still ahead of it.
    public static func make(match: RouteMatch, stop: RouteStop) -> TrackPlan? {
        guard stop.along > match.along + 20, stop.along <= match.shape.length else { return nil }
        return make(match: match, yours: stop, targetAlong: stop.along)
    }

    private static func make(match: RouteMatch, yours: RouteStop?, targetAlong: Double) -> TrackPlan {
        let shape = match.shape
        let target = yours.map { ($0.latitude, $0.longitude) } ?? shape.coordinate(at: targetAlong)
        let from = max(0, match.along - margin), to = min(shape.length, targetAlong + margin)
        return TrackPlan(
            // With its platform: the one to wait at.
            stop: yours?.label, target: target, distance: targetAlong - match.along,
            stops: match.remaining.filter { $0.along <= targetAlong + 1 }.count,
            at: match.lastStop?.name,
            path: shape.path(from: from, to: to),
            pathStops: shape.stops.filter { $0.along >= from && $0.along <= to })
    }
}
