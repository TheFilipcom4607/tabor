import SwiftUI

/// The caught vehicle's note, from the reveal's banner: the vehicle page's card, so the sources
/// and IN POLISH come with it. As tall as the note, up to most of the screen; a longer one scrolls.
struct NoteSheet: View {
    let title: String
    let number: Int
    let note: VehicleNote?
    let remark: VehicleRemark?
    @Environment(\.dismiss) private var dismiss
    @State private var height: CGFloat = 360

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Mono("\(String(localized: "NOTE")) · \(FleetNumber.isCoded(number) ? "" : "#")\(FleetNumber.label(number))" as String,
                     size: 10.5, weight: 700, spacing: 0.12, color: Palette.yellow)
                Text(title)
                    .font(TaborFont.grotesk(22, 700))
                    .em(-0.02, size: 22)
                    .foregroundStyle(Palette.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
                NotesCard(note: note, remark: remark)
                    .padding(.top, 14)
                Button {
                    dismiss()
                } label: {
                    Mono("CLOSE", size: 11.5, weight: 600, spacing: 0.12, color: Palette.sub)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.top, 6)
            }
            .padding(.horizontal, 22)
            .padding(.top, 26)
            .padding(.bottom, 4)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
        }
        .scrollBounceBehavior(.basedOnSize)
        .presentationDetents([.height(min(height, Self.screenHeight * 0.8))])
        .presentationDragIndicator(.visible)
        .presentationBackground(Palette.bg)
        .environment(\.colorScheme, .dark)
    }

    private static var screenHeight: CGFloat {
        UIApplication.shared.connectedScenes.lazy.compactMap { $0 as? UIWindowScene }.first?.screen.bounds.height ?? 800
    }
}
