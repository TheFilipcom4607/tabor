import CoreMotion
import Foundation

/// Watches whether anyone is using CATCH's camera, and says when it may rest (`RestPlan`).
/// A touch on a control counts (`poke`), and so does moving the phone, read off the
/// accelerometer twice a second: that needs no permission and costs next to nothing.
@Observable @MainActor
final class CameraRest {
    private(set) var level: RestPlan.Level = .awake
    /// A shot is being read, a reveal is up, or there's no camera running: nothing to rest.
    @ObservationIgnored var busy = true

    @ObservationIgnored private let motion = CMMotionManager()
    @ObservationIgnored private var lastUsed = Date()
    /// How the phone was held when it last counted as moved.
    @ObservationIgnored private var held: RestPlan.Gravity?
    @ObservationIgnored private var watcher: Task<Void, Never>?

    func start() {
        poke()
        guard watcher == nil else { return }
        if motion.isAccelerometerAvailable {
            motion.accelerometerUpdateInterval = 0.5
            motion.startAccelerometerUpdates()
        }
        watcher = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                self?.look()
            }
        }
    }

    func stop() {
        watcher?.cancel()
        watcher = nil
        motion.stopAccelerometerUpdates()
        held = nil
    }

    /// Someone touched a control, or came back to the screen.
    func poke() {
        lastUsed = Date()
        settle("touched")
    }

    private func look() {
        var why = "idle"
        if let a = motion.accelerometerData?.acceleration {
            let now = RestPlan.Gravity(x: a.x, y: a.y, z: a.z)
            if let held, RestPlan.moved(from: held, to: now) {
                self.held = now
                lastUsed = Date()
                why = "moved"
            } else if held == nil {
                held = now
            }
        }
        if busy { lastUsed = Date(); why = "busy" }
        settle(why)
    }

    /// `why` is only for the camera diary.
    private func settle(_ why: String) {
        let idle = Date().timeIntervalSince(lastUsed)
        let next = RestPlan.level(idle: idle, lowPower: LowPower.shared.on)
        guard next != level else { return }
        CameraLog.note("rest \(level) → \(next): \(why)\(LowPower.shared.on ? ", Low Power" : "")")
        level = next
    }
}
