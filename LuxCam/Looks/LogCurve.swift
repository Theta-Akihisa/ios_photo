//  LogCurve.swift
//  Apple Log -> display approximation (monitoring only).
//
//  Assumption: the CIImage built from the BGRA pixel buffer is interpreted by Core Image
//  as sRGB, so its numeric values ARE the Apple Log encoded values. We therefore apply a
//  colour cube with an sRGB colour space, so the values reach the cube un-linearised.
//  Gamut (Rec.2020-ish Apple Log primaries) is not converted; this is a rough preview aid.

import Foundation

enum AppleLogCurve {
    // Constants from Apple's "Apple Log Profile" white paper (as recalled; verify if exactness matters).
    static let R0: Float = -0.05641088
    static let Rt: Float = 0.01
    static let c: Float = 47.28711236
    static let beta: Float = 0.00964052     // offset inside log2 (Apple Log white paper)
    static let gamma: Float = 0.08550479    // log2 multiplier
    static let delta: Float = 0.69336945    // additive offset

    /// Encoded value at the quadratic/log junction.
    static var Pt: Float { c * (Rt - R0) * (Rt - R0) }

    /// Scene-linear -> Apple Log encoded.
    static func encode(_ x: Float) -> Float {
        if x >= Rt { return gamma * log2(x + beta) + delta }
        if x >= R0 { return c * (x - R0) * (x - R0) }
        return 0
    }

    /// Apple Log encoded -> scene-linear.
    static func decode(_ t: Float) -> Float {
        if t >= Pt { return exp2((t - delta) / gamma) - beta }
        if t >= 0 { return (t / c).squareRoot() + R0 }
        return R0
    }

    /// Simple filmic (extended Reinhard) tone map + sRGB OETF with a slight contrast bump.
    static func toDisplay(_ t: Float) -> Float {
        let lin = max(decode(t), 0)
        let v = lin * 1.4                          // exposure so 18% grey lands near 0.2
        let white: Float = 8
        let mapped = v * (1 + v / (white * white)) / (1 + v)
        let enc = srgbOETF(lc_clamp01(mapped))
        let s = enc * enc * (3 - 2 * enc)          // smoothstep contrast
        return enc + 0.25 * (s - enc)
    }

    static func srgbOETF(_ l: Float) -> Float {
        l <= 0.0031308 ? 12.92 * l : 1.055 * pow(l, 1 / 2.4) - 0.055
    }
}
