import AVKit
import CoreLocation
import LockedCameraCapture
import PhotosUI
import SwiftData
import SwiftUI

/// Everything the reveal screen needs about a fresh catch.
struct CatchDraft: Identifiable {
    let id = UUID()
    var photo: Data
    var number: Int?
    var modelId: String?
    var line: String?
    /// The line the live feed filled in; re-filled after a correction unless you changed it.
    var autoLine: String?
    /// Models that share the number when nothing could tell them apart: the reveal asks which
    /// one it is instead of guessing (#66). Picking one from here isn't a manual assignment.
    var choices: [VehicleModel] = []
    /// True when the user picked the model themselves — saved as a manual assignment.
    var modelPickedByHand = false
    /// Now for camera shots; the photo's own EXIF date for imports.
    var date = Date()
    /// Camera shots get saved to Photos; imports already live there.
    var fromCamera: Bool
    var geotag: Task<Geotag?, Never>?
    /// Die-cut sticker, generated in the background while the reveal plays.
    var sticker: Task<StickerCut?, Never>?
    /// Screen-sized copy of the photo; decoding the full-res shot on every frame of the
    /// reveal's animations would stutter on device.
    var preview: UIImage?
    /// Debug-mode record for this shot (nil when debug mode is off).
    var debug: DebugRecord?
    /// A coupled tram's other car, added as a catch of its own when this one is stuck.
    var partner: Int?
    /// Numbers to offer for the other car, likeliest first.
    var partnerSuggestions: [CoupledSet.Suggestion] = []
    /// Live vehicles around you at the shutter (fresh camera shots only).
    var nearby: [NearbyVehicle] = []
    /// Every number read in the photo, best first.
    var photoNumbers: Task<[Int], Never>?
    /// The whole read of the photo: where each number is written, for other vehicles in it.
    var photoRead: Task<TextReader.Report, Never>?
    /// Other vehicles read in the photo, offered on the reveal (`AlsoInShot`).
    var alsoInShot: [AlsoInShot.Vehicle] = []
    /// Numbers of those you added: each becomes a catch of its own.
    var alsoAdded: [Int] = []
    /// The camera's mode at the shutter: a works car's code is only asked for outside BUS.
    var mode: CatchMode = .auto
    /// The book just before this catch, which the reveal counts from.
    var book = BookBefore()
    /// An event wrap this vehicle may wear on the catch's date, and what the photo says.
    var wrapFinding: WrapFinding?
    /// The wrap it's caught in: shown by the photo, or confirmed on the reveal's chip.
    var wrap: Wrap?
}

/// What the reveal's check found about a wrap the caught vehicle may wear (`WrapCheck`).
struct WrapFinding: Equatable {
    let wrap: Wrap
    let verdict: WrapVerdict
}

/// The book as it stood at the shutter. The reveal counts from this rather than a live query:
/// once the catch is stuck in, a live count saw it twice (#2 of a vehicle seen once), and
/// recounting the whole book on every frame of the hold stuttered on a busy phone.
struct BookBefore {
    var stats = CollectionStats(sightings: [])
    /// Days in a row, counting this catch's day.
    var streak = 0
}

struct CatchView: View {
    /// The book's size, for the control tip: counted when CATCH appears, not a live query
    /// of every catch, which slowed the camera's start (#107).
    @State private var catches = 0
    @Query private var manual: [ManualAssignment]
    @AppStorage("saveToGallery") private var saveToGallery = true
    @AppStorage("geotag") private var geotag = true
    @AppStorage(DebugRecord.enabledKey) private var debugMode = false
    @AppStorage(CatchControlTip.seenKey) private var controlTipSeen = false
    /// Rapid fire: shots stack up and are dealt out as cards once you finish (#107).
    @AppStorage("rapidFire") private var rapid = false
    @State private var showControlHowTo = false

    private let camera = CameraModel.shared
    private let live = LiveFleetService.shared
    @State private var mode: CatchMode = .auto
    @State private var draft: CatchDraft?
    @State private var flash = false
    @State private var capturing = false
    /// The shot being read, held still in the brackets until the reveal opens: the live
    /// preview carrying on looked like the shutter hadn't fired.
    @State private var frozen: UIImage?
    @State private var pickerItem: PhotosPickerItem?
    /// Rapid fire picks several photos at once.
    @State private var pickerItems: [PhotosPickerItem] = []
    /// A finished burst being dealt out.
    @State private var cards: BurstCards?
    @State private var finishing = false
    @Environment(\.modelContext) private var context
    @State private var focusPoint: CGPoint?
    @State private var shutterDown = false
    /// Sticking a catch jumps to the Book tab while the reveal is still up; the cover's
    /// dismissal must not wake the camera behind a screen that's gone.
    @State private var visible = false
    /// The viewfinder and the brackets inside it (screen coordinates): shots are cropped to
    /// the brackets, so what you framed is what gets saved.
    @State private var finderFrame: CGRect = .zero
    @State private var bracketGlobal: CGRect = .zero
    /// Brief confirmation in the hint pill ("GEOTAG OFF").
    @State private var toast: String?
    @State private var toastTask: Task<Void, Never>?
    @Namespace private var modePill
    /// Zoom when the current pinch started.
    @State private var pinchStart: CGFloat?
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.wide) private var wide
    @Environment(\.tall) private var tall
    @Environment(Router.self) private var router

    var body: some View {
        ZStack {
            // Full bleed: the camera runs up under the Dynamic Island, like the Camera app.
            viewfinder
                .overlay {
                    if let p = focusPoint {
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Palette.yellow, lineWidth: 1.5)
                            .frame(width: 64, height: 64)
                            .position(p)
                            .transition(.scale(scale: 1.4).combined(with: .opacity))
                            .allowsHitTesting(false)
                    }
                }
                .clipped()
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { finderFrame = $0 }
                .ignoresSafeArea(edges: [.top, .horizontal])

            Color.black.opacity(frozen == nil ? 0 : 0.6)
                .ignoresSafeArea()
                .allowsHitTesting(false)

            LinearGradient(stops: [
                .init(color: Color(hex: 0x060709, opacity: 0.8), location: 0),
                .init(color: Color(hex: 0x060709, opacity: 0.05), location: 0.24),
                .init(color: .clear, location: 0.5),
                .init(color: Color(hex: 0x060709, opacity: 0.35), location: 0.72),
                .init(color: Color(hex: 0x060709, opacity: 0.88), location: 1),
            ], startPoint: .top, endPoint: .bottom)
            .ignoresSafeArea(edges: [.top, .horizontal])
            .allowsHitTesting(false)

            if wide {
                HStack(spacing: 0) {
                    VStack(spacing: 0) {
                        topBar
                            .padding(.top, 6)
                            .padding(.horizontal, 20)
                        hintPill
                            .padding(.top, 14)
                        brackets
                            .padding(.horizontal, 24)
                            .padding(.vertical, 14)
                            .frame(maxHeight: .infinity)
                            .allowsHitTesting(false)
                        controlTip
                            .frame(maxWidth: WideLayout.column, maxHeight: 78, alignment: .bottomLeading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 20)
                            .padding(.bottom, 14)
                    }
                    sideControls
                }
            } else if tall {
                // Upright or half folded: the brackets above the fold, the controls below it,
                // a thumb's reach across rather than out at the edges.
                FoldSplit {
                    VStack(spacing: 0) {
                        topBar
                            .padding(.top, 6)
                            .padding(.horizontal, 20)
                        hintPill
                            .padding(.top, 14)
                        brackets
                            .padding(.horizontal, 24)
                            .padding(.vertical, 14)
                            .frame(maxHeight: .infinity)
                            .allowsHitTesting(false)
                    }
                } bottom: {
                    VStack(spacing: 0) {
                        Spacer(minLength: 12)
                        controlTip
                            .frame(maxWidth: WideLayout.column, maxHeight: 78, alignment: .bottomLeading)
                            .padding(.horizontal, 20)
                        controls
                            .frame(maxWidth: 460)
                            .padding(.top, 16)
                        Spacer(minLength: 12)
                    }
                    .frame(maxWidth: .infinity)
                }
            } else {
                VStack(spacing: 0) {
                    topBar
                        .padding(.top, 6)
                        .padding(.horizontal, 20)

                    hintPill
                        .padding(.top, 14)

                    Spacer(minLength: 12)

                    brackets
                        .padding(.horizontal, 20)
                        .allowsHitTesting(false)

                    Spacer(minLength: 12)

                    // Fixed slot, so the brackets don't jump when the tip comes and goes.
                    controlTip
                        .frame(maxWidth: .infinity, maxHeight: 78, alignment: .bottomLeading)
                        .padding(.horizontal, 20)

                    controls
                        .padding(.top, 16)
                        .padding(.bottom, 16)
                }
            }

            Color.white.opacity(flash ? 0.85 : 0)
                .ignoresSafeArea(edges: [.top, .horizontal])
                .allowsHitTesting(false)
        }
        .background(Color.black.ignoresSafeArea())
        .onAppear {
            LaunchTiming.mark("catch")
            visible = true
            Haptics.shared.warmUp()
        }
        .task {
            camera.mode = mode
            live.start("camera")
            await camera.start()
            LaunchTiming.mark("running")
            catches = (try? context.fetchCount(FetchDescriptor<Sighting>())) ?? 0
            // Ask for location now, while spotting — never in the middle of a reveal.
            if geotag { LocationService.shared.requestPermission() }
        }
        .onDisappear {
            visible = false
            camera.stop()
            live.stop("camera")
        }
        // The volume buttons (and Camera Control) fire the shutter, as in the Camera app:
        // quicker than finding the button on screen with a bus pulling away. The system
        // only hands them over while the camera runs, so volume works as usual elsewhere.
        .onCameraCaptureEvent(isEnabled: draft == nil && camera.status == .running) { event in
            switch event.phase {
            case .began: shutterDown = true
            case .ended:
                shutterDown = false
                Task { await shoot() }
            default: shutterDown = false
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, visible { live.start("camera") }
            if phase == .active, draft == nil, visible {
                Task {
                    await camera.start()
                    LaunchTiming.mark("running")
                }
            }
            if phase == .background {
                camera.stop()
                live.stop("camera")
            }
        }
        .onChange(of: LocationService.shared.latest) { live.locationMoved() }
        // A photo shared from another app (Photos, Lightroom…): caught like an imported one.
        .onChange(of: router.sharedPhotos, initial: true) { takeShared() }
        // Shots from the Lock Screen camera: dealt out like a rapid fire burst.
        .onChange(of: router.lockedShots, initial: true) { takeLocked() }
        .onChange(of: pickerItem) { _, item in
            guard let item else { return }
            // The picker is still sliding away; a reveal presented under it comes out laid out
            // with no safe area (header under the status bar), for as long as it's up.
            let pickerGone = ContinuousClock.now + .milliseconds(600)
            Task {
                capturing = true
                defer { capturing = false }
                if let data = try? await item.loadTransferable(type: Data.self) {
                    await begin(with: data, fromCamera: false, presentAfter: pickerGone)
                } else {
                    Haptics.shared.nope()
                    DebugRecord.begin(source: "import", mode: mode)?.update { $0.error = "couldn't load the picked photo" }
                }
                pickerItem = nil
            }
        }
        .sheet(isPresented: $showControlHowTo) { CatchControlHowTo() }
        .onChange(of: pickerItems) { _, items in
            guard !items.isEmpty else { return }
            let pickerGone = ContinuousClock.now + .milliseconds(600)
            Task {
                finishing = true
                for item in items {
                    if let data = try? await item.loadTransferable(type: Data.self) { addImport(data) }
                }
                pickerItems = []
                try? await Task.sleep(until: pickerGone)
                finishing = false
                await finishBurst()
            }
        }
        .fullScreenCover(item: $cards, onDismiss: {
            if visible { Task { await camera.start() } }
            takeShared()
        }) { c in
            BurstRevealView(cards: c, reread: { old, cropped in await reread(old, cropped: cropped) })
                .windowControlsClearance()
        }
        .fullScreenCover(item: $draft, onDismiss: {
            frozen = nil
            if visible { Task { await camera.start() } }
            // Shared while this reveal was up.
            takeShared()
        }) { d in
            RevealView(draft: d, reread: { old, cropped in await reread(old, cropped: cropped) })
                .windowControlsClearance()
        }
    }

    // MARK: - Pieces

    @ViewBuilder private var frozenShot: some View {
        if let frozen {
            Image(uiImage: frozen)
                .resizable()
                .scaledToFill()
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay {
                    ProgressView()
                        .controlSize(.large)
                        .tint(.white)
                        .padding(18)
                        .background(.black.opacity(0.45), in: Circle())
                }
                .shadow(color: .black.opacity(0.5), radius: 16, y: 8)
                .transition(.scale(scale: 1.04).combined(with: .opacity))
                .accessibilityElement()
                .accessibilityLabel(Text("READING THE NUMBER…"))
        }
    }

    private var noCameraSymbol: String {
        switch camera.status {
        case .denied: "camera.badge.ellipsis"
        case .interrupted: "pause.circle"
        case .failed: "exclamationmark.triangle"
        default: "camera.metering.unknown"
        }
    }

    private var noCameraText: LocalizedStringKey {
        switch camera.status {
        case .denied: "CAMERA ACCESS IS OFF"
        case .interrupted: "CAMERA IN USE ELSEWHERE"
        case .failed: "THE CAMERA STOPPED"
        default: "NO CAMERA ON THIS DEVICE"
        }
    }

    @ViewBuilder private var viewfinder: some View {
        switch camera.status {
        case .running:
            CameraPreview(session: camera.session) { point, devicePoint in
                // Only inside the brackets: a hurried tap that just misses the shutter or a
                // zoom button used to refocus on whatever was behind it and spoil the shot.
                let brackets = bracketGlobal.offsetBy(dx: -finderFrame.minX, dy: -finderFrame.minY)
                guard brackets.contains(point) else { return }
                camera.focus(at: devicePoint)
                withAnimation(.spring(response: 0.3)) { focusPoint = point }
                Task {
                    try? await Task.sleep(for: .seconds(0.9))
                    withAnimation(.easeOut) { focusPoint = nil }
                }
            }
            .simultaneousGesture(MagnifyGesture()
                .onChanged { v in
                    let start = pinchStart ?? camera.zoom
                    if pinchStart == nil { pinchStart = start }
                    let before = camera.zoom
                    camera.setZoom(start * v.magnification, smooth: false)
                    // Click as the zoom crosses onto another lens.
                    if camera.zoomStops.contains(where: { (before - $0) * (camera.zoom - $0) < 0 }) { Haptics.shared.tick() }
                }
                .onEnded { _ in pinchStart = nil })
        case .idle:
            Color.black
        case .denied, .unavailable, .interrupted, .failed:
            ZStack {
                Color(hex: 0x0E1013)
                // Centred on the brackets: clear of the side column on a wide screen, above
                // the fold on a tall one.
                if tall {
                    FoldSplit { noCamera } bottom: { Color.clear }
                } else {
                    noCamera
                        .padding(.trailing, wide ? Self.sideColumn : 0)
                }
            }
        }
    }

    /// Why there's no camera, with the way round it.
    private var noCamera: some View {
        VStack(spacing: 14) {
            Image(systemName: noCameraSymbol)
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(Palette.faint)
            Mono(noCameraText, size: 11, color: Palette.sub)
            if camera.status == .denied {
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }
                .font(TaborFont.grotesk(14, 600))
                .tint(Palette.yellow)
            }
            if camera.status == .failed {
                Button("Try again") { Task { await camera.retry() } }
                    .font(TaborFont.grotesk(14, 600))
                    .tint(Palette.yellow)
            }
            PhotosPicker(selection: $pickerItem, matching: .images) {
                Mono("IMPORT A PHOTO INSTEAD", size: 11, weight: 600, color: Palette.bg)
                    .padding(.vertical, 9)
                    .padding(.horizontal, 14)
                    .background(Palette.yellow, in: Capsule())
            }
        }
    }

    @ViewBuilder private var controlTip: some View {
        if !controlTipSeen, catches >= CatchControlTip.afterCatches {
            CatchControlTipCard {
                showControlHowTo = true
                controlTipSeen = true
            } dismiss: {
                withAnimation(.snappy) { controlTipSeen = true }
            }
        }
    }

    private var topBar: some View {
        HStack(spacing: 8) {
            // Short, beside the toggle and the modes on a 390 pt phone in Polish.
            Mono(rapid ? "RAPID" : "SPOTTING", size: 12, spacing: 0.16, color: rapid ? Palette.yellow : .white.opacity(0.8))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .contentTransition(.opacity)
            if debugMode {
                Mono("DEBUG", size: 9.5, weight: 700, spacing: 0.1, color: .white)
                    .padding(.vertical, 3)
                    .padding(.horizontal, 6)
                    .background(Palette.red, in: RoundedRectangle(cornerRadius: 4))
            }
            Spacer()
            rapidToggle
            // One segmented control with a highlight that slides between modes.
            HStack(spacing: 0) {
                ForEach(CatchMode.allCases, id: \.self) { m in
                    let on = m == mode
                    Button {
                        guard !on else { return }
                        Haptics.shared.tick()
                        withAnimation(.spring(response: 0.32, dampingFraction: 0.78)) { mode = m }
                        camera.mode = m
                    } label: {
                        Mono(m.name, size: 11.5, weight: 600, spacing: 0.1,
                             color: on ? Palette.bg : .white.opacity(0.72))
                            .padding(.vertical, 7)
                            .padding(.horizontal, 12)
                            .background {
                                if on { Capsule().fill(Palette.yellow).matchedGeometryEffect(id: "mode", in: modePill) }
                            }
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
            .padding(3)
            .glass(Capsule())
            .fixedSize()
        }
    }

    private var hintPill: some View {
        let text = toast ?? hint
        return HStack(spacing: 7) {
            // A symbol effect pulses on the render server; a SwiftUI loop here re-rendered
            // the view every frame for as long as the camera was open.
            Image(systemName: "circle.fill")
                .font(.system(size: 5.5))
                .foregroundStyle(.white)
                .symbolEffect(.pulse)
            Text(text)
                .font(TaborFont.mono(10.5, 500))
                .em(0.12, size: 10.5)
                .foregroundStyle(.white.opacity(0.85))
                .contentTransition(.opacity)
        }
        .padding(.vertical, 6)
        .padding(.leading, 10)
        .padding(.trailing, 12)
        .glass(Capsule())
        .animation(.easeInOut(duration: 0.2), value: text)
    }

    // A 3:2 landscape frame, like a photo: the shot is cropped to it.
    private var brackets: some View {
        ViewfinderBrackets()
            .opacity(camera.status == .running ? 1 : 0)
            .overlay { frozenShot }
            .aspectRatio(3 / 2, contentMode: .fit)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { bracketGlobal = $0 }
    }

    private var controls: some View {
        VStack(spacing: 16) {
            HStack {
                geotagToggle
                Spacer()
                if showsZoom { zoomBar() }
                Spacer()
                galleryToggle
            }

            HStack {
                importOrStack
                Spacer()
                shutter
                Spacer()
                torch
            }
        }
        .padding(.horizontal, 28)
    }

    /// An opened foldable: the controls in a column down the side, like the Camera app held
    /// sideways, so the brackets get the whole width of the screen beside them.
    private var sideControls: some View {
        VStack(spacing: 0) {
            geotagToggle
            Spacer(minLength: 12)
            VStack(spacing: 18) {
                torch
                if showsZoom { zoomBar(vertical: true) }
            }
            shutter
                .padding(.vertical, 24)
            importOrStack
            Spacer(minLength: 12)
            galleryToggle
        }
        .padding(.vertical, 16)
        .frame(width: Self.sideColumn)
        .frame(maxHeight: .infinity)
        // Darker towards the edge, so the controls read over a bright street.
        .background {
            LinearGradient(colors: [Color(hex: 0x060709, opacity: 0), Color(hex: 0x060709, opacity: 0.7)],
                           startPoint: .leading, endPoint: .trailing)
                .ignoresSafeArea()
                .allowsHitTesting(false)
        }
    }

    private static let sideColumn: CGFloat = 116

    private var showsZoom: Bool { camera.status == .running && camera.zoomStops.count > 1 }

    private var geotagToggle: some View {
        settingToggle($geotag, name: String(localized: "GEOTAG"), on: "location.fill", off: "location.slash.fill")
    }

    private var galleryToggle: some View {
        settingToggle($saveToGallery, name: String(localized: "SAVE TO PHOTOS"), on: "photo.badge.arrow.down.fill", off: "photo.badge.arrow.down")
    }

    private var importButton: some View {
        Group {
            if rapid {
                PhotosPicker(selection: $pickerItems, maxSelectionCount: 30, selectionBehavior: .ordered, matching: .images) {
                    importIcon
                }
            } else {
                PhotosPicker(selection: $pickerItem, matching: .images) { importIcon }
            }
        }
        .buttonStyle(StickerPressStyle())
        .disabled(capturing || finishing)
        .accessibilityLabel(rapid ? "Import photos" : "Import a photo")
    }

    private var importIcon: some View {
        Image(systemName: rapid ? "photo.stack" : "photo.on.rectangle.angled")
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(.white.opacity(0.85))
            .contentTransition(.symbolEffect(.replace))
            .frame(width: 50, height: 50)
            .glass(Circle())
    }

    /// The import button, or once rapid fire has shots waiting, the stack of them: tap it
    /// to finish and deal them out.
    @ViewBuilder private var importOrStack: some View {
        if router.burst.isEmpty { importButton } else { burstStack }
    }

    private var burstStack: some View {
        let burst = router.burst
        let thumbs = Array(burst.shots.suffix(3).enumerated())
        return Button {
            Task { await finishBurst() }
        } label: {
            VStack(spacing: 5) {
                ZStack {
                    ForEach(thumbs, id: \.element.id) { i, shot in
                        let back = Double(thumbs.count - 1 - i)
                        Group {
                            if let img = shot.thumb {
                                Image(uiImage: img).resizable().scaledToFill()
                            } else {
                                Color(hex: 0x1A1D22)
                            }
                        }
                        .frame(width: 44, height: 44)
                        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(.white, lineWidth: 2))
                        .rotationEffect(.degrees(back * -7))
                        .offset(x: back * -3, y: back * -2)
                    }
                }
                .frame(width: 50, height: 50)
                .overlay(alignment: .topTrailing) {
                    Mono("\(burst.count)" as String, size: 11, weight: 700, spacing: 0, color: Palette.bg)
                        .padding(.vertical, 2)
                        .padding(.horizontal, 6)
                        .background(Palette.yellow, in: Capsule())
                        .offset(x: 8, y: -6)
                        .contentTransition(.numericText())
                }
                Mono("FINISH", size: 9.5, weight: 600, spacing: 0.12, color: .white.opacity(0.85))
            }
            .opacity(finishing ? 0.5 : 1)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: burst.count)
        }
        .buttonStyle(StickerPressStyle())
        .disabled(finishing)
        .accessibilityLabel("Finish")
        .accessibilityValue("\(burst.count) shots")
    }

    private var rapidToggle: some View {
        Button {
            Haptics.shared.tick()
            withAnimation(.snappy) { rapid.toggle() }
            let name = String(localized: "RAPID FIRE")
            showToast(rapid ? String(localized: "\(name) ON") : String(localized: "\(name) OFF"))
        } label: {
            Image(systemName: "square.stack.3d.down.right.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(rapid ? Palette.bg : .white.opacity(0.72))
                .frame(width: 36, height: 36)
                .background(Palette.yellow.opacity(rapid ? 1 : 0), in: Circle())
                .glass(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Rapid fire")
        .accessibilityValue(rapid ? "On" : "Off")
    }

    private var shutter: some View {
        Button {
            Task { await shoot() }
        } label: {
            ZStack {
                Circle().stroke(.white.opacity(0.92), lineWidth: 4)
                    .frame(width: 76, height: 76)
                Circle().fill(Palette.red)
                    .frame(width: 60, height: 60)
                    .scaleEffect(shutterDown ? 0.86 : 1)
            }
            .animation(.spring(response: 0.25, dampingFraction: 0.5), value: shutterDown)
            // Hit in a hurry without looking: a 100 pt target around the 76 pt ring.
            .contentShape(Circle().inset(by: -12))
        }
        .buttonStyle(ShutterStyle(pressed: $shutterDown))
        .disabled(capturing || camera.status != .running)
        .opacity(camera.status == .running ? 1 : 0.4)
        .accessibilityLabel("Catch")
    }

    private var torch: some View {
        Button {
            Haptics.shared.tick()
            camera.toggleTorch()
        } label: {
            Image(systemName: camera.torchOn ? "flashlight.on.fill" : "flashlight.off.fill")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(camera.torchOn ? Palette.bg : .white.opacity(0.85))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 50, height: 50)
                .background(Palette.yellow.opacity(camera.torchOn ? 1 : 0), in: Circle())
                .glass(Circle())
        }
        .buttonStyle(.plain)
        .opacity(camera.hasTorch ? 1 : 0.35)
        .disabled(!camera.hasTorch)
        .accessibilityLabel("Torch")
    }

    /// One button per lens, like the Camera app: the active one shows the exact zoom.
    private func zoomBar(vertical: Bool = false) -> some View {
        let stops = camera.zoomStops
        let active = stops.last { camera.zoom >= $0 - 0.05 } ?? stops.first!
        let layout = vertical ? AnyLayout(VStackLayout(spacing: 8)) : AnyLayout(HStackLayout(spacing: 8))
        return layout {
            ForEach(stops, id: \.self) { s in
                let on = s == active
                Button {
                    guard abs(camera.zoom - s) > 0.01 else { return }
                    Haptics.shared.tick()
                    camera.setZoom(s, smooth: true)
                } label: {
                    Text(on ? Self.zoomLabel(camera.zoom) + "×" : Self.zoomLabel(s))
                        .font(TaborFont.mono(on ? 12 : 11, on ? 700 : 500))
                        .foregroundStyle(on ? Palette.bg : .white.opacity(0.8))
                        .frame(minWidth: on ? 44 : 34, minHeight: on ? 34 : 30)
                        .padding(.horizontal, on ? 4 : 0)
                        .background(on ? Palette.yellow : Color.clear, in: Capsule())
                        .contentTransition(.numericText())
                        // Taller targets than they look; less below, where the shutter's is.
                        .hitArea(top: 12, bottom: 6, sides: 4)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Zoom \(Self.zoomLabel(s)) times")
            }
        }
        .padding(3)
        .glass(Capsule())
        .animation(.snappy(duration: 0.2), value: active)
        .opacity(camera.controlsFullscreen ? 0 : 1)
        .animation(.easeOut(duration: 0.2), value: camera.controlsFullscreen)
    }

    /// "0.5", "1", "2.4", "5".
    static func zoomLabel(_ z: CGFloat) -> String {
        let r = (z * 10).rounded() / 10
        // "0.5", or "0,5" in Polish, like the system Camera app.
        return r == r.rounded() ? String(Int(r)) : Double(r).formatted(FloatingPointFormatStyle<Double>(locale: .app).precision(.fractionLength(1)))
    }

    /// Icon toggle for a capture setting; the hint pill confirms which way it went.
    private func settingToggle(_ value: Binding<Bool>, name: String, on: String, off: String) -> some View {
        let isOn = value.wrappedValue
        return Button {
            Haptics.shared.tick()
            value.wrappedValue.toggle()
            showToast(value.wrappedValue ? String(localized: "\(name) ON") : String(localized: "\(name) OFF"))
        } label: {
            Image(systemName: isOn ? on : off)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isOn ? Palette.green : .white.opacity(0.5))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 36, height: 36)
                .glass(Circle())
                .overlay(Circle().stroke(Palette.green.opacity(isOn ? 0.35 : 0)))
                .frame(width: 50)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(name.capitalized)
        .accessibilityValue(isOn ? "On" : "Off")
    }

    private func showToast(_ text: String) {
        toastTask?.cancel()
        toast = text
        toastTask = Task {
            try? await Task.sleep(for: .seconds(1.4))
            guard !Task.isCancelled else { return }
            toast = nil
        }
    }

    private var hint: String {
        // The full-res read (and tile pass) can take a second or two on device.
        if finishing, router.burst.reading > 0 { return String(localized: "READING \(router.burst.reading) MORE…") }
        if capturing, !rapid { return String(localized: "READING THE NUMBER…") }
        switch camera.status {
        case .running: break
        case .idle: return String(localized: "WAKING THE CAMERA")
        case .interrupted: return String(localized: "WAITING FOR THE CAMERA")
        default: return String(localized: "IMPORT A SHOT TO CATCH IT")
        }
        if rapid {
            return router.burst.isEmpty ? String(localized: "SHOOT AWAY, REVEAL THEM AFTER") : String(localized: "TAP FINISH TO REVEAL THEM")
        }
        return String(localized: "GET THE WHOLE VEHICLE IN FRAME")
    }

    // MARK: - Actions

    private func shoot() async {
        guard !capturing else { return }
        capturing = true
        defer { capturing = false }
        // The feed polls slowly on this screen; top it up for the next shot if it's aging.
        if live.fresh(maxAge: 20) == nil { Task { await live.refresh() } }
        Haptics.shared.shutter()
        withAnimation(.easeOut(duration: 0.06)) { flash = true }
        let data = await camera.capture()
        withAnimation(.easeOut(duration: 0.35)) { flash = false }
        let record = DebugRecord.begin(source: "camera", mode: mode)
        let angle = Double(camera.captureAngle), torch = camera.torchOn, pressure = camera.pressure
        record?.update {
            $0.captureAngle = angle
            $0.torch = torch
            $0.pressure = pressure
        }
        guard var data else {
            let why = camera.lastCaptureError ?? "unknown"
            record?.update { $0.error = "capture failed: \(why)" }
            Haptics.shared.nope()
            return
        }
        // Held upright: keep only what's inside the brackets (plus a little breathing room).
        // Held sideways the whole landscape frame is already what you meant.
        if angle == 90, bracketGlobal.width > 0, finderFrame.width > 0 {
            let size = finderFrame.size
            let brackets = bracketGlobal.offsetBy(dx: -finderFrame.minX, dy: -finderFrame.minY)
            let frame = brackets.insetBy(dx: -brackets.width * 0.04, dy: -brackets.height * 0.04)
            let full = data
            if let cropped = await Task.detached(priority: .userInitiated, operation: {
                PhotoStore.crop(full, viewSize: size, frame: frame)
            }).value {
                data = cropped
                record?.attach(original: full)
                record?.update { $0.crop = "brackets \(frame.integral) in \(size.width)×\(size.height) viewfinder" }
            }
        }
        guard rapid else { return await begin(with: data, fromCamera: true, record: record) }
        // Rapid fire: into the stack, read in the background, and the camera carries on.
        let nearby = live.fresh() != nil ? live.nearby : []
        router.burst.add(data, fromCamera: true, date: Date(), mode: mode, nearby: nearby,
                         geotag: geotag ? Task { await LocationService.shared.geotag() } : nil,
                         record: record, manual: manual.map)
    }

    /// A photo picked from the library in rapid fire: its own date and place, no feed.
    private func addImport(_ data: Data) {
        let meta = PhotoStore.metadata(data)
        let tag: Task<Geotag?, Never>? = if geotag, let lat = meta.latitude, let lon = meta.longitude {
            Task { await LocationService.shared.geotag(CLLocation(latitude: lat, longitude: lon)) }
        } else { nil }
        router.burst.add(data, fromCamera: false, date: meta.date ?? Date(), mode: mode, nearby: [], geotag: tag,
                         record: DebugRecord.begin(source: "import", mode: mode), manual: manual.map)
    }

    /// The Lock Screen camera's shots, read and dealt out as cards. Its folders are only
    /// cleared once the cards are ready, so a crash before then leaves the shots for next time.
    private func takeLocked() {
        let folders = router.lockedFolders
        guard !folders.isEmpty, draft == nil, cards == nil, !finishing else { return }
        Task {
            finishing = true
            for folder in folders {
                for (photo, shot) in LockedShot.all(in: folder) { await addLocked(photo, shot) }
            }
            finishing = false
            await finishBurst()
            for folder in folders { try? await LockedCameraCaptureManager.shared.invalidateSessionContent(at: folder) }
        }
    }

    private func addLocked(_ photo: Data, _ shot: LockedShot) async {
        var data = photo
        let record = DebugRecord.begin(source: "locked", mode: .auto)
        if let crop = shot.crop, let size = shot.viewSize, let cropped = await Task.detached(priority: .userInitiated, operation: {
            PhotoStore.crop(photo, viewSize: size, frame: crop)
        }).value {
            data = cropped
            record?.attach(original: photo)
            record?.update { $0.crop = "brackets \(crop.integral) in \(size.width)×\(size.height) viewfinder" }
        }
        if let angle = shot.angle { record?.update { $0.captureAngle = angle } }
        let age = Date().timeIntervalSince(shot.date)
        // Taken a moment ago: you're still about where the shot was, and so are the vehicles.
        let nearby = age < 180 && live.fresh() != nil ? live.nearby : []
        let tag: Task<Geotag?, Never>? = if !geotag {
            nil
        } else if let lat = shot.latitude, let lon = shot.longitude {
            Task { await LocationService.shared.geotag(CLLocation(latitude: lat, longitude: lon)) }
        } else if age < 600 {
            Task { await LocationService.shared.geotag() }
        } else { nil }
        router.burst.add(data, fromCamera: true, date: shot.date, mode: .auto, nearby: nearby, geotag: tag,
                         record: record, manual: manual.map)
    }

    /// Rapid fire's shots, once they're all read, dealt out as cards.
    private func finishBurst() async {
        guard !finishing, !router.burst.isEmpty else { return }
        finishing = true
        defer { finishing = false }
        let book = (try? context.fetch(FetchDescriptor<Sighting>())) ?? []
        let drafts = await router.burst.finish(book: book)
        guard !drafts.isEmpty else { return }
        camera.stop()
        cards = BurstCards(drafts: drafts)
    }

    /// The photo waiting in the share inbox, if any and if nothing else is being caught.
    private func takeShared() {
        guard draft == nil, !capturing, let data = ShareInbox.take() else { return }
        Task {
            capturing = true
            defer { capturing = false }
            await begin(with: data, fromCamera: false, record: DebugRecord.begin(source: "share", mode: mode))
        }
    }

    private func begin(with data: Data, fromCamera: Bool, record: DebugRecord? = nil,
                       presentAfter: ContinuousClock.Instant? = nil) async {
        let preview = await CatchReader.preview(data)
        withAnimation(.easeOut(duration: 0.2)) { frozen = preview }
        let record = record ?? DebugRecord.begin(source: fromCamera ? "camera" : "import", mode: mode)
        // An imported photo could be from anywhere, any day: only fresh shots use the feed.
        let nearby = fromCamera && self.live.fresh() != nil ? self.live.nearby : []
        var d = await CatchReader.read(data, fromCamera: fromCamera, record: record, nearby: nearby, mode: mode, manual: manual.map)
        d.preview = preview
        if fromCamera {
            if geotag { d.geotag = Task { await LocationService.shared.geotag() } }
        } else {
            let meta = PhotoStore.metadata(data)
            if let date = meta.date { d.date = date }
            if geotag, let lat = meta.latitude, let lon = meta.longitude {
                d.geotag = Task { await LocationService.shared.geotag(CLLocation(latitude: lat, longitude: lon)) }
            }
        }
        let book = (try? context.fetch(FetchDescriptor<Sighting>())) ?? []
        d.book = BookBefore(stats: book.stats, streak: Streak.days(book.map(\.date) + [d.date]))
        camera.stop()
        if let presentAfter { try? await Task.sleep(until: presentAfter) }
        draft = d
    }

    /// The same catch, read again from a crop of its photo (#94): where and when it was caught,
    /// and the book it counts from, stay as they were.
    private func reread(_ old: CatchDraft, cropped data: Data) async -> CatchDraft {
        var d = await CatchReader.read(data, fromCamera: old.fromCamera, record: old.debug, nearby: old.nearby, mode: old.mode,
                                       manual: manual.map)
        d.preview = await CatchReader.preview(data)
        d.date = old.date
        d.geotag = old.geotag
        d.book = old.book
        d.line = d.line ?? old.line
        return d
    }
}

extension View {
    /// Grows the tappable area past what's drawn, without moving anything.
    func hitArea(top: CGFloat, bottom: CGFloat, sides: CGFloat, trailing: CGFloat? = nil) -> some View {
        let trailing = trailing ?? sides
        return padding(EdgeInsets(top: top, leading: sides, bottom: bottom, trailing: trailing))
            .contentShape(Rectangle())
            .padding(EdgeInsets(top: -top, leading: -sides, bottom: -bottom, trailing: -trailing))
    }

    /// Frosted dark glass for controls floating over the live camera.
    func glass<S: Shape>(_ shape: S) -> some View {
        background(.ultraThinMaterial, in: shape)
            .background(Color(hex: 0x0A0C0E, opacity: 0.35), in: shape)
            .overlay(shape.stroke(Color.white.opacity(0.1), lineWidth: 1))
            .environment(\.colorScheme, .dark)
    }
}

/// Reports press state so the shutter can squish the moment a finger lands.
private struct ShutterStyle: ButtonStyle {
    @Binding var pressed: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .onChange(of: configuration.isPressed) { _, down in
                pressed = down
                if down { Haptics.shared.warmUp() }
            }
    }
}
