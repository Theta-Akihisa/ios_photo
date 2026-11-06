//  CameraService.swift
//  Capture module entry point. All AVCaptureSession work happens on `sessionQueue`;
//  `state` is only mutated on the main thread.

import AVFoundation
import CoreImage
import Photos
import UIKit

// MARK: - Helpers (file private)

/// State read by the video data queue (per frame). Lock protected.
private final class RenderShared: @unchecked Sendable {
    private let lock = NSLock()
    private var _look: LookPreset = .native
    private var _isLog = false
    private var _recorder: MovieRecorder?
    private var _gear = GearSelection()

    func setLook(_ v: LookPreset) { lock.lock(); _look = v; lock.unlock() }
    func setGear(_ v: GearSelection) { lock.lock(); _gear = v; lock.unlock() }
    func setLog(_ v: Bool) { lock.lock(); _isLog = v; lock.unlock() }
    func setRecorder(_ v: MovieRecorder?) { lock.lock(); _recorder = v; lock.unlock() }

    func snapshot() -> (look: LookPreset, gear: GearSelection, isLog: Bool, recorder: MovieRecorder?) {
        lock.lock(); defer { lock.unlock() }
        return (_look, _gear, _isLog, _recorder)
    }
}

private enum RecordingPhase { case idle, recording, finalizing }
private enum RecordingKind { case baked(MovieRecorder), movieFile }

/// Per-capture delegate; collects the file data and reports once the capture is complete.
/// For Apple ProRAW the delegate receives two photos (DNG + processed); both are kept.
private final class PhotoCaptureDelegate: NSObject, AVCapturePhotoCaptureDelegate {
    private var data: Data?
    private var rawData: Data?
    private var captureError: Error?
    private let completion: (Data?, Data?, Error?) -> Void

    init(completion: @escaping (Data?, Data?, Error?) -> Void) {
        self.completion = completion
        super.init()
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        if let error = error {
            captureError = error
            return
        }
        if photo.isRawPhoto {
            rawData = photo.fileDataRepresentation()
        } else {
            data = photo.fileDataRepresentation()
        }
    }

    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings,
                     error: Error?) {
        completion(data, rawData, captureError ?? error)
    }
}

// MARK: - CameraService

final class CameraService: NSObject, ObservableObject, @unchecked Sendable {

    // MARK: Public API state
    @Published private(set) var state = CameraState()
    let frames = PreviewFrameSource()

    // MARK: Queues / shared
    private let lookRenderer: LookRendering
    private let sessionQueue = DispatchQueue(label: "com.luxcam.capture.session")
    private let videoDataQueue = DispatchQueue(label: "com.luxcam.capture.videodata")
    private let processingQueue = DispatchQueue(label: "com.luxcam.capture.processing", qos: .userInitiated)
    private let ciContext: CIContext
    private let photoProcessor: PhotoProcessor
    private let shared = RenderShared()

    // MARK: Session objects (sessionQueue only)
    private let session = AVCaptureSession()
    private var device: AVCaptureDevice?
    private var videoInput: AVCaptureDeviceInput?
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var currentZoom: CGFloat = 1
    private var capsReferenceID: String?
    private var audioInput: AVCaptureDeviceInput?
    private let photoOutput = AVCapturePhotoOutput()
    private let videoDataOutput = AVCaptureVideoDataOutput()
    private let audioDataOutput = AVCaptureAudioDataOutput()
    private let movieOutput = AVCaptureMovieFileOutput()
    private var observers: [NSKeyValueObservation] = []
    private var inflightPhotos: [Int64: PhotoCaptureDelegate] = [:]
    private var knownCaps = DeviceCapabilities()
    private var staticCapsComputed = false
    private var hasRAWVideoFormat = false
    /// RAW codecs that movieOutput has reported at least once (RAW format detection is heuristic).
    private var stickyRAWCodecs: Set<VideoCodecOption> = []
    private var wantsRunning = false
    private var pendingReconfigure = false
    private var phase: RecordingPhase = .idle
    private var recordingKind: RecordingKind?
    private var runtimeObserver: NSObjectProtocol?
    private var stopAfterRecording = false

    /// Configuration mirror used on sessionQueue.
    private struct QueueConfig {
        var mode: CameraMode = .photo
        var look: LookPreset = .native
        var manual = ManualSettings()
        var video = VideoFormatSettings()
        var aperture: Float = 2.8
        var gear = GearSelection()
        var photoFormat: PhotoFormat = .heif
        /// Video settings actually applied (cinematic overrides, colour fallbacks).
        var effective = VideoFormatSettings()
    }
    private var q = QueueConfig()

    // MARK: Live readout throttle
    private let liveLock = NSLock()
    private var lastLivePublish: CFTimeInterval = 0
    private var trailingLiveScheduled = false

    // MARK: Main-thread only
    private var recordTimer: Timer?

    // MARK: - Captured media history

    private static let recentAssetsKey = "LuxCam.recentAssetIDs"
    private static let recentAssetsCap = 500

    /// Main thread only.
    private func recordAsset(_ id: String) {
        var ids = state.recentAssetIDs
        ids.removeAll { $0 == id }
        ids.insert(id, at: 0)
        if ids.count > Self.recentAssetsCap { ids = Array(ids.prefix(Self.recentAssetsCap)) }
        state.recentAssetIDs = ids
        UserDefaults.standard.set(ids, forKey: Self.recentAssetsKey)
    }

    /// Main thread only. Drops the given IDs from the history (e.g. after deletion).
    func forgetAssets(_ ids: [String]) {
        let drop = Set(ids)
        // The camera screen thumbnail shows the newest capture; clear it if that one is gone
        // so the UI reloads the thumbnail of the next asset.
        if let first = state.recentAssetIDs.first, drop.contains(first) {
            state.lastThumbnail = nil
        }
        let ids = state.recentAssetIDs.filter { !drop.contains($0) }
        state.recentAssetIDs = ids
        UserDefaults.standard.set(ids, forKey: Self.recentAssetsKey)
    }

    // MARK: - Init

    init(lookRenderer: LookRendering) {
        self.lookRenderer = lookRenderer
        let ctx = CIContext(options: [.cacheIntermediates: false])
        self.ciContext = ctx
        self.photoProcessor = PhotoProcessor(renderer: lookRenderer, context: ctx)
        super.init()

        if let saved = UserDefaults.standard.stringArray(forKey: Self.recentAssetsKey) {
            state.recentAssetIDs = Array(saved.prefix(Self.recentAssetsCap))
        }

        runtimeObserver = NotificationCenter.default.addObserver(
            forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil
        ) { [weak self] _ in
            guard let self = self else { return }
            self.sessionQueue.async {
                if self.wantsRunning && !self.session.isRunning {
                    self.session.startRunning()
                    self.publishRunning()
                }
            }
        }
    }

    deinit {
        if let o = runtimeObserver { NotificationCenter.default.removeObserver(o) }
    }

    // MARK: - Public API

    func start() {
        let snapshot = state
        requestPermissions { [weak self] videoGranted in
            guard let self = self else { return }
            self.sessionQueue.async {
                guard videoGranted else {
                    self.publishError("Camera access is denied. Enable it in Settings > Privacy.")
                    return
                }
                let alreadyRunning = self.session.isRunning && self.videoInput != nil
                    && !self.pendingReconfigure
                self.wantsRunning = true
                self.stopAfterRecording = false
                if alreadyRunning {
                    // onAppear + scenePhase can both call start(); don't reconfigure twice.
                    self.publishRunning()
                    return
                }
                self.q.mode = snapshot.mode
                self.q.look = snapshot.look
                self.q.manual = snapshot.manual
                self.q.video = snapshot.video
                self.q.aperture = snapshot.simulatedAperture
                self.q.photoFormat = snapshot.photoFormat
                self.q.gear = snapshot.gear
                self.shared.setLook(snapshot.look)
                self.shared.setGear(snapshot.gear)
                self.reconfigure()
                if !self.session.isRunning { self.session.startRunning() }
                self.publishRunning()
            }
        }
    }

    func stop() {
        sessionQueue.async { [self] in
            wantsRunning = false
            if phase != .idle {
                // Let the recording finalise first; the session is stopped in finishRecordingCleanup().
                stopAfterRecording = true
                if phase == .recording { stopRecordingOnQueue() }
                return
            }
            if session.isRunning { session.stopRunning() }
            publishRunning()
        }
    }

    func set(mode: CameraMode) {
        guard mode != state.mode, !state.isRecording else { return }
        state.mode = mode
        if mode == .portrait || mode == .cinematic {
            state.simulatedAperture = max(state.simulatedAperture, max(state.gear.lens.maxAperture, 1))
        }
        let aperture = state.simulatedAperture
        sessionQueue.async { [self] in
            q.mode = mode
            q.aperture = aperture
            reconfigure()
        }
    }

    func set(look: LookPreset) {
        state.look = look
        shared.setLook(look)
        sessionQueue.async { [self] in
            q.look = look
            if q.mode == .photo, let dev = device, session.outputs.contains(photoOutput) {
                updatePhotoDimensions(mode: q.mode, device: dev)
            }
        }
    }

    func set(manual: ManualSettings) {
        state.manual = manual
        sessionQueue.async { [self] in
            q.manual = manual
            applyManualSettings()
        }
    }

    func set(video: VideoFormatSettings) {
        guard video != state.video else { return }
        state.video = video
        sessionQueue.async { [self] in
            q.video = video
            if q.mode == .video { reconfigure() }
            // Refresh the frame-rate list for the new resolution even when no reconfigure happened.
            if let dev = device {
                publishCapabilities(device: dev, cinematicActive: q.mode == .cinematic && knownCaps.cinematic)
            }
        }
    }

    func set(photoFormat: PhotoFormat) {
        guard photoFormat != state.photoFormat else { return }
        state.photoFormat = photoFormat
        sessionQueue.async { [self] in
            q.photoFormat = photoFormat
            if q.mode == .photo, let dev = device, session.outputs.contains(photoOutput) {
                session.beginConfiguration()
                applyProRAWState(mode: q.mode)
                updatePhotoDimensions(mode: q.mode, device: dev)
                session.commitConfiguration()
                publishCapabilities(device: dev, cinematicActive: false)
            }
        }
    }

    func set(simulatedAperture requested: Float) {
        var simulatedAperture = requested
        if state.mode == .portrait || state.mode == .cinematic {
            simulatedAperture = max(simulatedAperture, max(state.gear.lens.maxAperture, 1))
        }
        state.simulatedAperture = simulatedAperture
        sessionQueue.async { [self] in
            q.aperture = simulatedAperture
            if q.mode == .cinematic, let input = videoInput, let dev = device {
                CinematicSupport.setAperture(simulatedAperture, input: input, device: dev)
            }
        }
    }

    func set(gear requested: GearSelection) {
        let g = requested.normalized()
        let bodyChanged = g.body != state.gear.body
        guard !state.isRecording, g != state.gear else { return }
        state.gear = g
        shared.setGear(g)
        if bodyChanged && (!g.body.allows(state.look) || (g.body.family != .native && state.look.family != g.body.family)) {
            set(look: g.body.defaultLook)
        } else if !g.body.allows(state.look) {
            set(look: g.body.defaultLook)
        }
        if state.mode == .portrait || state.mode == .cinematic {
            state.simulatedAperture = max(state.simulatedAperture, max(g.lens.maxAperture, 1))
        }
        let aperture = state.simulatedAperture
        sessionQueue.async { [self] in
            q.gear = g
            q.aperture = aperture
            if q.mode == .cinematic, let input = videoInput, let dev = device {
                CinematicSupport.setAperture(aperture, input: input, device: dev)
            }
            // PHOTO / VIDEO: the gear may select another physical camera; PORTRAIT / CINEMATIC keep theirs.
            if q.mode == .portrait {
                if phase == .idle, let dev = device {
                    applyGearZoom(on: dev)
                    publishCapabilities(device: dev, cinematicActive: false)
                }
                return
            }
            guard q.mode == .photo || q.mode == .video else { return }
            let target = CaptureFormats.captureDevice(for: q.mode, gear: g)
            if phase == .idle, let dev = device, let target = target, target.uniqueID == dev.uniqueID {
                applyGearZoom(on: dev)
                if q.mode == .photo, session.outputs.contains(photoOutput) {
                    updatePhotoDimensions(mode: q.mode, device: dev)
                }
                publishCapabilities(device: dev, cinematicActive: false)
            } else {
                reconfigure()      // new camera (or deferred until recording ends)
            }
        }
    }

    func focus(at devicePoint: CGPoint) {
        var m = state.manual
        m.focus = .auto
        state.manual = m
        let point = CGPoint(x: min(max(devicePoint.x, 0), 1), y: min(max(devicePoint.y, 0), 1))
        sessionQueue.async { [self] in
            q.manual.focus = .auto
            guard let dev = device else { return }
            do { try dev.lockForConfiguration() } catch { return }
            defer { dev.unlockForConfiguration() }
            if dev.isFocusPointOfInterestSupported {
                dev.focusPointOfInterest = point
                if dev.isFocusModeSupported(.continuousAutoFocus) {
                    dev.focusMode = .continuousAutoFocus
                } else if dev.isFocusModeSupported(.autoFocus) {
                    dev.focusMode = .autoFocus
                }
            } else if dev.isFocusModeSupported(.continuousAutoFocus) {
                dev.focusMode = .continuousAutoFocus
            }
            if case .auto = q.manual.exposure, dev.isExposurePointOfInterestSupported {
                dev.exposurePointOfInterest = point
                if dev.isExposureModeSupported(.continuousAutoExposure) {
                    dev.exposureMode = .continuousAutoExposure
                }
            }
        }
    }

    func capturePhoto() {
        let mode = state.mode
        guard !state.isCapturingPhoto, mode == .photo || mode == .portrait else { return }
        state.isCapturingPhoto = true
        let look = state.look
        let gear = state.gear
        let aperture = state.simulatedAperture

        sessionQueue.async { [self] in
            guard session.isRunning, session.outputs.contains(photoOutput) else {
                publishError("Camera is not ready.")
                return
            }
            if let conn = photoOutput.connection(with: .video) {
                let angle = currentCaptureAngle()
                if conn.isVideoRotationAngleSupported(angle) { conn.videoRotationAngle = angle }
            }
            if mode == .photo, q.photoFormat == .proRAW, !photoOutput.isAppleProRAWEnabled {
                updateState { $0.errorMessage = "ProRAW を有効にできませんでした。HEIF で保存します。" }
            }
            let settings = makePhotoSettings(mode: mode)
            let id = settings.uniqueID
            let delegate = PhotoCaptureDelegate { [weak self] data, rawData, error in
                self?.photoCaptureFinished(id: id, data: data, rawData: rawData, error: error,
                                           mode: mode, look: look, gear: gear, aperture: aperture)
            }
            inflightPhotos[id] = delegate
            photoOutput.capturePhoto(with: settings, delegate: delegate)
        }
    }

    func toggleRecording() {
        sessionQueue.async { [self] in
            switch phase {
            case .idle: startRecordingOnQueue()
            case .recording: stopRecordingOnQueue()
            case .finalizing: break
            }
        }
    }

    // MARK: - State helpers

    private func updateState(_ change: @escaping (inout CameraState) -> Void) {
        if Thread.isMainThread {
            change(&state)
        } else {
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                change(&self.state)
            }
        }
    }

    private func publishError(_ message: String) {
        updateState { $0.errorMessage = message; $0.isCapturingPhoto = false }
    }

    private func publishRunning() {
        let running = session.isRunning
        updateState { $0.isSessionRunning = running }
    }

    // MARK: - Permissions

    private func requestPermissions(_ done: @escaping (Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .video) { videoOK in
            AVCaptureDevice.requestAccess(for: .audio) { _ in
                PHPhotoLibrary.requestAuthorization(for: .addOnly) { _ in
                    done(videoOK)
                }
            }
        }
    }

    // MARK: - Session configuration (sessionQueue)

    private func reconfigure() {
        guard phase == .idle else {
            pendingReconfigure = true
            return
        }
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else { return }

        let mode = q.mode
        let isVideoMode = mode.isVideo

        session.beginConfiguration()
        for o in observers { o.invalidate() }
        observers.removeAll()
        for i in session.inputs { session.removeInput(i) }
        for o in session.outputs { session.removeOutput(o) }
        videoInput = nil
        audioInput = nil
        device = nil
        rotationCoordinator = nil
        currentZoom = 1
        shared.setRecorder(nil)

        // Device + input (PHOTO / VIDEO: physical camera chosen by the gear's focal length)
        guard let dev = CaptureFormats.captureDevice(for: mode, gear: q.gear),
              let input = try? AVCaptureDeviceInput(device: dev),
              session.canAddInput(input) else {
            session.commitConfiguration()
            publishError("No usable camera found.")
            return
        }
        session.addInput(input)
        videoInput = input
        device = dev
        rotationCoordinator = AVCaptureDevice.RotationCoordinator(device: dev, previewLayer: nil)

        // Static capabilities (cinematic / depth once; Log / HLG / codecs per active physical camera).
        computeStaticCapabilities()
        updateDeviceCapabilities(activeDevice: dev, mode: mode)

        // Audio input for video modes.
        if isVideoMode, AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
           let mic = AVCaptureDevice.default(for: .audio),
           let micInput = try? AVCaptureDeviceInput(device: mic),
           session.canAddInput(micInput) {
            session.addInput(micInput)
            audioInput = micInput
        }

        // Preview frames (all modes).
        videoDataOutput.alwaysDiscardsLateVideoFrames = true
        videoDataOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)]
        videoDataOutput.setSampleBufferDelegate(self, queue: videoDataQueue)
        if session.canAddOutput(videoDataOutput) { session.addOutput(videoDataOutput) }

        var isLog = false
        var effective = VideoFormatSettings()
        var cinematicActive = false

        if isVideoMode {
            session.sessionPreset = .inputPriority
            session.automaticallyConfiguresCaptureDeviceForWideColor = false

            effective = q.video
            var format: AVCaptureDevice.Format?
            if mode == .cinematic {
                effective = VideoFormatSettings()
                effective.frameRate = 30
                format = CinematicSupport.bestFormat(for: dev)
                cinematicActive = (format != nil)
                if format == nil { effective.frameRate = 24 }   // fallback: plain 24 fps HEVC video
            }
            if format == nil { format = CaptureFormats.bestVideoFormat(for: dev, settings: effective) }
            if format == nil {
                effective.color = .standard
                format = CaptureFormats.bestVideoFormat(for: dev, settings: effective)
            }
            if let fmt = format {
                isLog = applyFormat(fmt, to: dev, settings: effective)
                if mode == .video, let note = CaptureFormats.mismatchNote(fmt, settings: effective) {
                    publishError(note)
                }
            }
            if cinematicActive {
                let ok = CinematicSupport.setEnabled(true, input: input, device: dev)
                if ok { CinematicSupport.setAperture(q.aperture, input: input, device: dev) }
                cinematicActive = ok
            }

            if audioInput != nil, session.canAddOutput(audioDataOutput) {
                audioDataOutput.setSampleBufferDelegate(self, queue: videoDataQueue)
                session.addOutput(audioDataOutput)
            }
            if session.canAddOutput(movieOutput) { session.addOutput(movieOutput) }
        } else {
            if session.canSetSessionPreset(.photo) { session.sessionPreset = .photo }
            session.automaticallyConfiguresCaptureDeviceForWideColor = true
            if session.canAddOutput(photoOutput) {
                session.addOutput(photoOutput)
                // Start from the smallest size; configurePhotoOutput raises it once the format is resolved.
                let startDims = dev.activeFormat.supportedMaxPhotoDimensions
                if let smallest = startDims.filter({ $0.width > 0 && $0.height > 0 })
                    .min(by: { Int($0.width) * Int($0.height) < Int($1.width) * Int($1.height) }) {
                    photoOutput.maxPhotoDimensions = smallest
                }
            }
        }

        q.effective = effective
        session.commitConfiguration()

        // Gear zoom must come after the format is final (changing activeFormat resets the zoom factor).
        applyGearZoom(on: dev)

        // Post-commit configuration (needs live connections).
        if isVideoMode {
            configureMovieOutput(effective: effective)
        } else {
            configurePhotoOutput(mode: mode, device: dev)
        }

        shared.setLog(isLog)
        applyManualSettings()
        observeLiveValues(of: dev)
        publishCapabilities(device: dev, cinematicActive: cinematicActive)
        updateState { $0.previewIsLog = isLog }

        if wantsRunning && !session.isRunning { session.startRunning() }
        publishRunning()
    }

    /// Applies format, frame rate and colour space. Returns true if Apple Log is active.
    private func applyFormat(_ format: AVCaptureDevice.Format,
                             to dev: AVCaptureDevice,
                             settings: VideoFormatSettings) -> Bool {
        var logActive = false
        do { try dev.lockForConfiguration() } catch { return false }
        defer { dev.unlockForConfiguration() }

        dev.activeFormat = format
        let fps = CaptureFormats.clampedFPS(format, Double(settings.frameRate))
        let duration = CMTime(value: 1, timescale: CMTimeScale(max(1, Int32(fps.rounded()))))
        dev.activeVideoMinFrameDuration = duration
        dev.activeVideoMaxFrameDuration = duration

        switch settings.color {
        case .appleLog:
            if CaptureFormats.supports(format, colorSpace: .appleLog) {
                dev.activeColorSpace = .appleLog
                logActive = true
            }
        case .hlg:
            if CaptureFormats.supports(format, colorSpace: .HLG_BT2020) {
                dev.activeColorSpace = .HLG_BT2020
            }
        case .standard:
            if CaptureFormats.supports(format, colorSpace: .sRGB) {
                dev.activeColorSpace = .sRGB
            }
        }
        return logActive
    }

    private func configurePhotoOutput(mode: CameraMode, device dev: AVCaptureDevice) {
        photoOutput.maxPhotoQualityPrioritization = .quality
        let portrait = (mode == .portrait)
        if photoOutput.isDepthDataDeliverySupported {
            photoOutput.isDepthDataDeliveryEnabled = portrait
        }
        if photoOutput.isPortraitEffectsMatteDeliverySupported {
            photoOutput.isPortraitEffectsMatteDeliveryEnabled = portrait && photoOutput.isDepthDataDeliveryEnabled
        }
        // ProRAW is evaluated here, after the photo preset / format has been applied.
        applyProRAWState(mode: mode)
        updatePhotoDimensions(mode: mode, device: dev)
        // Wide colour stays automatic in photo mode (session.automaticallyConfiguresCaptureDeviceForWideColor).
    }

    /// Enables / disables Apple ProRAW according to the current mode and user choice.
    private func applyProRAWState(mode: CameraMode) {
        let supported = photoOutput.isAppleProRAWSupported
        if supported { knownCaps.proRAW = true }
        let want = supported && mode == .photo && q.photoFormat == .proRAW
        if photoOutput.isAppleProRAWEnabled != want {
            photoOutput.isAppleProRAWEnabled = want
        }
    }

    /// Full-resolution (e.g. 48 MP) only when no re-render is needed; otherwise <= 12 MP to bound memory.
    /// Never exceeds device.activeFormat.supportedMaxPhotoDimensions.
    private func updatePhotoDimensions(mode: CameraMode, device dev: AVCaptureDevice) {
        func area(_ d: CMVideoDimensions) -> Int { Int(d.width) * Int(d.height) }
        let dims = dev.activeFormat.supportedMaxPhotoDimensions.filter { area($0) > 0 }
        guard !dims.isEmpty else { return }
        let portrait = (mode == .portrait)
        // Full resolution only when nothing is re-rendered: native look, 4:3 body, neutral gear characters
        // (or ProRAW, whose DNG is never re-rendered).
        let noRerender = q.look == .native && abs(q.gear.body.photoAspect - 4.0 / 3.0) < 0.001
            && CaptureFormats.isNeutral(q.gear)
        let wantFull = !portrait && (noRerender || q.photoFormat == .proRAW)
        let pick: CMVideoDimensions?
        if wantFull && currentZoom > 1.05 {
            // Zoomed: 48 MP would only be an upscaled crop, so stay at <= ~24 MP (5712x4284 = 24.5 MP).
            pick = dims.filter { area($0) <= 25_000_000 }.max(by: { area($0) < area($1) })
                ?? dims.min(by: { area($0) < area($1) })
        } else if wantFull {
            pick = dims.max(by: { area($0) < area($1) })
        } else {
            pick = dims.filter { area($0) <= 12_600_000 }.max(by: { area($0) < area($1) })
                ?? dims.min(by: { area($0) < area($1) })
        }
        guard let target = pick else { return }
        let cur = photoOutput.maxPhotoDimensions
        if cur.width != target.width || cur.height != target.height {
            photoOutput.maxPhotoDimensions = target
        }
    }

    private func configureMovieOutput(effective: VideoFormatSettings) {
        guard session.outputs.contains(movieOutput) else { return }
        guard let conn = movieOutput.connection(with: .video) else { return }
        let angle = currentCaptureAngle()
        if conn.isVideoRotationAngleSupported(angle) { conn.videoRotationAngle = angle }

        let available = movieOutput.availableVideoCodecTypes
        for c in [VideoCodecOption.proResRAW, .proResRAWHQ] where available.contains(c.avCodecType) {
            stickyRAWCodecs.insert(c)
        }
        var supported = knownCaps.supportedCodecs
        supported.formUnion(VideoCodecOption.allCases.filter { available.contains($0.avCodecType) })
        if hasRAWVideoFormat { supported.formUnion(stickyRAWCodecs) }
        supported.insert(.hevc)
        knownCaps.supportedCodecs = supported

        // HLG records as 10-bit HDR HEVC through the movie output; the colour space follows the device's
        // activeColorSpace, so only the codec has to be chosen here.
        var chosen: AVVideoCodecType?
        if effective.codec == .hevc || available.contains(effective.codec.avCodecType) {
            chosen = effective.codec.avCodecType
        }
        if let codec = chosen {
            if effective.codec != .hevc || available.contains(.hevc) {
                movieOutput.setOutputSettings([AVVideoCodecKey: codec.rawValue], for: conn)
            }
        } else {
            publishError("この組み合わせではProResを使用できません（外部ストレージが必要な場合があります）")
            if available.contains(.hevc) {
                movieOutput.setOutputSettings([AVVideoCodecKey: AVVideoCodecType.hevc.rawValue], for: conn)
            }
            q.effective.codec = .hevc
        }
    }

    // MARK: - Capabilities

    /// Device independent capabilities (computed once from the wide camera).
    private func computeStaticCapabilities() {
        guard !staticCapsComputed else { return }
        staticCapsComputed = true
        if let wide = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) {
            knownCaps.cinematic = CinematicSupport.deviceSupportsCinematic(wide)
        }
        knownCaps.portraitDepth = CaptureFormats.hasDepthCapableDevice()
    }

    /// Log / HLG / ProRes / RAW support of the camera actually used for recording. PHOTO / VIDEO use the
    /// gear-selected physical camera (ultra wide / telephoto may lack some); other modes use the wide camera.
    private func updateDeviceCapabilities(activeDevice dev: AVCaptureDevice, mode: CameraMode) {
        let usesGearDevice = (mode == .photo || mode == .video)
        let ref: AVCaptureDevice = usesGearDevice
            ? dev
            : (AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) ?? dev)
        if capsReferenceID != ref.uniqueID {
            capsReferenceID = ref.uniqueID
            stickyRAWCodecs.removeAll()
        }
        knownCaps.appleLog = CaptureFormats.anyFormat(of: ref, supports: .appleLog)
        knownCaps.hlg = CaptureFormats.anyFormat(of: ref, supports: .HLG_BT2020)
        // The movie output only lists codecs for the ACTIVE format, so derive ProRes from all formats.
        var codecs: Set<VideoCodecOption> = [.hevc]
        if ref.formats.contains(where: { CaptureFormats.is10Bit422($0) }) {
            codecs.formUnion([.proRes422HQ, .proRes422, .proRes422LT, .proRes422Proxy])
        }
        hasRAWVideoFormat = ref.formats.contains(where: { CaptureFormats.looksRAW($0) })
        if hasRAWVideoFormat { codecs.formUnion(stickyRAWCodecs) }
        knownCaps.supportedCodecs = codecs
    }

    private func publishCapabilities(device dev: AVCaptureDevice, cinematicActive: Bool) {
        var caps = knownCaps
        let fmt = dev.activeFormat
        caps.isoRange = CaptureFormats.range(fmt.minISO, fmt.maxISO)
        let minD = fmt.minExposureDuration.seconds
        let maxD = fmt.maxExposureDuration.seconds
        if minD.isFinite, maxD.isFinite, minD > 0 {
            caps.exposureRange = CaptureFormats.range(minD, maxD)
        }
        caps.exposureBiasRange = CaptureFormats.range(dev.minExposureTargetBias, dev.maxExposureTargetBias)
        caps.manualFocus = dev.isLockingFocusWithCustomLensPositionSupported
        if cinematicActive { caps.cinematic = true }
        caps.supportedFrameRates = CaptureFormats.supportedFrameRates(of: dev, resolution4K: q.video.resolution4K)
        if session.outputs.contains(photoOutput) { caps.proRAW = photoOutput.isAppleProRAWSupported }
        caps.maxZoomFactor = max(1, fmt.videoMaxZoomFactor)
        caps.supportedCodecs.insert(.hevc)
        let zoom = dev.videoZoomFactor
        updateState { $0.capabilities = caps; $0.liveZoomFactor = zoom }
    }

    // MARK: - Gear zoom / orientation (sessionQueue)

    /// Clockwise rotation angle (degrees) that makes captures horizon-level; 90 (portrait) as a fallback.
    private func currentCaptureAngle() -> CGFloat {
        rotationCoordinator?.videoRotationAngleForHorizonLevelCapture ?? 90
    }

    /// Residual zoom on the chosen physical camera for the gear's equivalent focal length.
    private func gearZoom(for dev: AVCaptureDevice) -> CGFloat {
        guard q.mode == .photo || q.mode == .video || q.mode == .portrait else { return 1 }
        if q.mode == .video && q.video.codec.isRAW { return 1 }     // ProRes RAW: sensor native
        let f = q.gear.lens.equivalentFocalLength(on: q.gear.body)
        let base = CaptureFormats.baseFocalLength(of: dev)
        guard base > 0, f.isFinite else { return 1 }
        let fmt = dev.activeFormat
        let lo = max(1, dev.minAvailableVideoZoomFactor)
        let hi = max(lo, min(fmt.videoMaxZoomFactor, dev.maxAvailableVideoZoomFactor))
        var z = min(max(lo, CGFloat(f / base)), hi)
        // Snap to a native-resolution crop (e.g. 2x on the 48 MP main camera) when close enough.
        if !dev.isVirtualDevice {
            let snaps = fmt.secondaryNativeResolutionZoomFactors
            if let best = snaps.min(by: { abs($0 - z) < abs($1 - z) }), best > 0, abs(best / z - 1) <= 0.08 {
                z = min(max(lo, best), hi)
            }
        }
        return z
    }

    private func applyGearZoom(on dev: AVCaptureDevice) {
        let target = gearZoom(for: dev)
        do { try dev.lockForConfiguration() } catch { return }
        defer { dev.unlockForConfiguration() }
        if dev.isRampingVideoZoom { dev.cancelVideoZoomRamp() }
        let clamped = min(max(target, dev.minAvailableVideoZoomFactor), dev.maxAvailableVideoZoomFactor)
        dev.videoZoomFactor = clamped
        currentZoom = clamped
        updateState { $0.liveZoomFactor = clamped }
    }

    // MARK: - Manual controls (sessionQueue)

    private func applyManualSettings() {
        guard let dev = device else { return }
        do { try dev.lockForConfiguration() } catch { return }
        defer { dev.unlockForConfiguration() }

        // Focus
        switch q.manual.focus {
        case .auto:
            if dev.isFocusModeSupported(.continuousAutoFocus) { dev.focusMode = .continuousAutoFocus }
        case .manual(let lensPosition):
            if dev.isLockingFocusWithCustomLensPositionSupported {
                dev.setFocusModeLocked(lensPosition: min(max(lensPosition, 0), 1), completionHandler: nil)
            }
        }

        // Exposure
        switch q.manual.exposure {
        case .auto:
            if dev.isExposureModeSupported(.continuousAutoExposure) { dev.exposureMode = .continuousAutoExposure }
            let lo = dev.minExposureTargetBias, hi = dev.maxExposureTargetBias
            if lo <= hi {
                dev.setExposureTargetBias(min(max(q.manual.exposureBias, lo), hi), completionHandler: nil)
            }
        case .manual(let seconds, let iso):
            guard dev.isExposureModeSupported(.custom) else { return }
            let fmt = dev.activeFormat
            let minD = fmt.minExposureDuration.seconds
            let maxD = fmt.maxExposureDuration.seconds
            var d = seconds
            if minD.isFinite && maxD.isFinite && minD <= maxD { d = min(max(seconds, minD), maxD) }
            let clampedISO = min(max(iso, fmt.minISO), fmt.maxISO)
            dev.setExposureModeCustom(duration: CMTime(seconds: d, preferredTimescale: 1_000_000),
                                      iso: clampedISO, completionHandler: nil)
        }
    }

    // MARK: - Live readouts (KVO)

    private func observeLiveValues(of dev: AVCaptureDevice) {
        observers = [
            dev.observe(\.iso, options: [.new]) { [weak self, weak dev] _, _ in
                guard let self = self, let dev = dev else { return }
                self.publishLive(from: dev)
            },
            dev.observe(\.exposureDuration, options: [.new]) { [weak self, weak dev] _, _ in
                guard let self = self, let dev = dev else { return }
                self.publishLive(from: dev)
            },
            dev.observe(\.lensPosition, options: [.new]) { [weak self, weak dev] _, _ in
                guard let self = self, let dev = dev else { return }
                self.publishLive(from: dev)
            },
            dev.observe(\.videoZoomFactor, options: [.new]) { [weak self, weak dev] _, _ in
                guard let self = self, let dev = dev else { return }
                let z = dev.videoZoomFactor
                self.updateState { $0.liveZoomFactor = z }
            }
        ]
        pushLive(dev)
    }

    /// Throttled to ~10 Hz with a trailing update so the last value is never lost.
    private func publishLive(from dev: AVCaptureDevice) {
        liveLock.lock()
        let now = CACurrentMediaTime()
        if now - lastLivePublish < 0.1 {
            let schedule = !trailingLiveScheduled
            trailingLiveScheduled = true
            liveLock.unlock()
            if schedule {
                DispatchQueue.global(qos: .userInteractive).asyncAfter(deadline: .now() + 0.12) { [weak self, weak dev] in
                    guard let self = self, let dev = dev else { return }
                    self.liveLock.lock()
                    self.trailingLiveScheduled = false
                    self.lastLivePublish = CACurrentMediaTime()
                    self.liveLock.unlock()
                    self.pushLive(dev)
                }
            }
            return
        }
        lastLivePublish = now
        liveLock.unlock()
        pushLive(dev)
    }

    private func pushLive(_ dev: AVCaptureDevice) {
        let iso = dev.iso
        let shutterRaw = dev.exposureDuration.seconds
        let shutter = shutterRaw.isFinite ? shutterRaw : 0
        let lens = dev.lensPosition
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.state.liveISO = iso
            self.state.liveShutterSeconds = shutter
            self.state.liveLensPosition = lens
        }
    }

    // MARK: - Photo

    private func makePhotoSettings(mode: CameraMode) -> AVCapturePhotoSettings {
        let settings: AVCapturePhotoSettings
        let hevcFormat: [String: Any] = [AVVideoCodecKey: AVVideoCodecType.hevc.rawValue]
        if mode == .photo, photoOutput.isAppleProRAWEnabled,
           let rawFormat = photoOutput.availableRawPhotoPixelFormatTypes.first(where: {
               AVCapturePhotoOutput.isAppleProRAWPixelFormat($0)
           }) {
            settings = AVCapturePhotoSettings(rawPixelFormatType: rawFormat, processedFormat: hevcFormat)
        } else if photoOutput.availablePhotoCodecTypes.contains(.hevc) {
            settings = AVCapturePhotoSettings(format: hevcFormat)
        } else {
            settings = AVCapturePhotoSettings()
        }
        settings.photoQualityPrioritization = .balanced
        let maxDims = photoOutput.maxPhotoDimensions
        if maxDims.width > 0, maxDims.height > 0 {
            settings.maxPhotoDimensions = maxDims
        }
        if mode == .portrait {
            if photoOutput.isDepthDataDeliveryEnabled {
                settings.isDepthDataDeliveryEnabled = true
                settings.embedsDepthDataInPhoto = true
            }
            if photoOutput.isPortraitEffectsMatteDeliveryEnabled {
                settings.isPortraitEffectsMatteDeliveryEnabled = true
                settings.embedsPortraitEffectsMatteInPhoto = true
            }
        }
        return settings
    }

    private func photoCaptureFinished(id: Int64, data: Data?, rawData: Data?, error: Error?,
                                      mode: CameraMode, look: LookPreset, gear: GearSelection, aperture: Float) {
        sessionQueue.async { [self] in inflightPhotos[id] = nil }

        // If only the DNG arrived, save it as the primary resource without processing.
        let primary = data ?? rawData
        let primaryIsDNG = (data == nil)
        guard let primary = primary else {
            publishError(error?.localizedDescription ?? "Photo capture failed.")
            return
        }
        let dng = (data != nil) ? rawData : nil
        processingQueue.async { [self] in
            let output: PhotoProcessor.Output
            if data != nil {
                // The processed companion of a ProRAW pair is left uncropped / un-geared like the 4:3 DNG.
                let isRAWPair = (rawData != nil)
                output = photoProcessor.process(data: primary, mode: mode, look: look,
                                                gear: isRAWPair ? GearSelection() : gear,
                                                aperture: aperture, cropToBody: !isRAWPair)
            } else {
                output = PhotoProcessor.Output(data: primary, thumbnail: LibrarySaver.photoThumbnail(from: primary))
            }
            LibrarySaver.savePhoto(data: output.data, rawDNG: dng, isDNG: primaryIsDNG) { [weak self] ok, saveError, assetID in
                guard let self = self else { return }
                DispatchQueue.main.async {
                    self.state.isCapturingPhoto = false
                    if ok {
                        if let assetID = assetID { self.recordAsset(assetID) }
                        if let thumb = output.thumbnail { self.state.lastThumbnail = thumb }
                    } else {
                        self.state.errorMessage = saveError?.localizedDescription
                            ?? "Could not save the photo. Check Photos permission."
                    }
                }
            }
        }
    }

    // MARK: - Recording (sessionQueue)

    private func startRecordingOnQueue() {
        guard q.mode.isVideo, session.isRunning, device != nil else { return }
        let look = q.look
        let gear = q.gear
        let baked = (q.mode == .video) && q.effective.bakesLook

        if baked {
            // Prefer the real pixel-buffer size of the preview frames.
            var w = 0, h = 0
            if let latest = frames.latest() {
                w = CVPixelBufferGetWidth(latest.buffer)
                h = CVPixelBufferGetHeight(latest.buffer)
            } else if let fmt = device?.activeFormat {
                let d = CaptureFormats.dimensions(fmt)
                w = d.w; h = d.h
            }
            guard w > 0, h > 0 else {
                publishError("Camera is not ready.")
                return
            }
            var audioSettings: [String: Any]?
            if audioInput != nil {
                audioSettings = audioDataOutput.recommendedAudioSettingsForAssetWriter(writingTo: .mov)
            }
            do {
                let recorder = try MovieRecorder(
                    url: CaptureFormats.temporaryMovieURL(),
                    width: w, height: h, frameRate: q.effective.frameRate,
                    rotationAngle: currentCaptureAngle(),
                    hasAudio: audioInput != nil, audioSettings: audioSettings,
                    renderer: lookRenderer, context: ciContext,
                    metadata: CaptureFormats.lookMetadata(look, gear: gear))
                recordingKind = .baked(recorder)
                shared.setRecorder(recorder)
            } catch {
                publishError("Could not start recording: \(error.localizedDescription)")
                return
            }
        } else {
            guard session.outputs.contains(movieOutput), !movieOutput.isRecording else {
                publishError("Recording is not available in this configuration.")
                return
            }
            if let conn = movieOutput.connection(with: .video) {
                let angle = currentCaptureAngle()
                if conn.isVideoRotationAngleSupported(angle) { conn.videoRotationAngle = angle }
            }
            movieOutput.metadata = CaptureFormats.lookMetadata(look, gear: gear)
            recordingKind = .movieFile
            movieOutput.startRecording(to: CaptureFormats.temporaryMovieURL(), recordingDelegate: self)
        }

        phase = .recording
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.state.isRecording = true
            self.state.recordingSeconds = 0
            self.startRecordTimer()
        }
    }

    private func stopRecordingOnQueue() {
        guard phase == .recording else { return }
        phase = .finalizing
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.recordTimer?.invalidate()
            self.recordTimer = nil
            self.state.isRecording = false
        }
        switch recordingKind {
        case .baked(let recorder)?:
            shared.setRecorder(nil)
            videoDataQueue.async { [weak self] in
                recorder.finish { url, error in
                    self?.recordingFinished(url: url, error: error)
                }
            }
        case .movieFile?:
            movieOutput.stopRecording()      // result arrives in the delegate
        case nil:
            finishRecordingCleanup()
        }
    }

    /// Called from any queue once the file is complete (or failed).
    private func recordingFinished(url: URL?, error: Error?) {
        guard let url = url else {
            publishError("Recording failed: \(error?.localizedDescription ?? "unknown error")")
            sessionQueue.async { [self] in finishRecordingCleanup() }
            return
        }
        processingQueue.async { [weak self] in
            let thumb = LibrarySaver.videoThumbnail(url: url)
            LibrarySaver.saveVideo(url: url) { ok, saveError, assetID in
                guard let self = self else { return }
                DispatchQueue.main.async {
                    if ok {
                        if let assetID = assetID { self.recordAsset(assetID) }
                        if let thumb = thumb { self.state.lastThumbnail = thumb }
                    } else {
                        self.state.errorMessage = saveError?.localizedDescription
                            ?? "Could not save the video. Check Photos permission."
                    }
                }
                self.sessionQueue.async { self.finishRecordingCleanup() }
            }
        }
    }

    private func finishRecordingCleanup() {
        phase = .idle
        recordingKind = nil
        if stopAfterRecording {
            // stop() was requested while recording; honour it now that the file is finalised.
            stopAfterRecording = false
            if !wantsRunning {
                if session.isRunning { session.stopRunning() }
                publishRunning()
                return
            }
        }
        if pendingReconfigure {
            pendingReconfigure = false
            reconfigure()
        }
    }

    private func startRecordTimer() {
        recordTimer?.invalidate()
        let began = Date()
        recordTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            self?.state.recordingSeconds = Date().timeIntervalSince(began)
        }
    }
}

// MARK: - Sample buffer delegates (video preview / baked recording / audio)

extension CameraService: AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        if output === videoDataOutput {
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
            let snap = shared.snapshot()
            frames.push(pixelBuffer, isLog: snap.isLog)
            snap.recorder?.appendVideo(sampleBuffer, pixelBuffer: pixelBuffer,
                                       look: snap.look, gear: snap.gear, isLog: snap.isLog)
        } else if output === audioDataOutput {
            shared.snapshot().recorder?.appendAudio(sampleBuffer)
        }
    }
}

// MARK: - Movie file output delegate (ProRes / Log / Cinematic)

extension CameraService: AVCaptureFileOutputRecordingDelegate {

    func fileOutput(_ output: AVCaptureFileOutput,
                    didFinishRecordingTo outputFileURL: URL,
                    from connections: [AVCaptureConnection],
                    error: Error?) {
        // An error may be reported even though the file was written successfully.
        var success = (error == nil)
        if let nsError = error as NSError?,
           let ok = nsError.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool {
            success = ok
        }
        if success {
            recordingFinished(url: outputFileURL, error: nil)
        } else {
            try? FileManager.default.removeItem(at: outputFileURL)
            recordingFinished(url: nil, error: error)
        }
    }
}
