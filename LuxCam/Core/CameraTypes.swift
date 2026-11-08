//  CameraTypes.swift
//  Shared contract between Capture / Looks / Preview / UI modules.
//  Do not change signatures here without updating every module.

import AVFoundation
import CoreImage
import CoreMedia
import UIKit

// MARK: - Modes

enum CameraMode: String, CaseIterable, Identifiable {
    case cinematic, video, photo, portrait
    var id: String { rawValue }
    var title: String { rawValue.uppercased() }
    var isVideo: Bool { self == .video || self == .cinematic }
}

// MARK: - Looks (original approximations, not proprietary LUTs)

enum LookFamily: String, CaseIterable, Identifiable {
    case native, leica, hasselblad, sigma
    var id: String { rawValue }
    var title: String {
        switch self {
        case .native: return "iOS"
        case .leica: return "LEICA"
        case .hasselblad: return "HASSELBLAD"
        case .sigma: return "SIGMA"
        }
    }
}

enum LookPreset: String, CaseIterable, Identifiable {
    case native
    case leicaClassic, leicaContemporary, leicaMonochrome
    case hasselbladNatural, hasselbladPortrait
    case sigmaTealOrange, sigmaWarmGold, sigmaPowderBlue, sigmaMonochrome

    var id: String { rawValue }

    var family: LookFamily {
        switch self {
        case .native: return .native
        case .leicaClassic, .leicaContemporary, .leicaMonochrome: return .leica
        case .hasselbladNatural, .hasselbladPortrait: return .hasselblad
        case .sigmaTealOrange, .sigmaWarmGold, .sigmaPowderBlue, .sigmaMonochrome: return .sigma
        }
    }

    var title: String {
        switch self {
        case .native: return "STANDARD"
        case .leicaClassic: return "CLASSIC"
        case .leicaContemporary: return "CONTEMPORARY"
        case .leicaMonochrome: return "MONOCHROM"
        case .hasselbladNatural: return "NATURAL"
        case .hasselbladPortrait: return "PORTRAIT"
        case .sigmaTealOrange: return "TEAL & ORANGE"
        case .sigmaWarmGold: return "WARM GOLD"
        case .sigmaPowderBlue: return "POWDER BLUE"
        case .sigmaMonochrome: return "MONO"
        }
    }

    static func presets(in family: LookFamily) -> [LookPreset] {
        allCases.filter { $0.family == family }
    }
}

// MARK: - Manual controls

struct ManualSettings: Equatable {
    enum Focus: Equatable {
        case auto
        case manual(lensPosition: Float)            // 0.0 (near) ... 1.0 (far)
    }
    enum Exposure: Equatable {
        case auto
        case manual(durationSeconds: Double, iso: Float)
    }
    var focus: Focus = .auto
    var exposure: Exposure = .auto
    /// Exposure bias in EV, used only while exposure == .auto.
    var exposureBias: Float = 0
}

// MARK: - Video recording formats

enum VideoCodecOption: String, CaseIterable, Identifiable {
    case hevc, proRes422HQ, proRes422, proRes422LT, proRes422Proxy, proResRAW, proResRAWHQ
    var id: String { rawValue }
    var title: String {
        switch self {
        case .hevc: return "HEVC"
        case .proRes422HQ: return "ProRes 422 HQ"
        case .proRes422: return "ProRes 422"
        case .proRes422LT: return "ProRes 422 LT"
        case .proRes422Proxy: return "ProRes 422 Proxy"
        case .proResRAW: return "ProRes RAW"
        case .proResRAWHQ: return "ProRes RAW HQ"
        }
    }
    var isRAW: Bool { self == .proResRAW || self == .proResRAWHQ }
    var isProRes: Bool { self != .hevc }
    /// AVFoundation codec type. RAW uses raw FourCCs so we never reference symbols missing in older SDKs.
    var avCodecType: AVVideoCodecType {
        switch self {
        case .hevc: return .hevc
        case .proRes422HQ: return .proRes422HQ
        case .proRes422: return .proRes422
        case .proRes422LT: return .proRes422LT
        case .proRes422Proxy: return .proRes422Proxy
        case .proResRAW: return AVVideoCodecType(rawValue: "aprn")
        case .proResRAWHQ: return AVVideoCodecType(rawValue: "aprh")
        }
    }
}

enum VideoColorProfile: String, CaseIterable, Identifiable {
    case standard, hlg, appleLog
    var id: String { rawValue }
    var title: String {
        switch self {
        case .standard: return "SDR"
        case .hlg: return "HDR"
        case .appleLog: return "LOG"
        }
    }
}

struct VideoFormatSettings: Equatable {
    var codec: VideoCodecOption = .hevc
    var color: VideoColorProfile = .standard
    var resolution4K: Bool = true
    var frameRate: Int = 30                 // 24 / 25 / 30 / 60 / 120
    /// When true, the selected look is rendered into the recorded file (AVAssetWriter, 8-bit SDR HEVC).
    /// HDR / RAW / ProRes / Log keep the source untouched and store the look name as metadata only.
    /// Real-time Core Image baking is limited to <= 30 fps to avoid dropped frames.
    var bakesLook: Bool { codec == .hevc && color == .standard && frameRate <= 30 }
}

// MARK: - Photo formats

enum PhotoFormat: String, CaseIterable, Identifiable {
    case heif, proRAW
    var id: String { rawValue }
    var title: String { self == .heif ? "HEIF" : "ProRAW" }
}

// MARK: - Capabilities

struct DeviceCapabilities: Equatable {
    /// Codecs usable with the current device/format (always contains .hevc).
    var supportedCodecs: Set<VideoCodecOption> = [.hevc]
    /// Frame rates (from 24/25/30/60/120) the device supports at the selected resolution.
    var supportedFrameRates: [Int] = [24, 25, 30, 60]
    /// Apple ProRAW still capture (iPhone 12 Pro and later Pro models).
    var proRAW = false
    var proRes422HQ: Bool { supportedCodecs.contains(.proRes422HQ) }
    var proResRAW: Bool { supportedCodecs.contains(.proResRAW) }
    var appleLog = false
    var hlg = false
    var cinematic = false
    var portraitDepth = false
    var manualFocus = true
    var isoRange: ClosedRange<Float> = 50...1600
    var exposureRange: ClosedRange<Double> = (1.0 / 8000.0)...(1.0 / 3.0)
    var exposureBiasRange: ClosedRange<Float> = -2...2
    /// Largest zoom factor of the active camera (for information only).
    var maxZoomFactor: CGFloat = 1
}

// MARK: - Observable state

struct CameraState: Equatable {
    var mode: CameraMode = .photo
    var look: LookPreset = .native
    var manual = ManualSettings()
    var video = VideoFormatSettings()
    var photoFormat: PhotoFormat = .heif
    /// Emulated camera body + lens (see Gear.swift).
    var gear = GearSelection()
    var capabilities = DeviceCapabilities()
    /// Simulated aperture (f-number) for PORTRAIT / CINEMATIC.
    var simulatedAperture: Float = 2.8

    var isSessionRunning = false
    var isRecording = false
    var recordingSeconds: Double = 0
    /// True from the shutter press until the sensor has captured the frame (didCapturePhoto).
    /// Processing / saving continues in the background and does not block the next shot.
    var isCapturingPhoto = false
    /// Incremented at the exact moment the sensor captures (willCapturePhoto) — drives the shutter flash.
    var shutterCount = 0
    /// Photos captured but not yet processed/saved (the shutter is blocked at 3 to bound memory).
    var pendingPhotos = 0

    /// Live readouts from the device (KVO), for HUD display.
    var liveISO: Float = 0
    var liveShutterSeconds: Double = 0
    var liveLensPosition: Float = 0
    /// Current videoZoomFactor of the active camera.
    var liveZoomFactor: CGFloat = 1

    /// True when the current preview frames are Apple Log encoded (Preview should normalise for display).
    var previewIsLog = false

    var lastThumbnail: UIImage?
    /// Photos-library local identifiers of assets captured by LuxCam, newest first (persisted, max 500).
    var recentAssetIDs: [String] = []
    var errorMessage: String?
}

// MARK: - Capture -> render hand-off

/// Thread-safe "latest frame" mailbox. Capture queue pushes, the Metal draw loop takes.
final class PreviewFrameSource: @unchecked Sendable {
    private let lock = NSLock()
    private var _latest: CVPixelBuffer?
    private var _isLog = false

    func push(_ pixelBuffer: CVPixelBuffer, isLog: Bool) {
        lock.lock(); _latest = pixelBuffer; _isLog = isLog; lock.unlock()
    }

    /// Returns the latest frame (without clearing it, so the view can redraw).
    func latest() -> (buffer: CVPixelBuffer, isLog: Bool)? {
        lock.lock(); defer { lock.unlock() }
        guard let b = _latest else { return nil }
        return (b, _isLog)
    }
}

// MARK: - Look rendering contract

protocol LookRendering: AnyObject {
    /// Applies `preset` to `image`. If `isLogSource` is true the image is first converted
    /// from Apple Log to a Rec.709-ish display curve (monitoring approximation).
    /// Must be thread-safe (called from capture queue and render thread).
    func apply(_ preset: LookPreset, to image: CIImage, isLogSource: Bool) -> CIImage

    /// Applies the colour look, then the body character (saturation/contrast/warmth/shadow tint/grain)
    /// and the lens character (vignette, bloom, sharpness, wide-open softness).
    /// `gear` nil = look only. `aperture` is the simulated f-number (wide-open softness); nil = ignore.
    /// `cheap` = true for real-time paths that must stay fast (baked 4K recording: no bloom, no grain).
    func apply(_ preset: LookPreset, gear: GearSelection?, aperture: Float?, cheap: Bool,
               to image: CIImage, isLogSource: Bool) -> CIImage
}

extension LookRendering {
    /// Default: gear ignored (modules can migrate independently).
    func apply(_ preset: LookPreset, gear: GearSelection?, aperture: Float?, cheap: Bool,
               to image: CIImage, isLogSource: Bool) -> CIImage {
        apply(preset, to: image, isLogSource: isLogSource)
    }
}
