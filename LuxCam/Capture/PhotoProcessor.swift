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
    func process(data: Data, mode: CameraMode, look: LookPreset, aperture: Float) -> Output {
        let original = Output(data: data, thumbnail: LibrarySaver.photoThumbnail(from: data))
        let wantsPortrait = (mode == .portrait)
        if !wantsPortrait && look == .native { return original }

        // Orientation is baked into the pixels so every auxiliary image lines up.
        guard let base = CIImage(data: data, options: [.applyOrientationProperty: true]) else { return original }
        let extent = base.extent
        var image = base
        var modified = false

        if wantsPortrait, let blurred = depthBlur(data: data, base: base, aperture: aperture) {
            image = blurred.cropped(to: extent)
            modified = true
        }
        if look != .native {
            image = renderer.apply(look, to: image, isLogSource: false)
            modified = true
        }
        guard modified else { return original }

        let colorSpace = CGColorSpace(name: CGColorSpace.displayP3) ?? CGColorSpaceCreateDeviceRGB()
        guard let cg = context.createCGImage(image, from: extent, format: .RGBA8, colorSpace: colorSpace),
              let encoded = encode(cg, sourceData: data) else { return original }
        return Output(data: encoded, thumbnail: LibrarySaver.photoThumbnail(from: encoded))
    }

    // MARK: Portrait

    private func depthBlur(data: Data, base: CIImage, aperture: Float) -> CIImage? {
        guard let disparity = CIImage(data: data, options: [.auxiliaryDisparity: true,
                                                            .applyOrientationProperty: true]) else { return nil }
        let target = base.extent

        let filter = CIFilter.depthBlurEffect()
        filter.inputImage = base
        filter.disparityImage = fit(disparity, to: target)
        if let matte = CIImage(data: data, options: [.auxiliaryPortraitEffectsMatte: true,
                                                     .applyOrientationProperty: true]) {
            filter.matteImage = fit(matte, to: target)
        }
        filter.aperture = aperture
        filter.scaleFactor = 1.0
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
            if let exif = meta[kCGImagePropertyExifDictionary] { props[kCGImagePropertyExifDictionary] = exif }
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
