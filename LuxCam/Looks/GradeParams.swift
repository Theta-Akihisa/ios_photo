//  GradeParams.swift
//  Original procedural grading model used to build the colour cubes.
//  Nothing here is derived from, or claims to match, any proprietary LUT or colour science.
//  The "-inspired" looks are our own subjective approximations of a general character.

import Foundation
import simd

// MARK: - Small math helpers

@inline(__always) func lc_clamp01(_ x: Float) -> Float { min(max(x, 0), 1) }

@inline(__always) func lc_smoothstep(_ a: Float, _ b: Float, _ x: Float) -> Float {
    let t = lc_clamp01((x - a) / (b - a))
    return t * t * (3 - 2 * t)
}

// MARK: - Per-hue adjustment

/// A localized adjustment around a hue angle (degrees; 0 red, 60 yellow, 120 green,
/// 180 cyan, 240 blue, 300 magenta). The weight uses a raised-cosine window so there
/// are no hue discontinuities.
struct HueAdjust {
    var center: Float           // degrees
    var width: Float            // half-width of the window in degrees
    var sat: Float = 0          // added to saturation factor (e.g. -0.2 = 20% less saturated)
    var shift: Float = 0        // hue rotation in degrees (+ moves red -> yellow -> green)

    /// Smooth 0...1 weight for hue `h` (degrees).
    func weight(_ h: Float) -> Float {
        var d = abs(h - center).truncatingRemainder(dividingBy: 360)
        if d > 180 { d = 360 - d }
        if d >= width { return 0 }
        return 0.5 * (1 + cos(Float.pi * d / width))
    }
}

// MARK: - Grade model

/// Parametric grade evaluated on gamma-encoded sRGB values (0...1).
struct GradeParams {
    // Tone
    var contrast: Float = 0             // S-curve blend; 0 = none, negative flattens
    var pivot: Float = 0.5              // S-curve pivot
    var blackLift: Float = 0            // >0 lifts (faded) blacks, <0 crushes deep blacks
    var highlightKnee: Float = 0.75     // where highlight roll-off starts
    var highlightRolloff: Float = 0     // 0...~0.6, softens the shoulder (white stays white)

    // Colour
    var saturation: Float = 1
    var hueAdjustments: [HueAdjust] = []
    var warmth: Float = 0               // + warm (more red / less blue), - cool
    var shadowTint = SIMD3<Float>(repeating: 0)     // added in shadows (small, e.g. 0.02)
    var highlightTint = SIMD3<Float>(repeating: 0)  // added in highlights
    var splitBalance: Float = 0         // -1...1, moves the shadow/highlight crossover

    // Monochrome
    var monochrome = false
    var channelMix = SIMD3<Float>(0.2126, 0.7152, 0.0722)

    static let lumaWeights = SIMD3<Float>(0.2126, 0.7152, 0.0722)

    // MARK: Tone curve

    private func sCurve(_ x: Float) -> Float {
        let a: Float = 6
        func g(_ v: Float) -> Float { 1 / (1 + exp(-a * (v - pivot))) }
        let g0 = g(0), g1 = g(1)
        return (g(x) - g0) / (g1 - g0)
    }

    func tone(_ input: Float) -> Float {
        var x = lc_clamp01(input)
        if contrast != 0 {
            x += contrast * (sCurve(x) - x)
        }
        if highlightRolloff != 0 && x > highlightKnee {
            let t = (x - highlightKnee) / (1 - highlightKnee)
            // Slope 1 at the knee, (1 - rolloff) at white; endpoint stays 1.
            x = highlightKnee + (1 - highlightKnee) * (t + highlightRolloff * t * t * (1 - t))
        }
        if blackLift > 0 {
            x = blackLift + x * (1 - blackLift)
        } else if blackLift < 0 {
            let toe: Float = 0.18
            if x < toe {
                let u = (toe - x) / toe
                x -= (-blackLift) * toe * u * u   // smooth, slope 1 at the toe edge
            }
        }
        return lc_clamp01(x)
    }

    // MARK: Full evaluation

    func apply(_ input: SIMD3<Float>) -> SIMD3<Float> {
        var rgb = input

        // 1. White balance warmth (simple gain in encoded space).
        if warmth != 0 {
            rgb.x *= 1 + 0.12 * warmth
            rgb.z *= 1 - 0.12 * warmth
        }
        rgb = simd_clamp(rgb, SIMD3<Float>(repeating: 0), SIMD3<Float>(repeating: 1))

        var luma: Float

        if monochrome {
            // 2a. Channel mix, then tone.
            let m = channelMix
            let y = simd_dot(rgb, m) / max(m.x + m.y + m.z, 1e-4)
            luma = tone(y)
            rgb = SIMD3<Float>(repeating: luma)
        } else {
            // 2b. Tone on luma, applied as an additive shift so chroma is preserved.
            let y = simd_dot(rgb, Self.lumaWeights)
            let y2 = tone(y)
            rgb += SIMD3<Float>(repeating: y2 - y)
            rgb = simd_clamp(rgb, SIMD3<Float>(repeating: 0), SIMD3<Float>(repeating: 1))
            luma = simd_dot(rgb, Self.lumaWeights)

            // 3. Hue-dependent saturation and hue shifts around luma.
            var c = rgb - SIMD3<Float>(repeating: luma)
            var satFactor = saturation
            var shiftDeg: Float = 0
            if !hueAdjustments.isEmpty {
                var h = atan2(sqrt(3) * (rgb.y - rgb.z), 2 * rgb.x - rgb.y - rgb.z) * 180 / Float.pi
                if h < 0 { h += 360 }
                var satAdd: Float = 0
                for adj in hueAdjustments {
                    let w = adj.weight(h)
                    satAdd += w * adj.sat
                    shiftDeg += w * adj.shift
                }
                satFactor *= max(0, 1 + satAdd)
            }
            if shiftDeg != 0 {
                // Rodrigues rotation of the chroma vector around the grey axis.
                let th = shiftDeg * Float.pi / 180
                let n = SIMD3<Float>(repeating: 1 / sqrt(3))
                let cosT = cos(th), sinT = sin(th)
                c = c * cosT + simd_cross(n, c) * sinT + n * (simd_dot(n, c) * (1 - cosT))
            }
            rgb = SIMD3<Float>(repeating: luma) + c * satFactor
        }

        // 4. Split toning.
        let mid = 0.5 + splitBalance * 0.25
        let ws = 1 - lc_smoothstep(0, mid + 0.25, luma)
        let wh = lc_smoothstep(mid - 0.25, 1, luma)
        rgb += shadowTint * ws + highlightTint * wh

        return simd_clamp(rgb, SIMD3<Float>(repeating: 0), SIMD3<Float>(repeating: 1))
    }
}

// MARK: - Cube generation

enum CubeBuilder {
    /// Builds Float32 RGBA cube data in CIColorCube order (red fastest, then green, then blue).
    static func build(dimension n: Int, _ transform: (SIMD3<Float>) -> SIMD3<Float>) -> Data {
        var floats = [Float]()
        floats.reserveCapacity(n * n * n * 4)
        let inv = 1 / Float(n - 1)
        for b in 0..<n {
            for g in 0..<n {
                for r in 0..<n {
                    let o = transform(SIMD3<Float>(Float(r) * inv, Float(g) * inv, Float(b) * inv))
                    floats.append(lc_clamp01(o.x))
                    floats.append(lc_clamp01(o.y))
                    floats.append(lc_clamp01(o.z))
                    floats.append(1)
                }
            }
        }
        return floats.withUnsafeBufferPointer { Data(buffer: $0) }
    }
}
