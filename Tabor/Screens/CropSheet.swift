import SwiftUI

/// Zoom in on a far vehicle the read and the cut both missed (#94): pinch and drag until it
/// fills the frame, and the catch is read again from just that part of the photo.
struct CropSheet: View {
    let photo: Data
    let preview: UIImage?
    /// The part of the photo in the frame, in 0–1 of the upright photo.
    let onRead: (CGRect) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var image: UIImage?
    @State private var scale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var baseScale: CGFloat = 1
    @State private var baseOffset: CGSize = .zero
    @State private var frame: CGSize = .zero

    private let maxScale: CGFloat = 10

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Spacer()
                Button { dismiss() } label: {
                    Mono("CANCEL", size: 12)
                        .padding(.vertical, 12)
                        .padding(.horizontal, 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.top, -2)

            VStack(alignment: .leading, spacing: 7) {
                Mono("CROP", size: 12, spacing: 0.16, color: Palette.yellow)
                Text("Zoom in on the vehicle")
                    .font(TaborFont.grotesk(30, 700))
                    .em(-0.03, size: 30)
                Text("Pinch until it fills the frame, or double-tap it. The number is read again from what's inside.")
                    .font(TaborFont.grotesk(13))
                    .foregroundStyle(Palette.sub)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 26)
            .padding(.top, 8)

            GeometryReader { geo in
                let shown = image ?? preview
                let aspect = shown.map { $0.size.width / max($0.size.height, 1) } ?? 0.75
                let fit = Self.fit(aspect: aspect, in: geo.size)
                ZStack {
                    if let shown {
                        Image(uiImage: shown)
                            .resizable()
                            .frame(width: fit.width, height: fit.height)
                            .scaleEffect(scale)
                            .offset(offset)
                    }
                    ViewfinderBrackets().padding(6).allowsHitTesting(false)
                }
                .frame(width: fit.width, height: fit.height)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .contentShape(Rectangle())
                .gesture(pinch(fit).simultaneously(with: pan(fit)))
                .onTapGesture(count: 2) { point in zoom(at: point, in: fit) }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onChange(of: fit, initial: true) { _, new in frame = new }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 18)

            Button {
                Haptics.shared.tick()
                onRead(Self.region(scale: scale, offset: offset, in: frame))
            } label: {
                Text("Read this")
                    .font(TaborFont.grotesk(16, 700))
                    .frame(maxWidth: .infinity)
                    .padding(17)
                    .foregroundStyle(Palette.bg)
                    .background(Palette.yellow, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .buttonStyle(StickerPressStyle())
            .disabled(scale < 1.3)
            .opacity(scale < 1.3 ? 0.4 : 1)
            .padding(.horizontal, 26)
            .padding(.bottom, 20)
        }
        .foregroundStyle(Palette.ink)
        .background(Palette.bg.ignoresSafeArea())
        .task {
            // The reveal's preview is only 900 px: too coarse to aim at a far vehicle.
            let photo = photo
            image = await Task.detached(priority: .userInitiated) {
                PhotoStore.downsample(photo, maxPixel: 2400).map(UIImage.init(cgImage:))
            }.value
        }
    }

    // MARK: - Gestures

    private func pinch(_ size: CGSize) -> some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let s = min(maxScale, max(1, baseScale * value.magnification))
                // The spot between your fingers stays under them, as in Photos.
                let p = value.startLocation
                let u = CGSize(width: (p.x - size.width / 2 - baseOffset.width) / baseScale,
                               height: (p.y - size.height / 2 - baseOffset.height) / baseScale)
                scale = s
                offset = Self.clamp(CGSize(width: p.x - size.width / 2 - u.width * s,
                                           height: p.y - size.height / 2 - u.height * s), scale: s, in: size)
            }
            .onEnded { _ in commit() }
    }

    private func pan(_ size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                let o = CGSize(width: baseOffset.width + value.translation.width, height: baseOffset.height + value.translation.height)
                offset = Self.clamp(o, scale: scale, in: size)
            }
            .onEnded { _ in commit() }
    }

    private func commit() {
        baseScale = scale
        baseOffset = offset
    }

    /// Double-tap: zoom in a step with the tapped spot brought to the middle; at full zoom, back out.
    private func zoom(at point: CGPoint, in size: CGSize) {
        Haptics.shared.tick()
        let s = scale >= maxScale * 0.9 ? 1 : min(maxScale, scale * 2.5)
        // The tapped spot, from the photo's middle, in unzoomed points.
        let u = CGSize(width: (point.x - size.width / 2 - offset.width) / scale,
                       height: (point.y - size.height / 2 - offset.height) / scale)
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            scale = s
            offset = Self.clamp(CGSize(width: -u.width * s, height: -u.height * s), scale: s, in: size)
        }
        commit()
    }

    // MARK: - Geometry

    /// The photo's frame: as big as fits, at the photo's own shape.
    static func fit(aspect: CGFloat, in space: CGSize) -> CGSize {
        guard space.width > 0, space.height > 0 else { return .zero }
        return space.width / space.height > aspect
            ? CGSize(width: space.height * aspect, height: space.height)
            : CGSize(width: space.width, height: space.width / aspect)
    }

    /// The photo always covers the frame.
    static func clamp(_ o: CGSize, scale: CGFloat, in size: CGSize) -> CGSize {
        let mx = (scale - 1) * size.width / 2, my = (scale - 1) * size.height / 2
        return CGSize(width: min(mx, max(-mx, o.width)), height: min(my, max(-my, o.height)))
    }

    /// What the frame shows, in 0–1 of the photo.
    static func region(scale: CGFloat, offset: CGSize, in size: CGSize) -> CGRect {
        guard size.width > 0, size.height > 0 else { return CGRect(x: 0, y: 0, width: 1, height: 1) }
        let w = 1 / scale
        return CGRect(x: 0.5 - w / 2 - offset.width / (scale * size.width),
                      y: 0.5 - w / 2 - offset.height / (scale * size.height),
                      width: w, height: w)
    }
}
