import Foundation
import os
import UIKit

/// Where the main thread stalls while the app is being used: the launch-timing log's twin.
/// Debug builds ping the main thread every 50 ms from a thread of their own and append any
/// answer that took over 80 ms to `Library/Caches/hangs.log`, with the last thing the app
/// said it was doing (`mark`). Idle CPU doesn't show these; an older phone feels them.
enum HangLog {
    private struct State {
        /// The last few things the app said it was doing, newest last.
        var marks: [(what: String, at: Date)] = [("launch", Date())]
        /// In the background the main thread is stopped, which is no hang.
        var away = false
    }

    private static let state = OSAllocatedUnfairLock(initialState: State())

    /// What the app is about to do: "tab ME", "save", "publish".
    static func mark(_ what: String) {
        #if DEBUG
        state.withLock {
            $0.marks.append((what, Date()))
            if $0.marks.count > 6 { $0.marks.removeFirst() }
        }
        #endif
    }

    static func start() {
        #if DEBUG
        let centre = NotificationCenter.default
        centre.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: nil) { _ in
            state.withLock { $0.away = true }
        }
        centre.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: nil) { _ in
            state.withLock { $0.away = false }
        }
        let thread = Thread {
            let answered = DispatchSemaphore(value: 0)
            while true {
                let asked = Date()
                DispatchQueue.main.async { answered.signal() }
                answered.wait()
                let ms = Int(Date().timeIntervalSince(asked) * 1000)
                let (marks, away) = state.withLock { ($0.marks, $0.away) }
                if ms > 80, !away {
                    // The last mark before the stall with how long before, then any set inside it.
                    let before = marks.last { $0.at <= asked }.map { "\($0.what) +\(Int(asked.timeIntervalSince($0.at) * 1000)) ms" }
                    let inside = marks.filter { $0.at > asked }.map { "[\($0.what)]" }
                    write("\(ISO8601DateFormatter().string(from: asked)) \(ms) ms · \(([before].compactMap { $0 } + inside).joined(separator: " "))\n")
                }
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
        thread.name = "HangLog"
        thread.qualityOfService = .userInteractive
        thread.start()
        #endif
    }

    private static func write(_ line: String) {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return }
        let file = caches.appendingPathComponent("hangs.log")
        if let handle = try? FileHandle(forWritingTo: file) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: file)
        }
    }
}
