import SwiftUI

extension EnvironmentValues {
    /// A screen wider than it is tall and wider than any phone held upright: an opened
    /// foldable (the iPhone Duo's inner screen is about 950 × 670 pt). Screens lay out side by
    /// side there instead of stretching a phone's column across it. Set once, in `RootView`.
    @Entry var wide = false
}

enum WideLayout {
    static func isWide(_ size: CGSize) -> Bool { size.width >= 640 && size.width > size.height }

    /// Where a phone-shaped column sits on a wide screen (ME, the reveal, sheets): about a
    /// big phone's width, so lines don't run across the whole screen.
    static let column: CGFloat = 520
}

extension View {
    /// A phone's single column, centred, on a wide screen; untouched on a phone.
    func wideColumn(_ wide: Bool, width: CGFloat = WideLayout.column) -> some View {
        frame(maxWidth: wide ? width : .infinity)
            .frame(maxWidth: .infinity)
    }
}
