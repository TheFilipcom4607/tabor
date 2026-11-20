/// How whole a sticker's cut-out looks. A bus or a tram is a box from any angle, so a cut-out
/// of all of it fills nearly all of its convex hull (0.90–0.99 on the test photos). Bushes
/// chewing off its bottom, or a car biting into it, leave a ragged, hollow outline that fills
/// far less (0.64–0.89 with foliage pasted over the same photos), and that's the shot rapid
/// fire shouldn't keep.
public struct CutShape: Sendable, Equatable {
    /// Share of its convex hull the cut-out fills, 0–1.
    public var solidity: Double
    /// Frame edges the cut-out runs into, 0–4: a vehicle the frame cuts off.
    public var edges: Int

    public init(solidity: Double, edges: Int) {
        self.solidity = solidity
        self.edges = edges
    }

    /// Higher is a more whole vehicle. Running off an edge costs about as much as a small bite.
    public var quality: Double { solidity - 0.04 * Double(edges) }

    /// An edge counts when this share of it is covered: a mirror grazing it isn't the vehicle
    /// running off.
    static let edgeShare = 0.02

    /// Measures a mask, one byte a pixel row by row, anything over 127 being the cut-out. Nil
    /// for an empty one.
    public static func measure(_ mask: [UInt8], width w: Int, height h: Int) -> CutShape? {
        guard w > 0, h > 0, mask.count >= w * h else { return nil }
        // Each row's outermost pixels, as the corners of their cells: the hull of those is the
        // hull of the whole cut-out, and it costs one pass.
        var corners: [Point] = []
        corners.reserveCapacity(h * 4)
        var pixels = 0
        var left = 0, right = 0
        for y in 0..<h {
            var first = -1, last = -1
            let row = y * w
            for x in 0..<w where mask[row + x] > 127 {
                pixels += 1
                if first < 0 { first = x }
                last = x
            }
            guard first >= 0 else { continue }
            if first == 0 { left += 1 }
            if last == w - 1 { right += 1 }
            let y0 = Double(y), y1 = Double(y + 1), x0 = Double(first), x1 = Double(last + 1)
            corners += [Point(x0, y0), Point(x1, y0), Point(x0, y1), Point(x1, y1)]
        }
        guard pixels > 0 else { return nil }
        var top = 0, bottom = 0
        for x in 0..<w {
            if mask[x] > 127 { top += 1 }
            if mask[(h - 1) * w + x] > 127 { bottom += 1 }
        }
        let edges = [(left, h), (right, h), (top, w), (bottom, w)]
            .count { Double($0.0) >= Double($0.1) * edgeShare }
        let area = hullArea(corners)
        return CutShape(solidity: min(1, Double(pixels) / max(area, 1)), edges: edges)
    }

    struct Point {
        var x, y: Double
        init(_ x: Double, _ y: Double) { self.x = x; self.y = y }
    }

    /// Area of the convex hull (Andrew's monotone chain, then the shoelace).
    static func hullArea(_ points: [Point]) -> Double {
        let pts = points.sorted { $0.x != $1.x ? $0.x < $1.x : $0.y < $1.y }
        guard pts.count >= 3 else { return 0 }
        let cross = { (o: Point, a: Point, b: Point) in (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x) }
        var hull: [Point] = []
        for p in pts {
            while hull.count >= 2, cross(hull[hull.count - 2], hull[hull.count - 1], p) <= 0 { hull.removeLast() }
            hull.append(p)
        }
        let lower = hull.count + 1
        for p in pts.reversed() {
            while hull.count >= lower, cross(hull[hull.count - 2], hull[hull.count - 1], p) <= 0 { hull.removeLast() }
            hull.append(p)
        }
        hull.removeLast()
        var twice = 0.0
        for i in hull.indices {
            let a = hull[i], b = hull[(i + 1) % hull.count]
            twice += a.x * b.y - b.x * a.y
        }
        return abs(twice) / 2
    }
}
