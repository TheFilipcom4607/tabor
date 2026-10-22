import SwiftData
import SwiftUI

enum DexFilter: String, CaseIterable {
    case all = "ALL", bus = "BUS", tram = "TRAM", missing = "MISSING"

    var name: String {
        switch self {
        case .all: String(localized: "ALL", comment: "Book filter")
        case .bus: String(localized: "filter.bus", defaultValue: "BUS", comment: "Book filter: buses only")
        case .tram: String(localized: "filter.tram", defaultValue: "TRAM", comment: "Book filter: trams only")
        case .missing: String(localized: "MISSING", comment: "Book filter: models you have under a quarter of")
        }
    }
}

struct BookIndexView: View {
    @Query private var sightings: [Sighting]
    @State private var filter: DexFilter = .all
    @AppStorage("bookOrder") private var order: BookOrder = .progress
    @Environment(\.wide) private var wide
    @Environment(\.tall) private var tall
    @Environment(Router.self) private var router
    private let catalog = Fleet.catalog

    var body: some View {
        let stats = sightings.stats
        let rows = catalog.models.filter { m in
            switch filter {
            case .all: true
            case .bus: m.kind == .bus
            case .tram: m.kind == .tram
            // Prototype rule: under a quarter collected.
            case .missing: Double(stats.ownedCount(modelId: m.id)) / Double(max(m.fleet, 1)) < 0.25
            }
        }
        let sorted = order.sort(rows, stats: stats)

        VStack(alignment: .leading, spacing: 0) {
            // A phone's width on a tall screen: one row stretched across it is mostly empty bar.
            VStack(alignment: .leading, spacing: 0) {
                TopBar {
                    Mono("YOUR BOOK", size: 12, spacing: 0.16)
                } trailing: {
                    // Same count as the widget: the total leaves vintage, test and works stock out, so the count must too.
                    Mono("\(stats.fleetCaught(catalog: catalog).grouped) / \(catalog.totalFleet.grouped)", size: 12)
                }
                ScreenTitle(text: String(localized: "Warsaw rolling stock"))
                    .padding(.top, 14)
                    .padding(.horizontal, 22)
                // "WSZYSTKIE" and "AUTOBUSY" broke in two mid-word on a 6.3" phone (#49): chips
                // never wrap, they tighten up first and scroll sideways only if that's not enough.
                // The order menu (#99) stays put at the end; the chips get what's left.
                HStack(spacing: 7) {
                    ViewThatFits(in: .horizontal) {
                        filterChips(padding: 12)
                        filterChips(padding: 9)
                        filterChips(padding: 7)
                        ScrollView(.horizontal) { filterChips(padding: 7) }
                            .scrollIndicators(.hidden)
                            .scrollClipDisabled()
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    orderMenu
                }
                .padding(.top, 14)
                .padding(.bottom, 2)
                .padding(.horizontal, 22)
            }
            .wideColumn(tall, width: Self.tallColumn)

            ScrollView {
                LazyVStack(spacing: 9) {
                    // Event wraps first: a set of their own, each only out for a few weeks. Hidden
                    // until the first one's caught: before that it's a row of slots for wraps most
                    // people never had a chance at.
                    let caughtWraps = Set(sightings.compactMap(\.wrap))
                    let wraps = Wrap.shelf(catalog.wraps, caught: caughtWraps).filter { w in
                        switch filter {
                        case .all, .missing: true
                        case .bus: w.kind == .bus
                        case .tram: w.kind == .tram
                        }
                    }
                    if !caughtWraps.isEmpty, !wraps.isEmpty {
                        WrapShelf(wraps: wraps, sightings: sightings, catalog: catalog)
                            .padding(.bottom, 8)
                    }
                    ForEach(sorted.filter(\.regular)) { m in row(m, stats: stats) }
                    // Test, tourist-line and works stock live in sections of their own: they're
                    // passing through, seasonal or not for passengers, not rare.
                    let onTest = sorted.filter(\.onTest)
                    if !onTest.isEmpty {
                        sectionHeader(.onTest, note: String(localized: "BUSES ON TRIAL · NOT PART OF THE FLEET %"))
                        ForEach(onTest) { m in row(m, stats: stats) }
                    }
                    let vintage = sorted.filter(\.vintage)
                    if !vintage.isEmpty {
                        sectionHeader(.vintage, note: String(localized: "TOURIST LINES ON SUMMER WEEKENDS · NOT PART OF THE FLEET %"))
                        ForEach(vintage) { m in row(m, stats: stats) }
                    }
                    // Shown from the start: hidden until the first catch, nobody could find
                    // them to go looking (#78).
                    let works = sorted.filter(\.works)
                    if !works.isEmpty {
                        sectionHeader(.works, note: String(localized: "TRAMWAJE WARSZAWSKIE'S OWN CARS · NOT PART OF THE FLEET %"))
                        ForEach(works) { m in row(m, stats: stats) }
                    }
                    Mono(catalog.sourceDisplay.uppercased(), size: 9, spacing: 0.06, color: Palette.faint)
                        .multilineTextAlignment(.center)
                        .padding(.vertical, 18)
                }
                .padding(.top, 10)
                .padding(.horizontal, 22)
                .frame(maxWidth: tall ? Self.tallColumn : .infinity)
                .fitScrollWidth()
            }
            .scrollIndicators(.hidden)
            .softTopEdge()
        }
        .taborScreen()
    }

    private static let tallColumn: CGFloat = 560

    private func filterChips(padding: CGFloat) -> some View {
        HStack(spacing: 7) {
            ForEach(DexFilter.allCases, id: \.self) { f in
                Button {
                    guard f != filter else { return }
                    Haptics.shared.tick()
                    withAnimation(.snappy) { filter = f }
                } label: {
                    Mono(f.name, size: 11.5, weight: 600, spacing: 0.1,
                         color: f == filter ? Palette.bg : Palette.sub)
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.vertical, 8)
                        .padding(.horizontal, padding)
                        .background(f == filter ? Palette.ink : Palette.chip, in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var orderMenu: some View {
        Menu {
            Picker(String(localized: "Order"), selection: $order) {
                ForEach(BookOrder.allCases, id: \.self) { o in Text(o.name).tag(o) }
            }
        } label: {
            // Lit up while it isn't the usual order, so a reordered book doesn't look broken.
            Image(systemName: "arrow.up.arrow.down")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(order == .progress ? Palette.sub : Palette.bg)
                .frame(width: 33, height: 31)
                .background(order == .progress ? Palette.chip : Palette.ink, in: Capsule())
        }
        .accessibilityLabel(String(localized: "Order"))
        .onChange(of: order) { Haptics.shared.tick() }
    }

    private func sectionHeader(_ tier: Tier, note: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Mono(tier.name, size: 10.5, weight: 700, spacing: 0.14, color: tier.color)
            Mono(note, size: 9.5, color: Palette.faint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 18)
        .padding(.bottom, 2)
    }

    private func row(_ m: VehicleModel, stats: CollectionStats) -> some View {
        BookLink(route: .model(m.id)) {
            DexRow(model: m, owned: stats.ownedCount(modelId: m.id), latest: latestSticker(m.id, stats: stats),
                   selected: wide && router.bookPath.first == .model(m.id))
        }
        .buttonStyle(RowPressStyle())
    }

    private func latestSticker(_ modelId: String, stats: CollectionStats) -> (number: Int, sticker: String?, photo: String?)? {
        guard let v = stats.owned(modelId: modelId).max(by: { $0.lastSeen < $1.lastSeen }) else { return nil }
        return (v.number, sightings.sticker(number: v.number, modelId: modelId), sightings.photo(number: v.number, modelId: modelId))
    }
}

struct DexRow: View {
    let model: VehicleModel
    let owned: Int
    var latest: (number: Int, sticker: String?, photo: String?)? = nil
    /// The page open beside the index, on a wide screen: edged in its tier's colour.
    var selected = false
    @Environment(\.wide) private var wide
    /// Inside the edge where the picked row is lit up.
    private var inset: Bool { wide }

    var body: some View {
        VStack(spacing: 9) {
            HStack(spacing: 10) {
                KindTag(kind: model.kind)
                // One line, shrinking a little if it must; a name too long even then (the works
                // cars: "Konstal 13N overhead line measuring car") wraps instead of losing its end.
                ViewThatFits(in: .horizontal) {
                    name(15).lineLimit(1)
                    name(12).lineLimit(1)
                    name(15).lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                OwnedCount(owned: owned, fleet: model.fleet, size: 13)
            }
            ProgressBar(fraction: Double(owned) / Double(max(model.fleet, 1)), color: model.tier.bar, height: 5)
            HStack {
                Mono(detail, size: 10.5, spacing: 0.1)
                Spacer()
                Mono(model.tier.name, size: 10, weight: 700, spacing: 0.12, color: model.tier.color)
            }
        }
        .padding(.vertical, 13)
        .padding(.horizontal, 15)
        // Room for the sticker: more where it sits inside the edge.
        .padding(.trailing, latest == nil ? 0 : inset ? 76 : 64)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        // Under the sticker, which peeks over the edge.
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .stroke(selected ? model.tier.color : Color.white.opacity(0.06), lineWidth: selected ? 1.5 : 1))
        // Your latest catch of this model, peeking off the edge of the row.
        .overlay(alignment: .trailing) {
            if let latest {
                DieCut(number: latest.number, sticker: latest.sticker, photo: latest.photo, height: 44, tagSize: 9, maxPixel: 240)
                    .frame(width: 74)
                    .rotationEffect(.degrees(stickerTilt(latest.number, range: 6)))
                    .offset(x: inset ? -8 : 6)
            }
        }
        .contentShape(Rectangle())
    }

    private func name(_ size: CGFloat) -> some View {
        Text(model.name)
            .font(TaborFont.grotesk(size, 600))
            .em(-0.015, size: size)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// "2005—2016 · 9 BATCHES", or the number span for single-batch models.
    private var detail: String {
        let years = model.yearsDisplay ?? model.trialDisplay ?? String(localized: "YEAR ?")
        if model.batches.count > 1 { return String(localized: "\(years) · \(model.batches.count) BATCHES") }
        return "\(years) · \(model.rangeDisplay)"
    }
}

/// A way into a page from the index: pushed on a phone; on a wide screen the page opens
/// beside the index instead (`BookTab`).
struct BookLink<Label: View>: View {
    let route: BookRoute
    @ViewBuilder var label: () -> Label
    @Environment(\.wide) private var wide
    @Environment(Router.self) private var router

    var body: some View {
        if wide {
            Button { router.pick(route) } label: { label() }
        } else {
            NavigationLink(value: route) { label() }
        }
    }
}

/// Rows dim and shrink a touch under the finger. Silent: navigation doesn't click.
struct RowPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

/// "3/48" with the denominator dimmed.
struct OwnedCount: View {
    let owned: Int
    let fleet: Int
    var size: CGFloat = 13

    var body: some View {
        (Text("\(owned)").foregroundStyle(Palette.ink)
            + Text("/\(fleet)").foregroundStyle(Palette.faint))
            .font(TaborFont.mono(size, 700))
    }
}

extension Int {
    /// "2 836" — thin grouping like the design.
    var grouped: String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        // No-break, so "2 673" never splits across a line end.
        f.groupingSeparator = "\u{00A0}"
        return f.string(from: NSNumber(value: self)) ?? String(self)
    }
}

/// The event wraps caught, and those still out or coming, newest first: the catch in it on foil,
/// or a slot to find it in. Each opens its vehicle's page, where the wraps are forms side by side.
private struct WrapShelf: View {
    let wraps: [Wrap]
    let sightings: [Sighting]
    let catalog: FleetCatalog

    var body: some View {
        let caught = Dictionary(sightings.compactMap { s in s.wrap.map { ($0, s) } }) { a, b in a.date > b.date ? a : b }
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Mono("EVENT WRAPS", size: 10.5, weight: 700, spacing: 0.14, color: Palette.foilInk)
                    Mono("EACH ONE OUT FOR A FEW WEEKS", size: 9.5, color: Palette.faint)
                }
                Spacer()
                Mono("\(wraps.filter { caught[$0.id] != nil }.count)/\(wraps.count)", size: 12, weight: 700, color: Palette.foilInk)
            }
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(wraps.reversed()) { w in card(w, caught: caught[w.id]) }
                }
                .padding(.vertical, 4)
            }
            .scrollIndicators(.hidden)
            .scrollClipDisabled()
        }
        .padding(.top, 8)
    }

    @ViewBuilder
    private func card(_ w: Wrap, caught: Sighting?) -> some View {
        let modelId = caught?.modelId ?? catalog.match(number: w.number, kind: w.kind).suggested?.id
        let label = VStack(alignment: .leading, spacing: 6) {
            ZStack {
                if let caught {
                    DieCut(number: w.number, sticker: caught.stickerFile, photo: caught.photoFile, height: 62, tagSize: 10,
                           maxPixel: 300, foil: true)
                } else {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Palette.foilInk.opacity(0.45), style: StrokeStyle(lineWidth: 1.2, dash: [4, 4]))
                        .background(Palette.slot.opacity(0.6), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay {
                            VStack(spacing: 4) {
                                Image(systemName: w.symbol).font(.system(size: 17, weight: .bold))
                                Mono(FleetNumber.label(w.number), size: 11, color: Palette.ghost)
                            }
                            .foregroundStyle(Palette.foilInk.opacity(0.55))
                        }
                }
            }
            .frame(width: 118, height: 72)
            Mono(w.nameDisplay, size: 9.5, weight: 700, spacing: 0.1, color: caught == nil ? Palette.sub : Palette.foilInk)
                .lineLimit(1)
        }
        .frame(width: 118, alignment: .leading)
        if let modelId {
            BookLink(route: .vehicle(modelId: modelId, number: w.number)) { label }
                .buttonStyle(StickerPressStyle(tilt: stickerTilt(w.number)))
                .accessibilityLabel(caught == nil ? Text("\(w.nameDisplay), \(String(w.number)): not caught yet")
                                                  : Text("\(w.nameDisplay), \(String(w.number)): caught"))
        } else {
            label
        }
    }
}
