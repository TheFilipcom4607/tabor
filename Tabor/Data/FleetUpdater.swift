import Foundation

/// Fetches newer fleet data between app releases. A GitHub Action refreshes fleet.json in
/// the repo weekly; this downloads it when its `fetched` date beats what the app has, and
/// `Fleet.catalog` picks it up on the next launch.
enum FleetUpdater {
    // Builds 25 and older ask for the repo's old name, busdex, which GitHub still serves from
    // here. That only holds while no other repo on the account is called busdex.
    static let remoteURL = URL(string: "https://raw.githubusercontent.com/TheFilipcom4607/tabor/main/Tabor/Resources/fleet.json")!
    static let enabledKey = "fleetUpdates"
    private static let lastCheckKey = "fleetLastCheck"
    /// The server's tag for the file last compared, and the catalog it was compared against.
    private static let etagKey = "fleetETag"
    private static let etagForKey = "fleetETagFor"

    static let downloadedURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("fleet.json")
    }()

    enum Outcome: Equatable {
        /// Saved; used from the next launch.
        case downloaded(fetched: String)
        case upToDate
        case failed(String)
    }

    static var isEnabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }

    /// At most once a day, and only when the user hasn't turned updates off.
    static func checkIfDue() async {
        guard isEnabled else { return }
        let last = UserDefaults.standard.object(forKey: lastCheckKey) as? Date ?? .distantPast
        guard Date().timeIntervalSince(last) > 24 * 3600 else { return }
        _ = await check()
    }

    static func check() async -> Outcome {
        var request = URLRequest(url: remoteURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // Most days nothing has changed, and the whole file came down just to compare one
        // stamp: say which copy was last looked at, and the server answers with no body. Only
        // while the answer would still be the same: the same catalog running, or the download
        // that came of it still there.
        let defaults = UserDefaults.standard
        let sameCatalog = defaults.string(forKey: etagForKey) == Fleet.catalog.fetched
        if let etag = defaults.string(forKey: etagKey), sameCatalog || FileManager.default.fileExists(atPath: downloadedURL.path) {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            defaults.set(Date(), forKey: lastCheckKey)
            let http = response as? HTTPURLResponse
            if http?.statusCode == 304 {
                let pending = (try? Data(contentsOf: downloadedURL)).flatMap(FleetCatalog.validated)
                return pending?.isNewer(than: Fleet.catalog) == true ? .downloaded(fetched: pending!.fetched!) : .upToDate
            }
            guard http?.statusCode == 200 else { return .failed(String(localized: "The server didn't answer.")) }
            guard let remote = FleetCatalog.validated(json: data) else { return .failed(String(localized: "The downloaded data was broken.")) }
            // Remembered only once this copy is dealt with: not if saving it fails below.
            func seen() {
                defaults.set(http?.value(forHTTPHeaderField: "ETag"), forKey: etagKey)
                defaults.set(Fleet.catalog.fetched, forKey: etagForKey)
            }
            // Beat both what's running and anything already waiting for the next launch.
            let pending = (try? Data(contentsOf: downloadedURL)).flatMap(FleetCatalog.validated)
            guard remote.isNewer(than: Fleet.catalog), remote.isNewer(than: pending) else {
                seen()
                return pending?.isNewer(than: Fleet.catalog) == true ? .downloaded(fetched: pending!.fetched!) : .upToDate
            }
            try data.write(to: downloadedURL, options: .atomic)
            seen()
            return .downloaded(fetched: remote.fetched!)
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}
