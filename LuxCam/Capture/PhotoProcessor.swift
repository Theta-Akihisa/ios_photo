//  PhotoProcessor.swift
//  Post-processing of captured photos: portrait depth blur, look, re-encode.

import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO
import UIKit

final class PhotoProcessor {

    struct Output {
        let data: Data
        let thumbnail: UIImage?
        /// True when the look could not be applied and `data` is the untouched original.
        var failed: Bool = false
    }

    private let renderer: LookRendering
    private let context: CIContext

    init(renderer: LookRendering, context: CIContext) {
        self.renderer = renderer
        self.context = context
    }

    /// Returns the data to save. On failure the original data is returned with `failed == true`
    /// (after logging the failing step), so the caller can tell the user.
    /// `cropToBody` is false only where the caller wants the 4:3 frame kept.
    func process(data: Data, mode: CameraMode, look: LookPreset, gear: GearSelection,
                 aperture: Float, cropToBody: Bool = true) -> Output {
        let wantsPortrait = (mode == .portrait)
        let wantsCrop = cropToBody && abs(gear.body.photoAspect - 4.0 / 3.0) > 0.001
        let wantsGear = !CaptureFormats.isNeutral(gear)
        // Nothing to do: return the original untouched (keeps its HDR), without decoding.
        if !wantsPortrait && look == .native && !wantsCrop && !wantsGear {
            return Output(data: data, thumbnail: LibrarySaver.photoThumbnail(from: data))
        }
        // The original's thumbnail is only decoded when the original is actually returned.
        func fail(_ step: String) -> Output {
            note("\(step) failed")
            return Output(data: data, thumbnail: LibrarySaver.photoThumbnail(from: data), failed: true)
        }

        // Orientation is baked into the pixels so every auxiliary image lines up.
        guard let decoded = CIImage(data: data, options: [.applyOrientationProperty: true]) else {
            return fail("decode")
        }
        let sourceProps = decoded.properties
        let sourceExtent = decoded.extent
        guard sourceExtent.width >= 2, sourceExtent.height >= 2, !sourceExtent.isInfinite else {
            return fail("decode (empty extent)")
        }
        // Bound memory (e.g. 48 MP ProRAW companions): work on at most ~12.6 MP.
        let pixels = Double(sourceExtent.width) * Double(sourceExtent.height)
        let downScale: CGFloat = pixels > 12_600_000 ? CGFloat((12_600_000.0 / pixels).squareRoot()) : 1
        let base = downScale < 1 ? scaled(decoded, by: downScale) : decoded

        var extent = base.extent
        var image = base
        var modified = false

        var portraitBlurred = false
        if wantsPortrait, let blurred = depthBlur(data: data, base: base, aperture: aperture) {
            image = fit(blurred, to: extent).cropped(to: extent)
            modified = true
            portraitBlurred = true
        }
        // Un-graded linear gain (HDR / SDR) of the capture; nil when there is no usable HDR content.
        // Everything here is a lazy Core Image graph: the full-size HDR and SDR decodes are only
        // materialised (tile by tile) while rendering, so they are not both resident up front.
        var gain: GainInfo?
        if #available(iOS 18.0, *) {
            gain = makeGain(data: data, sourceExtent: sourceExtent, downScale: downScale, base: base)
            if portraitBlurred, let info = gain {
                // The gain comes from the unblurred capture; soften it so sharp highlight detail is not
                // multiplied back into the blurred background.
                let apertureFactor = min(max(2.8 / max(aperture, 0.1), 0.5), 2)
                let radius = Float(extent.width) * 0.004 * apertureFactor
                let blur = CIFilter.gaussianBlur()
                blur.inputImage = info.image.clampedToExtent()
                blur.radius = radius
                if let blurredGain = blur.outputImage?.cropped(to: extent) {
                    gain = GainInfo(image: blurredGain, needsMeasure: info.needsMeasure)
                } else {
                    note("portrait gain blur failed; using the unblurred gain")
                }
            }
        }
        if wantsCrop, let rect = cropRect(for: extent, aspect: gear.body.photoAspect) {
            // Crop first so the lens vignette etc. follow the final frame; move the origin back to zero.
            let move = CGAffineTransform(translationX: -rect.minX, y: -rect.minY)
            image = image.cropped(to: rect).transformed(by: move)
            // The gain gets exactly the same geometry as the SDR image.
            if let info = gain {
                gain = GainInfo(image: info.image.cropped(to: rect).transformed(by: move),
                                needsMeasure: info.needsMeasure)
            }
            extent = CGRect(x: 0, y: 0, width: rect.width, height: rect.height)
            modified = true
        }
        if look != .native || wantsGear {
            image = renderer.apply(look, gear: gear, aperture: wantsPortrait ? aperture : nil,
                                   cheap: false, to: image, isLogSource: false)
            modified = true
        }
        guard modified else {
            return Output(data: data, thumbnail: LibrarySaver.photoThumbnail(from: data))
        }

        let p3 = CGColorSpace(name: CGColorSpace.displayP3) ?? CGColorSpaceCreateDeviceRGB()

        // Metadata: keep the source EXIF/GPS, but describe the new upright, re-sized file.
        var props: [String: Any] = sourceProps
        props[kCGImagePropertyOrientation as String] = 1
        var tiff = (props[kCGImagePropertyTIFFDictionary as String] as? [String: Any]) ?? [:]
        tiff[kCGImagePropertyTIFFOrientation as String] = 1
        props[kCGImagePropertyTIFFDictionary as String] = tiff
        var exif = (props[kCGImagePropertyExifDictionary as String] as? [String: Any]) ?? [:]
        exif[kCGImagePropertyExifPixelXDimension as String] = Int(extent.width)
        exif[kCGImagePropertyExifPixelYDimension as String] = Int(extent.height)
        // The old Apple HDR headroom must not describe the new gain map.
        exif.removeValue(forKey: kCGImagePropertyExifCustomRendered as String)
        props[kCGImagePropertyExifDictionary as String] = exif
        props.removeValue(forKey: kCGImagePropertyMakerAppleDictionary as String)

        let primary = image.cropped(to: extent).settingProperties(props as [AnyHashable: Any])
        let sdrOptions: [CIImageRepresentationOption: Any] = [
            CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): 0.92
        ]
        var hdrOptions = sdrOptions
        var hasHDR = false

        // HDR: SDR primary + our own gain map (Core Image computes it from hdrImage). In portrait the gain
        // was softened above so the blurred background does not regain sharp highlight detail.
        // NOTE: the exact headroom of the new gain map is left to Core Image; no `settingContentHeadroom`
        // call is made because its Swift spelling/availability is not verified.
        if #available(iOS 18.0, *), let info = gain {
            let g = info.image.cropped(to: extent)
            var hasContent = true
            if info.needsMeasure {
                if let peak = measureGainMax(g) {
                    hasContent = peak > 1.1
                    if !hasContent {
                        note("HDR dropped: peak gain \(peak) <= 1.1 (no real HDR content)")
                    }
                } else {
                    note("gain peak could not be measured (GPU and software read-back failed); trying HDR anyway")
                }
            }
            if hasContent {
                let multiply = CIFilter.multiplyCompositing()
                multiply.inputImage = image.cropped(to: extent)
                multiply.backgroundImage = g
                if let hdrGraded = multiply.outputImage?.cropped(to: extent) {
                    hdrOptions[.hdrImage] = hdrGraded
                    hasHDR = true
                } else {
                    note("HDR dropped: gain multiply produced no image")
                }
            }
        }

        // GPU+HDR -> GPU+SDR -> software+HDR -> software+SDR.
        var attempts: [(ctx: CIContext, opts: [CIImageRepresentationOption: Any], label: String)] = []
        if hasHDR { attempts.append((context, hdrOptions, "gpu+hdr")) }
        attempts.append((context, sdrOptions, "gpu+sdr"))
        if hasHDR { attempts.append((softwareContext, hdrOptions, "software+hdr")) }
        attempts.append((softwareContext, sdrOptions, "software+sdr"))
        for attempt in attempts {
            if let encoded = encodeImage(primary, colorSpace: p3, options: attempt.opts, context: attempt.ctx) {
                note("encoded with \(attempt.label)" + (hasHDR && attempt.label.hasSuffix("sdr")
                     ? " (HDR was available but dropped after a failed HDR encode)" : ""))
                return Output(data: encoded, thumbnail: LibrarySaver.photoThumbnail(from: encoded))
            }
            note("encode attempt \(attempt.label) failed")
        }
        return fail("encode")
    }

    private func note(_ message: String) {
        NSLog("%@", "LuxCam PhotoProcessor: " + message)
    }

    /// Un-graded gain plus whether its peak still has to be measured (false when the decoder reported a
    /// known content headroom that already passed the HDR gate).
    private struct GainInfo {
        let image: CIImage
        let needsMeasure: Bool
    }

    /// Two-sampler gain kernel (hdr / sdr, clamped to 1...maxGain). Deprecated API (warning only), still works.
    private static let gainKernel: CIColorKernel? = CIColorKernel(source:
        "kernel vec4 luxGain(__sample h, __sample s, float maxGain) { "
        + "vec3 g = clamp((h.rgb + 0.002) / (s.rgb + 0.002), vec3(1.0), vec3(maxGain)); "
        + "return vec4(g, 1.0); }")

    /// CPU renderer used only when the main context cannot encode.
    private lazy var softwareContext = CIContext(options: [.useSoftwareRenderer: true,
                                                           .cacheIntermediates: false])

    private func encodeImage(_ primary: CIImage, colorSpace: CGColorSpace,
                             options: [CIImageRepresentationOption: Any], context ctx: CIContext) -> Data? {
        if let heif = ctx.heifRepresentation(of: primary, format: .RGBA8, colorSpace: colorSpace, options: options) {
            return heif
        }
        return ctx.jpegRepresentation(of: primary, colorSpace: colorSpace, options: options)
    }

    private func scaled(_ image: CIImage, by scale: CGFloat) -> CIImage {
        let e = image.extent
        let f = CIFilter.lanczosScaleTransform()
        f.inputImage = image
        f.scale = Float(scale)
        f.aspectRatio = 1
        guard let out = f.outputImage else { return image }
        let o = out.extent
        return out.cropped(to: CGRect(x: o.minX, y: o.minY,
                                      width: (e.width * scale).rounded(.down),
                                      height: (e.height * scale).rounded(.down)))
    }

    /// 1/8-scale copy used for read-backs so statistics never touch full-size pixels.
    private func smallCopy(_ image: CIImage) -> CIImage {
        let small = image.transformed(by: CGAffineTransform(scaleX: 1.0 / 8.0, y: 1.0 / 8.0))
        let e = small.extent
        guard !e.isInfinite, e.width >= 1, e.height >= 1 else { return image }
        return small.cropped(to: e.integral)
    }

    /// 1x1 area reduction (average or maximum) of a small copy of `image`, read back as RGBA float.
    /// Nil on failure or when the read-back is all zero (a broken GPU context returns zeros).
    private func reduce(_ image: CIImage, maximum: Bool, on ctx: CIContext) -> [Float]? {
        let small = smallCopy(image)
        let reduced: CIImage?
        if maximum {
            let f = CIFilter.areaMaximum()
            f.inputImage = small
            f.extent = small.extent
            reduced = f.outputImage
        } else {
            let f = CIFilter.areaAverage()
            f.inputImage = small
            f.extent = small.extent
            reduced = f.outputImage
        }
        guard let out = reduced else { return nil }
        var px = [Float](repeating: 0, count: 4)
        let bounds = out.extent
        guard !bounds.isInfinite, !bounds.isEmpty else { return nil }
        px.withUnsafeMutableBytes { raw in
            guard let addr = raw.baseAddress else { return }
            ctx.render(out, toBitmap: addr, rowBytes: 16,
                       bounds: CGRect(x: bounds.minX, y: bounds.minY, width: 1, height: 1),
                       format: .RGBAf, colorSpace: nil)
        }
        guard px.allSatisfy({ $0.isFinite }) else { return nil }
        if px[0] == 0 && px[1] == 0 && px[2] == 0 { return nil }
        return px
    }

    /// Mean luminance of `image` (small-copy area average read back as float), nil on failure.
    private func averageLuminance(_ image: CIImage, on ctx: CIContext) -> Float? {
        guard let px = reduce(image, maximum: false, on: ctx) else { return nil }
        let y = 0.2126 * px[0] + 0.7152 * px[1] + 0.0722 * px[2]
        return (y.isFinite && y > 0) ? y : nil
    }

    /// Largest gain component, measured on the GPU context first and then the software one; nil if both fail.
    private func measureGainMax(_ gain: CIImage) -> Float? {
        for ctx in [context, softwareContext] {
            if let px = reduce(gain, maximum: true, on: ctx) {
                return max(px[0], max(px[1], px[2]))
            }
            note("gain peak read-back failed on \(ctx === context ? "gpu" : "software") context")
        }
        return nil
    }

    /// Per-pixel HDR/SDR gain (clamped to 1...maxGain) in the same pixel grid as `base`; nil if the capture has
    /// no HDR rendition, its geometry differs, or anything fails (then the photo is saved as SDR). Every nil
    /// exit is logged with its reason.
    @available(iOS 18.0, *)
    private func makeGain(data: Data, sourceExtent: CGRect, downScale: CGFloat, base: CIImage) -> GainInfo? {
        guard var hdr = CIImage(data: data, options: [.expandToHDR: true, .applyOrientationProperty: true]) else {
            note("HDR dropped: expandToHDR decode returned nil")
            return nil
        }
        guard hdr.extent == sourceExtent else {
            note("HDR dropped: extent mismatch (hdr \(hdr.extent) vs sdr \(sourceExtent))")
            return nil
        }
        // 0 = unknown. Read before any scaling, which may not carry the property along.
        let headroom = hdr.contentHeadroom
        let headroomKnown = headroom.isFinite && headroom >= 1
        if headroomKnown && headroom <= 1.05 {
            note("HDR dropped: content headroom \(headroom) <= 1.05")
            return nil
        }
        if downScale < 1 { hdr = scaled(hdr, by: downScale) }
        guard hdr.extent == base.extent else {
            note("HDR dropped: extent mismatch after scaling (hdr \(hdr.extent) vs sdr \(base.extent))")
            return nil
        }
        let maxGain: Float = (headroomKnown && headroom > 1) ? headroom : 8
        let info = { (image: CIImage) -> GainInfo in GainInfo(image: image, needsMeasure: !headroomKnown) }

        if let kernel = Self.gainKernel,
           let out = kernel.apply(extent: base.extent, arguments: [hdr, base, NSNumber(value: maxGain)]) {
            return info(out.cropped(to: base.extent))
        }
        note("gain kernel unavailable; falling back to divideBlendMode")

        // Fallback: a small bias keeps 0/0 and huge ratios out of the division in the shadows.
        func biased(_ img: CIImage) -> CIImage {
            let m = CIFilter.colorMatrix()
            m.inputImage = img
            m.rVector = CIVector(x: 1, y: 0, z: 0, w: 0)
            m.gVector = CIVector(x: 0, y: 1, z: 0, w: 0)
            m.bVector = CIVector(x: 0, y: 0, z: 1, w: 0)
            m.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
            m.biasVector = CIVector(x: 0.002, y: 0.002, z: 0.002, w: 0)
            return (m.outputImage ?? img).cropped(to: img.extent)
        }
        let b = biased(base), h = biased(hdr)
        func divide(_ numerator: CIImage, _ denominator: CIImage) -> CIImage? {
            // divideBlendMode's operand order is not certain; verified at runtime below.
            let f = CIFilter.divideBlendMode()
            f.inputImage = numerator
            f.backgroundImage = denominator
            return f.outputImage?.cropped(to: base.extent)
        }
        guard let candidate = divide(b, h) else {
            note("HDR dropped: divideBlendMode produced no image")
            return nil
        }
        guard let avg = averageLuminance(candidate, on: context) else {
            note("HDR dropped: gain read-back failed (fallback path)")
            return nil
        }
        // Real gain (hdr / base) is >= 1 on average; otherwise the operands were swapped.
        let ratio: CIImage
        if avg < 1.0 {
            guard let swapped = divide(h, b) else {
                note("HDR dropped: swapped divideBlendMode produced no image")
                return nil
            }
            ratio = swapped
        } else {
            ratio = candidate
        }
        let clamp = CIFilter.colorClamp()
        clamp.inputImage = ratio
        clamp.minComponents = CIVector(x: 1, y: 1, z: 1, w: 1)
        clamp.maxComponents = CIVector(x: CGFloat(maxGain), y: CGFloat(maxGain), z: CGFloat(maxGain), w: 1)
        guard let clamped = clamp.outputImage?.cropped(to: base.extent) else {
            note("HDR dropped: gain clamp produced no image")
            return nil
        }
        return info(clamped)
    }

    /// Centred crop rectangle (integral, even sizes) giving `aspect` (landscape w/h; inverted for portrait
    /// images). Returns nil when the image already has that aspect.
    private func cropRect(for extent: CGRect, aspect: CGFloat) -> CGRect? {
        let w = extent.width, h = extent.height
        guard w > 0, h > 0 else { return nil }
        let target = (h > w) ? 1.0 / aspect : aspect
        let current = w / h
        if abs(current - target) < 0.002 { return nil }
        var nw = w, nh = h
        if current > target {
            nw = (h * target / 2).rounded(.down) * 2
        } else {
            nh = (w / target / 2).rounded(.down) * 2
        }
        guard nw >= 2, nh >= 2 else { return nil }
        let x = (extent.minX + (w - nw) / 2).rounded(.down)
        let y = (extent.minY + (h - nh) / 2).rounded(.down)
        return CGRect(x: x, y: y, width: nw, height: nh)
    }

    // MARK: Portrait

    private func depthBlur(data: Data, base: CIImage, aperture: Float) -> CIImage? {
        if let out = systemDepthBlur(data: data, base: base, aperture: aperture) { return out }
        return handBuiltDepthBlur(data: data, base: base, aperture: aperture)
    }

    /// Uses CIContext's depthBlurEffectFilter (ObjC `depthBlurEffectFilterForImageData:options:`), which wires up
    /// disparity, matte, focus rect and calibration from the photo's auxiliary data. The selector is called
    /// dynamically so a Swift spelling mismatch cannot break the build; nil when unavailable.
    private func systemDepthBlur(data: Data, base: CIImage, aperture: Float) -> CIImage? {
        let selector = Selector(("depthBlurEffectFilterForImageData:options:"))
        guard context.responds(to: selector),
              let unmanaged = context.perform(selector, with: data as NSData, with: nil),
              let filter = unmanaged.takeUnretainedValue() as? CIFilter else { return nil }
        if filter.inputKeys.contains("inputAperture") {
            filter.setValue(NSNumber(value: min(max(aperture, 1.0), 22.0)), forKey: "inputAperture")
        }
        guard let output = filter.outputImage else { return nil }
        // The filter works in native (unoriented) pixel space; the pipeline is upright.
        var orientation: Int32 = 1
        if let props = CIImage(data: data)?.properties,
           let value = props[kCGImagePropertyOrientation as String] as? NSNumber {
            orientation = value.int32Value
        }
        let baseExtent = base.extent
        guard !baseExtent.isEmpty, !baseExtent.isInfinite, baseExtent.height > 0 else { return nil }
        let baseAspect = baseExtent.width / baseExtent.height
        func matches(_ img: CIImage) -> Bool {
            let e = img.extent
            if e.isInfinite || e.isEmpty || e.height <= 0 { return false }
            return abs((e.width / e.height) / baseAspect - 1) <= 0.02
        }
        func normalised(_ img: CIImage) -> CIImage {
            let e = img.extent
            return img.transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
        }
        // Prefer the oriented candidate, fall back to the unoriented output, else let the hand-built path run.
        if orientation >= 1, orientation <= 8, orientation != 1 {
            let upright = output.oriented(forExifOrientation: orientation)
            if matches(upright) { return normalised(upright) }
        }
        if matches(output) { return normalised(output) }
        return nil
    }

    private func handBuiltDepthBlur(data: Data, base: CIImage, aperture: Float) -> CIImage? {
        guard let disparity = CIImage(data: data, options: [.auxiliaryDisparity: true,
                                                            .applyOrientationProperty: true]) else { return nil }
        let target = base.extent

        // CIDepthBlurEffect has no typed factory in CIFilterBuiltins, so it is created by name.
        // Every key is checked against `inputKeys` first: setting an unknown key raises an
        // Objective-C exception (crash) instead of failing gracefully.
        guard let filter = CIFilter(name: "CIDepthBlurEffect") else { return nil }
        let keys = Set(filter.inputKeys)
        func set(_ value: Any, _ key: String) {
            if keys.contains(key) { filter.setValue(value, forKey: key) }
        }
        set(base, kCIInputImageKey)
        set(fit(disparity, to: target), "inputDisparityImage")
        if let matte = CIImage(data: data, options: [.auxiliaryPortraitEffectsMatte: true,
                                                     .applyOrientationProperty: true]) {
            set(fit(matte, to: target), "inputMatteImage")
        }
        // The filter accepts roughly f/1 ... f/22.
        set(NSNumber(value: min(max(aperture, 1.0), 22.0)), "inputAperture")
        set(NSNumber(value: 1.0), "inputScaleFactor")
        return filter.outputImage
    }

    /// Scales/translates `image` so its extent equals `target`.
    private func fit(_ image: CIImage, to target: CGRect) -> CIImage {
        let e = image.extent
        guard e.width > 0, e.height > 0, e != target else { return image }
        let t = CGAffineTransform(translationX: -e.minX, y: -e.minY)
            .concatenating(CGAffineTransform(scaleX: target.width / e.width, y: target.height / e.height))
            .concatenating(CGAffineTransform(translationX: target.minX, y: target.minY))
        return image.transformed(by: t)
    }
}
