//  LookRenderer+Gear.swift
//  Body + lens character on top of the colour look. Fresh CIFilters per call (thread-safe);
//  the only shared state is the cached noise image, guarded by `GearNoiseCache.lock`.

import CoreImage
import CoreImage.CIFilterBuiltins
import CoreGraphics
import Foundation

/// Monochrome noise (R channel replicated, values 0...1), generated once.
private enum GearNoiseCache {
    private static let lock = NSLock()
    private static var cached: CIImage?

    static func noise() -> CIImage? {
        lock.lock(); defer { lock.unlock() }
        if let c = cached { return c }
        guard let random = CIFilter.randomGenerator().outputImage else { return nil }
        let f = CIFilter.colorMatrix()
        f.inputImage = random
        f.rVector = CIVector(x: 1, y: 0, z: 0, w: 0)
        f.gVector = CIVector(x: 1, y: 0, z: 0, w: 0)
        f.bVector = CIVector(x: 1, y: 0, z: 0, w: 0)
        f.aVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        f.biasVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        guard let mono = f.outputImage else { return nil }
        cached = mono   // infinite extent; cropped by the caller
        return mono
    }
}

extension LookRenderer {

    func apply(_ preset: LookPreset, gear: GearSelection?, aperture: Float?, cheap: Bool,
               to image: CIImage, isLogSource: Bool) -> CIImage {
        // With a gear the lens character owns vignetting, so the Leica look vignette is skipped.
        let base = apply(preset, to: image, isLogSource: isLogSource, includeVignette: gear == nil)
        guard let gear = gear else { return base }
        let ext = image.extent
        guard !ext.isInfinite, !ext.isEmpty else { return base }

        let body = gear.body.character
        let lens = gear.lens.character
        let eps: Float = 0.001
        var out = base

        // MARK: Body character
        if abs(body.saturation) > eps || abs(body.contrast) > eps {
            let f = CIFilter.colorControls()
            f.inputImage = out
            f.saturation = 1 + body.saturation
            f.contrast = 1 + body.contrast
            f.brightness = 0
            out = f.outputImage ?? out
        }
        if abs(body.warmth) > eps {
            let w = CGFloat(body.warmth)
            let f = CIFilter.colorMatrix()
            f.inputImage = out
            f.rVector = CIVector(x: 1 + w, y: 0, z: 0, w: 0)
            f.gVector = CIVector(x: 0, y: 1, z: 0, w: 0)
            f.bVector = CIVector(x: 0, y: 0, z: 1 - w, w: 0)
            f.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
            f.biasVector = CIVector(x: 0, y: 0, z: 0, w: 0)
            out = f.outputImage ?? out
        }
        if !cheap && abs(body.shadowMagenta) > eps {
            out = shadowTint(out, amount: body.shadowMagenta)
        }
        if !cheap && body.grain > eps {
            out = addGrain(out, amount: body.grain, extent: ext)
        }

        // MARK: Lens character
        if lens.vignette > eps {
            let f = CIFilter.vignetteEffect()
            f.inputImage = out
            f.center = CGPoint(x: ext.midX, y: ext.midY)
            f.radius = Float(hypot(ext.width, ext.height) * 0.5 * 0.9)
            f.intensity = min(lens.vignette * 0.9, 1)
            f.falloff = 0.5
            out = (f.outputImage ?? out).cropped(to: ext)
        }
        if !cheap && lens.sharpness > eps {
            let f = CIFilter.sharpenLuminance()
            f.inputImage = out
            f.sharpness = min(lens.sharpness * 0.6, 2)
            f.radius = Float(min(max(ext.width / 1200, 0.8), 3))
            out = (f.outputImage ?? out).cropped(to: ext)
        }
        if !cheap && lens.bloom > eps {
            let f = CIFilter.bloom()
            f.inputImage = out
            f.radius = Float(min(max(ext.width * 0.01, 1), 100))
            f.intensity = min(lens.bloom * 0.6, 1)
            out = (f.outputImage ?? out).cropped(to: ext)
        }
        if !cheap, let ap = aperture, lens.softnessWideOpen > eps {
            let maxAp = max(gear.lens.maxAperture, 0.5)
            let t = min(max((maxAp * 2 - ap) / maxAp, 0), 1)
            let amount = lens.softnessWideOpen * t
            if amount > 0.01 {
                out = softGlow(out, amount: amount, extent: ext)
            }
        }
        return out.cropped(to: ext)
    }

    // MARK: Helpers

    /// Tints shadows: positive = magenta (R+B), negative = green. Blended through an inverted-luminance mask.
    private func shadowTint(_ image: CIImage, amount: Float) -> CIImage {
        let s = CGFloat(min(abs(amount), 0.3)) * 0.8
        let tint = CIFilter.colorMatrix()
        tint.inputImage = image
        tint.rVector = CIVector(x: 1, y: 0, z: 0, w: 0)
        tint.gVector = CIVector(x: 0, y: 1, z: 0, w: 0)
        tint.bVector = CIVector(x: 0, y: 0, z: 1, w: 0)
        tint.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        tint.biasVector = amount > 0 ? CIVector(x: s, y: -s * 0.3, z: s, w: 0)
                                     : CIVector(x: -s * 0.3, y: s, z: -s * 0.3, w: 0)
        guard let tinted = tint.outputImage else { return image }

        // mask = (1 - luminance)^1 as gray, alpha 1
        let m = CIFilter.colorMatrix()
        m.inputImage = image
        let r = CIVector(x: -0.2126, y: -0.7152, z: -0.0722, w: 0)
        m.rVector = r; m.gVector = r; m.bVector = r
        m.aVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        m.biasVector = CIVector(x: 1, y: 1, z: 1, w: 1)
        guard let mask = m.outputImage else { return image }

        let b = CIFilter.blendWithMask()
        b.inputImage = tinted
        b.backgroundImage = image
        b.maskImage = mask
        return (b.outputImage ?? image).cropped(to: image.extent)
    }

    private func addGrain(_ image: CIImage, amount: Float, extent ext: CGRect) -> CIImage {
        guard let noise = GearNoiseCache.noise() else { return image }
        // Centre the noise around mid-grey, scaled by amount (soft light leaves 0.5 unchanged).
        let k = CGFloat(min(amount, 1))   // M8 (0.25) ≈ ±12% around mid-grey
        let n = CIFilter.colorMatrix()
        // The generator image is infinite and deterministic: shift it randomly per call so the
        // grain differs every frame instead of being a fixed pattern.
        n.inputImage = noise.transformed(by: CGAffineTransform(translationX: CGFloat.random(in: 0..<512),
                                                               y: CGFloat.random(in: 0..<512)))
        n.rVector = CIVector(x: k, y: 0, z: 0, w: 0)
        n.gVector = CIVector(x: 0, y: k, z: 0, w: 0)
        n.bVector = CIVector(x: 0, y: 0, z: k, w: 0)
        n.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        let bias = 0.5 - 0.5 * k
        n.biasVector = CIVector(x: bias, y: bias, z: bias, w: 0)
        guard let scaled = n.outputImage?.cropped(to: ext) else { return image }
        let f = CIFilter.softLightBlendMode()
        f.inputImage = scaled
        f.backgroundImage = image
        return (f.outputImage ?? image).cropped(to: ext)
    }

    /// Blends a blurred copy over the image with alpha `amount * 0.5`.
    private func softGlow(_ image: CIImage, amount: Float, extent ext: CGRect) -> CIImage {
        let blur = CIFilter.gaussianBlur()
        blur.inputImage = image.clampedToExtent()
        blur.radius = Float(min(max(ext.width * 0.004, 1), 40))
        guard let blurred = blur.outputImage?.cropped(to: ext) else { return image }
        let a = CIFilter.colorMatrix()
        a.inputImage = blurred
        a.rVector = CIVector(x: 1, y: 0, z: 0, w: 0)
        a.gVector = CIVector(x: 0, y: 1, z: 0, w: 0)
        a.bVector = CIVector(x: 0, y: 0, z: 1, w: 0)
        a.aVector = CIVector(x: 0, y: 0, z: 0, w: CGFloat(min(amount, 1)) * 0.5)
        a.biasVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        guard let faded = a.outputImage else { return image }
        let over = CIFilter.sourceOverCompositing()
        over.inputImage = faded
        over.backgroundImage = image
        return (over.outputImage ?? image).cropped(to: ext)
    }
}
