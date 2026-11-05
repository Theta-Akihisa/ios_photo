//  LookRecipes.swift
//  Original, subjective grade recipes. Names containing "inspired" describe a general
//  character only; these are NOT the manufacturers' LUTs or colour pipelines.

import Foundation
import simd

extension LookPreset {
    /// Grade recipe for this preset; nil for `.native` (identity).
    var gradeParams: GradeParams? {
        switch self {
        case .native:
            return nil

        case .leicaClassic:
            // "Leica Looks Classic"-inspired: deep contrast, muted rich greens, warm skin,
            // gentle highlight roll-off, slightly crushed blacks.
            var p = GradeParams()
            p.contrast = 0.45; p.pivot = 0.48
            p.blackLift = -0.07
            p.highlightKnee = 0.72; p.highlightRolloff = 0.35
            p.saturation = 0.95
            p.warmth = 0.12
            p.hueAdjustments = [
                HueAdjust(center: 110, width: 50, sat: -0.20, shift: -8),   // greens: muted, toward yellow
                HueAdjust(center: 22, width: 40, sat: 0.08, shift: 2),      // warm skin
                HueAdjust(center: 225, width: 50, sat: -0.05, shift: 0)     // blues
            ]
            p.shadowTint = SIMD3(-0.004, 0.004, 0.010)
            p.highlightTint = SIMD3(0.012, 0.006, -0.008)
            return p

        case .leicaContemporary:
            // "Leica Looks Contemporary"-inspired: punchy, clean whites, bluer skies, crisp.
            var p = GradeParams()
            p.contrast = 0.40
            p.blackLift = -0.02
            p.highlightKnee = 0.85; p.highlightRolloff = 0.15
            p.saturation = 1.12
            p.warmth = -0.03
            p.hueAdjustments = [
                HueAdjust(center: 215, width: 55, sat: 0.20, shift: 8),     // skies: deeper blue
                HueAdjust(center: 15, width: 35, sat: 0.06, shift: 0),
                HueAdjust(center: 120, width: 50, sat: 0.03, shift: 0)
            ]
            return p

        case .leicaMonochrome:
            // Leica Monochrom-inspired: high-contrast B&W, deep-yellow-filter style mix, rich blacks.
            var p = GradeParams()
            p.monochrome = true
            p.channelMix = SIMD3(0.50, 0.42, 0.08)
            p.contrast = 0.70; p.pivot = 0.50
            p.blackLift = -0.08
            p.highlightKnee = 0.80; p.highlightRolloff = 0.25
            return p

        case .hasselbladNatural:
            // "HNCS"-inspired: neutral, accurate, low contrast, smooth tonal transition.
            var p = GradeParams()
            p.contrast = 0.08
            p.blackLift = 0.01
            p.highlightKnee = 0.70; p.highlightRolloff = 0.30
            p.saturation = 0.92
            p.hueAdjustments = [
                HueAdjust(center: 25, width: 35, sat: 0.03, shift: 0)       // natural skin
            ]
            return p

        case .hasselbladPortrait:
            // Soft contrast, warm pleasing skin, lowered green/magenta, lifted shadows.
            var p = GradeParams()
            p.contrast = -0.10
            p.blackLift = 0.04
            p.highlightKnee = 0.75; p.highlightRolloff = 0.25
            p.saturation = 0.95
            p.warmth = 0.10
            p.hueAdjustments = [
                HueAdjust(center: 120, width: 55, sat: -0.25, shift: -6),
                HueAdjust(center: 315, width: 40, sat: -0.20, shift: 0),
                HueAdjust(center: 25, width: 35, sat: 0.05, shift: 0)
            ]
            p.shadowTint = SIMD3(0.006, 0.002, 0.000)
            p.highlightTint = SIMD3(0.010, 0.005, -0.004)
            return p

        case .sigmaTealOrange:
            // SIGMA fp "Teal and Orange" colour-mode-inspired: skin -> orange, shadows/blues -> teal.
            var p = GradeParams()
            p.contrast = 0.35
            p.saturation = 1.05
            p.hueAdjustments = [
                HueAdjust(center: 28, width: 35, sat: 0.25, shift: 6),      // skin toward orange
                HueAdjust(center: 215, width: 60, sat: 0.10, shift: -25),   // blues toward teal
                HueAdjust(center: 180, width: 40, sat: 0.15, shift: 0),
                HueAdjust(center: 120, width: 50, sat: -0.20, shift: -15)
            ]
            p.shadowTint = SIMD3(-0.020, 0.012, 0.022)
            p.highlightTint = SIMD3(0.030, 0.012, -0.020)
            return p

        case .sigmaWarmGold:
            // Warm golden tint with faded blacks.
            var p = GradeParams()
            p.contrast = 0.15
            p.blackLift = 0.05
            p.saturation = 0.95
            p.warmth = 0.30
            p.hueAdjustments = [
                HueAdjust(center: 55, width: 40, sat: 0.15, shift: 0),
                HueAdjust(center: 225, width: 55, sat: -0.25, shift: 0)
            ]
            p.shadowTint = SIMD3(0.020, 0.010, -0.005)
            p.highlightTint = SIMD3(0.040, 0.025, -0.030)
            return p

        case .sigmaPowderBlue:
            // Cool pastel: low saturation, lifted blacks, blue cast.
            var p = GradeParams()
            p.contrast = -0.10
            p.blackLift = 0.07
            p.saturation = 0.72
            p.warmth = -0.20
            p.hueAdjustments = [
                HueAdjust(center: 10, width: 40, sat: -0.20, shift: 0),
                HueAdjust(center: 225, width: 50, sat: 0.10, shift: 0)
            ]
            p.shadowTint = SIMD3(-0.005, 0.008, 0.030)
            p.highlightTint = SIMD3(-0.004, 0.002, 0.015)
            return p

        case .sigmaMonochrome:
            // Soft, low-contrast B&W with slightly lifted blacks.
            var p = GradeParams()
            p.monochrome = true
            p.channelMix = SIMD3(0.30, 0.59, 0.11)
            p.contrast = 0.05
            p.blackLift = 0.04
            p.highlightKnee = 0.75; p.highlightRolloff = 0.20
            return p
        }
    }
}
