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

    func setLook(_ v: LookPreset) { lock.lock(); _look = v; lock.unlock() }
    func setLog(_ v: Bool) { lock.lock(); _isLog = v; lock.unlock() }
    func setRecorder(_ v: MovieRecorder?) { lock.lock(); _recorder = v; lock.unlock() }

    func snapshot() -> (look: LookPreset, isLog: Bool, recorder: MovieRecorder?) {
        lock.lock(); defer { lock.unlock() }
        return (_look, _isLog, _recorder)
    }
}

private enum RecordingPhase { case idle, recording, finalizing }
private enum RecordingKind { case baked(MovieRecorder), movieFile }

/// Per-capture delegate; collects the file data and reports once the capture is complete.
private final class PhotoCaptureDelegate: NSObject, AVCapturePhotoCaptureDelegate {
    private var data: Data?
    private var captureError: Error?
    private let completion: (Data?, Error?) -> Void

    init(completion: @escaping (Data?, Error?) -> Void) {
        self.completion = completion
        super.init()
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        if let error = error {
            captureError = error
            return
        }
        data = photo.fileDataRepresentation()
    }

    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings,
                     error: Error?) {
        completion(data, captureError ?? error)
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
    private var audioInput: AVCaptureDeviceInput?
    private let photoOutput = AVCapturePhotoOutput()
    private let videoDataOutput = AVCaptureVideoDataOutput()
    private let audioDataOutput = AVCaptureAudioDataOutput()
    private let movieOutput = AVCaptureMovieFileOutput()
    private var observers: [NSKeyValueObservation] = []
    private var inflightPhotos: [Int64: PhotoCaptureDelegate] = [:]
    private var knownCaps = DeviceCapabilities()
    private var staticCapsComputed = false
    private var wantsRunning = false
    private var pendingReconfigure = false
    private var phase: RecordingPhase = .idle
    private var recordingKind: RecordingKind?
    private var runtimeObserver: NSObjectProtocol?

    /// Configuration mirror used on sessionQueue.
    private struct QueueConfig {
        var mode: CameraMode = .photo
        var look: LookPreset = .native
        var manual = ManualSettings()
        var video = VideoFormatSettings()
        var aperture: Float = 2.8
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

    // MARK: - Init

    init(lookRenderer: LookRendering) {
        self.lookRenderer = lookRenderer
        let ctx = CIContext(options: [.cacheIntermediates: false])
        self.ciContext = ctx
        self.photoProcessor = PhotoProcessor(renderer: lookRenderer, context: ctx)
        super.init()

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
                self.q.mode = snapshot.mode
                self.q.look = snapshot.look
                self.q.manual = snapshot.manual
                self.q.video = snapshot.video
                self.q.aperture = snapshot.simulatedAperture
                self.shared.setLook(snapshot.look)
                self.wantsRunning = true
                self.reconfigure()
                if !self.session.isRunning { self.session.startRunning() }
                self.publishRunning()
            }
        }
    }

    func stop() {
        sessionQueue.async { [self] in
            wantsRunning = false
            if phase == .recording { stopRecordingOnQueue() }
            if session.isRunning { session.stopRunning() }
            publishRunning()
        }
    }

    func set(mode: CameraMode) {
        guard mode != state.mode, !state.isRecording else { return }
        state.mode = mode
        sessionQueue.async { [self] in
            q.mode = mode
            reconfigure()
        }
    }

    func set(look: LookPreset) {
        state.look = look
        shared.setLook(look)
        sessionQueue.async { [self] in q.look = look }
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
        }
    }

    func set(simulatedAperture: Float) {
        state.simulatedAperture = simulatedAperture
        sessionQueue.async { [self] in
            q.aperture = simulatedAperture
            if q.mode == .cinematic, let input = videoInput, let dev = device {
                CinematicSupport.setAperture(simulatedAperture, input: input, device: dev)
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
        let aperture = state.simulatedAperture

        sessionQueue.async { [self] in
            guard session.isRunning, session.outputs.contains(photoOutput) else {
                publishError("Camera is not ready.")
                return
            }
            if let conn = photoOutput.connection(with: .video), conn.isVideoRotationAngleSupported(90) {
                conn.videoRotationAngle = 90
            }
            let settings = makePhotoSettings(mode: mode)
            let id = settings.uniqueID
            let delegate = PhotoCaptureDelegate { [weak self] data, error in
                self?.photoCaptureFinished(id: id, data: data, error: error,
                                           mode: mode, look: look, aperture: aperture)
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
        shared.setRecorder(nil)

        // Device + input
        guard let dev = CaptureFormats.captureDevice(for: mode),
              let input = try? AVCaptureDeviceInput(device: dev),
              session.canAddInput(input) else {
            session.commitConfiguration()
            publishError("No usable camera found.")
            return
        }
        session.addInput(input)
        videoInput = input
        device = dev

        // Static capabilities (computed once from the wide camera).
        computeStaticCapabilities()

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
            if session.canAddOutput(photoOutput) { session.addOutput(photoOutput) }
        }

        q.effective = effective
        session.commitConfiguration()

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
        // Make sure a previous Log / HLG selection does not leak into photo mode.
        if dev.activeColorSpace != .sRGB, CaptureFormats.supports(dev.activeFormat, colorSpace: .sRGB),
           (try? dev.lockForConfiguration()) != nil {
            dev.activeColorSpace = .sRGB
            dev.unlockForConfiguration()
        }
    }

    private func configureMovieOutput(effective: VideoFormatSettings) {
        guard session.outputs.contains(movieOutput) else { return }
        guard let conn = movieOutput.connection(with: .video) else { return }
        if conn.isVideoRotationAngleSupported(90) { conn.videoRotationAngle = 90 }

        let available = movieOutput.availableVideoCodecTypes
        let rawCodec = AVVideoCodecType(rawValue: "aprn")
        let rawHQCodec = AVVideoCodecType(rawValue: "aprh")

        var chosen: AVVideoCodecType?
        switch effective.codec {
        case .hevc: chosen = available.contains(.hevc) ? .hevc : nil
        case .proRes422HQ: chosen = available.contains(.proRes422HQ) ? .proRes422HQ : nil
        case .proResRAW: chosen = available.contains(rawCodec) ? rawCodec : nil
        case .proResRAWHQ: chosen = available.contains(rawHQCodec) ? rawHQCodec : nil
        }
        if let codec = chosen {
            movieOutput.setOutputSettings([AVVideoCodecKey: codec.rawValue], for: conn)
        } else if effective.codec != .hevc {
            publishError("\(effective.codec.title) is not available for this format; using HEVC.")
            if available.contains(.hevc) {
                movieOutput.setOutputSettings([AVVideoCodecKey: AVVideoCodecType.hevc.rawValue], for: conn)
            }
        }

        // Capabilities that can only be discovered from the connected movie output.
        if available.contains(.proRes422HQ) { knownCaps.proRes422HQ = true }
        if available.contains(rawCodec) || available.contains(rawHQCodec) { knownCaps.proResRAW = true }
    }

    // MARK: - Capabilities

    private func computeStaticCapabilities() {
        guard !staticCapsComputed else { return }
        staticCapsComputed = true
        if let wide = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) {
            knownCaps.appleLog = CaptureFormats.anyFormat(of: wide, supports: .appleLog)
            knownCaps.hlg = CaptureFormats.anyFormat(of: wide, supports: .HLG_BT2020)
            knownCaps.cinematic = CinematicSupport.deviceSupportsCinematic(wide)
        }
        knownCaps.portraitDepth = CaptureFormats.hasDepthCapableDevice()
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
        knownCaps.proRes422HQ = caps.proRes422HQ
        knownCaps.proResRAW = caps.proResRAW
        updateState { $0.capabilities = caps }
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
            let bias = min(max(q.manual.exposureBias, dev.minExposureTargetBias), dev.maxExposureTargetBias)
            dev.setExposureTargetBias(bias, completionHandler: nil)
        case .manual(let seconds, let iso):
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
        if photoOutput.availablePhotoCodecTypes.contains(.hevc) {
            settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.hevc.rawValue])
        } else {
            settings = AVCapturePhotoSettings()
        }
        settings.photoQualityPrioritization = .balanced
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

    private func photoCaptureFinished(id: Int64, data: Data?, error: Error?,
                                      mode: CameraMode, look: LookPreset, aperture: Float) {
        sessionQueue.async { [self] in inflightPhotos[id] = nil }

        guard let data = data else {
            publishError(error?.localizedDescription ?? "Photo capture failed.")
            return
        }
        processingQueue.async { [self] in
            let output = photoProcessor.process(data: data, mode: mode, look: look, aperture: aperture)
            LibrarySaver.savePhoto(data: output.data) { [weak self] ok, saveError in
                guard let self = self else { return }
                DispatchQueue.main.async {
                    self.state.isCapturingPhoto = false
                    if ok {
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
                audioSettings = audioDataOutput.recommendedAudioSettingsForAssetWriter(writingTo: .mov) as? [String: Any]
            }
            do {
                let recorder = try MovieRecorder(
                    url: CaptureFormats.temporaryMovieURL(),
                    width: w, height: h, frameRate: q.effective.frameRate,
                    hasAudio: audioInput != nil, audioSettings: audioSettings,
                    renderer: lookRenderer, context: ciContext,
                    metadata: CaptureFormats.lookMetadata(look))
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
            if let conn = movieOutput.connection(with: .video), conn.isVideoRotationAngleSupported(90) {
                conn.videoRotationAngle = 90
            }
            movieOutput.metadata = CaptureFormats.lookMetadata(look)
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
            LibrarySaver.saveVideo(url: url) { ok, saveError in
                guard let self = self else { return }
                DispatchQueue.main.async {
                    if ok {
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
                                       look: snap.look, isLog: snap.isLog)
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
