import SwiftUI

/// A small breathing dot: HUNT's status dot by LIVE, and the one in CATCH's hint pill. A layer
/// the system animates: breathing through SwiftUI redrew it every frame, which was HUNT's whole
/// CPU between two refreshes (about 3%), and a pulsing symbol effect did the same on CATCH
/// (about 5%, for as long as the camera was open).
struct LiveDot: UIViewRepresentable {
    let color: UIColor
    let glows: Bool
    let breathing: Bool
    @Environment(\.lowPower) private var lowPower

    func makeUIView(context: Context) -> DotView { DotView() }

    func updateUIView(_ view: DotView, context: Context) {
        view.set(color: color, glows: glows, breathing: breathing && !lowPower)
    }

    final class DotView: UIView {
        private var breathing = false

        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
            layer.shadowOffset = .zero
            layer.shadowRadius = 4
            // The system drops a layer's animations when the app leaves the screen.
            NotificationCenter.default.addObserver(self, selector: #selector(restart), name: UIApplication.didBecomeActiveNotification, object: nil)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }

        func set(color: UIColor, glows: Bool, breathing: Bool) {
            layer.backgroundColor = color.cgColor
            layer.shadowColor = color.cgColor
            layer.shadowOpacity = glows ? 1 : 0
            guard breathing != self.breathing else { return }
            self.breathing = breathing
            restart()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            layer.cornerRadius = bounds.width / 2
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            restart()
        }

        @objc private func restart() {
            layer.removeAnimation(forKey: "breathe")
            guard breathing, window != nil else { return }
            let breathe = CABasicAnimation(keyPath: "opacity")
            breathe.fromValue = 0.35
            breathe.toValue = 1
            breathe.duration = 0.9
            breathe.autoreverses = true
            breathe.repeatCount = .infinity
            breathe.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            breathe.preferredFrameRateRange = CAFrameRateRange(minimum: 15, maximum: 30, preferred: 30)
            layer.add(breathe, forKey: "breathe")
        }
    }
}
