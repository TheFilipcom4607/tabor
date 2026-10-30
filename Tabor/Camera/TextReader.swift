import SwiftUI
import Vision

enum TextReader {
    /// `scale` turns heights relative to a region of interest back into heights relative to
    /// the whole frame, which is what number scoring expects.
    static func observations(from results: [VNRecognizedTextObservation], scale: CGFloat = 1) -> [TextObservation] {
        results.flatMap { obs in
            obs.topCandidates(2).map {
                TextObservation(text: $0.string, confidence: $0.confidence, height: Double(obs.boundingBox.height * scale))
            }
        }
    }

    /// Everything a still read saw, for debug mode.
    struct Report: Sendable {
        var number: Int?
        /// "full", "tiles", "full+tiles" (only short numbers on the first read), "none", or "decode-failed".
        var pass: String
        var full: [TextObservation] = []
        var tiles: [TextObservation] = []
        var candidates: [(number: Int, score: Double)] = []
        /// What the live feed changed about the candidates.
        var live = LiveHints.Adjustment()
        var duration: TimeInterval = 0

        /// Where `number` is written: the tallest text that reads as it. A number the live
        /// feed rescued was printed as the one it was rescued from.
        func box(of number: Int) -> CGRect? { boxes(of: number).max { $0.height < $1.height } }

        /// Everywhere `number` is written; none for a feed neighbour offered for a misread.
        func boxes(of number: Int) -> [CGRect] {
            let written = live.rescued.first { $0.to == number }?.from ?? number
            return NumberExtractor.boxes(of: written, in: full + tiles)
        }

        /// The numbers read, with where each is written, for `AlsoInShot`.
        var reads: [AlsoInShot.Read] {
            candidates.map { AlsoInShot.Read(number: $0.number, score: $0.score, boxes: boxes(of: $0.number)) }
        }

        var numberBox: CGRect? { number.flatMap(box(of:)) }
    }

    /// Accurate OCR over a captured or imported photo. Returns the best fleet number.
    static func bestNumber(in data: Data, mode: CatchMode) async -> Int? {
        await read(data, mode: mode, nearby: []).number
    }

    /// Full frame first; if that finds nothing, or only short numbers that may be a display's
    /// line, re-read overlapping 3×3 tiles so small numbers on a whole-vehicle shot get enough
    /// pixels (e.g. yellow-on-black "4425"), and weigh both reads together.
    /// `nearby` (live vehicles around you) boosts and rescues candidates, see `LiveHints`.
    static func read(_ data: Data, mode: CatchMode, nearby: [NearbyVehicle]) async -> Report {
        await Task.detached(priority: .userInitiated) {
            let start = Date()
            guard let image = UIImage(data: data), let decoded = image.cgImage else { return Report(pass: "decode-failed") }
            let cg = upscaled(decoded)
            let orientation = CGImagePropertyOrientation(image.imageOrientation)
            var report = Report(pass: "full")
            report.full = read(cg, orientation: orientation, roi: nil)
            report.candidates = NumberExtractor.candidates(in: report.full, mode: mode, catalog: Fleet.catalog)
            if NumberExtractor.wantsCloserLook(report.candidates) {
                report.pass = report.candidates.isEmpty ? "tiles" : "full+tiles"
                for y in [0.0, 0.3, 0.6] {
                    for x in [0.0, 0.3, 0.6] {
                        report.tiles += read(cg, orientation: orientation, roi: CGRect(x: x, y: y, width: 0.4, height: 0.4))
                    }
                }
                report.candidates = NumberExtractor.candidates(in: report.full + report.tiles, mode: mode, catalog: Fleet.catalog)
            }
            (report.candidates, report.live) = LiveHints.adjust(report.candidates, nearby: nearby, catalog: Fleet.catalog)
            report.number = report.candidates.max { $0.score < $1.score }?.number
            if report.number == nil { report.pass = "none" }
            report.duration = Date().timeIntervalSince(start)
            return report
        }.value
    }

    /// A small image (a tight crop of a far vehicle) blown up to about 1900 px on its long side.
    /// Vision doesn't do this itself: #1427 in a 472×629 crop read as nothing at its own size,
    /// "J427" at 2× and cleanly at 3× (#94).
    private static func upscaled(_ cg: CGImage) -> CGImage {
        let long = max(cg.width, cg.height)
        guard long > 0, long < 1600 else { return cg }
        let scale = min(4, 1900 / Double(long))
        let w = Int(Double(cg.width) * scale), h = Int(Double(cg.height) * scale)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return cg }
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage() ?? cg
    }

    private static func read(_ cg: CGImage, orientation: CGImagePropertyOrientation, roi: CGRect?) -> [TextObservation] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        // Fleet numbers are often small on a whole-vehicle shot (~1.5% of the frame);
        // Vision's default floor of 1/32 skips them.
        request.minimumTextHeight = 0.008
        if let roi { request.regionOfInterest = roi }
        try? VNImageRequestHandler(cgImage: cg, orientation: orientation).perform([request])
        let scale = Double(roi?.height ?? 1)
        return (request.results ?? []).flatMap { obs in
            let box = NumberExtractor.ocrBox(obs.boundingBox, roi: roi)
            return obs.topCandidates(2).map {
                TextObservation(text: $0.string, confidence: $0.confidence, height: Double(obs.boundingBox.height) * scale, box: box)
            }
        }
    }
}

extension CGImagePropertyOrientation {
    /// Orientation of a raw (landscape) camera buffer, given the capture rotation angle.
    init(bufferAngle: CGFloat) {
        switch Int(bufferAngle.rounded()) {
        case 0: self = .up
        case 180: self = .down
        case 270: self = .left
        default: self = .right
        }
    }

    init(_ o: UIImage.Orientation) {
        switch o {
        case .up: self = .up
        case .down: self = .down
        case .left: self = .left
        case .right: self = .right
        case .upMirrored: self = .upMirrored
        case .downMirrored: self = .downMirrored
        case .leftMirrored: self = .leftMirrored
        case .rightMirrored: self = .rightMirrored
        @unknown default: self = .up
        }
    }
}
