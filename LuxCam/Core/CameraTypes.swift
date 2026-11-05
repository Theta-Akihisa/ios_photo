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
    case hevc, proRes422HQ, proResRAW, proResRAWHQ
    var id: String { rawValue }
    var title: String {
        switch self {
        case .hevc: return "HEVC"
        case .proRes422HQ: return "ProRes 422 HQ"
        case .proResRAW: return "ProRes RAW"
        case .proResRAWHQ: return "ProRes RAW HQ"
        }
    }
    var isRAW: Bool { self == .proResRAW || self == .proResRAWHQ }
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
    var frameRate: Int = 30
    /// When true, the selected look is rendered into the recorded file (AVAssetWriter path).
    /// RAW / ProRes / Log keep the source untouched and store the look name as metadata only.
    var bakesLook: Bool { codec == .hevc && color != .appleLog }
}

// MARK: - Capabilities

struct DeviceCapabilities: Equatable {
    var proRes422HQ = false
    var proResRAW = false
    var appleLog = false
    var hlg = false
    var cinematic = false
    var portraitDepth = false
    var manualFocus = true
    var isoRange: ClosedRange<Float> = 50...1600
    var exposureRange: ClosedRange<Double> = (1.0 / 8000.0)...(1.0 / 3.0)
    var exposureBiasRange: ClosedRange<Float> = -2...2
}

// MARK: - Observable state

struct CameraState: Equatable {
    var mode: CameraMode = .photo
    var look: LookPreset = .native
    var manual = ManualSettings()
    var video = VideoFormatSettings()
    var capabilities = DeviceCapabilities()
    /// Simulated aperture (f-number) for PORTRAIT / CINEMATIC.
    var simulatedAperture: Float = 2.8

    var isSessionRunning = false
    var isRecording = false
    var recordingSeconds: Double = 0
    var isCapturingPhoto = false

    /// Live readouts from the device (KVO), for HUD display.
    var liveISO: Float = 0
    var liveShutterSeconds: Double = 0
    var liveLensPosition: Float = 0

    /// True when the current preview frames are Apple Log encoded (Preview should normalise for display).
    var previewIsLog = false

    var lastThumbnail: UIImage?
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
}
