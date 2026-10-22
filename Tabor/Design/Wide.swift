import SwiftUI

extension EnvironmentValues {
    /// A screen wider than it is tall and wider than any phone held upright: an opened
    /// foldable (the iPhone Duo's inner screen is about 950 × 670 pt). Screens lay out side by
    /// side there instead of stretching a phone's column across it. Set once, in `RootView`.
    @Entry var wide = false
    /// The same screen turned upright (about 670 × 950 pt), or half folded like a laptop: the
    /// fold runs across the middle, so screens put what you look at above it and what you
    /// tap below it.
    @Entry var tall = false
}

enum WideLayout {
    static func isWide(_ size: CGSize) -> Bool { size.width >= 640 && size.width > size.height }
    static func isTall(_ size: CGSize) -> Bool { size.width >= 600 && size.height > size.width }

    /// Where a phone-shaped column sits on a wide screen (ME, the reveal, sheets): about a
    /// big phone's width, so lines don't run across the whole screen.
    static let column: CGFloat = 520

    /// Where the fold runs on a tall screen, in window coordinates: across the middle.
    @MainActor static var foldY: CGFloat {
        let window = UIApplication.shared.connectedScenes.lazy.compactMap { $0 as? UIWindowScene }
            .compactMap(\.keyWindow).first
        return (window?.bounds.height ?? 0) / 2
    }
}

extension View {
    /// A phone's single column, centred, on a wide screen; untouched on a phone.
    func wideColumn(_ wide: Bool, width: CGFloat = WideLayout.column) -> some View {
        frame(maxWidth: wide ? width : .infinity)
            .frame(maxWidth: .infinity)
    }
}

/// A tall screen split at the fold: `top` above it, `bottom` below, whatever the bars above
/// and below take.
struct FoldSplit<Top: View, Bottom: View>: View {
    @ViewBuilder var top: () -> Top
    @ViewBuilder var bottom: () -> Bottom

    var body: some View {
        GeometryReader { geo in
            let above = min(max(WideLayout.foldY - geo.frame(in: .global).minY, 0), geo.size.height)
            VStack(spacing: 0) {
                top().frame(height: above)
                bottom().frame(maxHeight: .infinity)
            }
        }
    }
}
