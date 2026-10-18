import CoreGraphics
import Foundation

/// An event wrap: one vehicle dressed for an event (Christmas, Valentine's, the Chopin
/// Competition…) between two dates a source gives. Hand-kept in fetch_fleet.py's `WRAPS`.
/// A wrap only says the vehicle *may* be dressed: a catch gets it on the photo's evidence
/// (`WrapCheck`), because the wrap can come off before its window ends.
public struct Wrap: Codable, Hashable, Sendable, Identifiable {
    /// "bus-5887-xmas-2025": stored on the catch, so it never changes.
    public let id: String
    public let kind: VehicleKind
    public let number: Int
    /// The window, Warsaw dates as the sources give them: "2025-12-01", "2026-01-06".
    public let from: String
    public let to: String
    /// "CHRISTMAS 2025" / "ŚWIĘTA 2025".
    public let name: String
    public let namePl: String?
    /// What it's for, across years: "christmas", "valentines", "summer", "chopin", "halloween".
    public let event: String
    /// Its signature colours, as `WrapHue` names. Unknown names (from a newer fleet file) are skipped.
    public let hues: [String]
    /// Words painted on it, as OCR reads them ("CHOPINA", "HALLOWEEN").
    public let words: [String]
    /// Special lines it ran ("W26", "M").
    public let lines: [String]

    public init(id: String, kind: VehicleKind, number: Int, from: String, to: String, name: String,
                namePl: String? = nil, event: String, hues: [String] = [], words: [String] = [], lines: [String] = []) {
        self.id = id
        self.kind = kind
        self.number = number
        self.from = from
        self.to = to
        self.name = name
        self.namePl = namePl
        self.event = event
        self.hues = hues
        self.words = words
        self.lines = lines
    }

    public var nameDisplay: String { AppLanguage.polish ? namePl ?? name : name }

    /// "Christmas", "Valentine's": the event, across years.
    public static func eventName(_ event: String) -> String {
        switch event {
        case "christmas": String(localized: "CHRISTMAS", comment: "An event wraps are made for")
        case "valentines": String(localized: "VALENTINE'S", comment: "An event wraps are made for")
        case "summer": String(localized: "SUMMER HOLIDAYS", comment: "An event wraps are made for")
        case "chopin": String(localized: "CHOPIN COMPETITION", comment: "An event wraps are made for")
        case "halloween": String(localized: "HALLOWEEN", comment: "An event wraps are made for")
        default: event.uppercased()
        }
    }

    public var signature: [WrapHue] { hues.compactMap(WrapHue.init(rawValue:)) }

    /// Whether `date` falls in the window, by the Warsaw calendar day.
    public func covers(_ date: Date) -> Bool {
        let day = Self.day(date)
        return from <= day && day <= to
    }

    /// The window's last day, for "until 6 Jan".
    public var until: Date? { Self.parse(to) }

    /// Whether the window ended before `date`'s Warsaw day.
    public func isOver(_ date: Date) -> Bool { Self.day(date) > to }

    /// The wraps worth a place on a shelf: the ones caught, and the ones still out or coming.
    /// A wrap that came off before you could catch it isn't a gap in your book, just bad luck
    /// (most of them came off before TABOR existed), so it drops out rather than staying empty.
    public static func shelf(_ wraps: [Wrap], caught: Set<String>, now: Date = .now) -> [Wrap] {
        wraps.filter { caught.contains($0.id) || !$0.isOver(now) }
    }

    /// A window date ("2025-12-01") as noon in Warsaw, so it shows as that day anywhere nearby.
    public static func parse(_ day: String) -> Date? { dayFormatter.date(from: day)?.addingTimeInterval(12 * 3600) }

    static func day(_ date: Date) -> String { dayFormatter.string(from: date) }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "Europe/Warsaw")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}

/// Colour families a livery is told by. ZTM's own paint is yellow and red.
public enum WrapHue: String, Sendable, CaseIterable {
    case red, orange, yellow, green, blue, navy, purple, pink

    /// The family of one pixel, or nil for greys, black, white and anything too dull to count.
    static func of(r: Double, g: Double, b: Double) -> WrapHue? {
        let mx = max(r, g, b), mn = min(r, g, b)
        let v = mx, s = mx > 0 ? (mx - mn) / mx : 0
        guard s >= 0.35, v >= 0.12, mx > mn else { return nil }
        var h: Double
        if mx == r { h = (g - b) / (mx - mn) } else if mx == g { h = 2 + (b - r) / (mx - mn) } else { h = 4 + (r - g) / (mx - mn) }
        h = (h * 60).truncatingRemainder(dividingBy: 360)
        if h < 0 { h += 360 }
        // Dark blue reads as navy, not blue: Christmas 2025's ground, which no plain bus has.
        if (200..<260).contains(h), v < 0.45 { return .navy }
        guard v >= 0.3 else { return nil }
        switch h {
        case 345..., ..<15: return .red
        case 15..<38: return .orange
        case 38..<65: return .yellow
        case 65..<170: return .green
        case 170..<255: return .blue
        case 255..<290: return .purple
        default: return .pink
        }
    }
}

/// How much of a vehicle is each colour family: shares of the counted pixels, 0–1.
public struct HueShares: Equatable, Sendable {
    public var shares: [WrapHue: Double]
    /// Counted over a sticker's cut-out (just the vehicle) rather than a photo's middle,
    /// where sky, trees and road water the vehicle's colours down.
    public var masked: Bool

    public init(_ shares: [WrapHue: Double], masked: Bool) {
        self.shares = shares
        self.masked = masked
    }

    public subscript(hue: WrapHue) -> Double { shares[hue] ?? 0 }

    /// Counts RGBA8 pixels (premultiplied or not). With `masked`, only opaque pixels count,
    /// so a sticker's transparent background stays out; `region` (0–1, top-left origin)
    /// limits a plain photo to its middle. The sticker's white border, and white in
    /// general, isn't counted either way.
    public static func count(rgba: [UInt8], width: Int, height: Int, masked: Bool,
                             region: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1)) -> HueShares {
        var counts: [WrapHue: Int] = [:]
        var total = 0
        let x0 = Int(region.minX * Double(width)), x1 = Int(region.maxX * Double(width))
        let y0 = Int(region.minY * Double(height)), y1 = Int(region.maxY * Double(height))
        guard rgba.count >= width * height * 4 else { return HueShares([:], masked: masked) }
        for y in max(0, y0)..<min(height, y1) {
            for x in max(0, x0)..<min(width, x1) {
                let i = (y * width + x) * 4
                let a = Double(rgba[i + 3]) / 255
                if masked, a < 0.5 { continue }
                let un = a > 0 ? a : 1
                let r = Double(rgba[i]) / 255 / un, g = Double(rgba[i + 1]) / 255 / un, b = Double(rgba[i + 2]) / 255 / un
                if min(r, g, b) > 0.85 { continue }
                total += 1
                if let hue = WrapHue.of(r: r, g: g, b: b) { counts[hue, default: 0] += 1 }
            }
        }
        guard total > 0 else { return HueShares([:], masked: masked) }
        return HueShares(counts.mapValues { Double($0) / Double(total) }, masked: masked)
    }

    /// "yellow 0.012 red 0.255 …" for debug mode's info.json.
    public var summary: [String: Double] {
        Dictionary(uniqueKeysWithValues: WrapHue.allCases.map { ($0.rawValue, (self[$0] * 1000).rounded() / 1000) })
    }
}

public enum WrapVerdict: Equatable, Sendable {
    /// The photo shows the wrap: its words, its special line, or its colours.
    case dressed(WrapEvidence)
    /// ZTM's yellow and red, none of the wrap's signs: no claim anywhere.
    case plain
    /// Can't tell: the reveal offers the wrap as a one-tap chip.
    case unsure

    public var label: String {
        switch self {
        case .dressed(let e): "dressed:\(e.rawValue)"
        case .plain: "plain"
        case .unsure: "unsure"
        }
    }
}

public enum WrapEvidence: String, Sendable {
    case words, line, colours
}

public enum WrapCheck {
    struct Limits {
        /// Dressed: the wrap's own colours make up at least this much of the vehicle…
        let signature: Double
        /// …and ZTM's yellow at most this.
        let wrappedYellow: Double
        /// Plain: at least this much yellow, and at least half as much as the wrap's colours.
        let plainYellow: Double
    }

    /// Fitted on 2026-10-17 to Vision cut-outs of 11 wrap photos (yellow 0–4%, own colours
    /// 15–30%; Halloween kept the yellow body: 8.5%) and 15 plain buses (yellow 7–30%).
    static let masked = Limits(signature: 0.12, wrappedYellow: 0.05, plainYellow: 0.06)
    /// A photo's middle, sky and all: plain buses at night or far off show as little yellow
    /// as a wrap (0.3–2%), and a person's red coat can pass for Christmas, so it takes a lot
    /// of the wrap's colours. Doubtful shots get the chip, never a claim.
    static let photo = Limits(signature: 0.12, wrappedYellow: 0.025, plainYellow: 0.05)

    /// Whether `wrap` is on the vehicle in the photo. `texts` is everything OCR read in the
    /// shot; `line` the line it's on (the live feed's).
    public static func verdict(wrap: Wrap, colours: HueShares?, texts: [String], line: String?) -> WrapVerdict {
        if hasWords(wrap.words, in: texts) { return .dressed(.words) }
        if let line, wrap.lines.contains(where: { $0.caseInsensitiveCompare(line) == .orderedSame }) { return .dressed(.line) }
        // A special line on its display ("W26"). One letter ("M") could be anything.
        if wrap.lines.contains(where: { l in l.count >= 2 && texts.contains { folded($0) == folded(l) } }) { return .dressed(.line) }
        let signature = Set(wrap.signature.filter { $0 != .yellow })
        guard let colours, !signature.isEmpty else { return .unsure }
        let limits = colours.masked ? masked : photo
        let own = signature.reduce(0) { $0 + colours[$1] }
        let yellow = colours[.yellow]
        if own >= limits.signature, yellow <= limits.wrappedYellow { return .dressed(.colours) }
        return yellow >= limits.plainYellow && yellow >= own / 2 ? .plain : .unsure
    }

    /// Any of `words` in what was read, ignoring case, accents, spaces and line breaks.
    static func hasWords(_ words: [String], in texts: [String]) -> Bool {
        let read = folded(texts.joined())
        return words.contains { w in
            let f = folded(w)
            return f.count >= 5 && read.contains(f)
        }
    }

    /// "Miło was widzieć" → "MILOWASWIDZIEC": OCR set to English drops Polish accents.
    static func folded(_ s: String) -> String {
        let plain = s.replacingOccurrences(of: "ł", with: "l").replacingOccurrences(of: "Ł", with: "L")
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        return String(plain.uppercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
    }
}
