import MapKit
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct MeView: View {
    @Query(sort: \Sighting.date, order: .reverse) private var sightings: [Sighting]
    @Environment(Router.self) private var router
    @State private var showSettings = false
    @State private var showMap = false
    @State private var showStats = false
    @State private var showWidgetHowTo = false
    @AppStorage(WidgetTip.seenKey) private var widgetTipSeen = false
    @AppStorage(SupportTip.seenKey) private var supportTipSeen = false
    private let catalog = Fleet.catalog

    var body: some View {
        let stats = sightings.stats
        let trophies = stats.rarest(catalog: catalog, limit: 3)

        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                TopBar {
                    HStack(spacing: 8) {
                        Mono("ME", size: 12, spacing: 0.16)
                        if TipJar.shared.isSupporter {
                            HStack(spacing: 4) {
                                Image(systemName: "heart.fill").font(.system(size: 8, weight: .bold))
                                Mono("SUPPORTER", size: 9.5, weight: 700, spacing: 0.12, color: Palette.yellow)
                            }
                            .foregroundStyle(Palette.yellow)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Palette.yellow.opacity(0.12), in: Capsule())
                            .accessibilityElement(children: .combine)
                        }
                    }
                } trailing: {
                    Button {
                        showSettings = true
                    } label: { Mono("SETTINGS", size: 12) }
                    .buttonStyle(.plain)
                }

                VStack(alignment: .leading, spacing: 4) {
                    ScreenTitle(text: String(localized: "Trophy shelf"))
                    Mono(trophies.isEmpty ? "NOTHING ON THE SHELF YET"
                         : "YOUR \(trophies.count) RAREST OF \(stats.caught)",
                         size: 11, color: Palette.sub)
                }
                .padding(.top, 16)
                .padding(.horizontal, 22)

                TrophyShelf(trophies: trophies, sightings: sightings)
                    .padding(.top, 20)
                    .padding(.horizontal, 22)

                HStack(alignment: .firstTextBaseline) {
                    SectionLabel(text: String(localized: "STATS"))
                    Spacer()
                    if !sightings.isEmpty {
                        Button {
                            showStats = true
                        } label: { Mono("ALL STATS", size: 10.5, color: Palette.yellow) }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.top, 18)
                .padding(.bottom, 9)
                .padding(.horizontal, 22)

                Button {
                    if !sightings.isEmpty { showStats = true }
                } label: {
                    StatsStrip(items: [
                        (stats.caught.grouped, String(localized: "CAUGHT"), Palette.ink),
                        (fleetShareText(stats.fleetShare(catalog: catalog)), String(localized: "OF FLEET"), Palette.yellow),
                        ("\(Streak.days(sightings.map(\.date)))", String(localized: "DAY STREAK"), Palette.ink),
                        (depotsTouched(stats), String(localized: "DEPOTS"), Palette.ink),
                    ])
                }
                .buttonStyle(StickerPressStyle())
                .padding(.horizontal, 22)

                // One nudge at a time: the widgets first, then (much later) the tips.
                if !widgetTipSeen, sightings.count >= WidgetTip.afterCatches {
                    TipCard(icon: "square.grid.2x2.fill", kicker: "NEW: WIDGETS", title: "Put your book on your Home Screen") {
                        showWidgetHowTo = true
                        widgetTipSeen = true
                    } dismiss: {
                        withAnimation(.snappy) { widgetTipSeen = true }
                    }
                    .padding(.top, 18)
                    .padding(.horizontal, 22)
                } else if !supportTipSeen, !TipJar.shared.tipped, sightings.count >= SupportTip.afterCatches {
                    TipCard(icon: "heart.fill", kicker: "ENJOYING TABOR?", title: "Consider supporting it with a tip") {
                        showSettings = true
                        supportTipSeen = true
                    } dismiss: {
                        withAnimation(.snappy) { supportTipSeen = true }
                    }
                    .padding(.top, 18)
                    .padding(.horizontal, 22)
                }

                BadgeShelf(badges: Achievements.evaluate(sightings.map(\.record), catalog: catalog))
                    .padding(.top, 18)
                    .padding(.horizontal, 22)

                if !sightings.isEmpty {
                    CatchLogSection(sightings: sightings)
                        .padding(.top, 16)
                        .padding(.horizontal, 22)
                }

                HStack(alignment: .firstTextBaseline) {
                    SectionLabel(text: String(localized: "WHERE YOU SPOT"))
                    Spacer()
                    Button {
                        showMap = true
                    } label: { Mono("OPEN MAP", size: 10.5, color: Palette.yellow) }
                    .buttonStyle(.plain)
                }
                .padding(.top, 16)
                .padding(.bottom, 9)
                .padding(.horizontal, 22)

                SpotSnapshot(sightings: sightings)
                    .frame(height: 190)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color.white.opacity(0.06)))
                    .onTapGesture {
                        showMap = true
                    }
                    .padding(.horizontal, 22)
                mapCaption
                    .padding(.horizontal, 22)
                    .padding(.top, 8)
                    .padding(.bottom, 22)
            }
            .fitScrollWidth()
        }
        .scrollIndicators(.hidden)
        .taborScreen()
        .sheet(isPresented: $showSettings) { SettingsSheet() }
        .sheet(isPresented: $showWidgetHowTo) { WidgetHowTo() }
        .sheet(isPresented: $showStats) {
            StatsSheet(sightings: sightings) { route in
                showStats = false
                switch route {
                case .model(let id): router.openModel(id)
                case .vehicle(let modelId, let number): router.openVehicle(modelId: modelId, number: number)
                }
            }
        }
        // Every time ME comes up, not once: the tab stays alive behind the others.
        .task(id: router.tab == .me) {
            guard router.tab == .me else { return }
            if !widgetTipSeen, await WidgetTip.anyInstalled() { widgetTipSeen = true }
        }
        .fullScreenCover(isPresented: $showMap) {
            ZStack(alignment: .topLeading) {
                SpotMap(sightings: sightings, interactive: true) { s in
                    showMap = false
                    router.openVehicle(modelId: s.modelId, number: s.number)
                }
                Button {
                    showMap = false
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(Palette.ink)
                        .frame(width: 44, height: 44)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .padding(.leading, 18)
                .padding(.top, 8)
            }
            .windowControlsClearance()
            .preferredColorScheme(.dark)
        }
    }

    private var mapCaption: some View {
        let geotagged = sightings.filter { $0.latitude != nil && $0.pairedWith == nil }
        let patch = Dictionary(grouping: geotagged.compactMap(\.district), by: { $0 })
            .max { $0.value.count < $1.value.count }?.key
        return HStack {
            Mono(patch.map { String(localized: "\($0.uppercased()) IS YOUR PATCH") } ?? String(localized: "GEOTAG A CATCH TO START YOUR MAP"),
                 size: 9.5, color: Palette.sub)
            Spacer()
            Mono("\(geotagged.count) PINS", size: 9.5, color: Palette.faint)
        }
        .padding(.horizontal, 4)
    }

    /// Depots whose vehicles you've caught, out of all depots in the snapshot.
    private func depotsTouched(_ stats: CollectionStats) -> String {
        var hit = Set<String>()
        for v in stats.vehicles {
            if let b = catalog.model(id: v.modelId)?.batch(containing: v.number) {
                hit.insert(b.depotCode + b.depotName)
            }
        }
        return "\(hit.count)/\(catalog.depots.count)"
    }
}

// MARK: - Trophy shelf

private struct TrophyShelf: View {
    let trophies: [OwnedVehicle]
    let sightings: [Sighting]
    @Environment(Router.self) private var router
    private let catalog = Fleet.catalog

    var body: some View {
        if trophies.isEmpty {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [5, 5]))
                .foregroundStyle(Color.white.opacity(0.14))
                .frame(height: 180)
                .overlay(
                    VStack(spacing: 8) {
                        Image(systemName: "trophy")
                            .font(.system(size: 26, weight: .light))
                            .foregroundStyle(Palette.faint)
                        Mono("YOUR RAREST CATCHES LIVE HERE", size: 10.5, color: Palette.faint)
                    }
                )
        } else if trophies.count == 1 {
            trophy(trophies[0], big: true, tilt: -1.4)
                .frame(maxWidth: 280)
                .frame(maxWidth: .infinity)
        } else {
            HStack(alignment: .bottom, spacing: 11) {
                trophy(trophies[0], big: true, tilt: -1.4)
                    .frame(maxWidth: .infinity)
                VStack(spacing: 10) {
                    if trophies.count > 1 { trophy(trophies[1], big: false, tilt: 1.2) }
                    if trophies.count > 2 { trophy(trophies[2], big: false, tilt: -0.8) }
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    private func trophy(_ v: OwnedVehicle, big: Bool, tilt: Double) -> some View {
        let model = catalog.model(id: v.modelId)
        let tier = model?.tier ?? .common
        let ink = tier == .gold ? Palette.goldInk : (tier == .common ? Palette.stickerSub : tier.color)
        return VStack(spacing: big ? 8 : 6) {
            // A vehicle caught in a wrap shows off that catch.
            let dressed = v.wraps.isEmpty ? nil : sightings.of(number: v.number, modelId: v.modelId).first { $0.wrap != nil && $0.hasPicture }
            Button {
                router.openVehicle(modelId: v.modelId, number: v.number)
            } label: {
                DieCut(number: v.number,
                       sticker: dressed.map(\.stickerFile) ?? sightings.sticker(number: v.number, modelId: v.modelId),
                       photo: dressed?.photoFile ?? sightings.photo(number: v.number, modelId: v.modelId),
                       height: big ? 150 : 70, tagSize: big ? 15 : 11, maxPixel: big ? 900 : 420, foil: dressed != nil) {
                    Mono("/\(model?.fleet ?? 0)", size: big ? 10 : 8.5, weight: 700, spacing: 0, color: ink)
                }
            }
            .buttonStyle(StickerPressStyle(tilt: tilt))
            // The shelf ledge, with the model name engraved underneath.
            Capsule().fill(Palette.track).frame(height: 3)
            if big {
                Mono((model?.name ?? "").uppercased(), size: 9, color: Palette.faint).lineLimit(1)
            }
        }
    }
}

/// Stickers squish, flatten their tilt and give a soft haptic when pressed.
/// A ButtonStyle (not a drag gesture) so it never fights the scroll view.
struct StickerPressStyle: ButtonStyle {
    var tilt: Double = 0

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .rotationEffect(.degrees(configuration.isPressed ? 0 : tilt))
            .animation(.spring(response: 0.28, dampingFraction: 0.55), value: configuration.isPressed)
            .onChange(of: configuration.isPressed) { _, down in
                if down { Haptics.shared.press() }
            }
    }
}

// MARK: - Stats strip

private struct StatsStrip: View {
    let items: [(String, String, Color)]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                VStack(spacing: 3) {
                    Text(item.0)
                        .font(TaborFont.mono(18, 700))
                        .foregroundStyle(item.2)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    Mono(item.1, size: 8.5, color: Palette.dim)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .padding(.horizontal, 6)
                .overlay(alignment: .leading) {
                    if i > 0 { Rectangle().fill(Color.white.opacity(0.06)).frame(width: 1) }
                }
            }
        }
        .background(Palette.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color.white.opacity(0.06)))
    }
}

// MARK: - Map

struct SpotMap: View {
    let sightings: [Sighting]
    let interactive: Bool
    /// Interactive only: a picked catch's OPEN, to its page in the book.
    var onOpen: ((Sighting) -> Void)?
    /// The catch whose card is open. Tapping empty map clears it.
    @State private var selectedId: UUID?
    @Namespace private var mapScope
    static let warsaw = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 52.2297, longitude: 21.0122),
        span: MKCoordinateSpan(latitudeDelta: 0.22, longitudeDelta: 0.22))

    var body: some View {
        // A coupled tram's second car sits on the first one's spot: one pin for the pair.
        let pins = sightings.filter { $0.latitude != nil && $0.longitude != nil && $0.pairedWith == nil }
        let selected = pins.first { $0.id == selectedId }
        ZStack(alignment: .bottom) {
            Map(initialPosition: pins.isEmpty ? .region(Self.warsaw) : .automatic,
                interactionModes: interactive ? .all : [],
                selection: interactive ? $selectedId : .constant(nil), scope: mapScope) {
                ForEach(pins) { s in
                    // A catch in an event wrap: foil pink, and a little bigger.
                    let wrapped = s.wrap != nil
                    let color = wrapped ? Palette.foilInk : (Fleet.catalog.model(id: s.modelId)?.tier ?? .common).mapColor
                    let picked = s.id == selectedId
                    Annotation("", coordinate: CLLocationCoordinate2D(latitude: s.latitude!, longitude: s.longitude!)) {
                        ZStack {
                            // A soft glow drawn as a gradient: a blur on each of a few hundred pins
                            // made the map lag whenever it moved.
                            Circle()
                                .fill(RadialGradient(colors: [color.opacity(picked ? 0.5 : 0.35), color.opacity(0)],
                                                     center: .center, startRadius: 0, endRadius: picked ? 20 : 13))
                                .frame(width: picked ? 40 : 26, height: picked ? 40 : 26)
                            Circle().fill(wrapped ? AnyShapeStyle(AngularGradient(colors: Palette.foil, center: .center)) : AnyShapeStyle(color))
                                .frame(width: picked ? 13 : wrapped ? 10 : 7, height: picked ? 13 : wrapped ? 10 : 7)
                                .overlay(Circle().stroke(picked ? Palette.ink : Palette.bg.opacity(0.8), lineWidth: 2))
                        }
                        .animation(.spring(response: 0.3, dampingFraction: 0.6), value: picked)
                    }
                    .annotationTitles(.hidden)
                    .tag(s.id)
                }
            }
            .mapStyle(.standard(elevation: .flat, emphasis: .muted, pointsOfInterest: .excludingAll, showsTraffic: false))
            .mapControls {}
            .environment(\.colorScheme, .dark)
            .ignoresSafeArea(edges: interactive ? .all : [])

            if let selected, let onOpen {
                SpotCard(sighting: selected, sightings: sightings) { onOpen(selected) }
                    .id(selected.id)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 10)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        // The map runs under the status bar, and so would its own compass (#39): this one keeps
        // to the safe area, level with the close button. It shows only while the map is turned.
        .overlay(alignment: .topTrailing) {
            if interactive {
                MapCompass(scope: mapScope)
                    .padding(.trailing, 18)
                    .padding(.top, 8)
            }
        }
        .mapScope(mapScope)
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: selectedId)
        .onChange(of: selectedId) { _, id in if id != nil { Haptics.shared.tick() } }
    }
}

/// ME's map of where you've caught things: a still picture of the map with your catches drawn
/// on it. A live map in the scrolling page lagged it by a frame and wobbled; a picture scrolls
/// with the page. Tapping it opens the real one.
private struct SpotSnapshot: View {
    let sightings: [Sighting]
    @State private var image: UIImage?
    @Environment(\.displayScale) private var scale

    private struct Pin: Hashable {
        let latitude: Double
        let longitude: Double
        let tier: Tier
        /// Caught in an event wrap.
        var wrapped = false
    }

    /// What the picture shows: redrawn when a catch or the size changes.
    private struct Request: Hashable {
        let width: Double
        let height: Double
        let pins: [Pin]
    }

    var body: some View {
        // The full map's pins: one for a coupled pair.
        let pins = sightings.compactMap { s -> Pin? in
            guard s.pairedWith == nil, let lat = s.latitude, let lon = s.longitude else { return nil }
            return Pin(latitude: lat, longitude: lon, tier: Fleet.catalog.model(id: s.modelId)?.tier ?? .common,
                       wrapped: s.wrap != nil)
        }
        GeometryReader { geo in
            ZStack {
                Palette.card
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .transition(.opacity)
                }
            }
            .task(id: Request(width: geo.size.width, height: geo.size.height, pins: pins)) {
                let drawn = await Self.render(pins, size: geo.size, scale: scale)
                withAnimation(.easeOut(duration: 0.25)) { image = drawn ?? image }
            }
        }
        .accessibilityLabel("Map of where you've caught vehicles")
    }

    private static func render(_ pins: [Pin], size: CGSize, scale: CGFloat) async -> UIImage? {
        guard size.width > 0, size.height > 0 else { return nil }
        let options = MKMapSnapshotter.Options()
        options.region = region(fitting: pins)
        options.size = size
        options.traitCollection = UITraitCollection {
            $0.userInterfaceStyle = .dark
            $0.displayScale = scale
        }
        let map = MKStandardMapConfiguration(elevationStyle: .flat, emphasisStyle: .muted)
        map.pointOfInterestFilter = .excludingAll
        options.preferredConfiguration = map
        guard let snapshot = try? await MKMapSnapshotter(options: options).start() else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            snapshot.image.draw(at: .zero)
            let cg = ctx.cgContext
            let edge = UIColor(Palette.bg).withAlphaComponent(0.8).cgColor
            // As the full map draws them: a glow, then a dot with a dark edge.
            for pin in pins {
                let p = snapshot.point(for: CLLocationCoordinate2D(latitude: pin.latitude, longitude: pin.longitude))
                let color = UIColor(pin.wrapped ? Palette.foilInk : pin.tier.mapColor)
                let glow = [color.withAlphaComponent(0.35).cgColor, color.withAlphaComponent(0).cgColor] as CFArray
                if let gradient = CGGradient(colorsSpace: nil, colors: glow, locations: [0, 1]) {
                    cg.drawRadialGradient(gradient, startCenter: p, startRadius: 0, endCenter: p, endRadius: 13, options: [])
                }
                let r: CGFloat = pin.wrapped ? 5 : 3.5
                let dot = CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)
                cg.setFillColor(color.cgColor)
                cg.fillEllipse(in: dot)
                cg.setStrokeColor(edge)
                cg.setLineWidth(2)
                cg.strokeEllipse(in: dot)
            }
        }
    }

    /// Every catch with room round the edge, as the live map's automatic view does.
    private static func region(fitting pins: [Pin]) -> MKCoordinateRegion {
        guard let first = pins.first else { return SpotMap.warsaw }
        var lat = (first.latitude, first.latitude), lon = (first.longitude, first.longitude)
        for p in pins {
            lat = (min(lat.0, p.latitude), max(lat.1, p.latitude))
            lon = (min(lon.0, p.longitude), max(lon.1, p.longitude))
        }
        return MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: (lat.0 + lat.1) / 2, longitude: (lon.0 + lon.1) / 2),
            span: MKCoordinateSpan(latitudeDelta: max((lat.1 - lat.0) * 1.3, 0.01),
                                   longitudeDelta: max((lon.1 - lon.0) * 1.3, 0.01)))
    }
}

/// A catch picked on the full-screen map: its sticker, when and where, and a way to its page.
private struct SpotCard: View {
    let sighting: Sighting
    let sightings: [Sighting]
    let onOpen: () -> Void

    var body: some View {
        let s = sighting
        let model = Fleet.catalog.model(id: s.modelId)
        let tier = model?.tier ?? .common
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 14) {
                // This sighting's own sticker, else the vehicle's best.
                DieCut(number: s.number,
                       sticker: s.stickerFile ?? sightings.sticker(number: s.number, modelId: s.modelId),
                       photo: s.photoFile ?? sightings.photo(number: s.number, modelId: s.modelId),
                       height: 92, tagSize: 11, maxPixel: 420, foil: s.wrap != nil) { EmptyView() }
                    .frame(width: 128)
                VStack(alignment: .leading, spacing: 5) {
                    Text(model?.name ?? s.modelId)
                        .font(TaborFont.grotesk(19, 700))
                        .em(-0.03, size: 19)
                        .lineLimit(2)
                        .minimumScaleFactor(0.8)
                    Text(VehicleView.stamp.string(from: s.date))
                        .font(TaborFont.grotesk(13))
                        .foregroundStyle(Palette.sub)
                    if let line = s.line {
                        Mono("LINE \(line)", size: 10.5, weight: 600, color: Palette.routeInk)
                    }
                    if let wrap = s.wrap.flatMap(Fleet.catalog.wrap(id:)) {
                        WrapTag(wrap: wrap, size: 9.5)
                    }
                    if let place = [s.street, s.district].compactMap({ $0 }).joined(separator: " · ").nonEmpty {
                        Mono(place.uppercased(), size: 10.5, color: Palette.dim)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
            }
            Button(action: onOpen) {
                HStack(spacing: 7) {
                    Image(systemName: AppTab.book.symbol)
                        .font(.system(size: 12, weight: .bold))
                    Mono("OPEN", size: 12, weight: 700, spacing: 0.12, color: tier.onMapColor)
                }
                .foregroundStyle(tier.onMapColor)
                .frame(maxWidth: .infinity)
                .padding(13)
                .background(tier.mapColor, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            }
            .buttonStyle(StickerPressStyle())
            .accessibilityLabel("Open #\(FleetNumber.label(s.number)) in the book")
        }
        .padding(16)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(tier.mapColor.opacity(0.35)))
        .shadow(color: .black.opacity(0.45), radius: 16, y: 8)
    }
}

// MARK: - Settings

struct SettingsSheet: View {
    @AppStorage(Haptics.enabledKey) private var haptics = true
    @AppStorage("saveToGallery") private var saveToGallery = true
    @AppStorage("geotag") private var geotag = true
    @State private var showIntro = false
    @AppStorage(DebugRecord.enabledKey) private var debugMode = false
    @State private var debugCount = DebugRecord.count
    @AppStorage(DebugRecord.unlockedKey) private var debugUnlocked = false
    @State private var versionTaps = 0
    @State private var exportURL: URL?
    @State private var exporting = false
    @State private var confirmDelete = false
    @State private var confirmWipe = false
    @AppStorage(FleetUpdater.enabledKey) private var fleetUpdates = true
    @AppStorage(WeatherService.enabledKey) private var weatherLookup = true
    @AppStorage(LiveFleetService.keyOverrideKey) private var umKey = ""
    @State private var fleetStatus: String?
    @State private var checkingFleet = false
    @State private var backingUp = false
    @State private var importing = false
    @State private var backupMessage: String?
    @State private var storage: StorageUsage.Breakdown?
    @State private var showControlHowTo = false
    @State private var showWidgetHowTo = false
    @Query private var allSightings: [Sighting]
    @Query private var manual: [ManualAssignment]
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                // First, so it shows at the sheet's half height (the support tip on ME opens here).
                TipJarSection()
                Section {
                    Toggle("Haptics", isOn: $haptics)
                        .onChange(of: haptics) { _, on in if on { Haptics.shared.completed() } }
                    Toggle("Save catches to Photos", isOn: $saveToGallery)
                    Toggle("Geotag catches", isOn: $geotag)
                    Toggle("Weather for badges", isOn: $weatherLookup)
                } footer: {
                    Text("Weather comes from Open-Meteo: TABOR sends each geotagged catch's time and rough location (to about 1 km). Nothing else leaves your phone.")
                }
                AppIconSection()
                if showsDebug {
                    Section {
                        Toggle("Debug mode", isOn: $debugMode)
                        if debugMode || debugCount > 0 {
                            LabeledContent("Logged shots", value: "\(debugCount)")
                            Button(exporting ? "Zipping…" : "Share as ZIP") {
                                exporting = true
                                Task {
                                    exportURL = await Task.detached { DebugRecord.exportZip() }.value
                                    exporting = false
                                }
                            }
                            .disabled(debugCount == 0 || exporting)
                            Button("Delete debug data", role: .destructive) { confirmDelete = true }
                                .disabled(debugCount == 0)
                        }
                        if debugMode {
                            Button("Delete all catches", role: .destructive) { confirmWipe = true }
                                .disabled(allSightings.isEmpty)
                        }
                    } header: {
                        Text("Debug")
                    } footer: {
                        Text("Saves every shot — failed reads and retakes included — with what the OCR and sticker cutter saw. Also in Files › On My iPhone › TABOR › Debug.")
                    }
                }
                Section {
                    LabeledContent("Key", value: keySource)
                    LabeledContent("Status") {
                        HStack(spacing: 6) {
                            if case .loading = LiveFleetService.shared.status { ProgressView().controlSize(.small) }
                            Text(liveStatus.text).foregroundStyle(liveStatus.color)
                        }
                    }
                    TextField(LiveFleetService.proxy == nil ? "Paste your key" : "Use your own key instead", text: $umKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.system(.body, design: .monospaced))
                        // Checks the key on open, and again once you stop typing.
                        .task(id: umKey) {
                            try? await Task.sleep(for: .milliseconds(600))
                            guard !Task.isCancelled else { return }
                            let live = LiveFleetService.shared
                            live.keyChanged()
                            if live.fresh() == nil, LiveFleetService.source != nil { await live.refresh() }
                        }
                } header: {
                    Text("Live data")
                } footer: {
                    Text("HUNT and the camera use Warsaw's open-data feed of live bus and tram positions (dane.um.warszawa.pl) — only while they're on screen. Leave the key empty to go through TABOR's server, or get your own free key at dane.um.warszawa.pl.")
                }
                Section {
                    Button(backingUp ? "Packing…" : "Export catches") { exportBackup() }
                        .disabled(allSightings.isEmpty || backingUp)
                    Button("Export as spreadsheet (CSV)") { exportCSV() }
                        .disabled(allSightings.isEmpty || backingUp)
                    Button("Import a backup…") { importing = true }
                        .disabled(backingUp)
                } header: {
                    Text("Backup")
                } footer: {
                    // No iCloud entitlement in this build (personal teams can't sign it), so the
                    // book only lives on this phone: don't promise sync or a restore on reinstall.
                    Text("Your book lives on this phone — deleting TABOR deletes it. Export a ZIP now and then: it keeps every sighting, photo and sticker. Importing only adds what's missing.")
                }
                Section {
                    if let storage {
                        LabeledContent("All together") {
                            Text(StorageUsage.text(storage.total)).fontWeight(.semibold)
                        }
                        storageRow("Photos", storage.photos)
                        storageRow("Stickers", storage.stickers)
                        storageRow("Book", storage.book)
                        storageRow("Fleet and route data", storage.data)
                        storageRow("Debug shots", storage.debug)
                        storageRow("Other", storage.other)
                    } else {
                        LabeledContent("All together") { ProgressView().controlSize(.small) }
                    }
                } header: {
                    Text("Storage")
                } footer: {
                    Text("Shots saved to Photos aren't counted here.")
                }
                Section {
                    if Fleet.catalog.models.isEmpty {
                        Text("Fleet data couldn't be loaded. Check for an update, or reinstall TABOR.")
                            .foregroundStyle(Palette.red)
                    }
                    LabeledContent("Vehicles", value: Fleet.catalog.totalFleet.grouped)
                    LabeledContent("Models", value: "\(Fleet.catalog.models.count)")
                    Toggle("Download fleet updates", isOn: $fleetUpdates)
                    Button(checkingFleet ? "Checking…" : "Check now") { checkFleet() }
                        .disabled(checkingFleet)
                } header: {
                    Text("Fleet data")
                } footer: {
                    VStack(alignment: .leading, spacing: 6) {
                        if let fleetStatus { Text(fleetStatus).foregroundStyle(Palette.yellow) }
                        Text(Fleet.catalog.sourceDisplay)
                        Text("New deliveries show up without an app update: TABOR checks GitHub for a fresher ZTM snapshot once a day.")
                        Text("District outlines for the badges: © OpenStreetMap contributors.")
                    }
                }
                Section {
                    Button("Home Screen widgets") { showWidgetHowTo = true }
                    Button("Catch from the Lock Screen") { showControlHowTo = true }
                    Button("Show the intro again") { showIntro = true }
                } footer: { betaNote }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .tint(Palette.yellow)
        .presentationDetents([.medium, .large])
        .onAppear { debugCount = DebugRecord.count }
        .task { await measureStorage() }
        .sheet(item: $exportURL) { url in
            // The ZIP or CSV is only for handing over; wherever it went keeps its own copy.
            ShareSheet(items: [url])
                .onDisappear {
                    try? FileManager.default.removeItem(at: url)
                    Task { await measureStorage() }
                }
        }
        .fullScreenCover(isPresented: $showIntro) { OnboardingView { showIntro = false }.windowControlsClearance() }
        .sheet(isPresented: $showControlHowTo) { CatchControlHowTo() }
        .sheet(isPresented: $showWidgetHowTo) { WidgetHowTo() }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.zip]) { result in
            if case .success(let url) = result { importBackup(url) }
        }
        .alert("Backup", isPresented: Binding(get: { backupMessage != nil }, set: { if !$0 { backupMessage = nil } })) {
            Button("OK") {}
        } message: {
            Text(backupMessage ?? "")
        }
        .confirmationDialog("Delete all \(allSightings.count) catches?", isPresented: $confirmWipe, titleVisibility: .visible) {
            Button("Delete everything in the book", role: .destructive) { wipeBook() }
        } message: {
            Text("Every sighting, photo, sticker and hand-picked model goes. Shots already saved to your Photos stay. This can't be undone.")
        }
        .confirmationDialog("Delete all debug data?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete \(debugCount) shots", role: .destructive) {
                DebugRecord.deleteAll()
                debugCount = 0
                Task { await measureStorage() }
            }
        }
    }
}

extension SettingsSheet {
    var liveStatus: (text: String, color: Color) {
        let live = LiveFleetService.shared
        switch live.status {
        case .noKey: return (String(localized: "No key"), Palette.red)
        case .idle, .loading: return (String(localized: "Checking…"), Palette.sub)
        case .live:
            let n = live.snapshot?.vehicles.count ?? 0
            return (String(localized: "Working · \(n) vehicles"), Palette.green)
        case .error(let why): return (live.fresh(maxAge: 120) != nil ? String(localized: "Working (last call failed)") : why, Palette.red)
        case .late(let age): return (String(localized: "Running late · \(Int((age / 60).rounded())) min behind"), Palette.yellow)
        }
    }

    /// Which key is in use, without showing all of it.
    var keySource: String {
        if let own = LiveFleetService.overrideKey { return String(localized: "Your own · …\(String(own.suffix(4)))") }
        if LiveFleetService.proxy != nil { return String(localized: "TABOR's server") }
        return String(localized: "None", comment: "No API key")
    }
}

extension SettingsSheet {
    /// Debug: start the book from scratch.
    func wipeBook() {
        try? context.delete(model: Sighting.self)
        try? context.delete(model: ManualAssignment.self)
        try? context.save()
        PhotoStore.deleteAll()
        Haptics.shared.nope()
        Task { await measureStorage() }
    }
}

extension SettingsSheet {
    /// Xcode builds always show Debug. TestFlight and App Store builds keep it hidden until
    /// it's unlocked, or while it's still on or holding shots from before it was hidden.
    var showsDebug: Bool {
        #if DEBUG
        true
        #else
        debugUnlocked || debugMode || debugCount > 0
        #endif
    }

    /// Signs off the bottom of Settings, with the build to quote. The same for everyone: App
    /// Review runs in the sandbox like TestFlight, so a TestFlight-only beta note would show
    /// the reviewer a beta too (guideline 2.2).
    var betaNote: some View {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        let line = debugUnlocked ? "\(version) (\(build)) · DEBUG" : "\(version) (\(build))"
        return VStack(spacing: 6) {
            Text("Thank you for using TABOR 💛")
                .font(TaborFont.grotesk(15, 600))
                .foregroundStyle(Palette.ink)
            Text("Something broken, or a bus it got wrong? Write to me:")
                .multilineTextAlignment(.center)
            Link("tabor@thefilip.com", destination: URL(string: "mailto:tabor@thefilip.com")!)
                .font(TaborFont.grotesk(14, 600))
                .foregroundStyle(Palette.yellow)
            // The testers whose GitHub issues shaped the app (#76). Handles, so never translated.
            Text("Thanks to everyone who tested the beta, above all \(["Szpieg0", "Pepe-PL", "flyingkonstal"].formatted(.list(type: .and))).")
                .multilineTextAlignment(.center)
                .padding(.top, 6)
            Mono(line, size: 10, spacing: 0.12, color: debugUnlocked ? Palette.yellow : Palette.faint)
                .padding(.top, 4)
                .contentShape(Rectangle())
                // Seven taps unlock Debug, like Android's developer options.
                .onTapGesture {
                    guard !debugUnlocked else { return }
                    versionTaps += 1
                    if versionTaps >= 7 {
                        withAnimation { debugUnlocked = true }
                        Haptics.shared.completed()
                    }
                }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
    }

    func exportBackup() {
        backingUp = true
        let manifest = BackupService.manifest(sightings: allSightings, manual: manual)
        Task {
            let result = await Task.detached { Result { try BackupService.export(manifest) } }.value
            backingUp = false
            switch result {
            case .success(let url): exportURL = url
            case .failure(let error): backupMessage = String(localized: "Couldn't export: \(error.localizedDescription)")
            }
        }
    }

    /// The catches as a table for Excel or Numbers (#97). Not a backup: no photos, and
    /// nothing reads it back in.
    func exportCSV() {
        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.dateFormat = "yyyy-MM-dd HHmm"
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("TABOR catches \(stamp.string(from: Date())).csv")
        do {
            try Data(CatchCSV.make(records: allSightings.map(\.record), catalog: Fleet.catalog).utf8).write(to: url)
            exportURL = url
        } catch {
            backupMessage = String(localized: "Couldn't export: \(error.localizedDescription)")
        }
    }

    func importBackup(_ url: URL) {
        backingUp = true
        Task {
            // Unzipping and writing photos happens off the main thread; inserting records on it.
            let result = await Task.detached { Result { try BackupService.read(url) } }.value
            backingUp = false
            do {
                let added = try context.restore(try result.get(), into: allSightings, manual: manual)
                Haptics.shared.completed()
                backupMessage = added == 0 ? String(localized: "Everything in that backup is already in your book.")
                    : String(localized: "Added \(added) sightings to your book.")
                await measureStorage()
            } catch {
                backupMessage = String(localized: "Couldn't import: \(error.localizedDescription)")
            }
        }
    }

    func measureStorage() async {
        let stickers = Set(allSightings.compactMap(\.stickerFile))
        storage = await Task.detached { StorageUsage.measure(stickers: stickers) }.value
    }

    /// Empty parts are left out.
    @ViewBuilder func storageRow(_ title: LocalizedStringKey, _ bytes: Int64) -> some View {
        if bytes > 0 {
            LabeledContent(title, value: StorageUsage.text(bytes))
        }
    }

    func checkFleet() {
        checkingFleet = true
        Task {
            let outcome = await FleetUpdater.check()
            checkingFleet = false
            switch outcome {
            case .downloaded(let fetched): fleetStatus = String(localized: "Snapshot from \(fetched) downloaded — it's used next time you open TABOR.")
            case .upToDate: fleetStatus = String(localized: "You have the latest fleet data.")
            case .failed(let why): fleetStatus = String(localized: "Couldn't check: \(why)")
            }
        }
    }
}

extension URL: @retroactive Identifiable {
    public var id: String { absoluteString }
}

/// UIKit share sheet, for files that only exist once a button is tapped.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
