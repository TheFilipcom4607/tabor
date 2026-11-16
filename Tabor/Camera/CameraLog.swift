import Foundation

/// The camera's diary, in debug builds only (the phone build): every start and stop and how
/// long the session took, rests and wakes and why, what AVFoundation said, and when a picture
/// actually reached the viewfinder, in `Library/Caches/camera.log`. A black viewfinder after a
/// rest (2026-11-16) left no trail but a stall in hangs.log; this is the trail.
/// Only events go in, a few a minute at most, never frames: nothing runs while the camera
/// just runs, so it costs no battery to speak of.
enum CameraLog {
    #if DEBUG
    private static let queue = DispatchQueue(label: "tabor.camera.log", qos: .utility)
    private static let file = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
        .appendingPathComponent("camera.log")
    /// Past this, the older half goes.
    private static let cap = 512 * 1024
    #endif

    static func note(_ what: @autoclosure () -> String) {
        #if DEBUG
        let at = Date()
        let line = what()
        queue.async {
            append("\(at.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: true)))Z \(line)\n")
        }
        #endif
    }

    #if DEBUG
    private static func append(_ line: String) {
        guard let file else { return }
        if let size = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? Int, size > cap,
           let data = try? Data(contentsOf: file) {
            let tail = data.suffix(cap / 2)
            let start = tail.firstIndex(of: 0x0A).map { $0 + 1 } ?? tail.startIndex
            try? Data(data[start...]).write(to: file)
        }
        if let handle = try? FileHandle(forWritingTo: file) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: file)
        }
    }
    #endif
}
