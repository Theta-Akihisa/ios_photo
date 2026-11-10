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
    }

    private let renderer: LookRendering
    private let context: CIContext

    init(renderer: LookRendering, context: CIContext) {
        self.renderer = renderer
        self.context = context
    }

    /// Returns the data to save. Falls back to the original data whenever processing fails.
    /// `cropToBody` is false for the processed companion of a ProRAW capture (the DNG stays 4:3).
    func process(data: Data, mode: CameraMode, look: LookPreset, gear: GearSelection,
                 aperture: Float, cropToBody: Bool = true) -> Output {
        let wantsPortrait = (mode == .portrait)
        let wantsCrop = cropToBody && abs(gear.body.photoAspect - 4.0 / 3.0) > 0.001
        let wantsGear = !CaptureFormats.isNeutral(gear)
        // Nothing to do (e.g. ProRAW companion): return the original untouched, without decoding.
        if !wantsPortrait && look == .native && !wantsCrop && !wantsGear {
            return Output(data: data, thumbnail: LibrarySaver.photoThumbnail(from: data))
        }
        let original = Output(data: data, thumbnail: LibrarySaver.photoThumbnail(from: data))

        // Orientation is baked into the pixels so every auxiliary image lines up.
        guard let base = CIImage(data: data, options: [.applyOrientationProperty: true]) else { return original }
        var extent = base.extent
        var image = base
        var modified = false

        if wantsPortrait, let blurred = depthBlur(data: data, base: base, aperture: aperture) {
            image = fit(blurred, to: extent).cropped(to: extent)
            modified = true
        }
        if wantsCrop, let rect = cropRect(for: extent, aspect: gear.body.photoAspect) {
            // Crop first so the lens vignette etc. follow the final frame; move the origin back to zero.
            image = image.cropped(to: rect)
                .transformed(by: CGAffineTransform(translationX: -rect.minX, y: -rect.minY))
            extent = CGRect(x: 0, y: 0, width: rect.width, height: rect.height)
            modified = true
        }
        if look != .native || wantsGear {
            image = renderer.apply(look, gear: gear, aperture: wantsPortrait ? aperture : nil,
                                   cheap: false, to: image, isLogSource: false)
            modified = true
        }
        guard modified else { return original }

        let colorSpace = CGColorSpace(name: CGColorSpace.displayP3) ?? CGColorSpaceCreateDeviceRGB()
        guard let cg = context.createCGImage(image, from: extent, format: .RGBA8, colorSpace: colorSpace),
              let encoded = encode(cg, sourceData: data) else { return original }
        return Output(data: encoded, thumbnail: LibrarySaver.photoThumbnail(from: encoded))
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

    // MARK: Encoding

    /// Encodes as HEIC (JPEG fallback), upright (orientation 1), keeping EXIF/GPS from the source.
    private func encode(_ cg: CGImage, sourceData: Data) -> Data? {
        var props: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: 0.92,
            kCGImagePropertyOrientation: 1
        ]
        if let src = CGImageSourceCreateWithData(sourceData as CFData, nil),
           let meta = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] {
            if var exif = meta[kCGImagePropertyExifDictionary] as? [CFString: Any] {
                exif[kCGImagePropertyExifPixelXDimension] = cg.width
                exif[kCGImagePropertyExifPixelYDimension] = cg.height
                props[kCGImagePropertyExifDictionary] = exif
            }
            if let gps = meta[kCGImagePropertyGPSDictionary] { props[kCGImagePropertyGPSDictionary] = gps }
            if var tiff = meta[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
                tiff[kCGImagePropertyTIFFOrientation] = 1
                props[kCGImagePropertyTIFFDictionary] = tiff
            }
        }
        for type in ["public.heic", "public.jpeg"] {
            let out = NSMutableData()
            guard let dest = CGImageDestinationCreateWithData(out, type as CFString, 1, nil) else { continue }
            CGImageDestinationAddImage(dest, cg, props as CFDictionary)
            if CGImageDestinationFinalize(dest) { return out as Data }
        }
        return nil
    }
}
