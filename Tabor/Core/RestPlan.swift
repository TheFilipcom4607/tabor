import Foundation

/// When CATCH's camera may rest. The camera is the app's biggest drain and CATCH is where
/// the app opens, so a phone left on it (on a desk, in a hand at your side) ran the camera
/// flat out until the screen locked. Touching a control or moving the phone counts as using
/// it; holding it still doesn't.
public enum RestPlan {
    public enum Level: Sendable, Equatable {
        /// Full frame rate.
        case awake
        /// Fewer frames. The shutter works as ever.
        case slow
        /// The camera is off until a tap or a lift.
        case asleep
    }

    /// Seconds without a touch or a move before the viewfinder slows down.
    public static let slowAfter: TimeInterval = 20
    /// …and before the camera stops.
    public static let asleepAfter: TimeInterval = 90
    /// In Low Power Mode the camera stops sooner, and never runs at full rate.
    public static let lowPowerAsleepAfter: TimeInterval = 45

    public static func level(idle: TimeInterval, lowPower: Bool) -> Level {
        if idle >= (lowPower ? lowPowerAsleepAfter : asleepAfter) { return .asleep }
        return lowPower || idle >= slowAfter ? .slow : .awake
    }

    /// Which way is down, from the accelerometer (in g).
    public struct Gravity: Sendable, Equatable {
        public var x, y, z: Double
        public init(x: Double, y: Double, z: Double) { (self.x, self.y, self.z) = (x, y, z) }
    }

    /// The phone has turned this far from where it was held: lifted, or swung after a bus.
    /// A hand's sway while waiting stays well under it.
    public static let movedDegrees = 12.0

    public static func moved(from a: Gravity, to b: Gravity) -> Bool {
        let la = (a.x * a.x + a.y * a.y + a.z * a.z).squareRoot()
        let lb = (b.x * b.x + b.y * b.y + b.z * b.z).squareRoot()
        guard la > 0, lb > 0 else { return false }
        let cos = (a.x * b.x + a.y * b.y + a.z * b.z) / (la * lb)
        return acos(min(max(cos, -1), 1)) * 180 / .pi >= movedDegrees
    }
}
