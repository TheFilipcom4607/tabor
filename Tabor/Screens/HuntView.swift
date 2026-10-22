import CoreLocation
import MapKit
import SwiftData
import SwiftUI

/// The raw values are what's saved, so they stay as they were when the chips were renamed.
enum HuntFilter: String, CaseIterable {
    case uncaught = "ALL UNCAUGHT"
    case newModels = "NEW MODELS"
    /// Vehicles already in your book too, for when you just want to see what's running.
    case everything = "EVERYTHING"
    /// Every vehicle of a model you've starred, caught or not, across the city (#88). Only
    /// offered once something is starred; the chip is just a ★.
    case starred = "STARRED"

    var name: String {
        switch self {
        // Keys of their own: the chips need shorter words than the book and stats (in Polish
        // "NIEZŁAPANE · NOWE MODELE · WSZYSTKIE" doesn't fit next to FILTR). "Missing" (NIE MASZ),
        // not "new": testers took NEW MODELS for models new to the city (#54).
        case .uncaught: String(localized: "hunt.filter.uncaught", defaultValue: "UNCAUGHT")
        case .newModels: String(localized: "hunt.filter.missing", defaultValue: "MISSING")
        case .everything: String(localized: "hunt.filter.all", defaultValue: "ALL")
        case .starred: String(localized: "hunt.filter.starred", defaultValue: "STARRED")
        }
    }
}

/// HUNT: every bus and tram running near you that isn't in your book yet, live (or, in the
/// ALL view, everything running).
/// Two rules on the map: a vehicle on its own is a tag with its line, vehicles that would
/// overlap become one bubble with their count; filled means a model you're missing, outlined
/// a model you already have. Colour is always rarity.
/// A filter (rarities, models) narrows it to what you're after, anywhere in the city.
struct HuntView: View {
    @Query private var sightings: [Sighting]
    @Environment(Router.self) private var router
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.wide) private var wide
    @AppStorage("huntFilter") private var filter: HuntFilter = .uncaught
    /// Rarities and models picked in the filter sheet; empty shows everything.
    @AppStorage("huntTargets") private var targets = HuntTargets()
    @AppStorage("starredModels") private var starred = StarredModels()
    @State private var showFilters = false
    /// The search field in the header is open (#31): a fleet number or a line.
    @State private var searching = false
    @State private var query = ""
    @FocusState private var queryFocused: Bool
    /// A vehicle picked from the search: on the map and selected whatever the filters say.
    @State private var focusId: String?
    /// A vehicle to open once the feed has it: a Live Activity tap can land before the first poll.
    @State private var pendingFocus: String?
    /// Satellite photos (with street names) instead of the plain dark map.
    @AppStorage("huntSatellite") private var satellite = false

    private let live = LiveFleetService.shared
    private let location = LocationService.shared
    private let routes = RoutesUpdater.shared
    private let track = TrackService.shared
    private let catalog = Fleet.catalog

    @State private var position: MapCameraPosition = .region(Self.warsaw)
    /// Opened on the default 3 km view around you, once there was a fix to open it on.
    @State private var centered = false
    @State private var pins: [WantedPin] = []
    /// Vehicles out in an event wrap you haven't caught them in, anywhere, nearest first.
    @State private var wrapsOut: [WantedPin] = []
    /// Each vehicle placed on its route, when it could be, as of the last refresh.
    @State private var matches: [String: RouteMatch] = [:]
    /// Where pins sit on the map: slid along their route to where they probably are now, since
    /// every fix is some seconds old. Distances and sorting stay on the fix itself.
    @State private var nowCoordinates: [String: CLLocationCoordinate2D] = [:]
    /// Moves on while a vehicle is selected, so its pin creeps along between polls.
    @State private var tick = Date()
    /// The stop list being scrolled (#74). Not observed: flipping it mustn't redraw the map.
    @State private var stopScroll = StopScroll()
    @State private var selectedId: String?
    /// The map keeps the selected vehicle in view as it drives, until you move the map yourself.
    @State private var following = false
    /// A small bubble you tapped: its vehicles, listed so you can pick one.
    @State private var openGroup: [String]?
    /// The selected vehicle's whole run, stop by stop, on the card and the map.
    @State private var routeOpen = false
    /// Where the card starts and the map ends, in points from the top: what's left of the map
    /// between the header and the card is where things are shown.
    @State private var cardTop: CGFloat?
    @State private var mapBottom: CGFloat?
    /// On a wide screen: the side panel's right edge and the map's, for the open part beside it.
    @State private var panelEdge: CGFloat?
    @State private var mapRight: CGFloat?
    /// What the map is showing: pins cover it, however far you zoom out.
    @State private var mapRegion: MKCoordinateRegion?
    /// The map's rotation, for your dot and the pins' arrows. Not state of this view: it changes
    /// every frame of a turn, and redrawing the whole map that often made the compass lag (#52).
    @State private var turn = MapTurn()
    /// The map turned the way you're facing, centred on you (the second tap on 3 KM).
    /// Anything else that moves the map ends it.
    @State private var facing = false
    private var mapCenter: CLLocationCoordinate2D? { mapRegion?.center }

    private static let warsaw = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 52.2297, longitude: 21.0122),
        span: MKCoordinateSpan(latitudeDelta: 0.06, longitudeDelta: 0.06))
    /// Kilometres from the centre past which the feed has nothing (the suburban lines end
    /// about 40 km out): further than this, you're not in Warsaw.
    private static let feedReach = 50.0

    var body: some View {
        // Read once: the stored filter is decoded from a string on every read.
        let picked = targets
        let shown = shown(pins, picked: picked)
        let selected = shown.first { $0.id == selectedId }

        ZStack(alignment: .top) {
            map(onMap(shown))
                .ignoresSafeArea()
                .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).maxY } action: { mapBottom = $0 }
                .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).maxX } action: { mapRight = $0 }

            LinearGradient(colors: [Palette.bg.opacity(0.85), Palette.bg.opacity(0)], startPoint: .top, endPoint: .bottom)
                .frame(height: picked.isEmpty ? 150 : 196)
                .ignoresSafeArea(edges: [.top, .horizontal])
                .allowsHitTesting(false)

            Group {
                if wide {
                    widePanel(shown: shown, selected: selected, picked: picked)
                } else {
                    phonePanel(shown: shown, selected: selected, picked: picked)
                }
            }
            .animation(.snappy, value: offDefaultView)
            .animation(.snappy, value: facing)
            .animation(.snappy, value: following)
            .animation(.snappy, value: picked)
            .animation(.snappy, value: wrapsOut.first?.id)
        }
        .background(Palette.bg.ignoresSafeArea())
        .foregroundStyle(Palette.ink)
        .sheet(isPresented: $showFilters) {
            HuntFilterSheet(targets: $targets, running: cityWide(), withCaught: withCaught, hasFix: hasFix)
        }
        // The tab stays alive behind the others once opened, so it comes back at once: the
        // fast polling and the refreshes only run while it's the one on screen.
        .onChange(of: onScreen, initial: true) { _, on in
            guard on else {
                location.stopHeading("hunt")
                return live.stop("hunt")
            }
            live.start("hunt")
            location.startHeading("hunt")
            routes.prepare()
            centerOnceOnYou()
            // Models a fleet update dropped can't match anything; don't leave them as ghost chips.
            let known = targets.models.filter { catalog.model(id: $0) != nil }
            if known != targets.models { targets.models = known }
            recompute(animated: false)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, onScreen { live.start("hunt") }
            if phase == .background { live.stop("hunt") }
        }
        .onChange(of: live.snapshot?.fetched, initial: true) {
            // Gliding every pin redraws the whole map, which stutters a stop list being
            // scrolled (#74): it waits for the list to settle.
            if stopScroll.active { stopScroll.missed = true } else { recompute(animated: true) }
        }
        // MapKit follows you on its own while facing; whatever ends facing leaves the map
        // where it is rather than letting it keep turning.
        .onChange(of: facing) { _, on in
            guard !on, position.followsUserLocation, let camera = turn.camera else { return }
            position = .camera(camera)
        }
        .onChange(of: location.latest) {
            centerOnceOnYou()
            live.locationMoved()
            recompute(animated: false)
        }
        .onChange(of: sightings.count) { recompute(animated: false) }
        .onChange(of: routes.book?.feed) { recompute(animated: false) }
        .task(id: onScreen ? selectedId : nil) { await creep() }
        .onChange(of: picked) {
            selectedId = nil
            openGroup = nil
            recompute(animated: false)
        }
        // A searched vehicle stays on the map only while it's the one selected.
        .onChange(of: selectedId) {
            if selectedId != focusId, pendingFocus == nil { focusId = nil }
            routeOpen = false
        }
        // Caught vehicles are only fetched for the ALL and ★ views.
        .onChange(of: filter) { filterChanged() }
        .onChange(of: starred, initial: true) { starsChanged() }
        // SHOW ON MAP in the book: go to where that model is running, not the 3 km around you.
        .onChange(of: router.huntModel, initial: true) { _, id in
            guard let id else { return }
            router.huntModel = nil
            centered = true
            selectedId = nil
            fit(cityWide().filter { $0.model.id == id && targets.matches($0) })
        }
        // A tracked vehicle's Live Activity: straight to it on the map (#61).
        .onChange(of: router.huntVehicle, initial: true) { _, id in
            guard let id else { return }
            router.huntVehicle = nil
            focus(on: id)
        }
    }

    /// Header and filters at the top, the card at the bottom, the map between them.
    private func phonePanel(shown: [WantedPin], selected: WantedPin?, picked: HuntTargets) -> some View {
        VStack(spacing: 12) {
            header
            filterBar
            if !picked.isEmpty {
                targetChips
                    .padding(.top, -4)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            if let out = wrapsOut.first, selectedId != out.id {
                wrapBanner(out, more: wrapsOut.count - 1)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            Spacer()
            HStack(spacing: 8) {
                if let tracked = track.trackedId, tracked != selectedId {
                    trackedButton(tracked)
                        .transition(.scale(scale: 0.8, anchor: .leading).combined(with: .opacity))
                }
                Spacer()
                if let selected, !following {
                    followButton(selected)
                        .transition(.scale(scale: 0.8, anchor: .trailing).combined(with: .opacity))
                }
                if here != nil, offDefaultView || facing || location.hasHeading {
                    locationButton
                        .transition(.scale(scale: 0.8, anchor: .trailing).combined(with: .opacity))
                }
                mapStyleButton
            }
            .padding(.horizontal, 14)
            bottomCard(shown: shown, selected: selected)
                .padding(.horizontal, 14)
                .padding(.bottom, 10)
                .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY } action: { cardTop = $0 }
        }
    }

    /// An opened foldable: header, filters and the card in a panel down the left, a phone's
    /// width, and the map buttons in the far corner, so the map gets the rest of the screen.
    private func widePanel(shown: [WantedPin], selected: WantedPin?, picked: HuntTargets) -> some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(spacing: 12) {
                header
                filterBar
                if !picked.isEmpty {
                    targetChips
                        .padding(.top, -4)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                if let out = wrapsOut.first, selectedId != out.id {
                    wrapBanner(out, more: wrapsOut.count - 1)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                bottomCard(shown: shown, selected: selected)
                    .padding(.horizontal, 14)
                Spacer(minLength: 10)
            }
            .frame(width: Self.panelWidth)
            .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).maxX } action: { panelEdge = $0 }
            // Behind the panel the map fades out, as it does behind the header on a phone.
            .background {
                LinearGradient(colors: [Palette.bg.opacity(0.8), Palette.bg.opacity(0)], startPoint: .leading, endPoint: .trailing)
                    .padding(.trailing, -60)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
            }
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 8) {
                Spacer()
                if let tracked = track.trackedId, tracked != selectedId {
                    trackedButton(tracked)
                        .transition(.scale(scale: 0.8, anchor: .trailing).combined(with: .opacity))
                }
                HStack(spacing: 8) {
                    if let selected, !following {
                        followButton(selected)
                            .transition(.scale(scale: 0.8, anchor: .trailing).combined(with: .opacity))
                    }
                    if here != nil, offDefaultView || facing || location.hasHeading {
                        locationButton
                            .transition(.scale(scale: 0.8, anchor: .trailing).combined(with: .opacity))
                    }
                    mapStyleButton
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 10)
        }
    }

    private static let panelWidth: CGFloat = 390

    /// Rows a list shows before it scrolls: a phone keeps the map above it open, the side
    /// panel has the screen's height to itself.
    private func rows(_ phone: CGFloat) -> CGFloat { wide ? phone + 3 : phone }

    /// The pins the header toggle and the filter let through.
    private func shown(_ pins: [WantedPin], picked: HuntTargets) -> [WantedPin] {
        pins.filter { pin in
            let wanted = switch filter {
            case .uncaught: pin.kind != .caught
            case .newModels: pin.kind == .newModel
            case .everything: true
            case .starred: starred.contains(pin.model.id)
            }
            // A line from the search shows all of it, like the search counted (#37).
            // Out in a wrap you haven't caught it in: wanted in every view.
            return ((wanted || pin.wrap != nil || picked.line != nil) && picked.matches(pin)) || pin.id == focusId
        }
    }

    /// A city-wide (filtered) hunt only gets pins around where you're looking, with a screen's
    /// margin all round, so a broad filter doesn't hand the map a thousand annotations.
    private func onMap(_ shown: [WantedPin]) -> [WantedPin] {
        guard cityWideHunt, let r = mapRegion else { return shown }
        return shown.filter { p in
            p.id == selectedId || (abs(p.vehicle.latitude - r.center.latitude) < r.span.latitudeDelta
                                   && abs(p.vehicle.longitude - r.center.longitude) < r.span.longitudeDelta)
        }
    }

    // MARK: - Map

    private func map(_ shown: [WantedPin]) -> some View {
        // Picked on the map itself: follow it, above the card that opens.
        let selection = Binding<String?>(get: { selectedId }, set: { id in
            selectedId = id
            if let pin = shown.first(where: { $0.id == id }) { follow(pin) }
        })
        let selectedPin = shown.first { $0.id == selectedId }
        let now = selectedPin.flatMap(creeping)
        return Map(position: $position, interactionModes: .all, selection: selection) {
            if let pin = selectedPin {
                // Its recent path, fading out behind it: along the streets once it's on its route.
                let fixes = live.trails.trail(pin.id)
                let path = now.map { $0.trail(fixes).map(CLLocationCoordinate2D.init) }
                    ?? fixes.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) } + [pin.coordinate]
                // MapKit won't draw a gradient along a line: fade it one segment at a time.
                ForEach(0..<max(0, path.count - 1), id: \.self) { i in
                    MapPolyline(coordinates: [path[i], path[i + 1]])
                        .stroke(pin.accent.opacity(0.25 + 0.75 * Double(i + 1) / Double(path.count - 1)),
                                style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
                }
                // Where it goes next: a dotted line along its route to the next few stops (to
                // the end of its run with the route open), fainter the further ahead, and
                // lighter than the solid trail behind it since it's a forecast. Stops are white
                // beads, as on a transit map, so they don't read as more of the dots.
                if let now {
                    let ahead = routeOpen ? now.remaining : now.upcoming(stops: 4).stops
                    let yours = yourStop(now)
                    // Zoomed in far enough that names don't pile up: each bead says which stop
                    // (and which of its platforms) it is.
                    let named = (mapRegion?.span.longitudeDelta ?? 1) < Self.stopNameSpan
                    let legs = legs(of: now, to: ahead)
                    ForEach(legs.indices, id: \.self) { i in
                        MapPolyline(coordinates: legs[i])
                            .stroke(pin.accent.opacity(Self.aheadOpacity(i)),
                                    style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round, dash: [0.01, 5.5]))
                    }
                    // On the line rather than at the platform, a few metres off it.
                    ForEach(Array(ahead.enumerated()), id: \.offset) { i, stop in
                        Annotation(stop.label, coordinate: CLLocationCoordinate2D(now.shape.coordinate(at: stop.along)),
                                   anchor: .center) {
                            // The last stop of its run: a square, like a line's end on a transit map.
                            let terminus = now.end != nil && stop == now.shape.stops.last
                            RoundedRectangle(cornerRadius: terminus ? 2 : 3.5, style: .continuous)
                                .fill(stop == yours ? Palette.yellow : Palette.ink)
                                .overlay(RoundedRectangle(cornerRadius: terminus ? 2 : 3.5, style: .continuous)
                                    .strokeBorder(Palette.bg, lineWidth: 1.5))
                                .frame(width: terminus ? 9 : 7, height: terminus ? 9 : 7)
                                .opacity(terminus || stop == yours ? 1 : Self.aheadOpacity(i))
                                // Beside the bead, so the bead stays on the line.
                                .overlay(alignment: .leading) {
                                    if named {
                                        StopName(text: stop.label, accent: stop == yours ? Palette.yellow : pin.accent)
                                            .fixedSize()
                                            .offset(x: terminus ? 15 : 13)
                                            .transition(.opacity)
                                    }
                                }
                                .animation(.easeInOut(duration: 0.2), value: named)
                                .accessibilityHidden(true)
                        }
                        .annotationTitles(.hidden)
                    }
                }
            }
            // Drawn here rather than MapKit's own dot, which only shows which way you face
            // while the map follows your heading.
            UserAnnotation(anchor: .center) { _ in YouDot(turn: turn) }
            // Rarest on top: SwiftUI draws later annotations above earlier ones.
            ForEach(groups(shown).reversed()) { g in
                if g.pins.count == 1 {
                    Annotation(g.lead.model.name, coordinate: mapCoordinate(g.lead, selected: now), anchor: .bottom) {
                        WantedPinView(pin: g.lead, selected: g.id == selectedId, starred: starred.contains(g.lead.model.id),
                                      travel: live.trails.heading(g.lead.id), turn: turn)
                    }
                    .tag(g.id)
                    .annotationTitles(.hidden)
                } else {
                    Annotation("\(g.pins.count) vehicles", coordinate: CLLocationCoordinate2D(latitude: g.latitude, longitude: g.longitude),
                               anchor: .center) {
                        GroupBubble(group: g)
                    }
                    .tag(g.id)
                    .annotationTitles(.hidden)
                }
            }
        }
        .mapStyle(satellite
                  ? .hybrid(elevation: .flat, pointsOfInterest: .excludingAll, showsTraffic: false)
                  : .standard(elevation: .flat, emphasis: .muted, pointsOfInterest: .excludingAll, showsTraffic: false))
        .mapControls {}
        .environment(\.colorScheme, .dark)
        .onMapCameraChange(frequency: .continuous) { ctx in turn.update(ctx.camera) }
        .onMapCameraChange(frequency: .onEnd) { ctx in
            // Moved by hand: leave the map where it was put. Moves made in code don't count, nor
            // does zooming while facing (MapKit keeps following).
            if position.positionedByUser {
                following = false
                facing = false
            }
            // Only turned, as the facing map does several times a second: nothing the pins
            // depend on changed, and redoing them each time made it lag (#52).
            guard turn.moved(ctx.camera) else { return }
            mapRegion = ctx.region
            recompute(animated: false)
        }
        .onChange(of: selectedId) { _, id in
            if id != nil { facing = false }
            guard let id else {
                following = false
                return
            }
            Haptics.shared.tick()
            guard id.hasPrefix("group:"), let g = groups(shown).first(where: { $0.id == id }) else {
                // Picked from the open list: keep it, so closing the card goes back to it.
                if openGroup?.contains(id) != true { openGroup = nil }
                return
            }
            selectedId = nil
            // A few vehicles, or already zoomed in (a pętla, a stop): list them to pick from.
            // A big crowd further out: zoom in until it comes apart.
            if g.pins.count <= 6 || (mapRegion?.span.longitudeDelta ?? 1) < 0.02 {
                withAnimation(.snappy) { openGroup = g.pins.map(\.id) }
            } else {
                zoom(into: g)
            }
        }
    }

    /// Vehicles merged only where their tags would really sit on top of each other (a
    /// square is roughly a tenth of the screen wide, a bit under a tag). The selected one
    /// stands alone.
    private func groups(_ shown: [WantedPin]) -> [PinGroup] {
        let rest = shown.filter { $0.id != selectedId }
        let lone = shown.filter { $0.id == selectedId }.map { PinGroup(lead: $0, pins: [$0]) }
        guard let region = mapRegion else { return lone + rest.map { PinGroup(lead: $0, pins: [$0]) } }
        // Squares snap to powers of two, so a nudge of the map (or a tap) doesn't redraw
        // every group; they only change when you really zoom.
        let cell = pow(2, (log2(region.span.longitudeDelta / 10)).rounded())
        // A fixed reference latitude too, for the same reason.
        return Wanted.group(rest, cellLon: cell, latitude: 52.23) + lone
    }

    /// Where the map centres to keep a vehicle in view at the current zoom. The card opens over
    /// the bottom of the map, its top edge a little below the middle, so the vehicle sits in
    /// the open part above it. North-up, so latitude runs up the screen.
    private func region(showing coordinate: CLLocationCoordinate2D) -> MKCoordinateRegion? {
        guard let span = mapRegion?.span else { return nil }
        let open = openPart
        // With the route open the card covers more: the middle of what's left. Beside a side
        // panel it's always the middle of the open part.
        let middle = routeOpen || wide ? open.middle : 0.35
        return MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: coordinate.latitude - span.latitudeDelta * (0.5 - middle),
                                                                 longitude: coordinate.longitude - span.longitudeDelta * (open.centre - 0.5)),
                                  span: span)
    }

    /// The part of the map between the header and the map buttons over the card, as fractions
    /// of its height from the top.
    private var openPart: (top: Double, bottom: Double, middle: Double, left: Double, right: Double, centre: Double) {
        if wide {
            // Beside the panel, above the tab bar and the map buttons in the corner.
            // Until both are measured, about where the panel ends on an opened Duo.
            let left = panelEdge.flatMap { edge in mapRight.map { min(edge / max($0, 1), 0.6) } } ?? 0.42
            let top = 0.06, bottom = 0.82, right = 0.97
            return (top, bottom, (top + bottom) / 2, left, right, (left + right) / 2)
        }
        let top = targets.isEmpty ? 0.19 : 0.24
        guard let cardTop, let mapBottom, mapBottom > 0 else { return (top, 0.5, (top + 0.5) / 2, 0, 1, 0.5) }
        // The row of map buttons (FOLLOW, 3 KM, the globe) stands on the card.
        let bottom = min(max((cardTop - 56) / mapBottom, top + 0.1), 0.9)
        return (top, bottom, (top + bottom) / 2, 0, 1, 0.5)
    }

    /// A region with `points` in the open part of the map, no closer than `minSpan` degrees of
    /// latitude. North-up; the span keeps the map's own shape, so MapKit takes it as it is.
    private func region(fitting points: [(latitude: Double, longitude: Double)], minSpan: Double) -> MKCoordinateRegion? {
        guard let current = mapRegion, !points.isEmpty else { return nil }
        let lats = points.map(\.latitude), lons = points.map(\.longitude)
        let midLat = (lats.min()! + lats.max()!) / 2, midLon = (lons.min()! + lons.max()!) / 2
        let k = cos(midLat * .pi / 180)
        // Width over height, in metres.
        let shape = current.span.longitudeDelta * k / current.span.latitudeDelta
        let open = openPart
        // Room to spare: a pin's tag stands above its point.
        let tall = (lats.max()! - lats.min()!) * 1.35 / (open.bottom - open.top)
        let across = (lons.max()! - lons.min()!) * k * 1.2 / shape / (open.right - open.left)
        let lat = max(tall, across, minSpan), lon = lat * shape / k
        return MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: midLat - (0.5 - open.middle) * lat,
                                                                 longitude: midLon - (open.centre - 0.5) * lon),
                                  span: MKCoordinateSpan(latitudeDelta: lat, longitudeDelta: lon))
    }

    /// Opens or closes the selected vehicle's whole run. Open, the map pulls back to show all of
    /// it above the taller card; closed, it goes back to following the vehicle.
    private func toggleRoute(_ pin: WantedPin) {
        Haptics.shared.tick()
        withAnimation(.snappy) { routeOpen.toggle() }
        guard routeOpen else { return follow(pin) }
        following = false
        // Once the card has grown, so the open part is measured with it.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(80))
            guard routeOpen, let now = creeping(pin),
                  let region = region(fitting: [now.coordinate] + now.shape.path(from: now.along, to: now.shape.length),
                                      minSpan: Self.stopSpan) else { return }
            withAnimation(.easeInOut(duration: 0.7)) { position = .region(region) }
        }
    }

    /// A stop picked on the card: close enough on the map to read its name.
    private func show(stop: RouteStop) {
        Haptics.shared.tick()
        following = false
        guard let region = region(fitting: [(stop.latitude, stop.longitude)], minSpan: Self.stopSpan) else { return }
        withAnimation(.easeInOut(duration: 0.6)) { position = .region(region) }
    }

    /// Where you'd wait for it, when its route comes past you.
    private func yourStop(_ match: RouteMatch) -> RouteStop? {
        guard let here else { return nil }
        return match.yourStop(lat: here.latitude, lon: here.longitude)?.stop
    }

    /// Tags on screen above which a refresh moves them without the glide.
    private static let glideLimit = 40

    /// Stop names show on the map below this span (degrees of longitude, about 1 km across).
    private static let stopNameSpan = 0.015
    /// A stop shown on its own: a few streets, close enough for the names (degrees of latitude).
    private static let stopSpan = 0.008

    /// Glide to a vehicle, keeping the zoom, and keep it in view from now on.
    private func follow(_ pin: WantedPin) {
        following = true
        guard let region = region(showing: pin.coordinate) else { return }
        withAnimation(.easeInOut(duration: 0.5)) { position = .region(region) }
    }

    private func zoom(into g: PinGroup) {
        let lats = g.pins.map(\.vehicle.latitude), lons = g.pins.map(\.vehicle.longitude)
        let current = mapRegion?.span ?? Self.warsaw.span
        // Fit the group with room to spare, and always at least a few times closer.
        let span = MKCoordinateSpan(
            latitudeDelta: min(current.latitudeDelta / 3, max((lats.max()! - lats.min()!) * 2.5, 0.002)),
            longitudeDelta: min(current.longitudeDelta / 3, max((lons.max()! - lons.min()!) * 2.5, 0.002)))
        // Off to the side of a side panel, in the middle of the map you can see.
        let center = CLLocationCoordinate2D(latitude: (lats.max()! + lats.min()!) / 2,
                                            longitude: (lons.max()! + lons.min()!) / 2 - span.longitudeDelta * (openPart.centre - 0.5))
        withAnimation(.easeInOut(duration: 0.6)) { position = .region(MKCoordinateRegion(center: center, span: span)) }
    }

    /// "❄ CHRISTMAS 2025 IS OUT · #5887 · 2.3 KM": a wrap only runs for a few weeks, so
    /// HUNT says so whatever the filters. Tapping flies to it.
    private func wrapBanner(_ pin: WantedPin, more: Int) -> some View {
        Button {
            Haptics.shared.wrapAdded()
            focus(on: pin.id)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: pin.wrap?.symbol ?? "sparkles").font(.system(size: 12, weight: .bold))
                Mono(String(localized: "\(pin.wrap?.nameDisplay ?? "") IS OUT", comment: "HUNT banner: a vehicle in an event wrap is running"),
                     size: 11, weight: 700, spacing: 0.1, color: Palette.foilDeep)
                    .lineLimit(1)
                    .layoutPriority(1)
                Spacer(minLength: 4)
                // What gives way on a narrow phone: the name of the wrap stays whole.
                Mono([String(localized: "LINE \(pin.vehicle.line)"), hasFix ? HuntDistance.text(pin.distance) : nil,
                      more > 0 ? "+\(more)" : nil].compactMap { $0 }.joined(separator: " · "),
                     size: 10.5, weight: 600, color: Palette.foilDeep.opacity(0.75))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold))
            }
            .foregroundStyle(Palette.foilDeep)
            .padding(.vertical, 9)
            .padding(.horizontal, 13)
            .background { Foil(animated: true).clipShape(Capsule()) }
            .shadow(color: Palette.foilInk.opacity(0.35), radius: 10, y: 4)
        }
        .buttonStyle(StickerPressStyle())
        .padding(.horizontal, 20)
        .accessibilityLabel(Text("\(pin.model.name) \(String(pin.vehicle.number)) is out in its \(pin.wrap?.nameDisplay.lowercased() ?? "") wrap. Show it"))
    }

    // MARK: - Chrome

    @ViewBuilder
    private var header: some View {
        if searching {
            searchField
        } else {
            titleRow
        }
    }

    private var titleRow: some View {
        HStack(spacing: 8) {
            Mono("HUNT", size: 12, spacing: 0.16, color: .white.opacity(0.85))
            Spacer()
            Button {
                Haptics.shared.tick()
                withAnimation(.snappy) {
                    searching = true
                    selectedId = nil
                    openGroup = nil
                }
                queryFocused = true
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 10.5, weight: .bold))
                    Mono("SEARCH", size: 10.5, weight: 600, spacing: 0.1, color: .white.opacity(0.85))
                }
                .foregroundStyle(.white.opacity(0.85))
                .padding(.vertical, 6)
                .padding(.horizontal, 10)
                .glass(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Search for a fleet number or a line")
            HStack(spacing: 6) {
                let isLive = live.status == .live
                Circle().fill(statusColor).frame(width: 6, height: 6)
                    .shadow(color: statusColor, radius: isLive ? 4 : 0)
                    // Breathes while the feed is live, like the camera's hint dot.
                    .phaseAnimator([0.35, 1]) { v, p in v.opacity(isLive ? p : 1) } animation: { _ in .easeInOut(duration: 0.9) }
                Mono(statusText, size: 10.5, weight: 600, spacing: 0.1, color: .white.opacity(0.85))
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 10)
            .glass(Capsule())
        }
        .padding(.top, 6)
        .padding(.horizontal, 20)
    }

    /// Replaces the title row while searching: the field, and Cancel to close it.
    private var searchField: some View {
        HStack(spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white.opacity(0.6))
                TextField("", text: $query, prompt: Text("Fleet number or line").foregroundStyle(.white.opacity(0.45)))
                    .font(TaborFont.mono(14, 600))
                    .foregroundStyle(Palette.ink)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .focused($queryFocused)
                    .onSubmit(pickTopResult)
                if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(.white.opacity(0.5))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear the search")
                }
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
            .glass(Capsule())
            Button("Cancel") { endSearch() }
                .font(TaborFont.grotesk(15, 600))
                .foregroundStyle(Palette.radar)
        }
        .padding(.top, 2)
        .padding(.horizontal, 20)
        .transition(.opacity)
    }

    private var filterBar: some View {
        // With the ★ view the row is one chip longer than a 390 pt phone has room for in
        // Polish (NIEZŁAPANE got cut): chips sit a little tighter, and FILTER is just its icon
        // until a filter is on.
        let tight = !starred.isEmpty
        return HStack(spacing: tight ? 5 : 7) {
            ForEach(HuntFilter.allCases.filter { $0 != .starred || !starred.isEmpty }, id: \.self) { f in
                let on = f == filter
                Button {
                    guard !on else { return }
                    Haptics.shared.tick()
                    withAnimation(.snappy) {
                        filter = f
                        selectedId = nil
                        openGroup = nil
                    }
                } label: {
                    // A chip never wraps: a long translation shrinks a touch instead. The ★
                    // view is just the star: the row is full on a 390 pt phone in Polish.
                    Group {
                        if f == .starred {
                            Image(systemName: "star.fill")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(on ? Palette.bg : Palette.yellow)
                                .padding(.horizontal, -2)
                        } else {
                            Mono(f.name, size: 11, weight: 600, spacing: 0.1, color: on ? Palette.bg : .white.opacity(0.75))
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                        }
                    }
                    .padding(.vertical, 7)
                    .padding(.horizontal, tight ? 10 : 12)
                    .background(on ? Palette.ink : .clear, in: Capsule())
                    .glass(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(f.name.capitalized)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
            Spacer(minLength: 0)
            filterButton(compact: tight)
        }
        .padding(.horizontal, 20)
    }

    /// Opens the filter sheet; lit, with the number of picks, while a filter is on.
    private func filterButton(compact: Bool) -> some View {
        let on = !targets.isEmpty
        return Button {
            Haptics.shared.tick()
            showFilters = true
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "line.3.horizontal.decrease")
                    .font(.system(size: 11, weight: .bold))
                if on || !compact {
                    Mono(on ? "\(targets.count)" : "FILTER", size: 11, weight: 600, spacing: 0.1,
                         color: on ? Palette.bg : .white.opacity(0.75))
                        .contentTransition(.numericText())
                }
            }
            .foregroundStyle(on ? Palette.bg : .white.opacity(0.75))
            .padding(.vertical, 7)
            .padding(.horizontal, compact ? 10 : 11)
            .background(on ? Palette.radar : .clear, in: Capsule())
            .glass(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(on ? "Filter, \(targets.count) picked" : "Filter")
    }

    /// What the filter is set to, one removable chip each.
    private var targetChips: some View {
        let picked = targets
        return ScrollView(.horizontal) {
            HStack(spacing: 6) {
                if let kind = picked.kind {
                    targetChip(kind == .bus ? String(localized: "BUSES ONLY") : String(localized: "TRAMS ONLY"), color: Palette.ink) { targets.kind = nil }
                }
                ForEach(Tier.allCases.filter { picked.tiers.contains($0) }, id: \.self) { t in
                    targetChip(t.name, color: t.mapColor) { targets.tiers.subtract([t]) }
                }
                ForEach(picked.models.compactMap(catalog.model(id:)).sorted { $0.name < $1.name }) { m in
                    targetChip(m.name.uppercased(), color: m.tier.mapColor) { targets.models.subtract([m.id]) }
                }
                if let line = picked.line {
                    targetChip(String(localized: "LINE \(line)"), color: Palette.ink) { targets.line = nil }
                }
                ForEach(picked.lengths.sorted(), id: \.self) { l in
                    targetChip(l.name, color: Palette.ink) { targets.lengths.remove(l) }
                }
                ForEach(ModelSpecs.Drive.allCases.filter { picked.drives.contains($0) }, id: \.self) { d in
                    targetChip(d.name, color: Palette.ink) { targets.drives.remove(d) }
                }
                ForEach(ModelSpecs.Floor.allCases.filter { picked.floors.contains($0) }, id: \.self) { f in
                    targetChip(f.name.uppercased(), color: Palette.ink) { targets.floors.remove(f) }
                }
                ForEach(Livery.allCases.filter { picked.paints.contains($0) }, id: \.self) { l in
                    targetChip(l.name, color: Palette.ink) { targets.paints.remove(l) }
                }
            }
            .padding(.horizontal, 20)
        }
        .scrollIndicators(.hidden)
    }

    private func targetChip(_ text: String, color: Color, remove: @escaping () -> Void) -> some View {
        Button {
            Haptics.shared.tick()
            withAnimation(.snappy) { remove() }
        } label: {
            HStack(spacing: 6) {
                Mono(text, size: 10.5, weight: 600, spacing: 0.08, color: color)
                    .lineLimit(1)
                Image(systemName: "xmark")
                    .font(.system(size: 8.5, weight: .heavy))
                    .foregroundStyle(color.opacity(0.7))
            }
            .padding(.vertical, 6)
            .padding(.leading, 11)
            .padding(.trailing, 9)
            .glass(Capsule())
            .overlay(Capsule().stroke(color.opacity(0.45)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Remove \(text.capitalized) from the filter")
    }

    /// Like Apple Maps' arrow: away from the 3 km around you, it goes back there; on it, it
    /// turns the map the way you're facing; facing, it turns it back to north.
    private var locationButton: some View {
        let away = !facing && offDefaultView
        return Button {
            if facing || away { return resetView() }
            Haptics.shared.tick()
            following = false
            facing = true
            turnToFacing()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: facing ? "location.north.line.fill" : away ? "location" : "location.fill")
                    .font(.system(size: 10.5, weight: .bold))
                    .contentTransition(.symbolEffect(.replace))
                Mono("3 KM", size: 11, weight: 600, spacing: 0.1, color: Palette.radar)
            }
            .foregroundStyle(Palette.radar)
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
            .glass(Capsule())
            .overlay(Capsule().fill(Palette.radar.opacity(facing ? 0.16 : 0)).allowsHitTesting(false))
            .shadow(color: .black.opacity(0.35), radius: 8, y: 4)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(facing ? "Turn the map back to north"
                            : away ? "Back to 3 kilometres around you" : "Turn the map the way you're facing")
    }

    /// Back to following the selected vehicle: shown once you've moved the map away from it.
    private func followButton(_ pin: WantedPin) -> some View {
        Button {
            Haptics.shared.tick()
            follow(pin)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "scope")
                    .font(.system(size: 10.5, weight: .bold))
                Mono("FOLLOW", size: 11, weight: 600, spacing: 0.1, color: Palette.radar)
            }
            .foregroundStyle(Palette.radar)
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
            .glass(Capsule())
            .shadow(color: .black.opacity(0.35), radius: 8, y: 4)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Follow #\(pin.vehicle.number) on the map")
    }

    /// Back to the vehicle on the Lock Screen, once you've wandered off it (#61).
    private func trackedButton(_ id: String) -> some View {
        let number = id.split(separator: "#").last.map(String.init) ?? id
        return Button {
            Haptics.shared.tick()
            focus(on: id)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .font(.system(size: 10.5, weight: .bold))
                Mono("TRACKING #\(number)", size: 11, weight: 600, spacing: 0.1, color: Palette.radar)
                    .lineLimit(1)
            }
            .foregroundStyle(Palette.radar)
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
            .glass(Capsule())
            .shadow(color: .black.opacity(0.35), radius: 8, y: 4)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Show tracked #\(number) on the map")
    }

    /// Flips between the plain map and satellite; shows the one you'd switch to.
    private var mapStyleButton: some View {
        Button {
            Haptics.shared.tick()
            satellite.toggle()
        } label: {
            Image(systemName: satellite ? "map.fill" : "globe.europe.africa.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 36, height: 36)
                .glass(Circle())
                .shadow(color: .black.opacity(0.35), radius: 8, y: 4)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(satellite ? "Show the map" : "Show satellite")
    }

    /// The default view: you in the middle, the 3 km the list covers around you.
    private func defaultRegion() -> MKCoordinateRegion? {
        guard let here = location.recent(maxAge: 300)?.coordinate ?? mapCenter else { return nil }
        guard wide else { return MKCoordinateRegion(center: here, latitudinalMeters: Wanted.radius * 2, longitudinalMeters: Wanted.radius * 2) }
        // Beside a side panel: the 6 km across the open part, you in its middle. A sliver of
        // height, so MapKit fits the width and lets the height follow the screen.
        let open = openPart
        let span = MKCoordinateRegion(center: here, latitudinalMeters: 100,
                                      longitudinalMeters: Wanted.radius * 2 / (open.right - open.left)).span
        return MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: here.latitude,
                                                                 longitude: here.longitude - span.longitudeDelta * (open.centre - 0.5)),
                                  span: span)
    }

    /// Zoomed in or out from the default, or panned (or walked) away from its centre.
    private var offDefaultView: Bool {
        guard let region = mapRegion, let here else { return false }
        // Width, not height: on a tall phone screen the region fits the 6 km across. Beside a
        // side panel, the width and the middle of the open part.
        let open = openPart
        let across = Geo.km((region.center.latitude, region.center.longitude - region.span.longitudeDelta / 2),
                            (region.center.latitude, region.center.longitude + region.span.longitudeDelta / 2)) * 1000 * (open.right - open.left)
        let zoom = across / (Wanted.radius * 2)
        if zoom < 0.6 || zoom > 1.6 { return true }
        let middle = region.center.longitude + region.span.longitudeDelta * (open.centre - 0.5)
        return Geo.km((here.latitude, here.longitude), (region.center.latitude, middle)) > 0.5
    }

    private func centerOnceOnYou() {
        guard !centered, let region = defaultRegion(), location.recent(maxAge: 300) != nil else { return }
        centered = true
        position = .region(region)
    }

    /// Facing: you in the middle, the map turned the way the phone points. MapKit's own
    /// following, which turns the map smoothly without redrawing HUNT; moving the camera
    /// ourselves on each compass reading juddered and lagged (#52). It starts a few streets
    /// across rather than at 3 km, but pinching keeps it following.
    private func turnToFacing() {
        withAnimation(.easeInOut(duration: 0.5)) { position = .userLocation(followsHeading: true, fallback: position) }
    }

    private func resetView() {
        guard let region = defaultRegion() else { return }
        Haptics.shared.tick()
        following = false
        facing = false
        withAnimation(.easeInOut(duration: 0.7)) { position = .region(region) }
    }

    @ViewBuilder
    private func bottomCard(shown: [WantedPin], selected: WantedPin?) -> some View {
        Group {
            if searching {
                searchCard(HuntSearch.results(for: query, snapshot: live.snapshot, catalog: catalog))
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            } else if let selected {
                let stats = sightings.stats
                PinCard(pin: selected, owned: stats.ownedCount(modelId: selected.model.id),
                        mine: stats.vehicle(number: selected.vehicle.number, modelId: selected.model.id),
                        showDistance: hasFix, motion: motion(of: selected),
                        nextStops: creeping(selected)?.upcoming(stops: 3).stops.map(\.name) ?? [],
                        ending: creeping(selected)?.ending(within: 3),
                        route: creeping(selected).map { PinCard.Route(match: $0, yours: yourStop($0)) },
                        routeOpen: routeOpen,
                        onRoute: { toggleRoute(selected) },
                        onStop: show(stop:),
                        onScrolling: stopsScrolling,
                        track: trackButton(selected),
                        trackedStop: track.isTracking(selected) ? track.trackedStop : nil,
                        onTrackStop: { trackTo(selected, stop: $0) },
                        onOpen: {
                            if selected.kind == .caught {
                                router.openVehicle(modelId: selected.model.id, number: selected.vehicle.number)
                            } else {
                                router.openModel(selected.model.id)
                            }
                        },
                        onCatch: { withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { router.tab = .catchTab } },
                        onClose: { withAnimation(.snappy) { selectedId = nil } })
                .id(selected.id)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            } else if let ids = openGroup {
                let members = ids.compactMap { id in shown.first { $0.id == id } }
                groupList(members)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            } else if let empty = emptyState(shown: shown) {
                empty
            } else {
                wantedList(listed(shown))
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: selectedId)
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: openGroup)
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: searching)
    }

    // MARK: - Search

    /// What the search found: lines running now, then the vehicles with that number.
    private func searchCard(_ results: HuntSearch.Results) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if query.trimmingCharacters(in: .whitespaces).isEmpty {
                SectionLabel(text: String(localized: "SEARCH"))
                Text("Type a fleet number to find that vehicle, or a line to see everything running on it.")
                    .font(TaborFont.grotesk(14))
                    .foregroundStyle(Palette.sub)
                    .lineSpacing(2)
                    .padding(.top, 6)
            } else if results.isEmpty {
                SectionLabel(text: String(localized: "NOTHING FOUND"))
                Text("No line “\(query)” is running right now, and no vehicle has that number.")
                    .font(TaborFont.grotesk(14))
                    .foregroundStyle(Palette.sub)
                    .lineSpacing(2)
                    .padding(.top, 6)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(results.lines, id: \.self) { l in lineRow(l) }
                        ForEach(results.vehicles, id: \.self) { v in searchedVehicleRow(v) }
                    }
                }
                .scrollBounceBehavior(.basedOnSize)
                .scrollIndicators(.hidden)
                .frame(maxHeight: rows(4.5) * Self.rowHeight)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .huntCard()
    }

    private func lineRow(_ l: HuntSearch.Line) -> some View {
        Button { pickLine(l) } label: {
            HStack(spacing: 10) {
                Image(systemName: l.kind == .bus ? "bus.fill" : "tram.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Palette.radar)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(String(localized: "Line \(l.line)"))
                        .font(TaborFont.grotesk(14.5, 600))
                    Mono(String(localized: "\(l.count) OUT NOW"), size: 10.5, color: Palette.sub)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Palette.faint)
            }
            .frame(height: Self.rowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func searchedVehicleRow(_ v: HuntSearch.Vehicle) -> some View {
        let mine = sightings.contains { $0.number == v.number && $0.modelId == v.model.id }
        let accent = v.model.tier.mapColor
        return Button { pickVehicle(v) } label: {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(mine ? .clear : accent)
                    .strokeBorder(accent, lineWidth: 1.5)
                    .frame(width: 5, height: 30)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Mono("#\(v.number)" as String, size: 12, weight: 700, spacing: 0.04, color: Palette.ink)
                            .fixedSize()
                        Text(v.model.name)
                            .font(TaborFont.grotesk(14.5, 600))
                            .lineLimit(1)
                    }
                    Mono(searchedSubtitle(v, mine: mine), size: 10.5, color: v.live == nil ? Palette.faint : Palette.sub)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                Image(systemName: v.live == nil ? "book.closed" : "location.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(v.live == nil ? Palette.faint : Palette.radar)
            }
            .frame(height: Self.rowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// "LINE 523 · 2.1 KM · IN YOUR BOOK", or "NOT OUT NOW · OPEN IN BOOK".
    private func searchedSubtitle(_ v: HuntSearch.Vehicle, mine: Bool) -> String {
        guard let live = v.live else { return String(localized: "NOT OUT NOW · OPEN IN BOOK") }
        let user = here
        let distance = user.map { Geo.km(($0.latitude, $0.longitude), (live.latitude, live.longitude)) * 1000 }
        return [live.line.isEmpty ? nil : String(localized: "LINE \(live.line)"), distance.map(HuntDistance.text),
                mine ? String(localized: "IN YOUR BOOK") : nil]
            .compactMap { $0 }.joined(separator: " · ")
    }

    /// Return on the keyboard: the answer, when there's only one; a list stays up to pick from.
    private func pickTopResult() {
        let r = HuntSearch.results(for: query, snapshot: live.snapshot, catalog: catalog)
        switch (r.lines.count, r.vehicles.count) {
        case (1, 0): pickLine(r.lines[0])
        case (0, 1): pickVehicle(r.vehicles[0])
        default: break
        }
    }

    /// Everything on that line, across the city, through the filter (so it shows as a chip).
    /// It replaces other picks: a line with LEGENDARY still on would usually show nothing.
    private func pickLine(_ l: HuntSearch.Line) {
        Haptics.shared.detent()
        endSearch()
        withAnimation(.snappy) { targets = HuntTargets(line: l.line) }
        // The map only draws pins around where you're looking: go to where the line is.
        fit(cityWide())
    }

    /// Frames these vehicles in the open part of the map above the card.
    private func fit(_ pins: [WantedPin]) {
        guard !pins.isEmpty else { return }
        // Beside a side panel the open part isn't a band across the map: work it out.
        if wide, let region = region(fitting: pins.map { ($0.vehicle.latitude, $0.vehicle.longitude) }, minSpan: 0.02) {
            following = false
            facing = false
            withAnimation(.easeInOut(duration: 0.7)) { position = .region(region) }
            return
        }
        let lats = pins.map(\.vehicle.latitude), lons = pins.map(\.vehicle.longitude)
        // The open part runs from under the header (a fifth of the way down) to the card's top
        // edge (about 60%): the pins get that band, a little inside it, and its middle is
        // nearly a tenth of the map above the map's own centre.
        let latSpan = max((lats.max()! - lats.min()!) * 2.8, 0.02)
        let span = MKCoordinateSpan(latitudeDelta: latSpan, longitudeDelta: max((lons.max()! - lons.min()!) * 1.25, 0.01))
        let center = CLLocationCoordinate2D(latitude: (lats.max()! + lats.min()!) / 2 - latSpan * 0.09,
                                            longitude: (lons.max()! + lons.min()!) / 2)
        following = false
        facing = false
        withAnimation(.easeInOut(duration: 0.7)) { position = .region(MKCoordinateRegion(center: center, span: span)) }
    }

    /// Running: fly to it and open its card. Not out: its page in the book.
    private func pickVehicle(_ v: HuntSearch.Vehicle) {
        Haptics.shared.detent()
        endSearch()
        guard let live = v.live else {
            return router.openVehicle(modelId: v.model.id, number: v.number)
        }
        focus(on: "\(live.kind.rawValue)#\(live.number)")
    }

    /// Fly to a running vehicle and open its card, past the filters. If the feed hasn't come
    /// in yet, it opens as soon as it does.
    private func focus(on id: String) {
        // Opened cold from a Live Activity: don't let the first fix pull the map back to you.
        centered = true
        focusId = id
        pendingFocus = id
        recompute(animated: false)
    }

    private func endSearch() {
        queryFocused = false
        withAnimation(.snappy) { searching = false }
        query = ""
    }

    /// A vehicle from the search as a pin, wherever it is and whether or not you've caught it.
    private func searchedPin(_ id: String, in snapshot: LiveSnapshot) -> WantedPin? {
        guard let v = snapshot.vehicles.first(where: { "\($0.kind.rawValue)#\($0.number)" == id }) else { return nil }
        let user = here
        return Wanted.pins(snapshot: LiveSnapshot(vehicles: [v], fetched: snapshot.fetched), catalog: catalog,
                           caught: sightings.stats, lat: v.latitude, lon: v.longitude, within: 10,
                           from: user.map { ($0.latitude, $0.longitude) }, includeCaught: true)
            .first
    }

    /// The vehicles in a tapped bubble; picking one opens its card (and ✕ on that card
    /// comes back here).
    private func groupList(_ members: [WantedPin]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                SectionLabel(text: String(localized: "\(members.count) HERE"))
                Spacer()
                CloseButton { withAnimation(.snappy) { openGroup = nil } }
            }
            pinList(members, visibleRows: rows(4.5)) { pin in
                withAnimation(.snappy) { selectedId = pin.id }
                follow(pin)
            }
        }
        .padding(14)
        .huntCard()
    }

    private static let rowHeight: CGFloat = 50

    /// Rows that fit their content; past `visibleRows` the list scrolls, with the half row
    /// peeking out to say so.
    private func pinList(_ pins: [WantedPin], visibleRows: CGFloat, action: @escaping (WantedPin) -> Void) -> some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(pins) { pin in pinRow(pin) { action(pin) } }
            }
        }
        .scrollBounceBehavior(.basedOnSize)
        .scrollIndicators(.hidden)
        .frame(height: min(CGFloat(pins.count), visibleRows) * Self.rowHeight)
    }

    private func pinRow(_ pin: WantedPin, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(pin.kind == .newModel ? pin.accent : .clear)
                    .strokeBorder(pin.accent, lineWidth: 1.5)
                    .frame(width: 5, height: 30)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Mono(pin.model.tier.name, size: 9.5, weight: 700, spacing: 0.12, color: pin.accent)
                            .fixedSize()
                        Text(pin.model.name)
                            .font(TaborFont.grotesk(14.5, 600))
                            .lineLimit(1)
                    }
                    Mono(pin.subtitle(showDistance: false), size: 10.5, color: Palette.sub)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                if hasFix {
                    VStack(alignment: .trailing, spacing: 3) {
                        Mono(HuntDistance.text(pin.distance), size: 11, weight: 700, spacing: 0.04, color: Palette.ink)
                        if let m = motion(of: pin) {
                            Mono(m.short, size: 8.5, weight: 700, spacing: 0.1, color: m.color)
                        }
                    }
                    .fixedSize()
                } else {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Palette.faint)
                }
            }
            .frame(height: Self.rowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// The ★ view is the whole city's worth of them: the map goes to where they all are, as
    /// SHOW ON MAP does for one model.
    private func filterChanged() {
        recompute(animated: false)
        guard filter == .starred else { return }
        // Picked just after launch: don't let the first fix pull the map back to you.
        centered = true
        selectedId = nil
        fit(cityWide().filter { starred.contains($0.model.id) && targets.matches($0) })
    }

    /// The last star taken off: the ★ view has nothing left to show, and its chip goes.
    private func starsChanged() {
        if starred.isEmpty, filter == .starred { filter = .uncaught }
        recompute(animated: false)
    }

    /// The ALL and ★ views fetch vehicles already in your book too.
    private var withCaught: Bool { filter == .everything || filter == .starred }

    /// Hunting across the whole city: a filter that picks something, or the ★ view.
    private var cityWideHunt: Bool { targets.isCityWide || filter == .starred }

    /// The list sticks to what's actually near you, even with all of Warsaw on the map.
    private func nearYou(_ shown: [WantedPin]) -> [WantedPin] {
        hasFix ? shown.filter { $0.distance <= Wanted.radius } : shown
    }

    /// Unfiltered: what's within 3 km, most wanted first. Filtered: every match in the city,
    /// nearest first (to you, or to the map's centre without a fix) — you're after something
    /// specific, so how far it is matters most.
    private func listed(_ shown: [WantedPin]) -> [WantedPin] {
        guard cityWideHunt else { return nearYou(shown) }
        return shown.sorted { $0.distance < $1.distance }
    }

    /// "UNCAUGHT NEARBY", or "MISSING TRAM MODELS NEARBY" with trams picked.
    private var nearbyTitle: String {
        switch (filter, targets.kind) {
        case (.newModels, nil): String(localized: "MISSING MODELS NEARBY")
        case (.newModels, .bus): String(localized: "MISSING BUS MODELS NEARBY")
        case (.newModels, .tram): String(localized: "MISSING TRAM MODELS NEARBY")
        case (.uncaught, nil): String(localized: "UNCAUGHT NEARBY")
        case (.uncaught, .bus): String(localized: "UNCAUGHT BUSES NEARBY")
        case (.uncaught, .tram): String(localized: "UNCAUGHT TRAMS NEARBY")
        case (.everything, nil): String(localized: "ALL NEARBY")
        case (.everything, .bus): String(localized: "BUSES NEARBY")
        case (.everything, .tram): String(localized: "TRAMS NEARBY")
        case (.starred, _): String(localized: "YOUR STARRED MODELS")
        }
    }

    private func wantedList(_ near: [WantedPin]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                // One line even with the count beside it on a 390 pt phone ("BRAKUJĄCE MODELE TRAMWAJÓW").
                SectionLabel(text: !cityWideHunt ? nearbyTitle
                             : filter == .starred && !targets.isCityWide ? String(localized: "YOUR STARRED MODELS")
                             : String(localized: "MATCHING YOUR FILTER"))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Spacer()
                Mono(cityWideHunt ? "\(near.count) OUT NOW" : hasFix ? "\(near.count) WITHIN 3 KM" : "AROUND THE MAP CENTRE",
                     size: 9.5, color: Palette.faint)
            }
            if filter != .newModels {
                HStack(spacing: 12) {
                    LegendSwatch(filled: true, text: String(localized: "MODEL YOU DON'T HAVE"))
                    LegendSwatch(filled: false, text: String(localized: "MODEL YOU HAVE"))
                    Spacer()
                }
                .padding(.top, 2)
            }
            Spacer().frame(height: 6)
            pinList(near, visibleRows: rows(3.5)) { select($0) }
        }
        .padding(14)
        .huntCard()
    }

    /// Why there's nothing to hunt, when there isn't.
    private func emptyState(shown: [WantedPin]) -> MessageCard? {
        switch live.status {
        case .noKey:
            return MessageCard(icon: "key.fill", title: String(localized: "Live positions are off"),
                               text: String(localized: "HUNT needs a free dane.um.warszawa.pl key. Add yours in ME › Settings › Live data."))
        case .error(let why) where live.fresh(maxAge: 120) == nil:
            return MessageCard(icon: "antenna.radiowaves.left.and.right.slash", title: String(localized: "The city's feed is down"),
                               text: String(localized: "\(why) Trying again every 10 seconds."))
        // Every position the city sends is old: say so rather than that nothing runs near you (#67).
        case .late(let age) where live.fresh(maxAge: 120) == nil:
            return MessageCard(icon: "clock.badge.exclamationmark", title: String(localized: "The city's feed is running late"),
                               text: String(localized: "Its newest positions are \(Int((age / 60).rounded())) min old. Trying again every 10 seconds."))
        case .idle, .loading:
            if live.snapshot == nil {
                return MessageCard(icon: "dot.radiowaves.left.and.right", title: String(localized: "Finding what's running…"), text: nil)
            }
        default: break
        }
        if location.isDenied, mapCenter == nil {
            return MessageCard(icon: "location.slash.fill", title: String(localized: "Location is off"),
                               text: String(localized: "Turn it on to see what's running around you — or pan the map to look anywhere."),
                               action: (String(localized: "Open Settings"), {
                                   if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                               }))
        }
        if cityWideHunt {
            guard shown.isEmpty else { return nil }
            if filter == .starred, !targets.isCityWide {
                return MessageCard(icon: "star", title: String(localized: "None of your starred models is out"),
                                   text: String(localized: "They show up here the moment one is. Star a model on its page in the book, or on its card here."))
            }
            return MessageCard(icon: "line.3.horizontal.decrease.circle", title: String(localized: "Nothing out that matches"),
                               text: targets.line == nil && filter == .newModels
                                   ? String(localized: "None of it is a model you're missing. Switch to UNCAUGHT, or widen the filter.")
                                   : targets.line != nil || withCaught
                                   ? String(localized: "Nothing on your filter is running right now. It shows up here the moment one is.")
                                   : String(localized: "Nothing on your filter that you haven't caught is running right now. It shows up here the moment one is."),
                               action: (String(localized: "Clear the filter"), { withAnimation(.snappy) { targets = HuntTargets() } }))
        }
        if nearYou(shown).isEmpty {
            // Nothing of the kind running here at all, caught or not: say that, rather than that
            // you've caught everything around you (what a tester in Bydgoszcz was told, #38).
            // Your actual position, even outside Warsaw: that's the case to explain.
            let around = location.recent(maxAge: 300)?.coordinate ?? mapCenter
            let running = around.map { a in
                live.snapshot?.nearby(lat: a.latitude, lon: a.longitude, within: Wanted.radius)
                    .contains { targets.kind == nil || $0.vehicle.kind == targets.kind } ?? true
            } ?? true
            if !running, let around {
                let center = Self.warsaw.center
                if Geo.km((around.latitude, around.longitude), (center.latitude, center.longitude)) > Self.feedReach {
                    return MessageCard(icon: "map", title: String(localized: "Nothing runs near you"),
                                       text: String(localized: "TABOR follows Warsaw's buses and trams. Pan over to Warsaw, or pick a filter to hunt across the whole city."),
                                       action: (String(localized: "Show Warsaw"), {
                                           following = false
                                           facing = false
                                           withAnimation(.easeInOut(duration: 0.7)) { position = .region(Self.warsaw) }
                                       }))
                }
                let title = switch targets.kind {
                case nil: String(localized: "Nothing within 3 km")
                case .bus: String(localized: "No buses within 3 km")
                case .tram: String(localized: "No trams within 3 km")
                }
                return MessageCard(icon: "location.magnifyingglass", title: title, text: String(localized: "Nothing running within 3 km right now."))
            }
            let title = switch (filter, targets.kind) {
            case (.newModels, nil): String(localized: "No models you're missing within 3 km")
            case (.newModels, .bus): String(localized: "No bus models you're missing within 3 km")
            case (.newModels, .tram): String(localized: "No tram models you're missing within 3 km")
            case (.uncaught, nil): String(localized: "No uncaught vehicles within 3 km")
            case (.uncaught, .bus): String(localized: "No uncaught buses within 3 km")
            case (.uncaught, .tram): String(localized: "No uncaught trams within 3 km")
            case (.everything, nil): String(localized: "Nothing within 3 km")
            case (.everything, .bus): String(localized: "No buses within 3 km")
            case (.everything, .tram): String(localized: "No trams within 3 km")
            case (.starred, _): String(localized: "None of your starred models is out")
            }
            let text = switch (filter, targets.kind) {
            case (.newModels, _): String(localized: "Everything running around here is a model you have. Switch to UNCAUGHT for more of them.")
            case (.everything, _), (.starred, _): String(localized: "Nothing running within 3 km right now.")
            case (.uncaught, nil): String(localized: "Every vehicle running around here is already in your book.")
            case (.uncaught, .bus): String(localized: "Every bus running around here is already in your book.")
            case (.uncaught, .tram): String(localized: "Every tram running around here is already in your book.")
            }
            return MessageCard(icon: "checkmark.seal.fill", title: title, text: text)
        }
        return nil
    }

    // MARK: - State

    private var hasFix: Bool { here != nil }

    /// Where you are, when it's somewhere the feed covers. From further away (a tester in
    /// Bydgoszcz), HUNT works as it does without a fix: around where you're looking, with
    /// distances from there, rather than measuring 230 km to every bus.
    private var here: CLLocationCoordinate2D? {
        guard let c = location.recent(maxAge: 300)?.coordinate else { return nil }
        let center = Self.warsaw.center
        return Geo.km((c.latitude, c.longitude), (center.latitude, center.longitude)) <= Self.feedReach ? c : nil
    }

    private var statusColor: Color {
        switch live.status {
        case .live: Palette.green
        case .loading, .idle, .late: Palette.yellow
        case .noKey, .error: Palette.red
        }
    }

    private var statusText: String {
        switch live.status {
        case .noKey: String(localized: "NO KEY")
        case .idle, .loading: String(localized: "CONNECTING")
        case .error: live.fresh(maxAge: 120) == nil ? String(localized: "OFFLINE") : String(localized: "RETRYING")
        case .live: String(localized: "LIVE")
        case .late: String(localized: "RUNNING LATE")
        }
    }

    /// Every uncaught vehicle out right now, anywhere (caught ones too in the ALL view);
    /// distances from you when there's a fix.
    private func cityWide() -> [WantedPin] {
        guard let snapshot = live.snapshot else { return [] }
        let user = here
        let from = user ?? mapCenter ?? Self.warsaw.center
        if let line = targets.line {
            return Wanted.onLine(line, snapshot: snapshot, catalog: catalog, caught: sightings.stats,
                                 lat: from.latitude, lon: from.longitude, from: user.map { ($0.latitude, $0.longitude) })
        }
        return Wanted.anywhere(snapshot: snapshot, catalog: catalog, caught: sightings.stats,
                               lat: from.latitude, lon: from.longitude,
                               from: user.map { ($0.latitude, $0.longitude) }, includeCaught: withCaught)
    }

    private var onScreen: Bool { router.tab == .hunt }

    private func recompute(animated: Bool) {
        guard onScreen else { return }
        let user = here
        guard let snapshot = live.snapshot, let center = mapCenter ?? user else { return }
        // Half the visible diagonal, and never less than the 3 km the list needs.
        let visible = mapRegion.map { r in
            Geo.km((r.center.latitude - r.span.latitudeDelta / 2, r.center.longitude - r.span.longitudeDelta / 2),
                   (r.center.latitude + r.span.latitudeDelta / 2, r.center.longitude + r.span.longitudeDelta / 2)) * 500
        } ?? 0
        // Filtered down to what you're after: look across the whole city, not just the view.
        let picked = targets
        let filtered = picked.isCityWide || filter == .starred
        var next = filtered
            ? cityWide().filter { picked.matches($0) }
            : Wanted.pins(snapshot: snapshot, catalog: catalog, caught: sightings.stats,
                          lat: center.latitude, lon: center.longitude, within: max(Wanted.radius, visible),
                          from: user.map { ($0.latitude, $0.longitude) }, includeCaught: withCaught)
        // Panned away from you: make sure what's around you still feeds the list.
        if !filtered, let user, Geo.km((user.latitude, user.longitude), (center.latitude, center.longitude)) * 1000 > visible {
            let ids = Set(next.map(\.id))
            next += Wanted.pins(snapshot: snapshot, catalog: catalog, caught: sightings.stats,
                                lat: user.latitude, lon: user.longitude, from: (user.latitude, user.longitude),
                                includeCaught: withCaught)
                .filter { !ids.contains($0.id) }
        }
        // The vehicle picked from the search, wherever it is and whether or not you have it.
        if let focusId, !next.contains(where: { $0.id == focusId }), let pin = searchedPin(focusId, in: snapshot) {
            next.append(pin)
        }
        // The selected vehicle too, while it's still running: a stop picked far down its route
        // takes the map well away from it, and dropping it there closed the card (#73).
        if let selectedId, !next.contains(where: { $0.id == selectedId }), let pin = searchedPin(selectedId, in: snapshot) {
            next.append(pin)
        }
        // Only tags standing alone around the view, and the selected one, get placed on their
        // route: it's the costly part, and a bubble sits on its vehicles' fixes anyway. Zoomed
        // out, matching all 600-odd vehicles in view stalled the map after every move (#85).
        // The list works out the rest as its rows show.
        let lone = groups(onMap(shown(next, picked: targets))).filter { $0.pins.count == 1 }.map(\.lead)
        let region = mapRegion
        func near(_ pin: WantedPin, screens: Double) -> Bool {
            region.map { r in
                abs(pin.vehicle.latitude - r.center.latitude) < r.span.latitudeDelta * screens / 2
                    && abs(pin.vehicle.longitude - r.center.longitude) < r.span.longitudeDelta * screens / 2
            } ?? true
        }
        var placed: [String: RouteMatch] = [:]
        var coordinates: [String: CLLocationCoordinate2D] = [:]
        if let book = routes.book {
            let now = Date()
            for pin in lone where pin.id == selectedId || near(pin, screens: 2) {
                guard let m = Self.match(pin, book: book, trails: live.trails) else { continue }
                placed[pin.id] = m
                let ahead = m.advanced(by: now.timeIntervalSince(pin.vehicle.time), stopped: live.trails.isStopped(pin.id))
                coordinates[pin.id] = CLLocationCoordinate2D(ahead.coordinate)
            }
        }
        matches = placed
        wrapsOut = Wanted.wrapsOut(snapshot: snapshot, catalog: catalog, caught: sightings.stats,
                                   lat: (user ?? center).latitude, lon: (user ?? center).longitude,
                                   from: user.map { ($0.latitude, $0.longitude) })
        // Vehicles glide to where they are now rather than jumping. Not with a crowd of tags on
        // screen: gliding them all every refresh kept the map redrawing and the phone warm (#85).
        if animated, lone.count(where: { near($0, screens: 1) }) <= Self.glideLimit {
            withAnimation(.easeInOut(duration: 1.2)) {
                pins = next
                nowCoordinates = coordinates
                tick = Date()
            }
        } else {
            pins = next
            nowCoordinates = coordinates
        }
        if let selectedId, !next.contains(where: { $0.id == selectedId }) { self.selectedId = nil }
        // The feed is in: open the vehicle waiting for it, or give up if it's not running.
        if let pendingFocus {
            self.pendingFocus = nil
            if let pin = next.first(where: { $0.id == pendingFocus }) { return select(pin) }
        }
        // Following the selected vehicle and it's leaving the open part above the card: catch up,
        // keeping the zoom. Not after you've moved the map yourself.
        if following, let selectedId, let pin = next.first(where: { $0.id == selectedId }), let region = mapRegion,
           let target = self.region(showing: pin.coordinate),
           abs(target.center.latitude - region.center.latitude) > region.span.latitudeDelta * 0.2
            || abs(target.center.longitude - region.center.longitude) > region.span.longitudeDelta * 0.3 {
            withAnimation(.easeInOut(duration: 1.2)) { position = .region(target) }
        }
    }

    /// The straight-line guess from its trail, checked against its route when there is one:
    /// heading for you but turning off first isn't coming your way, and far off its route it
    /// could be going anywhere.
    private func motion(of pin: WantedPin) -> Motion? {
        guard let here else { return nil }
        let guess = live.trails.motion(pin.id, lat: here.latitude, lon: here.longitude)
        guard let match = routeMatch(pin) else { return isOffRoute(pin) ? .offRoute : guess }
        return match.motion(fallback: guess, lat: here.latitude, lon: here.longitude)
    }

    private func isOffRoute(_ pin: WantedPin) -> Bool {
        let v = pin.vehicle
        guard !v.line.isEmpty, let book = routes.book else { return false }
        return book.isOffRoute(line: v.line, kind: v.kind,
                               position: LiveTrails.Point(latitude: v.latitude, longitude: v.longitude, time: v.time))
    }

    private func routeMatch(_ pin: WantedPin) -> RouteMatch? {
        if let m = matches[pin.id] { return m }
        guard let book = routes.book else { return nil }
        return Self.match(pin, book: book, trails: live.trails)
    }

    private static func match(_ pin: WantedPin, book: RouteBook, trails: LiveTrails) -> RouteMatch? {
        let v = pin.vehicle
        guard !v.line.isEmpty else { return nil }
        return book.match(line: v.line, kind: v.kind, trail: trails.trail(pin.id),
                          position: LiveTrails.Point(latitude: v.latitude, longitude: v.longitude, time: v.time))
    }

    /// Where it probably is right now: its route match slid forward by the fix's age.
    private func advanced(_ pin: WantedPin, at date: Date) -> RouteMatch? {
        routeMatch(pin)?.advanced(by: date.timeIntervalSince(pin.vehicle.time), stopped: live.trails.isStopped(pin.id))
    }

    /// TRACK on the card. It only works while the vehicle is coming your way (it counts down to
    /// your stop); otherwise it's greyed out and says why, so the button never just goes missing.
    private func trackButton(_ pin: WantedPin) -> PinCard.Track {
        if track.isTracking(pin) { return PinCard.Track(state: .on) { track.stop() } }
        guard track.enabled else {
            return PinCard.Track(state: .off(String(localized: "Live Activities are off for TABOR. Turn them on in Settings › TABOR to track it.")))
        }
        guard let here else {
            return PinCard.Track(state: .off(String(localized: "TRACK counts down to your stop, so it needs your location.")))
        }
        let motion = motion(of: pin)
        guard motion == .approaching, let m = creeping(pin) ?? routeMatch(pin),
              let plan = TrackPlan.make(match: m, lat: here.latitude, lon: here.longitude) else {
            let why = switch motion {
            case nil: String(localized: "Still watching which way it goes. TRACK works once it's coming your way.")
            case .offRoute: String(localized: "It's off its line's route (a depot run or a detour), so there's no stop to count down to.")
            default: String(localized: "TRACK works once it's coming your way: it counts down to your stop.")
            }
            return PinCard.Track(state: .off(why))
        }
        return PinCard.Track(state: .ready) { track.start(pin, plan: plan, sightings: sightings) }
    }

    /// A bell in the stop list (#96): counts down to that stop rather than the one by you, so it
    /// works on your way there, wherever you are now. Says why when it can't.
    private func trackTo(_ pin: WantedPin, stop: RouteStop) -> String? {
        guard track.enabled else {
            return String(localized: "Live Activities are off for TABOR. Turn them on in Settings › TABOR to track it.")
        }
        if motion(of: pin) == .offRoute {
            return String(localized: "It's off its line's route (a depot run or a detour), so there's no stop to count down to.")
        }
        guard let m = creeping(pin) ?? routeMatch(pin), let plan = TrackPlan.make(match: m, stop: stop) else {
            return String(localized: "It's already at that stop or past it.")
        }
        track.start(pin, plan: plan, sightings: sightings)
        return nil
    }

    /// The selected vehicle, moved on to the last tick.
    private func creeping(_ pin: WantedPin) -> RouteMatch? { advanced(pin, at: tick) }

    /// Moves the selected pin along its route between polls, but only in steps you'd see: a few
    /// points on screen at the current zoom, so zoomed out it hardly ticks at all. Each step is
    /// a short glide rather than non-stop animation, which would keep the map redrawing at full
    /// frame rate, and a stopped vehicle (or one already at its next stop) doesn't tick.
    private func creep() async {
        while !Task.isCancelled, let id = selectedId {
            // No steps while the stop list scrolls (#74); the next one catches up.
            if stopScroll.active {
                try? await Task.sleep(for: .seconds(0.5))
                continue
            }
            var wait = 2.0
            if let pin = pins.first(where: { $0.id == id }), let now = creeping(pin), now.speed >= 0.5,
               !live.trails.isStopped(id), let region = mapRegion {
                // Metres per screen point, across a phone-width map.
                let perPoint = region.span.longitudeDelta * 111_320 * cos(region.center.latitude * .pi / 180) / 400
                wait = min(max(Self.creepStep * perPoint / now.speed, 1), 10)
                try? await Task.sleep(for: .seconds(wait))
                guard !Task.isCancelled, let later = advanced(pin, at: Date()), later.along - now.along > 1 else { continue }
                withAnimation(.easeInOut(duration: 0.4)) { tick = Date() }
                continue
            }
            try? await Task.sleep(for: .seconds(wait))
        }
    }

    private func stopsScrolling(_ on: Bool) {
        stopScroll.active = on
        guard !on, stopScroll.missed else { return }
        stopScroll.missed = false
        recompute(animated: true)
    }

    /// Screen points a creeping pin moves per step.
    private static let creepStep = 4.0

    private func mapCoordinate(_ pin: WantedPin, selected now: RouteMatch?) -> CLLocationCoordinate2D {
        if pin.id == selectedId, let now { return CLLocationCoordinate2D(now.coordinate) }
        return nowCoordinates[pin.id] ?? pin.coordinate
    }

    /// Leg by leg, the route ahead fades.
    private static func aheadOpacity(_ leg: Int) -> Double { max(0.35, 0.95 - 0.2 * Double(leg)) }

    /// The path ahead cut at each stop, so each leg can fade a little more.
    private func legs(of match: RouteMatch, to stops: [RouteStop]) -> [[CLLocationCoordinate2D]] {
        var from = match.along
        return stops.map { stop in
            defer { from = stop.along }
            return match.shape.path(from: from, to: stop.along).map(CLLocationCoordinate2D.init)
        }.filter { $0.count >= 2 }
    }

    /// From the list: select the pin and fly to it.
    private func select(_ pin: WantedPin) {
        withAnimation(.snappy) { selectedId = pin.id }
        following = true
        // Beside a side panel: about as close, in the middle of the map you can see.
        if wide, let region = region(fitting: [(pin.vehicle.latitude, pin.vehicle.longitude)], minSpan: 0.015) {
            withAnimation(.easeInOut(duration: 0.6)) { position = .region(region) }
            return
        }
        withAnimation(.easeInOut(duration: 0.6)) {
            position = .camera(MapCamera(centerCoordinate: pin.coordinate, distance: 1800))
        }
    }
}

// MARK: - Pieces

private extension CLLocationCoordinate2D {
    init(_ c: (latitude: Double, longitude: Double)) { self.init(latitude: c.latitude, longitude: c.longitude) }
}

private extension WantedPin {
    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: vehicle.latitude, longitude: vehicle.longitude) }

    var accent: Color { wrap != nil ? Palette.foilInk : model.tier.mapColor }

    func subtitle(showDistance: Bool, showKind: Bool = true) -> String {
        [showKind ? vehicle.kind.name : nil, "#\(vehicle.number)", vehicle.line.isEmpty ? nil : String(localized: "LINE \(vehicle.line)"),
         showDistance ? HuntDistance.text(distance) : nil]
            .compactMap { $0 }.joined(separator: " · ")
    }
}

enum HuntDistance {
    /// "400 M", "1.2 KM" ("1,2 KM" in Polish).
    static func text(_ metres: Double) -> String {
        metres < 1000 ? "\(Int((metres / 50).rounded()) * 50) M"
            : "\((metres / 1000).formatted(FloatingPointFormatStyle<Double>(locale: .app).precision(.fractionLength(1)))) KM"
    }
}

/// A missing model: a tier-coloured tag with the line it's running on.
/// Up close: a tag with the line. Filled for a model new to you, outlined for one you have.
private struct WantedPinView: View {
    let pin: WantedPin
    let selected: Bool
    /// A model you've starred (#88).
    var starred = false
    /// Direction of travel (degrees from north), once the vehicle has been seen moving.
    var travel: Double? = nil
    /// The map's rotation, read here so a turning map redraws only the pins.
    let turn: MapTurn
    private var filled: Bool { pin.kind == .newModel || pin.wrap != nil }
    private var ink: Color { pin.wrap != nil ? Palette.foilDeep : filled ? pin.model.tier.onMapColor : pin.accent }
    /// On screen, 0 = up.
    private var heading: Double? { travel.map { $0 - turn.coarse } }

    /// Screen angle (0 = up, clockwise) to the nearest of eight arrows.
    static func arrow(_ degrees: Double) -> String {
        let names = ["arrow.up", "arrow.up.right", "arrow.right", "arrow.down.right",
                     "arrow.down", "arrow.down.left", "arrow.left", "arrow.up.left"]
        let d = (degrees.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
        return names[Int((d / 45).rounded()) % 8]
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                if starred {
                    Image(systemName: "star.fill")
                        .font(.system(size: 8.5, weight: .heavy))
                        .accessibilityHidden(true)
                }
                Image(systemName: pin.wrap?.symbol ?? (pin.vehicle.kind == .tram ? "tram.fill" : "bus.fill"))
                    .font(.system(size: 9.5, weight: .bold))
                Text(pin.vehicle.line.isEmpty ? String(pin.vehicle.number) : pin.vehicle.line)
                    .font(TaborFont.mono(12.5, 700))
                    .lineLimit(1)
                    .fixedSize()
                if let heading {
                    // One of eight arrows rather than a rotated one: MapKit doesn't re-apply
                    // transforms inside an annotation, so a rotation sticks at its first angle.
                    Image(systemName: Self.arrow(heading))
                        .font(.system(size: 10, weight: .heavy))
                        .accessibilityHidden(true)
                }
            }
            .foregroundStyle(ink)
            .padding(.vertical, 4)
            .padding(.horizontal, 7)
            .background(filled ? pin.accent : Palette.bg.opacity(0.88), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            // Foil, still: a turning one on every tag would redraw the map all the time (#85).
            .background { if pin.wrap != nil { Foil().clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous)) } }
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(selected ? .white : (filled ? Palette.bg.opacity(0.6) : pin.accent), lineWidth: selected ? 2 : 1.5))
            Triangle()
                .fill(selected ? .white : pin.accent)
                .frame(width: 9, height: 5)
        }
        // Only the selected tag glows. A shadow is drawn again for every tag on every frame of a
        // pan, and with a couple of hundred on screen it stuttered and heated an iPhone 12 (#85).
        .glow(selected ? pin.accent.opacity(filled ? 0.55 : 0.25) : nil, radius: 10)
        .scaleEffect(selected ? 1.18 : 1, anchor: .bottom)
        .animation(.spring(response: 0.3, dampingFraction: 0.6), value: selected)
        .accessibilityLabel("\(pin.model.tier.name.lowercased()) \(pin.model.name), line \(pin.vehicle.line)")
        .accessibilityAddTraits(.isButton)
    }
}

@Observable
private final class MapTurn {
    /// Degrees clockwise from north.
    private(set) var heading: Double = 0
    /// The same in 5° steps, for the pins' arrows (eight of them, 45° apart): a smooth turn
    /// would otherwise redraw every pin on every frame.
    private(set) var coarse: Double = 0
    /// Where the camera is now, to leave the map there when facing ends.
    @ObservationIgnored private(set) var camera: MapCamera?
    /// Where it last came to rest.
    @ObservationIgnored private var settled: MapCamera?

    func update(_ camera: MapCamera) {
        self.camera = camera
        if camera.heading != heading { heading = camera.heading }
        let step = (camera.heading / 5).rounded() * 5
        if step != coarse { coarse = step }
    }

    /// Whether the camera came to rest somewhere new, rather than only turning on the spot.
    func moved(_ camera: MapCamera) -> Bool {
        defer { settled = camera }
        guard let settled else { return true }
        let a = settled.centerCoordinate, b = camera.centerCoordinate
        return Geo.km((a.latitude, a.longitude), (b.latitude, b.longitude)) > 0.01
            || abs(camera.distance / settled.distance - 1) > 0.01
    }
}

/// You on the map: Apple's blue dot, with a beam the way the phone points. Like Apple Maps,
/// the beam widens when the compass isn't sure.
private struct YouDot: View {
    let turn: MapTurn
    private static let blue = Color(uiColor: .systemBlue)

    var body: some View {
        ZStack {
            if let heading = LocationService.shared.heading {
                Beam(spread: min(max(heading.accuracy, 20), 60))
                    .fill(RadialGradient(colors: [Self.blue.opacity(0.6), Self.blue.opacity(0)],
                                         center: .center, startRadius: 6, endRadius: 46))
                    .rotationEffect(.degrees(heading.degrees - turn.heading))
            }
            Circle().fill(.white).frame(width: 20, height: 20)
                .shadow(color: .black.opacity(0.35), radius: 3)
            Circle().fill(Self.blue).frame(width: 14, height: 14)
        }
        .frame(width: 92, height: 92)
        .allowsHitTesting(false)
        .accessibilityLabel("You")
    }

    private struct Beam: Shape {
        /// Half the beam's angle, in degrees.
        var spread: Double

        func path(in rect: CGRect) -> Path {
            let c = CGPoint(x: rect.midX, y: rect.midY)
            var p = Path()
            p.move(to: c)
            p.addArc(center: c, radius: rect.width / 2, startAngle: .degrees(-90 - spread), endAngle: .degrees(-90 + spread), clockwise: false)
            p.closeSubpath()
            return p
        }
    }
}

/// Vehicles too close to tell apart at this zoom: their count, in the rarest one's colour,
/// filled if any of them is a model new to you.
private struct GroupBubble: View {
    let group: PinGroup

    var body: some View {
        let filled = group.hasNewModel
        let accent = group.lead.accent
        let size = min(38, 22 + sqrt(CGFloat(group.pins.count)) * 2.5)
        Text("\(group.pins.count)")
            .font(TaborFont.mono(group.pins.count > 99 ? 11 : 12.5, 700))
            .foregroundStyle(filled ? group.lead.model.tier.onMapColor : accent)
            .frame(width: size, height: size)
            .background(filled ? accent : Palette.bg.opacity(0.88), in: Circle())
            .overlay(Circle().strokeBorder(filled ? Palette.bg.opacity(0.6) : accent, lineWidth: 1.5))
            .accessibilityLabel("\(group.pins.count) vehicles here, zoom in")
            .accessibilityAddTraits(.isButton)
    }
}

private extension View {
    @ViewBuilder func glow(_ color: Color?, radius: CGFloat) -> some View {
        if let color { shadow(color: color, radius: radius) } else { self }
    }
}

private struct LegendSwatch: View {
    let filled: Bool
    let text: String

    var body: some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 3)
                .fill(filled ? Palette.routeInk : .clear)
                .strokeBorder(Palette.routeInk, lineWidth: 1.5)
                .frame(width: 12, height: 9)
            Mono(text, size: 9.5, color: Palette.faint)
        }
    }
}

struct Triangle: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
        p.addLine(to: CGPoint(x: r.midX, y: r.maxY))
        p.closeSubpath()
        return p
    }
}

/// Whether HUNT's stop list is being scrolled. A plain class, so setting it doesn't redraw.
private final class StopScroll {
    var active = false
    /// A feed update came in meanwhile.
    var missed = false
}

/// A selected vehicle's run, stop by stop, drawn like a line on a transit map: the stop it's
/// at or just passed, faded, then every stop to the end, yours marked. Each stop with its
/// platform ("Centrum 06"), so you can tell whether you're waiting on the right side.
private struct StopList: View {
    let route: PinCard.Route
    let accent: Color
    let onStop: (RouteStop) -> Void
    /// The stop TRACK counts down to, its bell filled.
    let tracked: String?
    let onTrack: (RouteStop) -> Void
    let onScrolling: (Bool) -> Void

    private struct Row: Identifiable {
        let stop: RouteStop
        let passed: Bool
        var id: Double { stop.along }
    }

    private static let rowHeight: CGFloat = 28
    @Environment(\.wide) private var wide
    private static let bellWidth: CGFloat = 34

    var body: some View {
        let rows = (route.last.map { [Row(stop: $0, passed: true)] } ?? []) + route.ahead.map { Row(stop: $0, passed: false) }
        ScrollViewReader { reader in
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { i, row in
                        HStack(spacing: 0) {
                            Button { onStop(row.stop) } label: { line(row, first: i == 0, last: i == rows.count - 1) }
                                .buttonStyle(.plain)
                            if row.passed {
                                Color.clear.frame(width: Self.bellWidth)
                            } else {
                                bell(row.stop)
                            }
                        }
                        .id(row.id)
                    }
                }
            }
            .scrollIndicators(.hidden)
            .onScrollPhaseChange { _, phase in onScrolling(phase.isScrolling) }
            .onDisappear { onScrolling(false) }
            // Four and a bit stops at a time: the map above keeps room to show the route. Beside
            // it, in a side panel, there's the screen's height to spare.
            .frame(height: min(CGFloat(rows.count) * Self.rowHeight, Self.rowHeight * (wide ? 9.5 : 4.5)))
            .onAppear {
                // Yours, a couple of rows down from the top so the stops before it show too.
                guard let yours = route.yours,
                      let i = rows.firstIndex(where: { $0.stop == yours }), i > 3 else { return }
                reader.scrollTo(rows[i - 2].id, anchor: .top)
            }
        }
    }

    /// TRACK to this stop, for when you're on your way to it rather than at it (#96).
    private func bell(_ stop: RouteStop) -> some View {
        let on = stop.label == tracked
        return Button { onTrack(stop) } label: {
            Image(systemName: on ? "bell.fill" : "bell")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(on ? Palette.radar : Palette.sub)
                .frame(width: Self.bellWidth, height: Self.rowHeight, alignment: .trailing)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(on ? Text("Stop tracking it") : Text("Track it to \(stop.label) on the Lock Screen"))
    }

    private func line(_ row: Row, first: Bool, last: Bool) -> some View {
        let yours = row.stop == route.yours
        let terminus = last && route.end != nil
        return HStack(spacing: 10) {
            // The line through the stops, the bead on it.
            ZStack {
                VStack(spacing: 0) {
                    Rectangle().fill(first ? .clear : accent.opacity(row.passed ? 0.25 : 0.5))
                    Rectangle().fill(last ? .clear : accent.opacity(0.5))
                }
                .frame(width: 2)
                RoundedRectangle(cornerRadius: terminus ? 2 : 4.5, style: .continuous)
                    .fill(yours ? Palette.yellow : row.passed ? Palette.faint : Palette.ink)
                    .overlay(RoundedRectangle(cornerRadius: terminus ? 2 : 4.5, style: .continuous)
                        .strokeBorder(Palette.card, lineWidth: 2))
                    .frame(width: yours || terminus ? 11 : 9, height: yours || terminus ? 11 : 9)
            }
            .frame(width: 14)
            Text(row.stop.label)
                .font(TaborFont.grotesk(13.5, yours ? 600 : 500))
                .foregroundStyle(yours ? Palette.yellow : row.passed ? Palette.faint : Palette.routeInk)
                .lineLimit(1)
            Spacer(minLength: 6)
            if row.passed {
                if route.atLast { Mono("NOW", size: 9.5, weight: 700, spacing: 0.12, color: accent) }
            } else if yours {
                Mono("YOUR STOP", size: 9.5, weight: 700, spacing: 0.12, color: Palette.yellow)
            } else if terminus, let end = route.end {
                Image(systemName: end.symbol)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Palette.sub)
            }
        }
        .frame(height: Self.rowHeight)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint("Shows the stop on the map")
    }
}

/// A stop's name beside its bead on the map, once zoomed in.
private struct StopName: View {
    let text: String
    let accent: Color

    var body: some View {
        Text(text)
            .font(TaborFont.grotesk(11, 600))
            .foregroundStyle(Palette.ink)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Palette.bg.opacity(0.85), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(accent.opacity(0.7), lineWidth: 1))
    }
}

private struct PinCard: View {
    let pin: WantedPin
    let owned: Int
    /// This very vehicle in your book, in the ALL view.
    let mine: OwnedVehicle?
    let showDistance: Bool
    /// Which way it's going relative to you; nil until it's been seen moving.
    let motion: Motion?
    /// Its next stops, when it's been placed on its route.
    let nextStops: [String]
    /// Its route ends within those stops, or it's at the last one.
    let ending: (end: RouteEnd, arrived: Bool)?
    /// Its whole run from here, for the stop list.
    let route: Route?
    let routeOpen: Bool
    let onRoute: () -> Void
    /// A stop tapped in the list: shown on the map.
    let onStop: (RouteStop) -> Void
    let onScrolling: (Bool) -> Void
    /// Follow it on the Lock Screen (#42).
    let track: Track
    /// The stop it's tracked to, when it is.
    let trackedStop: String?
    /// Track it to a stop picked in the list (#96); why not, when it can't.
    let onTrackStop: (RouteStop) -> String?
    let onOpen: () -> Void
    /// Why TRACK is greyed out, shown for a few seconds after tapping it.
    @State private var trackHint: String?

    /// The stop list's rows: where it is, every stop left, and yours among them.
    struct Route {
        /// At or last passed.
        let last: RouteStop?
        let ahead: [RouteStop]
        let yours: RouteStop?
        /// The run ends at the last stop (rather than the street's shape just stopping there).
        let end: RouteEnd?
        /// Standing at `last` rather than between it and the next.
        let atLast: Bool

        init(match: RouteMatch, yours: RouteStop?) {
            last = match.lastStop
            ahead = match.remaining
            self.yours = yours
            end = match.end
            atLast = last.map { match.along - $0.along <= 15 } ?? false
        }
    }

    struct Track {
        enum State: Equatable {
            case ready
            /// Already followed: the button stops it.
            case on
            /// Can't be tracked now, and why.
            case off(String)
        }

        let state: State
        var action: () -> Void = {}
    }
    /// Off to the camera to catch it.
    let onCatch: () -> Void
    let onClose: () -> Void

    /// Where it goes next, in one line: its next stops, and how its route ends once that's
    /// among them. The last stop coming up next, or reached, is said in words.
    private var routeLine: (label: String?, symbol: String?, text: Text)? {
        if let ending, ending.arrived {
            return (nil, ending.end.symbol, Text(ending.end.arrivedText))
        }
        guard !nextStops.isEmpty else { return nil }
        let next = String(localized: "NEXT")
        if let ending, nextStops.count == 1 {
            return (next, nil, Text(ending.end.comingText))
        }
        var text = Text(nextStops.joined(separator: " · "))
        if let ending {
            text = text + Text(" ") + Text(Image(systemName: ending.end.symbol)).foregroundStyle(Palette.sub)
        }
        return (next, nil, text)
    }

    private var motionLine: (text: String, color: Color) {
        motion.map { (text: $0.text, color: $0.color) } ?? (text: String(localized: "WATCHING WHICH WAY IT GOES…"), color: Palette.faint)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                KindTag(kind: pin.vehicle.kind)
                if let wrap = pin.wrap {
                    WrapTag(wrap: wrap, animated: true)
                } else {
                    TierPill(tier: pin.model.tier, fleet: pin.model.fleet)
                }
                Spacer()
                StarButton(modelId: pin.model.id)
                CloseButton(action: onClose)
            }
            Text(pin.model.name)
                .font(TaborFont.grotesk(24, 700))
                .em(-0.03, size: 24)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Mono(pin.subtitle(showDistance: showDistance, showKind: false), size: 11, weight: 600, color: Palette.routeInk)
                    .lineLimit(1)
                Spacer(minLength: 4)
                SeenAgo(time: pin.vehicle.time)
            }
            if showDistance {
                HStack(spacing: 6) {
                    Circle().fill(motionLine.color).frame(width: 6, height: 6)
                    Mono(motionLine.text, size: 11, weight: 600, color: motionLine.color)
                        .lineLimit(1)
                        .contentTransition(.opacity)
                }
                .animation(.easeInOut(duration: 0.3), value: motionLine.text)
            }
            if let line = routeLine {
                // Tapping it opens the whole run, stop by stop.
                let opens = !(route?.ahead.isEmpty ?? true)
                Button(action: onRoute) {
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        if routeOpen, let terminus = route?.ahead.last {
                            Mono("ROUTE", size: 10, weight: 700, spacing: 0.12, color: pin.accent)
                            Text("→ \(terminus.name)")
                                .font(TaborFont.grotesk(13, 500))
                                .foregroundStyle(Palette.routeInk)
                                .lineLimit(1)
                        } else {
                            if let label = line.label {
                                Mono(label, size: 10, weight: 700, spacing: 0.12, color: pin.accent)
                            } else if let symbol = line.symbol {
                                Image(systemName: symbol)
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(pin.accent)
                            }
                            line.text
                                .font(TaborFont.grotesk(13, 500))
                                .foregroundStyle(Palette.routeInk)
                                .lineLimit(1)
                                .contentTransition(.opacity)
                        }
                        Spacer(minLength: 4)
                        if opens {
                            Image(systemName: "chevron.down")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(Palette.sub)
                                .rotationEffect(.degrees(routeOpen ? 180 : 0))
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!opens)
                .animation(.easeInOut(duration: 0.3), value: nextStops)
                .accessibilityElement(children: .combine)
                .accessibilityHint(!opens ? Text(verbatim: "") : routeOpen ? Text("Hides the stops") : Text("Shows every stop to the end of its run"))
                if routeOpen, let route, !route.ahead.isEmpty {
                    StopList(route: route, accent: pin.accent, onStop: onStop, tracked: trackedStop,
                             onTrack: trackStop, onScrolling: onScrolling)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            // With the route open the map needs the room more than this line does.
            if !routeOpen {
                Group {
                    if let wrap = pin.wrap, let until = wrap.until {
                        // The sources' plan, not what the photo will show: said as the plan.
                        Text("Due out in its \(wrap.nameDisplay) wrap until \(until.formatted(.dateTime.day().month().locale(.app))). Catch it in it for a form of its own.")
                    } else if let mine {
                        Text("In your book since \(mine.firstSeen.formatted(.dateTime.day().month())) · seen \(mine.timesSeen)×")
                    } else if pin.kind == .newModel {
                        Text("Not in your book yet — catching it opens a new page.")
                    } else {
                        Text("You have \(owned) of \(pin.model.fleet). This one isn't among them.")
                    }
                }
                .font(TaborFont.grotesk(13))
                .foregroundStyle(pin.wrap != nil ? Palette.foilInk : pin.kind == .newModel ? Palette.greenInk : Palette.sub)
            }
            HStack(spacing: 8) {
                Button(action: onOpen) {
                    HStack(spacing: 6) {
                        Image(systemName: AppTab.book.symbol)
                            .font(.system(size: 11, weight: .bold))
                        Mono("BOOK", size: 12, weight: 700, spacing: 0.12, color: Palette.ink)
                    }
                    .foregroundStyle(Palette.ink)
                    .padding(.vertical, 13)
                    .padding(.horizontal, 12)
                    .background(Palette.chip, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).stroke(Color.white.opacity(0.1)))
                }
                .buttonStyle(StickerPressStyle())
                .accessibilityLabel("Open \(pin.model.name) in the book")
                trackButton
                Button(action: onCatch) {
                    HStack(spacing: 7) {
                        Image(systemName: AppTab.catchTab.symbol)
                            .font(.system(size: 13, weight: .bold))
                        Mono("CATCH IT", size: 12, weight: 700, spacing: 0.12, color: pin.model.tier.onMapColor)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .foregroundStyle(pin.model.tier.onMapColor)
                    .frame(maxWidth: .infinity)
                    .padding(13)
                    .background(pin.accent, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                }
                .buttonStyle(StickerPressStyle())
                .accessibilityLabel("Open the camera to catch it")
            }
            .padding(.top, 2)
            if let trackHint {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Image(systemName: "bell.slash").font(.system(size: 11, weight: .semibold))
                    Text(trackHint).font(TaborFont.grotesk(12.5)).fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(Palette.sub)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(16)
        .huntCard(radius: 20, stroke: pin.accent.opacity(0.35))
        .task(id: trackHint) {
            guard trackHint != nil else { return }
            try? await Task.sleep(for: .seconds(4))
            withAnimation(.snappy) { trackHint = nil }
        }
        // Coming your way now: whatever held it back no longer does.
        .onChange(of: track.state) { if track.state == .ready { trackHint = nil } }
    }

    /// A stop's bell: the tracked one stops it, any other starts (or moves) the track there.
    private func trackStop(_ stop: RouteStop) {
        if stop.label == trackedStop, track.state == .on {
            Haptics.shared.tick()
            track.action()
        } else if let why = onTrackStop(stop) {
            Haptics.shared.nope()
            withAnimation(.snappy) { trackHint = why }
        } else {
            Haptics.shared.tick()
        }
    }

    private var trackButton: some View {
        let on = track.state == .on
        let off: String? = if case .off(let why) = track.state { why } else { nil }
        let ink = on ? Palette.bg : off != nil ? Palette.faint : Palette.radar
        return Button {
            if let off {
                Haptics.shared.nope()
                withAnimation(.snappy) { trackHint = off }
            } else {
                Haptics.shared.tick()
                track.action()
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: on ? "bell.fill" : "bell")
                    .font(.system(size: 11, weight: .bold))
                Mono(on ? "TRACKING" : "TRACK", size: 12, weight: 700, spacing: 0.12, color: ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(ink)
            .padding(.vertical, 13)
            .padding(.horizontal, 11)
            .background(on ? Palette.radar : Palette.chip, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous)
                .stroke(off != nil ? Color.white.opacity(0.08) : Palette.radar.opacity(0.4)))
        }
        .buttonStyle(StickerPressStyle())
        // Ahead of CATCH IT, which stretches: "OBSERWUJESZ" wrapped in two otherwise. The
        // buttons' padding is tight enough that "ZŁAP GO" still fits beside it.
        .layoutPriority(1)
        .accessibilityLabel(on ? String(localized: "Stop tracking it on the Lock Screen")
                            : off ?? String(localized: "Track it on the Lock Screen until it reaches you"))
        .animation(.snappy, value: track.state)
    }
}

/// How old the position on the map is: the city's feed lags a few seconds behind, and a
/// vehicle that's stopped reporting sits still at its last fix.
private struct SeenAgo: View {
    let time: Date
    /// Past this, the pin may well be somewhere else by now.
    static let stale: TimeInterval = 60

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            let age = max(0, ctx.date.timeIntervalSince(time))
            let seconds = Int(age)
            Mono(age < Self.stale ? "\(seconds) S AGO" : "\(seconds / 60) MIN AGO",
                 size: 10, weight: 600, spacing: 0.08, color: age < Self.stale ? Palette.sub : Palette.faint)
                .lineLimit(1)
                .fixedSize()
        }
    }
}

private extension RouteEnd {
    /// The last stop, coming up next.
    var comingText: String {
        switch self {
        case .depot(let stop): String(localized: "\(stop), then into the depot")
        case .turnsBack(let stop): String(localized: "\(stop), where it turns back")
        case .ends(let stop): String(localized: "\(stop), where its run ends")
        }
    }

    /// At the last stop.
    var arrivedText: String {
        switch self {
        case .depot(let stop): String(localized: "Pulling into \(stop)")
        case .turnsBack(let stop): String(localized: "Turning back at \(stop)")
        case .ends(let stop): String(localized: "End of its run at \(stop)")
        }
    }

    var symbol: String {
        switch self {
        case .depot: "house.fill"
        case .turnsBack: "arrow.uturn.backward"
        case .ends: "flag.checkered"
        }
    }
}

private extension Motion {
    /// On the card.
    var text: String {
        switch self {
        case .approaching: String(localized: "COMING YOUR WAY")
        case .passing: String(localized: "GOING PAST")
        case .leaving: String(localized: "MOVING AWAY")
        case .stopped: String(localized: "STOPPED")
        case .turnsOff: String(localized: "TURNS OFF BEFORE YOU")
        case .offRoute: String(localized: "OFF ITS ROUTE")
        }
    }

    /// Under the distance in a list row.
    var short: String {
        switch self {
        case .approaching: String(localized: "COMING", comment: "Short: vehicle heading towards you")
        case .passing: String(localized: "PASSING", comment: "Short: vehicle going past you")
        case .leaving: String(localized: "AWAY", comment: "Short: vehicle moving away from you")
        case .stopped: String(localized: "STOPPED")
        case .turnsOff: String(localized: "TURNS OFF", comment: "Short: vehicle heading your way, but its route turns before reaching you")
        case .offRoute: String(localized: "OFF ROUTE", comment: "Short: vehicle far from its line's route")
        }
    }

    var color: Color {
        switch self {
        case .approaching: Palette.green
        case .passing, .stopped: Palette.yellow
        case .leaving: Palette.sub
        case .turnsOff, .offRoute: Palette.faint
        }
    }
}

/// The small ✕ on HUNT's cards, with a finger-sized target around it.
private struct CloseButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Palette.sub)
                .frame(width: 30, height: 30)
                .background(Palette.chip, in: Circle())
                .padding(7)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(-7)
        .accessibilityLabel("Close")
    }
}

private struct MessageCard: View {
    let icon: String
    let title: String
    let text: String?
    var action: (String, () -> Void)? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Palette.sub)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(TaborFont.grotesk(15, 600))
                if let text {
                    Text(text).font(TaborFont.grotesk(13)).foregroundStyle(Palette.sub)
                }
                if let action {
                    Button(action.0, action: action.1)
                        .font(TaborFont.grotesk(14, 600))
                        .tint(Palette.yellow)
                        .padding(.top, 4)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(15)
        .huntCard()
    }
}

private extension View {
    /// A card floating over the map. Solid: pins and street names showing through the
    /// text made it hard to read.
    func huntCard(radius: CGFloat = 18, stroke: Color = Palette.hairline) -> some View {
        background(Palette.card, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).stroke(stroke))
            .shadow(color: .black.opacity(0.45), radius: 16, y: 8)
    }
}
