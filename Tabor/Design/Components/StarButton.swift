import SwiftUI

/// Stars a model (#88): its tags in HUNT get a ★, and HUNT's ★ view shows every one of it
/// running. On the model page and HUNT's card, reading the same stored set.
struct StarButton: View {
    let modelId: String
    /// The card's round chip; on the model page's top bar it sits bare, like SORT.
    var chip = true
    @AppStorage("starredModels") private var starred = StarredModels()

    var body: some View {
        let on = starred.contains(modelId)
        Button {
            on ? Haptics.shared.tick() : Haptics.shared.completed()
            withAnimation(.snappy) { starred.toggle(modelId) }
        } label: {
            Image(systemName: on ? "star.fill" : "star")
                .font(.system(size: chip ? 12 : 15, weight: .bold))
                .foregroundStyle(on ? Palette.yellow : Palette.sub)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 30, height: 30)
                .background(chip ? Palette.chip : .clear, in: Circle())
                .padding(7)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(-7)
        .accessibilityLabel(on ? "Starred" : "Star this model")
        .accessibilityHint("Starred models get a star in HUNT, and a view of their own.")
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}
