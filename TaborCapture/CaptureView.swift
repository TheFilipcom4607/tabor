import AVKit
import CoreLocation
import LockedCameraCapture
import SwiftUI

/// CATCH's camera, cut down to what a locked phone allows: shots stack up, and REVEAL unlocks
/// the phone and opens the app, which deals them out as cards.
struct CaptureView: View {
    let session: LockedCameraCaptureSession
    private let camera = CameraModel.shared
    @State private var place = ShotPlace()
    @State private var thumbs: [UIImage] = []
    @State private var flash = false
    @State private var capturing = false
    @State private var opening = false
    @State private var shutterDown = false
    @State private var finderFrame: CGRect = .zero
    @State private var bracketGlobal: CGRect = .zero
    @State private var pinchStart: CGFloat?

    private static let yellow = Color(red: 1, green: 0.808, blue: 0)
    private static let red = Color(red: 0.894, green: 0, blue: 0.169)

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if camera.status == .running {
                CameraPreview(session: camera.session) { _, devicePoint in camera.focus(at: devicePoint) }
                    .simultaneousGesture(MagnifyGesture()
                        .onChanged { v in
                            let start = pinchStart ?? camera.zoom
                            if pinchStart == nil { pinchStart = start }
                            camera.setZoom(start * v.magnification, smooth: false)
                        }
                        .onEnded { _ in pinchStart = nil })
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { finderFrame = $0 }
                    .ignoresSafeArea()
            }
            Color.white.opacity(flash ? 0.85 : 0).ignoresSafeArea().allowsHitTesting(false)

            VStack(spacing: 0) {
                HStack {
                    mono("TABOR", size: 12, weight: .semibold, color: Self.yellow)
                    Spacer()
                    Image(systemName: "lock.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.7))
                }
                .padding(.top, 6)
                .padding(.horizontal, 20)

                mono(thumbs.isEmpty ? String(localized: "SHOOT AWAY, REVEAL THEM AFTER")
                     : String(localized: "UNLOCK TO REVEAL \(thumbs.count)"), size: 10.5, color: .white.opacity(0.85))
                    .padding(.vertical, 6)
                    .padding(.horizontal, 12)
                    .background(.ultraThinMaterial, in: Capsule())
                    .environment(\.colorScheme, .dark)
                    .padding(.top, 14)

                Spacer(minLength: 12)
                ViewfinderBrackets()
                    .aspectRatio(3 / 2, contentMode: .fit)
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { bracketGlobal = $0 }
                    .padding(.horizontal, 20)
                    .allowsHitTesting(false)
                Spacer(minLength: 12)

                if camera.zoomStops.count > 1 { zoomBar.padding(.bottom, 16) }
                HStack {
                    stack
                    Spacer()
                    shutter
                    Spacer()
                    torch
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 16)
            }
        }
        .preferredColorScheme(.dark)
        .task {
            await camera.start()
            place.start()
        }
        .onDisappear { camera.stop() }
        // The volume buttons and Camera Control fire the shutter, as in CATCH.
        .onCameraCaptureEvent(isEnabled: camera.status == .running) { event in
            switch event.phase {
            case .began: shutterDown = true
            case .ended:
                shutterDown = false
                Task { await shoot() }
            default: shutterDown = false
            }
        }
    }

    private var shutter: some View {
        Button {
            Task { await shoot() }
        } label: {
            ZStack {
                Circle().stroke(.white.opacity(0.92), lineWidth: 4).frame(width: 76, height: 76)
                Circle().fill(Self.red).frame(width: 60, height: 60).scaleEffect(shutterDown ? 0.86 : 1)
            }
            .animation(.spring(response: 0.25, dampingFraction: 0.5), value: shutterDown)
            .contentShape(Circle().inset(by: -12))
        }
        .buttonStyle(.plain)
        .disabled(camera.status != .running)
        .opacity(camera.status == .running ? 1 : 0.4)
        .accessibilityLabel("Catch")
    }

    /// The shots so far; tapping it unlocks the phone and opens the app to reveal them.
    private var stack: some View {
        Button(action: reveal) {
            VStack(spacing: 5) {
                ZStack {
                    let last = Array(thumbs.suffix(3).enumerated())
                    ForEach(last, id: \.offset) { i, img in
                        let back = Double(last.count - 1 - i)
                        Image(uiImage: img).resizable().scaledToFill()
                            .frame(width: 44, height: 44)
                            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(.white, lineWidth: 2))
                            .rotationEffect(.degrees(back * -7))
                            .offset(x: back * -3, y: back * -2)
                    }
                }
                .frame(width: 50, height: 50)
                .overlay(alignment: .topTrailing) {
                    mono("\(thumbs.count)", size: 11, weight: .bold, color: .black)
                        .padding(.vertical, 2)
                        .padding(.horizontal, 6)
                        .background(Self.yellow, in: Capsule())
                        .offset(x: 8, y: -6)
                }
                mono(String(localized: "REVEAL"), size: 9.5, weight: .semibold, color: .white.opacity(0.85))
            }
            .opacity(opening ? 0.5 : 1)
        }
        .buttonStyle(.plain)
        .opacity(thumbs.isEmpty ? 0 : 1)
        .disabled(thumbs.isEmpty || opening)
        .frame(width: 60)
        .accessibilityLabel("Reveal")
        .accessibilityValue("\(thumbs.count) shots")
    }

    private var torch: some View {
        Button { camera.toggleTorch() } label: {
            Image(systemName: camera.torchOn ? "flashlight.on.fill" : "flashlight.off.fill")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(camera.torchOn ? .black : .white.opacity(0.85))
                .frame(width: 50, height: 50)
                .background(camera.torchOn ? Self.yellow : .clear, in: Circle())
                .background(.ultraThinMaterial, in: Circle())
                .environment(\.colorScheme, .dark)
        }
        .buttonStyle(.plain)
        .opacity(camera.hasTorch ? 1 : 0.35)
        .disabled(!camera.hasTorch)
        .frame(width: 60)
        .accessibilityLabel("Torch")
    }

    /// As CATCH's: one stop per lens, the active one showing the exact zoom.
    private var zoomBar: some View {
        let stops = camera.zoomStops
        let active = stops.last { camera.zoom >= $0 - 0.05 } ?? stops.first!
        return HStack(spacing: 8) {
            ForEach(stops, id: \.self) { s in
                let on = s == active
                Button { camera.setZoom(s, smooth: true) } label: {
                    mono(on ? Self.zoomLabel(camera.zoom) + "×" : Self.zoomLabel(s), size: on ? 12 : 11,
                         weight: on ? .bold : .medium, color: on ? .black : .white.opacity(0.8))
                        .frame(minWidth: on ? 44 : 34, minHeight: on ? 34 : 30)
                        .padding(.horizontal, on ? 4 : 0)
                        .background(on ? Self.yellow : .clear, in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Zoom \(Self.zoomLabel(s)) times")
            }
        }
        .padding(3)
        .background(.ultraThinMaterial, in: Capsule())
        .environment(\.colorScheme, .dark)
        .animation(.snappy(duration: 0.2), value: active)
    }

    /// "0.5", "1", "2.4", "5"; "0,5" in Polish, like the system Camera app.
    private static func zoomLabel(_ z: CGFloat) -> String {
        let r = (z * 10).rounded() / 10
        return r == r.rounded() ? String(Int(r)) : Double(r).formatted(.number.precision(.fractionLength(1)))
    }

    private func mono(_ text: String, size: CGFloat, weight: Font.Weight = .medium, color: Color) -> some View {
        Text(text)
            .font(.system(size: size, weight: weight, design: .monospaced))
            .tracking(size * 0.12)
            .foregroundStyle(color)
    }

    // MARK: - Actions

    private func shoot() async {
        guard !capturing, camera.status == .running else { return }
        capturing = true
        defer { capturing = false }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        withAnimation(.easeOut(duration: 0.06)) { flash = true }
        let data = await camera.capture()
        withAnimation(.easeOut(duration: 0.35)) { flash = false }
        guard let data else { return }
        var shot = LockedShot(date: Date(), latitude: place.latest?.coordinate.latitude,
                              longitude: place.latest?.coordinate.longitude)
        // Held upright, the app crops to the brackets as CATCH does; sideways it keeps it all.
        if camera.captureAngle == 90, bracketGlobal.width > 0, finderFrame.width > 0 {
            let brackets = bracketGlobal.offsetBy(dx: -finderFrame.minX, dy: -finderFrame.minY)
            shot.crop = brackets.insetBy(dx: -brackets.width * 0.04, dy: -brackets.height * 0.04)
            shot.viewSize = finderFrame.size
        }
        do {
            try shot.save(data, in: session.sessionContentURL)
        } catch {
            return UINotificationFeedbackGenerator().notificationOccurred(.error)
        }
        let thumb = await Task.detached { UIImage(data: data)?.preparingThumbnail(of: CGSize(width: 120, height: 120)) }.value
        if let thumb { withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { thumbs.append(thumb) } }
    }

    /// Unlocks the phone (Face ID) and opens the app, which picks the shots up.
    private func reveal() {
        guard !opening else { return }
        opening = true
        Task {
            defer { opening = false }
            try? await session.openApplication(for: NSUserActivity(activityType: NSUserActivityTypeLockedCameraCapture))
        }
    }
}

/// Where the phone is, if TABOR may know: a locked phone can't ask, so this only listens.
@Observable
final class ShotPlace: NSObject, CLLocationManagerDelegate {
    private(set) var latest: CLLocation?
    @ObservationIgnored private let manager = CLLocationManager()

    func start() {
        manager.delegate = self
        let status = manager.authorizationStatus
        guard status == .authorizedWhenInUse || status == .authorizedAlways else { return }
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        latest = manager.location
        manager.startUpdatingLocation()
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        latest = locations.last
    }
}
