import Foundation

/// Whether the phone is in Low Power Mode. While it is, TABOR does what the phone asks:
/// HUNT polls more slowly, nothing polls off CATCH and HUNT, and decorations hold still.
@Observable @MainActor
final class LowPower {
    static let shared = LowPower()

    private(set) var on = ProcessInfo.processInfo.isLowPowerModeEnabled

    private init() {
        NotificationCenter.default.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                let now = ProcessInfo.processInfo.isLowPowerModeEnabled
                guard now != LowPower.shared.on else { return }
                LowPower.shared.on = now
                LiveFleetService.shared.powerChanged()
            }
        }
    }
}
