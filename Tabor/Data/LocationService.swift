import CoreLocation

struct Geotag {
    let coordinate: CLLocationCoordinate2D
    let street: String?
    let district: String?
}

/// One-shot location + reverse geocode for geotagging a catch, plus continuous updates
/// while the HUNT map or the camera needs to know what's nearby.
///
/// The camera only needs to know what's within a few hundred metres, so it watches with a
/// rough fix (Wi-Fi and cell, no GPS). A catch's pin and district want better: the shutter
/// asks for a precise fix (`geotag()`), and the GPS runs just until it has one.
@Observable @MainActor
final class LocationService: NSObject, CLLocationManagerDelegate {
    static let shared = LocationService()

    /// Latest fix from continuous updates (or a one-shot request).
    private(set) var latest: CLLocation?
    private(set) var authorization: CLAuthorizationStatus = .notDetermined
    /// Which way the phone points, while someone asks for it: nil without a compass.
    private(set) var heading: Heading?
    /// Whether there's a heading at all. Views that only need this read it instead of `heading`,
    /// which changes every couple of degrees and would redraw them each time.
    private(set) var hasHeading = false

    struct Heading: Equatable {
        /// Degrees clockwise from true north (magnetic north until there's a fix).
        let degrees: Double
        /// How far off it may be, in degrees.
        let accuracy: Double
    }

    @ObservationIgnored private let manager = CLLocationManager()
    @ObservationIgnored private var pending: [CheckedContinuation<CLLocation?, Never>] = []
    /// Who wants continuous updates, and whether they need them precise.
    @ObservationIgnored private var watchers: [String: Bool] = [:]
    /// The best fix seen while a shutter waits for a precise one.
    @ObservationIgnored private var best: CLLocation?
    @ObservationIgnored private var giveUp: Task<Void, Never>?

    /// Good enough for a catch's pin: the street and district come out right.
    static let preciseEnough: CLLocationAccuracy = 25
    /// How long a shutter waits for a precise fix before taking the best one so far.
    static let preciseWait: Duration = .seconds(10)
    @ObservationIgnored private var headingWatchers: Set<String> = []

    override init() {
        super.init()
        authorization = manager.authorizationStatus
        manager.delegate = self
        applyAccuracy()
        // Enough to turn the map smoothly without redrawing it for every tremble.
        manager.headingFilter = 2
    }

    var isDenied: Bool { authorization == .denied || authorization == .restricted }

    /// Keeps a live fix while any `client` wants one; `precise` ones get the GPS, the rest a
    /// rough fix to about 100 m. Foreground only: the app has no background location mode,
    /// so iOS pauses this when TABOR leaves the screen.
    func startUpdating(_ client: String, precise: Bool = true) {
        requestPermission()
        let first = watchers.isEmpty
        watchers[client] = precise
        applyAccuracy()
        if first { manager.startUpdatingLocation() }
    }

    func stopUpdating(_ client: String) {
        guard watchers.removeValue(forKey: client) != nil else { return }
        applyAccuracy()
        if watchers.isEmpty { manager.stopUpdatingLocation() }
    }

    /// Precise while a screen or a shutter needs it, rough otherwise.
    private func applyAccuracy() {
        let waiting = !pending.isEmpty
        let precise = waiting || watchers.values.contains(true)
        let accuracy = precise ? kCLLocationAccuracyNearestTenMeters : kCLLocationAccuracyHundredMeters
        // While a shutter waits, every fix comes through: a better one a few metres from the
        // rough one would otherwise be filtered out.
        let filter = waiting ? kCLDistanceFilterNone : precise ? 20 : 50
        if manager.desiredAccuracy != accuracy { manager.desiredAccuracy = accuracy }
        if manager.distanceFilter != filter { manager.distanceFilter = filter }
    }

    /// The compass, while any `client` wants it (HUNT's cone and its facing map).
    func startHeading(_ client: String) {
        guard CLLocationManager.headingAvailable() else { return }
        let first = headingWatchers.isEmpty
        headingWatchers.insert(client)
        if first { manager.startUpdatingHeading() }
    }

    func stopHeading(_ client: String) {
        guard headingWatchers.remove(client) != nil, headingWatchers.isEmpty else { return }
        manager.stopUpdatingHeading()
        heading = nil
        hasHeading = false
    }

    /// `latest`, if it's recent enough to say what's around you.
    func recent(maxAge: TimeInterval = 60) -> CLLocation? {
        guard let latest, latest.timestamp.timeIntervalSinceNow > -maxAge, latest.horizontalAccuracy < 250 else { return nil }
        return latest
    }

    func requestPermission() {
        if manager.authorizationStatus == .notDetermined { manager.requestWhenInUseAuthorization() }
    }

    func geotag() async -> Geotag? {
        requestPermission()
        guard let loc = await currentLocation() else { return nil }
        return await geotag(loc)
    }

    /// Reverse-geocodes a known position (e.g. from an imported photo's EXIF).
    func geotag(_ loc: CLLocation) async -> Geotag? {
        let mark = try? await CLGeocoder().reverseGeocodeLocation(loc, preferredLocale: Locale(identifier: "pl_PL")).first
        return Geotag(coordinate: loc.coordinate, street: mark?.thoroughfare, district: mark?.subLocality)
    }

    private func currentLocation() async -> CLLocation? {
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways: break
        default: return nil
        }
        if let recent = manager.location, recent.timestamp.timeIntervalSinceNow > -30,
           recent.horizontalAccuracy >= 0, recent.horizontalAccuracy <= Self.preciseEnough { return recent }
        return await withCheckedContinuation { cont in
            pending.append(cont)
            guard pending.count == 1 else { return }
            best = nil
            applyAccuracy()
            // Running updates pick up the new accuracy on their own; otherwise ask once.
            if watchers.isEmpty { manager.requestLocation() }
            giveUp = Task { [weak self] in
                try? await Task.sleep(for: Self.preciseWait)
                guard !Task.isCancelled, let self else { return }
                let fallback = self.manager.location.flatMap { $0.timestamp.timeIntervalSinceNow > -60 ? $0 : nil }
                self.resolve(self.best ?? fallback)
            }
        }
    }

    private func received(_ loc: CLLocation?) {
        guard let loc, loc.horizontalAccuracy >= 0 else { return }
        latest = loc
        guard !pending.isEmpty else { return }
        if best.map({ loc.horizontalAccuracy <= $0.horizontalAccuracy }) ?? true { best = loc }
        // A one-off request answers once, so take what it gives.
        if loc.horizontalAccuracy <= Self.preciseEnough || watchers.isEmpty { resolve(loc) }
    }

    /// Answers every waiting shutter and lets the GPS go back to sleep.
    private func resolve(_ loc: CLLocation?) {
        giveUp?.cancel()
        giveUp = nil
        best = nil
        let conts = pending
        pending.removeAll()
        applyAccuracy()
        conts.forEach { $0.resume(returning: loc) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let loc = locations.last
        Task { @MainActor in self.received(loc) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateHeading new: CLHeading) {
        // A negative accuracy means the reading is no good (the compass needs calibrating).
        let reading = new.headingAccuracy < 0 ? nil
            : Heading(degrees: new.trueHeading >= 0 ? new.trueHeading : new.magneticHeading, accuracy: new.headingAccuracy)
        Task { @MainActor in
            guard !self.headingWatchers.isEmpty else { return }
            self.heading = reading
            if self.hasHeading != (reading != nil) { self.hasHeading = reading != nil }
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            self.authorization = status
            if !self.watchers.isEmpty, status == .authorizedWhenInUse || status == .authorizedAlways {
                self.manager.startUpdatingLocation()
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Running updates keep trying after a miss; a one-off request is over.
        Task { @MainActor in
            if self.watchers.isEmpty, !self.pending.isEmpty { self.resolve(self.best) }
        }
    }
}
