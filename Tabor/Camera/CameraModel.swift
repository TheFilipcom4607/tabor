import AVFoundation
#if CAPTURE_EXTENSION
import CoreMotion
#endif
import os
import SwiftUI

/// Owns the capture session and takes stills. Numbers are read off the still, not the live
/// preview: reading frames all the time cost battery and heat for a banner nobody needed.
/// One shared instance, so hopping between tabs reuses the configured session.
@Observable
final class CameraModel: NSObject, @unchecked Sendable {
    static let shared = CameraModel()

    /// `unavailable` is no camera at all; `interrupted` is another app or a call holding it;
    /// `failed` is a session that died and wouldn't come back.
    enum Status { case idle, running, denied, unavailable, interrupted, failed }

    private(set) var status: Status = .idle
    private(set) var torchOn = false
    /// Zoom as the Camera app shows it: 1 = main lens, 0.5 = ultra-wide, 5 = telephoto.
    private(set) var zoom: CGFloat = 1
    /// One stop per physical lens (plus 2× on phones whose main sensor crops cleanly),
    /// e.g. [0.5, 1, 2, 5] on an iPhone 16 Pro.
    private(set) var zoomStops: [CGFloat] = [1]
    private(set) var zoomRange: ClosedRange<CGFloat> = 1...1
    /// Device zoom factor that the UI calls 1× (the main lens on a virtual device).
    @ObservationIgnored private var zoomScale: CGFloat = 1
    /// Camera Control's zoom slider is showing its full overlay; the on-screen zoom
    /// buttons step aside, as in the Camera app.
    private(set) var controlsFullscreen = false
    @ObservationIgnored private var zoomSlider: AVCaptureSlider?
    /// The values Camera Control's zoom slider clicks through.
    @ObservationIgnored private var zoomDetents: [Float] = []

    #if !CAPTURE_EXTENSION
    /// For camera trouble's debug records. Guarded by `lock`.
    var mode: CatchMode {
        get { lock.withLock { _mode } }
        set { lock.withLock { _mode = newValue } }
    }
    @ObservationIgnored private var _mode: CatchMode = .auto
    #endif

    @ObservationIgnored let session = AVCaptureSession()
    @ObservationIgnored private let photoOutput = AVCapturePhotoOutput()
    @ObservationIgnored private let sessionQueue = DispatchQueue(label: "tabor.camera.session")
    @ObservationIgnored private let lock = NSLock()
    @ObservationIgnored private var configured = false
    /// CATCH is on screen and wants the camera; recovery only restarts it then. Guarded by `lock`.
    @ObservationIgnored private var _wantsRunning = false
    private var wantsRunning: Bool { lock.withLock { _wantsRunning } }
    @ObservationIgnored private let log = Logger(subsystem: "com.filipmanikowski.tabor", category: "camera")
    @ObservationIgnored private var device: AVCaptureDevice?
    @ObservationIgnored private var photoContinuation: CheckedContinuation<Data?, Never>?
    /// Tracks how the phone is held so stills stay upright even though the UI is portrait-only.
    @ObservationIgnored private var rotation: AVCaptureDevice.RotationCoordinator?
    @ObservationIgnored private var rotationObservation: NSKeyValueObservation?
    @ObservationIgnored private var _captureAngle: CGFloat = 90
    #if CAPTURE_EXTENSION
    @ObservationIgnored private let motion = CMMotionManager()
    #endif
    @ObservationIgnored private var pressureObservation: NSKeyValueObservation?
    /// The phone is running hot: fewer frames. Guarded by `lock`.
    @ObservationIgnored private var _hot = false
    @ObservationIgnored private var _pressure = "nominal"
    @ObservationIgnored private var _lastCaptureError: String?

    /// Horizon-level rotation for captured frames, in degrees. Guarded by `lock`.
    var captureAngle: CGFloat { lock.withLock { _captureAngle } }
    /// Why the last `capture()` came back empty, if it did.
    var lastCaptureError: String? { lock.withLock { _lastCaptureError } }
    /// The camera's heat level (for debug mode).
    var pressure: String { lock.withLock { _pressure } }

    // MARK: - Lifecycle

    override init() {
        super.init()
        observeSession()
    }

    @MainActor
    func start() async {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .notDetermined:
            guard await AVCaptureDevice.requestAccess(for: .video) else { status = .denied; return }
        case .authorized: break
        default: status = .denied; return
        }
        lock.withLock { _wantsRunning = true }
        status = await withCheckedContinuation { cont in
            sessionQueue.async { cont.resume(returning: self.startSession()) }
        }
    }

    /// Builds the session ahead of CATCH asking for it, at launch, so the camera only has to
    /// start (#107). Building it doesn't turn the camera on, so no indicator shows meanwhile.
    func prepare(then done: @escaping @Sendable () -> Void = {}) {
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else { return }
        sessionQueue.async {
            _ = self.configure()
            done()
        }
    }

    func stop() {
        lock.withLock { _wantsRunning = false }
        sessionQueue.async { if self.session.isRunning { self.session.stopRunning() } }
        Task { @MainActor in self.torchOn = false }
    }

    /// Try again after the camera stopped: build the session from scratch.
    @MainActor
    func retry() async {
        status = .idle
        await withCheckedContinuation { cont in
            sessionQueue.async {
                self.tearDown()
                cont.resume()
            }
        }
        await start()
    }

    /// Called on sessionQueue.
    private func startSession() -> Status {
        guard configure() else { return Self.hasCamera ? .failed : .unavailable }
        if !session.isRunning { session.startRunning() }
        if session.isRunning {
            sessionQueue.async { self.addLenses() }
            return .running
        }
        // A call or another app has it; it comes back when that ends.
        if session.isInterrupted { return .interrupted }
        // Configured before and won't start: a session left dead by an error nobody saw.
        // Rebuild it once before giving up.
        record("session wouldn't start; rebuilding it")
        tearDown()
        guard configure() else { return .failed }
        session.startRunning()
        return session.isRunning ? .running : .failed
    }

    private static var hasCamera: Bool {
        AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) != nil
    }

    /// Called on sessionQueue. Back to nothing, so `configure()` builds it all again.
    private func tearDown() {
        if session.isRunning { session.stopRunning() }
        session.beginConfiguration()
        session.inputs.forEach(session.removeInput)
        session.outputs.forEach(session.removeOutput)
        session.controls.forEach(session.removeControl)
        session.commitConfiguration()
        zoomSlider = nil
        zoomDetents = []
        rotationObservation = nil
        rotation = nil
        pressureObservation = nil
        device = nil
        configured = false
        // A shot in flight won't finish now.
        photoContinuation?.resume(returning: nil)
        photoContinuation = nil
        Task { @MainActor in self.torchOn = false }
    }

    #if CAPTURE_EXTENSION
    /// On the Lock Screen the rotation coordinator always said 0° (on its side), however the
    /// phone was held (phone test, 2026-11-01): shots came out sideways and uncropped. Which
    /// way is down comes from the accelerometer instead, which needs no permission.
    private func followGravity() {
        guard motion.isAccelerometerAvailable, !motion.isAccelerometerActive else { return }
        motion.accelerometerUpdateInterval = 0.2
        motion.startAccelerometerUpdates(to: OperationQueue()) { [weak self] data, _ in
            guard let self, let a = data?.acceleration else { return }
            // Lying flat says nothing about which way up: keep the last angle.
            guard max(abs(a.x), abs(a.y)) > 0.35 else { return }
            // The back camera's angles: 90 upright, 0 with the top to the left, 180 to the
            // right, 270 upside down.
            let angle: CGFloat = abs(a.y) >= abs(a.x) ? (a.y < 0 ? 90 : 270) : (a.x > 0 ? 0 : 180)
            lock.withLock { self._captureAngle = angle }
        }
    }
    #endif

    // MARK: - Recovery

    /// Without these, a session that hit an error stayed stopped until the phone restarted:
    /// nothing started it again, and `configured` kept `start()` from rebuilding it.
    private func observeSession() {
        let center = NotificationCenter.default
        center.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil) { [weak self] note in
            let error = note.userInfo?[AVCaptureSessionErrorKey] as? AVError
            self?.sessionQueue.async { self?.recover(from: error) }
        }
        center.addObserver(forName: AVCaptureSession.wasInterruptedNotification, object: session, queue: nil) { [weak self] note in
            guard let self else { return }
            let reason = (note.userInfo?[AVCaptureSessionInterruptionReasonKey] as? Int)
                .flatMap(AVCaptureSession.InterruptionReason.init(rawValue:))
            // Going to the background interrupts it too, after CATCH has let go: not news.
            guard wantsRunning else { return }
            record("interrupted: \(reason.map(Self.describe) ?? "unknown reason")")
            Task { @MainActor in self.status = .interrupted }
        }
        center.addObserver(forName: AVCaptureSession.interruptionEndedNotification, object: session, queue: nil) { [weak self] _ in
            guard let self, wantsRunning else { return }
            record("interruption ended")
            sessionQueue.async {
                guard self.wantsRunning else { return }
                let status = self.session.isRunning ? .running : self.startSession()
                Task { @MainActor in self.status = status }
            }
        }
    }

    /// Called on sessionQueue.
    private func recover(from error: AVError?) {
        record("runtime error \(error.map { "\($0.code.rawValue): \($0.localizedDescription)" } ?? "unknown")")
        // The media server restarted under us: the session may just need starting again.
        if error?.code == .mediaServicesWereReset, wantsRunning {
            session.startRunning()
            if session.isRunning {
                Task { @MainActor in self.status = .running }
                return
            }
        }
        tearDown()
        guard wantsRunning else { return }
        let status = startSession()
        Task { @MainActor in self.status = status }
    }

    /// Camera trouble goes to the system log, and, in debug mode, gets its own folder, so a
    /// tester's ZIP has it next time the camera dies.
    private func record(_ what: String) {
        log.error("\(what, privacy: .public)")
        // The Lock Screen camera has no debug mode: it can't see the app's settings.
        #if !CAPTURE_EXTENSION
        DebugRecord.begin(source: "camera", mode: mode)?.update { $0.error = what }
        #endif
    }

    private static func describe(_ reason: AVCaptureSession.InterruptionReason) -> String {
        switch reason {
        case .videoDeviceNotAvailableInBackground: "in background"
        case .audioDeviceInUseByAnotherClient: "audio in use elsewhere"
        case .videoDeviceInUseByAnotherClient: "camera in use elsewhere"
        case .videoDeviceNotAvailableWithMultipleForegroundApps: "several apps in the foreground"
        case .videoDeviceNotAvailableDueToSystemPressure: "system pressure"
        case .sensitiveContentMitigationActivated: "sensitive content"
        @unknown default: "reason \(reason.rawValue)"
        }
    }

    /// Called on sessionQueue.
    private func configure() -> Bool {
        if configured { return true }
        // The main lens on its own: it starts in about half the time the multi-lens camera
        // takes (0.6 s against 1.05 s on an iPhone 16 Pro, #107), and a bus doesn't wait.
        // `addLenses` brings in the others once it's running.
        guard let cam = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: cam)
        else { return false }

        session.beginConfiguration()
        session.sessionPreset = .photo
        guard session.canAddInput(input), session.canAddOutput(photoOutput) else {
            session.commitConfiguration()
            return false
        }
        session.addInput(input)
        session.addOutput(photoOutput)
        // Every shot asks for .balanced: a .quality pipeline only made the session slower to start.
        photoOutput.maxPhotoQualityPrioritization = .balanced
        session.commitConfiguration()
        use(cam)
        configured = true
        return true
    }

    /// Called on sessionQueue, once the main lens is running: swaps in the multi-lens camera,
    /// so 0.5× and 5× are real lenses. A shot asked for meanwhile waits for the swap.
    private func addLenses() {
        guard configured, session.isRunning, device?.isVirtualDevice == false,
              let cam = AVCaptureDevice.default(.builtInTripleCamera, for: .video, position: .back)
                ?? AVCaptureDevice.default(.builtInDualWideCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: cam),
              let old = session.inputs.first
        else { return }
        session.beginConfiguration()
        session.removeInput(old)
        guard session.canAddInput(input) else {
            session.addInput(old)
            session.commitConfiguration()
            return
        }
        session.addInput(input)
        session.commitConfiguration()
        // So the new camera's first heat reading is applied, not taken for no change.
        lock.withLock { _hot = false }
        use(cam)
        // The main lens's torch went with it.
        Task { @MainActor in self.torchOn = false }
    }

    /// Called on sessionQueue. Everything that follows the camera in use: zoom stops, focus,
    /// Camera Control's slider, which way up the phone is, and how hot it's running.
    private func use(_ cam: AVCaptureDevice) {
        // A virtual (multi-lens) device hands off between the physical cameras by itself as
        // the zoom factor crosses each switch-over point, so 0.5× really is the ultra-wide
        // and 5× the telephoto — not a digital crop of the main lens.
        let switchOvers = cam.virtualDeviceSwitchOverVideoZoomFactors.map { CGFloat(truncating: $0) }
        let hasUltraWide = cam.constituentDevices.contains { $0.deviceType == .builtInUltraWideCamera }
        let scale = hasUltraWide ? (switchOvers.first ?? 1) : 1
        var stops = Set(([1] + switchOvers).map { ($0 / scale * 10).rounded() / 10 })
        if hasUltraWide { stops.insert(0.5) }
        // The 48MP main sensor gives a clean 2× crop (like the Camera app); add it when the
        // next lens is further than that.
        if let tele = stops.filter({ $0 > 1 }).min(), tele > 2.5 { stops.insert(2) } else if stops.count == 1 { stops.insert(2) }
        let maxUI = min(cam.maxAvailableVideoZoomFactor / scale, max(stops.max() ?? 1, 2) * 3)
        let minUI = cam.minAvailableVideoZoomFactor / scale
        // A bus pulling away is gone before a pinch gets there (#47): one tap to twice the
        // longest lens (10× on a 5× telephoto), where its number is big enough to read.
        if let longest = stops.max() { stops.insert(min(longest * 2, maxUI)) }

        // Buses are big and far: continuous focus, and start on the main lens (1×).
        try? cam.lockForConfiguration()
        if cam.isFocusModeSupported(.continuousAutoFocus) { cam.focusMode = .continuousAutoFocus }
        if cam.isSmoothAutoFocusSupported { cam.isSmoothAutoFocusEnabled = true }
        cam.videoZoomFactor = max(cam.minAvailableVideoZoomFactor, min(scale, cam.maxAvailableVideoZoomFactor))
        cam.unlockForConfiguration()
        zoomScale = scale
        let sortedStops = stops.filter { $0 >= minUI - 0.01 && $0 <= maxUI + 0.01 }.sorted()
        Task { @MainActor in
            self.zoomStops = sortedStops
            self.zoomRange = minUI...max(minUI, maxUI)
            self.zoom = 1
        }
        addZoomControl(range: minUI...max(minUI, maxUI), stops: sortedStops)

        #if CAPTURE_EXTENSION
        followGravity()
        #else
        let coordinator = AVCaptureDevice.RotationCoordinator(device: cam, previewLayer: nil)
        rotationObservation = coordinator.observe(\.videoRotationAngleForHorizonLevelCapture, options: [.initial, .new]) {
            [weak self] c, _ in
            guard let self else { return }
            let angle = c.videoRotationAngleForHorizonLevelCapture
            lock.withLock { self._captureAngle = angle }
        }
        rotation = coordinator
        #endif

        // Apple's advice for a hot camera is fewer frames; the viewfinder stays usable at 15.
        pressureObservation = cam.observe(\.systemPressureState, options: [.initial, .new]) { [weak self] d, _ in
            let level = d.systemPressureState.level
            self?.sessionQueue.async { self?.throttle(level) }
        }

        device = cam
    }

    /// Called on sessionQueue.
    private func throttle(_ level: AVCaptureDevice.SystemPressureState.Level) {
        let hot = level == .serious || level == .critical || level == .shutdown
        let changed = lock.withLock {
            _pressure = level.rawValue
            defer { _hot = hot }
            return _hot != hot
        }
        guard changed, let d = device, (try? d.lockForConfiguration()) != nil else { return }
        let fps: Int32 = 15
        if hot, d.activeFormat.videoSupportedFrameRateRanges.contains(where: { $0.minFrameRate <= Double(fps) }) {
            d.activeVideoMinFrameDuration = CMTime(value: 1, timescale: fps)
            d.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: fps)
        } else {
            // Invalid restores the format's default frame rate.
            d.activeVideoMinFrameDuration = .invalid
            d.activeVideoMaxFrameDuration = .invalid
        }
        d.unlockForConfiguration()
    }

    // MARK: - Controls

    func toggleTorch() {
        guard let d = device, d.hasTorch else { return }
        let on = !torchOn
        sessionQueue.async {
            try? d.lockForConfiguration()
            d.torchMode = on ? .on : .off
            d.unlockForConfiguration()
        }
        torchOn = on
    }

    var hasTorch: Bool { device?.hasTorch ?? false }

    /// Sets the zoom in Camera-app terms (0.5, 1, 2, 5…). Buttons ramp smoothly; pinch
    /// sets it directly so it tracks the fingers.
    func setZoom(_ value: CGFloat, smooth: Bool, fromControl: Bool = false) {
        guard let d = device else { return }
        let ui = min(max(value, zoomRange.lowerBound), zoomRange.upperBound)
        zoom = ui
        // The slider only takes its own steps: show the nearest.
        if !fromControl, let near = zoomDetents.min(by: { abs($0 - Float(ui)) < abs($1 - Float(ui)) }) {
            zoomSlider?.value = near
        }
        let factor = min(max(ui * zoomScale, d.minAvailableVideoZoomFactor), d.maxAvailableVideoZoomFactor)
        sessionQueue.async {
            guard (try? d.lockForConfiguration()) != nil else { return }
            if smooth { d.ramp(toVideoZoomFactor: factor, withRate: 12) } else { d.videoZoomFactor = factor }
            d.unlockForConfiguration()
        }
    }

    /// Called on sessionQueue. Camera Control (iPhone 16 and later): a light press and a
    /// swipe zooms, as in the Camera app. Our own slider rather than the system one, so it
    /// stops where the zoom buttons and pinch do instead of running into blurry digital zoom.
    /// It moves in 0.1× steps, because a continuous slider only clicks at the lenses.
    private func addZoomControl(range: ClosedRange<CGFloat>, stops: [CGFloat]) {
        guard session.supportsControls else { return }
        var values = Set(stops.map { Float($0) })
        var v = Float(range.lowerBound)
        while v <= Float(range.upperBound) + 0.001 {
            values.insert((v * 10).rounded() / 10)
            v += 0.1
        }
        let detents = values.sorted()
        let slider = AVCaptureSlider(String(localized: "Zoom"), symbolName: "plus.magnifyingglass", values: detents)
        slider.prominentValues = stops.map { Float($0) }
        slider.localizedValueFormat = "%.1f×"
        slider.value = 1
        slider.setActionQueue(.main) { [weak self] value in
            self?.setZoom(CGFloat(value), smooth: true, fromControl: true)
        }
        zoomDetents = detents
        session.beginConfiguration()
        // The main lens's slider, when the other lenses come in.
        session.controls.forEach(session.removeControl)
        if session.canAddControl(slider) { session.addControl(slider) }
        session.commitConfiguration()
        session.setControlsDelegate(self, queue: sessionQueue)
        zoomSlider = slider
    }

    func focus(at devicePoint: CGPoint) {
        guard let d = device else { return }
        sessionQueue.async {
            try? d.lockForConfiguration()
            // Refocus around the tapped point but keep tracking: the next bus is never
            // at the same distance, so a one-shot focus lock would leave it blurry.
            if d.isFocusPointOfInterestSupported {
                d.focusPointOfInterest = devicePoint
                d.focusMode = d.isFocusModeSupported(.continuousAutoFocus) ? .continuousAutoFocus : .autoFocus
            }
            if d.isExposurePointOfInterestSupported {
                d.exposurePointOfInterest = devicePoint
                d.exposureMode = .continuousAutoExposure
            }
            d.unlockForConfiguration()
        }
    }

    /// Full-resolution JPEG/HEIC data.
    func capture() async -> Data? {
        await withCheckedContinuation { cont in
            sessionQueue.async {
                guard self.session.isRunning, self.photoContinuation == nil else {
                    self.lock.withLock {
                        self._lastCaptureError = self.session.isRunning ? "a capture was already in flight" : "session not running"
                    }
                    cont.resume(returning: nil)
                    return
                }
                self.photoContinuation = cont
                if let conn = self.photoOutput.connection(with: .video) {
                    let angle = self.captureAngle
                    if conn.isVideoRotationAngleSupported(angle) { conn.videoRotationAngle = angle }
                }
                let settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
                settings.photoQualityPrioritization = .balanced
                if let d = self.device, d.hasFlash { settings.flashMode = .off }
                self.photoOutput.capturePhoto(with: settings, delegate: self)
            }
        }
    }
}

extension CameraModel: AVCapturePhotoCaptureDelegate {
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        let data = photo.fileDataRepresentation()
        lock.withLock {
            _lastCaptureError = error.map { $0.localizedDescription } ?? (data == nil ? "no file data in the photo" : nil)
        }
        sessionQueue.async {
            self.photoContinuation?.resume(returning: data)
            self.photoContinuation = nil
        }
    }
}

// MARK: - Preview

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    /// The tap in the view's own points, and the same spot as a device point for focusing.
    var onTap: ((_ point: CGPoint, _ devicePoint: CGPoint) -> Void)? = nil

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
        var onTap: ((CGPoint, CGPoint) -> Void)?

        @objc func tapped(_ g: UITapGestureRecognizer) {
            let p = g.location(in: self)
            onTap?(p, previewLayer.captureDevicePointConverted(fromLayerPoint: p))
        }
    }

    func makeUIView(context: Context) -> PreviewView {
        let v = PreviewView()
        v.previewLayer.session = session
        v.previewLayer.videoGravity = .resizeAspectFill
        v.backgroundColor = .black
        v.addGestureRecognizer(UITapGestureRecognizer(target: v, action: #selector(PreviewView.tapped)))
        return v
    }

    func updateUIView(_ v: PreviewView, context: Context) {
        v.onTap = onTap
    }
}

extension CameraModel: AVCaptureSessionControlsDelegate {
    func sessionControlsDidBecomeActive(_ session: AVCaptureSession) {}

    func sessionControlsWillEnterFullscreenAppearance(_ session: AVCaptureSession) {
        Task { @MainActor in self.controlsFullscreen = true }
    }

    func sessionControlsWillExitFullscreenAppearance(_ session: AVCaptureSession) {
        Task { @MainActor in self.controlsFullscreen = false }
    }

    func sessionControlsDidBecomeInactive(_ session: AVCaptureSession) {
        Task { @MainActor in self.controlsFullscreen = false }
    }
}
