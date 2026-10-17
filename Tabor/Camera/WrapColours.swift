import CoreGraphics
import Foundation

/// The colours a catch's vehicle wears, for `WrapCheck`: counted over the sticker's cut-out
/// (just the vehicle), or without one (a failed cut; the simulator can't lift subjects) over
/// the photo's middle, which `WrapCheck` trusts less.
enum WrapColours {
    /// Enough pixels to tell colours apart; any more is time spent for nothing.
    private static let side = 200
    private static let middle = CGRect(x: 0.1, y: 0.15, width: 0.8, height: 0.7)

    static func shares(sticker: Data?, photo: Data) -> HueShares? {
        if let sticker, let s = count(sticker, masked: true), !s.shares.isEmpty { return s }
        return count(photo, masked: false)
    }

    private static func count(_ data: Data, masked: Bool) -> HueShares? {
        guard let cg = PhotoStore.downsample(data, maxPixel: side) else { return nil }
        let w = cg.width, h = cg.height
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        let drawn = pixels.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return nil }
        // CGContext rows run top-down in memory, as `HueShares.count` expects.
        return HueShares.count(rgba: pixels, width: w, height: h, masked: masked,
                               region: masked ? CGRect(x: 0, y: 0, width: 1, height: 1) : middle)
    }
}
