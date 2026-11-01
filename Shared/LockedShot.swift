import Foundation

/// A shot from the Lock Screen camera (#107). The extension can't read numbers or reach the app's
/// data, so it leaves each photo in its session's folder as `<id>.jpg`, with this beside it as
/// `<id>.json`; once the phone is unlocked, the app reads them like a rapid fire burst.
struct LockedShot: Codable {
    var date: Date
    /// The brackets (with a little breathing room) in the viewfinder's points, for the same
    /// crop CATCH makes. Nil when the phone was held sideways: the whole frame is the shot.
    var crop: CGRect?
    var viewSize: CGSize?
    var latitude: Double?
    var longitude: Double?
    /// The camera's rotation for the shot, in degrees (90 upright), for debug mode.
    var angle: Double?

    func save(_ photo: Data, in folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let id = UUID().uuidString
        try photo.write(to: folder.appendingPathComponent("\(id).jpg"), options: .atomic)
        // The sidecar last: a photo without one is still taken, just with less known about it.
        try JSONEncoder().encode(self).write(to: folder.appendingPathComponent("\(id).json"), options: .atomic)
    }

    static func hasShots(in folder: URL) -> Bool {
        ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .contains { $0.pathExtension == "jpg" }
    }

    /// Every shot in a session's folder, oldest first.
    static func all(in folder: URL) -> [(photo: Data, shot: LockedShot)] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "jpg" }.compactMap { file in
            guard let photo = try? Data(contentsOf: file) else { return nil }
            let sidecar = file.deletingPathExtension().appendingPathExtension("json")
            let shot = (try? Data(contentsOf: sidecar)).flatMap { try? JSONDecoder().decode(LockedShot.self, from: $0) }
            let made = (try? file.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
            return (photo, shot ?? LockedShot(date: made))
        }
        .sorted { $0.shot.date < $1.shot.date }
    }
}
