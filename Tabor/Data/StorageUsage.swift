import Foundation

/// How much room TABOR takes on the phone (#92), split the way you'd think of it, adding up to
/// about what iOS shows as "Documents & Data". Walks the disk, so run it off the main thread.
enum StorageUsage {
    struct Breakdown: Sendable {
        var photos: Int64 = 0
        var stickers: Int64 = 0
        /// The SwiftData store: sightings, hand-picked models.
        var book: Int64 = 0
        /// Downloaded fleet.json and routes.json.
        var data: Int64 = 0
        var debug: Int64 = 0
        /// Everything else in the app's container and the App Group: widget pictures,
        /// preferences, caches, exported ZIPs not yet cleaned up.
        var other: Int64 = 0

        var total: Int64 { photos + stickers + book + data + debug + other }
    }

    /// `stickers` are the sticker file names in the book. Photos and stickers share one folder,
    /// so the names are the only way to tell them apart; a file no sighting knows counts as a photo.
    static func measure(stickers: Set<String>) -> Breakdown {
        var b = Breakdown()
        for (url, size) in files(in: PhotoStore.folder) {
            if stickers.contains(url.lastPathComponent) { b.stickers += size } else { b.photos += size }
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        b.book = ["default.store", "default.store-wal", "default.store-shm"]
            .reduce(0) { $0 + size(of: support.appendingPathComponent($1)) }
        b.data = size(of: FleetUpdater.downloadedURL) + size(of: RoutesUpdater.fileURL)
        b.debug = files(in: DebugRecord.root).reduce(0) { $0 + $1.size }

        var everything = files(in: URL(fileURLWithPath: NSHomeDirectory())).reduce(0) { $0 + $1.size }
        if let group = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: WidgetSnapshot.appGroup) {
            everything += files(in: group).reduce(0) { $0 + $1.size }
        }
        b.other = max(0, everything - b.photos - b.stickers - b.book - b.data - b.debug)
        return b
    }

    static func text(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private static func size(of url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey])
        return Int64(values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? 0)
    }

    private static func files(in dir: URL) -> [(url: URL, size: Int64)] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
        guard let walk = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: keys) else { return [] }
        var out: [(URL, Int64)] = []
        for case let url as URL in walk {
            guard let v = try? url.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { continue }
            out.append((url, Int64(v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? 0)))
        }
        return out
    }
}
