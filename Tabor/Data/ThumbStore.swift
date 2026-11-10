import ImageIO
import UIKit
import UniformTypeIdentifiers

/// Small copies of the book's pictures, kept ready in Caches. A list's sticker used to be made
/// from its full-size file each time the app was opened: on an iPhone 16 Pro that's about
/// 12 ms a sticker on the main thread, three to a row, and scrolling a page for the first time
/// dropped frames (worse on anything older). A ready-made small one opens in about a tenth of
/// that, with nothing to show for the difference.
///
/// Each is a JPEG, and for a die-cut sticker the cut-out's shape beside it. Not HEIC: on a
/// phone a small HEIC with a see-through edge still took 6 ms, half the original's time, where
/// a PNG took 1.8 ms; but a PNG runs to 200 KB a sticker, four times this.
///
/// iOS may empty Caches when the phone is short of room: a missing copy is made again from
/// the picture itself, on first view or by `fill`.
enum ThumbStore {
    /// Pictures asked for bigger than this come straight from the file: they're one to a
    /// screen (a vehicle's page, a share card), not a list's worth.
    static let limit = 600

    /// The sizes the book's lists ask for, which `fill` gets ready ahead of time: a row of the
    /// catch log, a row of the index, a sticker on a model's page.
    static let logRow = 200, indexRow = 240, page = 500

    private static let dir: URL = {
        let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Thumbs", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    /// One folder per picture, a file per size in it, so a picture's copies go in one move.
    private static func folder(_ file: String) -> URL { dir.appendingPathComponent(file, isDirectory: true) }
    private static func url(_ file: String, _ maxPixel: Int) -> URL { folder(file).appendingPathComponent("\(maxPixel)") }

    /// Copies are written one at a time, out of the way of the screen.
    private static let writing = DispatchQueue(label: "tabor.thumbs", qos: .utility)

    static func has(_ file: String, maxPixel: Int) -> Bool {
        FileManager.default.fileExists(atPath: url(file, maxPixel).path)
    }

    // MARK: - Reading

    /// The ready-made copy, drawn as the screen wants it; nil when there isn't one (yet).
    static func load(_ file: String, maxPixel: Int) -> UIImage? {
        guard let data = try? Data(contentsOf: url(file, maxPixel), options: .mappedIfSafe),
              let parts = Packed(data),
              let src = CGImageSourceCreateWithData(parts.jpeg as CFData, nil),
              let picture = CGImageSourceCreateImageAtIndex(src, 0, nil)
        else { return nil }
        guard let shape = parts.shape else {
            return UIImage(cgImage: picture).preparingForDisplay() ?? UIImage(cgImage: picture)
        }
        return cut(picture, shape: shape).map(UIImage.init(cgImage:))
    }

    /// A sticker again: the picture (kept on white) drawn through its cut-out's shape. Where
    /// the shape is soft, at the edge, the sticker is its white border, and white on white
    /// through a soft edge comes out exactly as it went in.
    private static func cut(_ picture: CGImage, shape: Data) -> CGImage? {
        let w = picture.width, h = picture.height
        guard shape.count == w * h, let provider = CGDataProvider(data: shape as CFData),
              let mask = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: w,
                                 space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                                 provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
              let ctx = canvas(w, h, like: picture, opaque: false)
        else { return nil }
        let all = CGRect(x: 0, y: 0, width: w, height: h)
        ctx.clip(to: all, mask: mask)
        ctx.draw(picture, in: all)
        return ctx.makeImage()
    }

    /// A bitmap in the layout the screen draws without converting, in the picture's own colours.
    private static func canvas(_ w: Int, _ h: Int, like image: CGImage, opaque: Bool) -> CGContext? {
        let space = image.colorSpace.flatMap { $0.model == .rgb && $0.supportsOutput ? $0 : nil }
            ?? CGColorSpace(name: CGColorSpace.sRGB)!
        let alpha: CGImageAlphaInfo = opaque ? .noneSkipFirst : .premultipliedFirst
        return CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                         bitmapInfo: alpha.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
    }

    // MARK: - Writing

    /// Keeps a small copy just made for the screen, for next time. Returns at once.
    static func keep(_ image: CGImage, of file: String, maxPixel: Int) {
        writing.async { write(image, of: file, maxPixel: maxPixel) }
    }

    private static func write(_ image: CGImage, of file: String, maxPixel: Int) {
        guard let data = pack(image) else { return }
        try? FileManager.default.createDirectory(at: folder(file), withIntermediateDirectories: true)
        try? data.write(to: url(file, maxPixel), options: .atomic)
    }

    private static func pack(_ image: CGImage) -> Data? {
        let w = image.width, h = image.height
        let all = CGRect(x: 0, y: 0, width: w, height: h)
        var shape: Data?
        var flat = image
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: break
        default:
            // A sticker: its shape on its own, and the picture on white. On white rather than
            // on nothing, because the edge is the white border: no hard line for JPEG to smear.
            guard let cutOut = canvas(w, h, like: image, opaque: false), let onWhite = canvas(w, h, like: image, opaque: true)
            else { return nil }
            cutOut.draw(image, in: all)
            guard let pixels = cutOut.data else { return nil }
            var alpha = [UInt8](repeating: 0, count: w * h)
            let rows = pixels.assumingMemoryBound(to: UInt8.self), stride = cutOut.bytesPerRow
            for y in 0..<h {
                // Little-endian ARGB: the alpha is each pixel's fourth byte.
                for x in 0..<w { alpha[y * w + x] = rows[y * stride + x * 4 + 3] }
            }
            // See-through nowhere (a photo that came with an alpha channel): just the picture.
            shape = alpha.contains { $0 != 255 } ? Data(alpha) : nil
            onWhite.setFillColor(CGColor(gray: 1, alpha: 1))
            onWhite.fill(all)
            onWhite.draw(image, in: all)
            guard let made = onWhite.makeImage() else { return nil }
            flat = made
        }
        let jpeg = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(jpeg, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, flat, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return Packed(jpeg: jpeg as Data, shape: shape).data
    }

    /// High enough that a copy can't be told from the picture at the size it's shown.
    private static let quality = 0.9

    /// Makes whatever copies are missing, from the pictures themselves, so the lists never
    /// have to: after an update, a restored backup, or iOS emptying Caches. `wanted` is each
    /// picture's file and the sizes the book shows it at. It opens every picture that lacks a
    /// copy, so it runs off the main thread (it's async for that), a picture at a time, and
    /// stops when its task is cancelled. Copies of pictures that are gone go too (a picture
    /// deleted takes its copies with it, so this is only for what slipped through).
    static func fill(_ wanted: [String: Set<Int>]) async {
        let fm = FileManager.default
        for name in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] where !PhotoStore.exists(name) {
            try? fm.removeItem(at: folder(name))
        }
        for (file, sizes) in wanted {
            let missing = sizes.filter { $0 <= limit && !has(file, maxPixel: $0) }
            guard !missing.isEmpty else { continue }
            guard !Task.isCancelled else { return }
            guard let src = CGImageSourceCreateWithURL(PhotoStore.url(file) as CFURL, nil) else { continue }
            for size in missing {
                guard let small = PhotoStore.thumbnail(from: src, maxPixel: size) else { continue }
                write(small, of: file, maxPixel: size)
            }
            await Task.yield()
        }
    }

    // MARK: - Clearing

    /// A picture deleted or replaced: its copies go with it.
    static func remove(_ file: String) {
        try? FileManager.default.removeItem(at: folder(file))
    }

    static func removeAll() {
        for name in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [] { remove(name) }
    }

    // MARK: - The file

    /// A small copy as kept on disk: "TBT1", the JPEG's length, the JPEG, then (for a sticker)
    /// its shape, a byte a pixel, squeezed. One file to open rather than two.
    private struct Packed {
        let jpeg: Data
        /// The cut-out's shape, a byte a pixel, row by row; nil for a plain photo.
        let shape: Data?

        private static let magic = Data("TBT1".utf8)

        init(jpeg: Data, shape: Data?) {
            self.jpeg = jpeg
            self.shape = shape
        }

        init?(_ data: Data) {
            let head = Self.magic.count + 4
            guard data.count > head, data.prefix(Self.magic.count) == Self.magic else { return nil }
            let length = data.dropFirst(Self.magic.count).prefix(4).enumerated().reduce(0) { $0 | Int($1.element) << (8 * $1.offset) }
            guard length > 0, data.count >= head + length else { return nil }
            let start = data.startIndex + head
            jpeg = data.subdata(in: start..<start + length)
            let rest = data.subdata(in: start + length..<data.endIndex)
            if rest.isEmpty {
                shape = nil
            } else {
                guard let plain = try? (rest as NSData).decompressed(using: .lzfse) as Data else { return nil }
                shape = plain
            }
        }

        var data: Data? {
            var out = Self.magic
            let n = UInt32(jpeg.count)
            out.append(contentsOf: (0..<4).map { UInt8(truncatingIfNeeded: n >> (8 * UInt32($0))) })
            out.append(jpeg)
            if let shape {
                guard let squeezed = try? (shape as NSData).compressed(using: .lzfse) as Data else { return nil }
                out.append(squeezed)
            }
            return out
        }
    }
}
