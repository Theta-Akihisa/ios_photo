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

/// Sensor / colour-science character of a body, applied together with the lens character.
struct BodyCharacter: Equatable {
    /// Added to saturation (e.g. 0.1 = +10 %).
    var saturation: Float = 0
    /// Added to contrast around mid-grey.
    var contrast: Float = 0
    /// Positive = warmer, negative = cooler (small values, ~±0.1).
    var warmth: Float = 0
    /// Positive = magenta cast in the shadows (M8 IR sensitivity), negative = green.
    var shadowMagenta: Float = 0
    /// 0...1 luminance grain.
    var grain: Float = 0

    static let neutral = BodyCharacter()
}

enum CameraBody: String, CaseIterable, Identifiable, Codable {
    case iphone
    case leicaM11, leicaM11Monochrom, leicaM10, leicaM9, leicaM8, leicaSL3, leicaSL3S
    case hasselbladX2D, hasselblad907X

    var id: String { rawValue }

    var family: LookFamily {
        switch self {
        case .iphone: return .native
        case .leicaM11, .leicaM11Monochrom, .leicaM10, .leicaM9, .leicaM8, .leicaSL3, .leicaSL3S:
            return .leica
        case .hasselbladX2D, .hasselblad907X: return .hasselblad
        }
    }

    var title: String {
        switch self {
        case .iphone: return "iPhone"
        case .leicaM11: return "M11"
        case .leicaM11Monochrom: return "M11 Monochrom"
        case .leicaM10: return "M10"
        case .leicaM9: return "M9"
        case .leicaM8: return "M8"
        case .leicaSL3: return "SL3"
        case .leicaSL3S: return "SL3-S"
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
        case .leicaM10: return "M10"
        case .leicaM9: return "M9"
        case .leicaM8: return "M8"
        case .leicaSL3: return "SL3"
        case .leicaSL3S: return "SL3-S"
        case .hasselbladX2D: return "X2D"
        case .hasselblad907X: return "907X"
        }
    }

    /// One-line Japanese description for the picker.
    var subtitle: String {
        switch self {
        case .iphone: return "iPhone 純正の描写"
        case .leicaM11: return "60MP フルサイズ CMOS・現代的でクリーン"
        case .leicaM11Monochrom: return "モノクロ専用センサー・豊かな階調"
        case .leicaM10: return "24MP CMOS・落ち着いたクラシックな色"
        case .leicaM9: return "18MP CCD・濃密で深い色乗り"
        case .leicaM8: return "10MP CCD（APS-H ×1.33）・独特の発色と粒状感"
        case .leicaSL3: return "60MP ミラーレス・高精細でニュートラル"
        case .leicaSL3S: return "24MP ミラーレス・動画向け、ニュートラル"
        case .hasselbladX2D: return "100MP 中判・HNCS 風の自然な色"
        case .hasselblad907X: return "100MP 中判デジタルバック・柔らかな階調"
        }
    }

    /// Sensor size relative to 35mm full frame (35mm-equivalent = focal length × cropFactor).
    var cropFactor: Double {
        switch self {
        case .iphone: return 1.0          // iPhone lenses are already given as equivalents
        case .leicaM8: return 1.33        // APS-H
        case .hasselbladX2D, .hasselblad907X: return 0.79   // 44×33 medium format
        default: return 1.0
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

    var character: BodyCharacter {
        switch self {
        case .iphone, .leicaSL3, .leicaSL3S, .hasselbladX2D:
            return .neutral
        case .leicaM11:
            return BodyCharacter(saturation: 0.02, contrast: 0.02)
        case .leicaM11Monochrom:
            return BodyCharacter(contrast: 0.04, grain: 0.08)
        case .leicaM10:
            return BodyCharacter(saturation: -0.02, contrast: 0.03, warmth: 0.03, grain: 0.05)
        case .leicaM9:
            // CCD: dense, rich colour; deeper reds/blues, a touch more contrast.
            return BodyCharacter(saturation: 0.12, contrast: 0.08, warmth: 0.02, grain: 0.12)
        case .leicaM8:
            // CCD with weak IR filtering: slightly magenta shadows, more noise.
            return BodyCharacter(saturation: 0.08, contrast: 0.06, warmth: -0.01, shadowMagenta: 0.06, grain: 0.25)
        case .hasselblad907X:
            return BodyCharacter(saturation: -0.03, contrast: -0.03, warmth: 0.01)
        }
    }

    var defaultLook: LookPreset {
        switch self {
        case .iphone: return .native
        case .leicaM11, .leicaM10, .leicaM9, .leicaM8: return .leicaClassic
        case .leicaM11Monochrom: return .leicaMonochrome
        case .leicaSL3, .leicaSL3S: return .leicaContemporary
        case .hasselbladX2D, .hasselblad907X: return .hasselbladNatural
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
        case .leicaM11, .leicaM11Monochrom, .leicaM10, .leicaM9, .leicaM8:
            return [.summicronM28, .summiluxM35, .noctiluxM50, .apoSummicronM90]
        case .leicaSL3, .leicaSL3S:
            // SL lenses plus M lenses via the M-L adapter.
            return [.slApoSummicron35, .slApoSummicron50, .summicronM28, .summiluxM35, .noctiluxM50, .apoSummicronM90]
        case .hasselbladX2D, .hasselblad907X: return [.xcd25V, .xcd38V, .xcd55V, .xcd90V]
        }
    }

    var defaultLens: LensProfile {
        switch self {
        case .iphone: return .iphone24
        case .leicaM11, .leicaM11Monochrom, .leicaM10, .leicaM9: return .summiluxM35
        case .leicaM8: return .summicronM28      // ≈ 37mm equivalent on APS-H
        case .leicaSL3, .leicaSL3S: return .slApoSummicron50
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
    // Leica SL
    case slApoSummicron35, slApoSummicron50
    // Hasselblad XCD (medium format; real focal lengths, body cropFactor 0.79)
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
        case .slApoSummicron35: return "APO-SL 35"
        case .slApoSummicron50: return "APO-SL 50"
        case .xcd25V: return "XCD 25V"
        case .xcd38V: return "XCD 38V"
        case .xcd55V: return "XCD 55V"
        case .xcd90V: return "XCD 90V"
        }
    }

    /// Real focal length in mm (for iPhone lenses: the 35mm-equivalent marketing value).
    var focalLength: Double {
        switch self {
        case .iphone13: return 13
        case .iphone24: return 24
        case .iphone48: return 48
        case .iphone120: return 120
        case .summicronM28: return 28
        case .summiluxM35, .slApoSummicron35: return 35
        case .noctiluxM50, .slApoSummicron50: return 50
        case .apoSummicronM90: return 90
        case .xcd25V: return 25
        case .xcd38V: return 38
        case .xcd55V: return 55
        case .xcd90V: return 90
        }
    }

    /// 35mm-equivalent focal length on `body`; selects the iPhone camera and zoom factor.
    func equivalentFocalLength(on body: CameraBody) -> Double {
        focalLength * body.cropFactor
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
