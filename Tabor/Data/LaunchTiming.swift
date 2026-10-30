import Foundation
import os

/// How long it takes from opening TABOR to a camera ready to shoot (#107). Debug builds append
/// one line per launch to `Library/Caches/launch-timing.log`: a cold launch counts from the
/// process starting, a return from the background from the moment the app is back.
enum LaunchTiming {
    private struct Run {
        var kind: String
        var from: Date
        var marks: [String] = []
    }

    private static let run = OSAllocatedUnfairLock<Run?>(initialState: Run(kind: "cold", from: processStart))

    /// The app is back from the background: time the camera from here.
    static func warm() {
        run.withLock { $0 = Run(kind: "warm", from: Date()) }
    }

    /// A step on the way; "running" ends the run and writes it down.
    static func mark(_ step: String) {
        #if DEBUG
        let line: String? = run.withLock { r in
            guard var current = r else { return nil }
            current.marks.append("\(step) \(Int(Date().timeIntervalSince(current.from) * 1000)) ms")
            r = step == "running" ? nil : current
            guard step == "running" else { return nil }
            return "\(ISO8601DateFormatter().string(from: Date())) \(current.kind): \(current.marks.joined(separator: " · "))\n"
        }
        if let line { write(line) }
        #endif
    }

    private static func write(_ line: String) {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return }
        let file = caches.appendingPathComponent("launch-timing.log")
        if let handle = try? FileHandle(forWritingTo: file) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: file)
        }
    }

    private static var processStart: Date {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return Date() }
        let t = info.kp_proc.p_starttime
        return Date(timeIntervalSince1970: Double(t.tv_sec) + Double(t.tv_usec) / 1_000_000)
    }
}
