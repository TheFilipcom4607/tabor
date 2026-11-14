import SwiftUI

enum AppTab: String, CaseIterable {
    case catchTab = "CATCH"
    case hunt = "HUNT"
    case book = "BOOK"
    case me = "ME"

    var accent: Color {
        switch self {
        case .catchTab: Palette.yellow
        case .hunt: Palette.radar
        case .book: Palette.red
        case .me: Palette.green
        }
    }

    var symbol: String {
        switch self {
        case .catchTab: "viewfinder"
        case .hunt: "dot.radiowaves.left.and.right"
        case .book: "square.grid.3x3.fill"
        case .me: "trophy.fill"
        }
    }
}

/// Bottom bar: icon over a mono label, lit in the tab's accent, with a soft glow
/// under the active icon and a bounce on switch.
struct TabBar: View {
    @Binding var selection: AppTab
    /// Tapping the tab you're already on (e.g. BOOK pops back to the index).
    var onReselect: (AppTab) -> Void = { _ in }
    @Namespace private var glow
    /// Bumped when a tab becomes active, so only that icon bounces (not the one left behind).
    @State private var bounces: [AppTab: Int] = [:]
    /// The tab just tapped, lit before the app has switched to it. A tab opened for the first
    /// time takes a moment to build (over a second on an older phone), and with the bar waiting
    /// for that the tap looked ignored, so people tapped again (#115).
    @State private var tapped: AppTab?
    private var lit: AppTab { tapped ?? selection }
    @Environment(\.wide) private var wide
    @Environment(\.tall) private var tall

    var body: some View {
        HStack(spacing: 0) {
            ForEach(AppTab.allCases, id: \.self) { tab in
                let on = tab == lit
                Button {
                    guard tab != selection else { return onReselect(tab) }
                    HangLog.mark("tab \(tab.rawValue)")
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { tapped = tab }
                    // The switch itself a frame later, so the bar is drawn lit first.
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(10))
                        guard tapped == tab else { return }
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { selection = tab }
                    }
                } label: {
                    VStack(spacing: 5) {
                        ZStack {
                            if on {
                                Circle()
                                    .fill(tab.accent.opacity(0.22))
                                    .frame(width: 34, height: 34)
                                    .blur(radius: 10)
                                    .matchedGeometryEffect(id: "glow", in: glow)
                            }
                            Image(systemName: tab.symbol)
                                .font(.system(size: 19, weight: .semibold))
                                .foregroundStyle(on ? tab.accent : Color.white.opacity(0.3))
                                .symbolEffect(.bounce.down, value: bounces[tab, default: 0])
                        }
                        .frame(height: 24)
                        Mono(tab.rawValue, size: 10, weight: on ? 600 : 400, spacing: 0.1,
                             color: on ? tab.accent : Palette.dim)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 9)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tab.rawValue.capitalized)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(.horizontal, 10)
        // Four tabs a thumb's reach apart, not spread across an opened foldable.
        .wideColumn(wide || tall)
        .padding(.top, 4)
        .padding(.bottom, 2)
        // Frosted, so whatever scrolls underneath still reads as being there.
        .background {
            Rectangle().fill(.ultraThinMaterial)
                .overlay(Palette.bg.opacity(0.72))
                .overlay(alignment: .top) { Rectangle().fill(Palette.hairline).frame(height: 1) }
                .ignoresSafeArea(edges: [.bottom, .horizontal])
        }
        // Also when the app switches tabs itself (a catch jumping to the book).
        .onChange(of: lit) { _, new in bounces[new, default: 0] += 1 }
        .onChange(of: selection) { tapped = nil }
    }
}
