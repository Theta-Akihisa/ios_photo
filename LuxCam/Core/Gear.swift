//  Gear.swift
//  Camera body + lens emulation profiles (shared contract).
//
//  These are ORIGINAL approximations inspired by the general character of each camera
//  system. They are not affiliated with, endorsed by, or calibrated against any manufacturer.

import CoreGraphics
import Foundation

/// Rendering character of a lens, applied after the colour look.
struct LensCharacter: Equatable {
    /// 0...1 corner darkening.
    var vignette: Float = 0
    /// 0...1 highlight glow / halation.
    var bloom: Float = 0
    /// 0...1 micro-contrast (luminance sharpening).
    var sharpness: Float = 0
    /// 0...1 extra softness/glow when the simulated aperture is near wide open.
    var softnessWideOpen: Float = 0

    static let neutral = LensCharacter()
}

enum CameraBody: String, CaseIterable, Identifiable, Codable {
    case iphone
    case leicaM11, leicaM11Monochrom, leicaQ3, leicaSL3
    case hasselbladX2D, hasselblad907X

    var id: String { rawValue }

    var family: LookFamily {
        switch self {
        case .iphone: return .native
        case .leicaM11, .leicaM11Monochrom, .leicaQ3, .leicaSL3: return .leica
        case .hasselbladX2D, .hasselblad907X: return .hasselblad
        }
    }

    var title: String {
        switch self {
        case .iphone: return "iPhone"
        case .leicaM11: return "M11"
        case .leicaM11Monochrom: return "M11 Monochrom"
        case .leicaQ3: return "Q3"
        case .leicaSL3: return "SL3"
        case .hasselbladX2D: return "X2D 100C"
        case .hasselblad907X: return "907X CFV 100C"
        }
    }

    /// Short label for the top bar.
    var shortTitle: String {
        switch self {
        case .iphone: return "iPhone"
        case .leicaM11: return "M11"
        case .leicaM11Monochrom: return "M11 MONO"
        case .leicaQ3: return "Q3"
        case .leicaSL3: return "SL3"
        case .hasselbladX2D: return "X2D"
        case .hasselblad907X: return "907X"
        }
    }

    /// Photo aspect ratio as landscape width / height (invert for portrait).
    var photoAspect: CGFloat {
        switch family {
        case .leica: return 3.0 / 2.0
        default: return 4.0 / 3.0
        }
    }

    var isMonochrome: Bool { self == .leicaM11Monochrom }

    var defaultLook: LookPreset {
        switch self {
        case .iphone: return .native
        case .leicaM11: return .leicaClassic
        case .leicaM11Monochrom: return .leicaMonochrome
        case .leicaQ3: return .leicaContemporary
        case .leicaSL3: return .leicaContemporary
        case .hasselbladX2D: return .hasselbladNatural
        case .hasselblad907X: return .hasselbladNatural
        }
    }

    /// Looks this body may use. Monochrom bodies are B&W only.
    func allows(_ look: LookPreset) -> Bool {
        if isMonochrome { return look == .leicaMonochrome || look == .sigmaMonochrome }
        return true
    }

    var lenses: [LensProfile] {
        switch self {
        case .iphone: return [.iphone13, .iphone24, .iphone48, .iphone120]
        case .leicaM11, .leicaM11Monochrom:
            return [.summicronM28, .summiluxM35, .noctiluxM50, .apoSummicronM90]
        case .leicaQ3: return [.q3Summilux28]
        case .leicaSL3: return [.slApoSummicron35, .slApoSummicron50, .summiluxM35, .noctiluxM50]
        case .hasselbladX2D, .hasselblad907X: return [.xcd25V, .xcd38V, .xcd55V, .xcd90V]
        }
    }

    var defaultLens: LensProfile {
        switch self {
        case .iphone: return .iphone24
        case .leicaM11, .leicaM11Monochrom: return .summiluxM35
        case .leicaQ3: return .q3Summilux28
        case .leicaSL3: return .slApoSummicron50
        case .hasselbladX2D, .hasselblad907X: return .xcd55V
        }
    }

    /// Bodies shown in the picker, grouped by family.
    static func bodies(in family: LookFamily) -> [CameraBody] {
        allCases.filter { $0.family == family }
    }
}

enum LensProfile: String, CaseIterable, Identifiable, Codable {
    // iPhone 16 Pro native focal lengths
    case iphone13, iphone24, iphone48, iphone120
    // Leica M
    case summicronM28, summiluxM35, noctiluxM50, apoSummicronM90
    // Leica Q3 (fixed lens)
    case q3Summilux28
    // Leica SL
    case slApoSummicron35, slApoSummicron50
    // Hasselblad XCD (medium format, ×0.79 crop already applied to focalLength35mm)
    case xcd25V, xcd38V, xcd55V, xcd90V

    var id: String { rawValue }

    var title: String {
        switch self {
        case .iphone13: return "Ultra Wide 13mm"
        case .iphone24: return "Main 24mm"
        case .iphone48: return "2× 48mm"
        case .iphone120: return "Telephoto 120mm"
        case .summicronM28: return "Summicron-M 28 f/2"
        case .summiluxM35: return "Summilux-M 35 f/1.4"
        case .noctiluxM50: return "Noctilux-M 50 f/0.95"
        case .apoSummicronM90: return "APO-Summicron-M 90 f/2"
        case .q3Summilux28: return "Summilux 28 f/1.7 ASPH"
        case .slApoSummicron35: return "APO-Summicron-SL 35 f/2"
        case .slApoSummicron50: return "APO-Summicron-SL 50 f/2"
        case .xcd25V: return "XCD 25V f/2.5"
        case .xcd38V: return "XCD 38V f/2.5"
        case .xcd55V: return "XCD 55V f/2.5"
        case .xcd90V: return "XCD 90V f/2.5"
        }
    }

    /// Short label for the top bar, e.g. "SUMMILUX 35".
    var shortTitle: String {
        switch self {
        case .iphone13: return "13mm"
        case .iphone24: return "24mm"
        case .iphone48: return "48mm"
        case .iphone120: return "120mm"
        case .summicronM28: return "SUMMICRON 28"
        case .summiluxM35: return "SUMMILUX 35"
        case .noctiluxM50: return "NOCTILUX 50"
        case .apoSummicronM90: return "APO 90"
        case .q3Summilux28: return "SUMMILUX 28"
        case .slApoSummicron35: return "APO-SL 35"
        case .slApoSummicron50: return "APO-SL 50"
        case .xcd25V: return "XCD 25V"
        case .xcd38V: return "XCD 38V"
        case .xcd55V: return "XCD 55V"
        case .xcd90V: return "XCD 90V"
        }
    }

    /// 35mm-equivalent focal length used to pick the iPhone camera and zoom factor.
    var focalLength35mm: Double {
        switch self {
        case .iphone13: return 13
        case .iphone24: return 24
        case .iphone48: return 48
        case .iphone120: return 120
        case .summicronM28, .q3Summilux28: return 28
        case .summiluxM35, .slApoSummicron35: return 35
        case .noctiluxM50, .slApoSummicron50: return 50
        case .apoSummicronM90: return 90
        case .xcd25V: return 20
        case .xcd38V: return 30
        case .xcd55V: return 43
        case .xcd90V: return 71
        }
    }

    /// Widest aperture; lower bound of the simulated-aperture dial (PORTRAIT / CINEMATIC).
    /// Note: depth-blur filters clamp to about f/1.0, so f/0.95 is rendered as f/1.0.
    var maxAperture: Float {
        switch self {
        case .iphone13: return 2.2
        case .iphone24: return 1.78
        case .iphone48: return 1.78
        case .iphone120: return 2.8
        case .summicronM28: return 2.0
        case .summiluxM35: return 1.4
        case .noctiluxM50: return 0.95
        case .apoSummicronM90: return 2.0
        case .q3Summilux28: return 1.7
        case .slApoSummicron35, .slApoSummicron50: return 2.0
        case .xcd25V, .xcd38V, .xcd55V, .xcd90V: return 2.5
        }
    }

    var character: LensCharacter {
        switch self {
        case .iphone13, .iphone24, .iphone48, .iphone120:
            return .neutral
        case .summicronM28:
            return LensCharacter(vignette: 0.35, bloom: 0.05, sharpness: 0.45, softnessWideOpen: 0.1)
        case .summiluxM35:
            return LensCharacter(vignette: 0.45, bloom: 0.15, sharpness: 0.35, softnessWideOpen: 0.35)
        case .noctiluxM50:
            return LensCharacter(vignette: 0.6, bloom: 0.45, sharpness: 0.15, softnessWideOpen: 0.7)
        case .apoSummicronM90:
            return LensCharacter(vignette: 0.2, bloom: 0.0, sharpness: 0.7, softnessWideOpen: 0.05)
        case .q3Summilux28:
            return LensCharacter(vignette: 0.3, bloom: 0.1, sharpness: 0.5, softnessWideOpen: 0.2)
        case .slApoSummicron35, .slApoSummicron50:
            return LensCharacter(vignette: 0.15, bloom: 0.0, sharpness: 0.65, softnessWideOpen: 0.05)
        case .xcd25V, .xcd38V, .xcd55V, .xcd90V:
            return LensCharacter(vignette: 0.15, bloom: 0.05, sharpness: 0.4, softnessWideOpen: 0.1)
        }
    }
}

struct GearSelection: Equatable, Codable {
    var body: CameraBody = .iphone
    var lens: LensProfile = .iphone24

    /// Returns a selection whose lens belongs to the body.
    func normalized() -> GearSelection {
        var g = self
        if !body.lenses.contains(lens) { g.lens = body.defaultLens }
        return g
    }
}
