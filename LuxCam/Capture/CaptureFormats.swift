//  CaptureFormats.swift
//  Device / format selection helpers for the Capture module.

import AVFoundation
import CoreMedia
import CoreVideo

enum CaptureFormats {

    // MARK: Device selection

    /// Back camera for the mode. PORTRAIT prefers a depth-capable virtual device.
    static func captureDevice(for mode: CameraMode) -> AVCaptureDevice? {
        if mode == .portrait {
            let found = AVCaptureDevice.DiscoverySession(
                deviceTypes: depthCapableTypes, mediaType: .video, position: .back).devices
            if let first = found.first { return first }
        }
        return AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
            ?? AVCaptureDevice.default(for: .video)
    }

    /// Physical back camera for PHOTO / VIDEO selected by the gear's 35mm-equivalent focal length.
    /// Other modes keep `captureDevice(for:)`. Missing cameras fall back to the wide camera.
    static func captureDevice(for mode: CameraMode, gear: GearSelection) -> AVCaptureDevice? {
        guard mode == .photo || mode == .video else { return captureDevice(for: mode) }
        let f = gear.lens.equivalentFocalLength(on: gear.body)
        if f < 20,
           let uw = AVCaptureDevice.default(.builtInUltraWideCamera, for: .video, position: .back) {
            return uw
        }
        if f >= 96,
           let tele = AVCaptureDevice.default(.builtInTelephotoCamera, for: .video, position: .back) {
            return tele
        }
        return AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
            ?? captureDevice(for: mode)
    }

    /// 35mm-equivalent focal length of the device's native (zoom 1) field of view.
    /// Ultra wide / telephoto are derived from the field of view relative to the wide camera.
    static func baseFocalLength(of dev: AVCaptureDevice) -> Double {
        switch dev.deviceType {
        case .builtInUltraWideCamera: return 13
        case .builtInTripleCamera, .builtInDualWideCamera:
            // Factor 1 = ultra wide (13mm); the first switch-over factor is the wide camera (24mm).
            if let s = dev.virtualDeviceSwitchOverVideoZoomFactors.first?.doubleValue, s > 0 {
                return 24 / s
            }
            return 13
        case .builtInTelephotoCamera:
            let fallback = 120.0
            guard let wide = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
                return fallback
            }
            let fw = Double(wide.activeFormat.videoFieldOfView)
            let fd = Double(dev.activeFormat.videoFieldOfView)
            guard fw > 1, fd > 1, fw < 179, fd < 179 else { return fallback }
            let v = 24 * tan(fw * Double.pi / 360) / tan(fd * Double.pi / 360)
            return (v.isFinite && (48.0...130.0).contains(v)) ? v : fallback
        default: return 24      // wide, and .builtInDualCamera (factor 1 = wide 24mm)
        }
    }

    /// True when neither the body nor the lens adds any rendering character.
    static func isNeutral(_ gear: GearSelection) -> Bool {
        gear.body.character == BodyCharacter.neutral && gear.lens.character == LensCharacter.neutral
            && !gear.body.isMonochrome
    }

    static let depthCapableTypes: [AVCaptureDevice.DeviceType] = [
        .builtInTripleCamera, .builtInDualWideCamera, .builtInDualCamera
    ]

    static func hasDepthCapableDevice() -> Bool {
        !AVCaptureDevice.DiscoverySession(deviceTypes: depthCapableTypes,
                                          mediaType: .video, position: .back).devices.isEmpty
    }

    // MARK: Format queries

    static func dimensions(_ f: AVCaptureDevice.Format) -> (w: Int, h: Int) {
        let d = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
        return (Int(d.width), Int(d.height))
    }

    static func supportsFPS(_ f: AVCaptureDevice.Format, _ fps: Double) -> Bool {
        f.videoSupportedFrameRateRanges.contains { $0.minFrameRate <= fps && fps <= $0.maxFrameRate }
    }

    static func clampedFPS(_ f: AVCaptureDevice.Format, _ fps: Double) -> Double {
        let ranges = f.videoSupportedFrameRateRanges
        guard let lo = ranges.map({ $0.minFrameRate }).min(),
              let hi = ranges.map({ $0.maxFrameRate }).max() else { return fps }
        return min(max(fps, lo), hi)
    }

    /// Uses KVC so it compiles whether the SDK exposes `[NSNumber]` or `[AVCaptureColorSpace]`.
    static func supports(_ f: AVCaptureDevice.Format, colorSpace cs: AVCaptureColorSpace) -> Bool {
        let raw = (f.value(forKey: "supportedColorSpaces") as? [NSNumber]) ?? []
        return raw.contains { $0.intValue == cs.rawValue }
    }

    static func anyFormat(of device: AVCaptureDevice, supports cs: AVCaptureColorSpace) -> Bool {
        device.formats.contains { supports($0, colorSpace: cs) }
    }

    static func subType(_ f: AVCaptureDevice.Format) -> FourCharCode {
        CMFormatDescriptionGetMediaSubType(f.formatDescription)
    }

    /// 10-bit 4:2:0 ('x420' / 'xf20').
    static func is10Bit420(_ f: AVCaptureDevice.Format) -> Bool {
        let sub = subType(f)
        return sub == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
            || sub == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
    }

    /// 10-bit 4:2:2 ('x422' / 'xf22'), the layout ProRes 422 records from.
    static func is10Bit422(_ f: AVCaptureDevice.Format) -> Bool {
        let sub = subType(f)
        return sub == kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange
            || sub == kCVPixelFormatType_422YpCbCr10BiPlanarFullRange
    }

    static func is10Bit(_ f: AVCaptureDevice.Format) -> Bool {
        is10Bit420(f) || is10Bit422(f)
    }

    /// Heuristic: any media subtype that is not a plain YpCbCr layout (8-bit 4:2:0, 10-bit 4:2:0 / 4:2:2)
    /// is treated as a RAW/Bayer format.
    static func looksRAW(_ f: AVCaptureDevice.Format) -> Bool {
        let sub = subType(f)
        let yuv: [FourCharCode] = [
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
            kCVPixelFormatType_420YpCbCr10BiPlanarFullRange,
            kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange,
            kCVPixelFormatType_422YpCbCr10BiPlanarFullRange
        ]
        return !yuv.contains(sub)
    }

    static func matchesResolution(_ f: AVCaptureDevice.Format, is4K: Bool) -> Bool {
        let d = dimensions(f)
        return is4K ? (d.w >= 3840 && d.w <= 4096) : (d.w == 1920)
    }

    /// Frame rates (subset of 24/25/30/60/120) available at the chosen resolution on non-RAW formats.
    static func supportedFrameRates(of device: AVCaptureDevice, resolution4K: Bool) -> [Int] {
        let formats = device.formats.filter { !looksRAW($0) && matchesResolution($0, is4K: resolution4K) }
        let rates = [24, 25, 30, 60, 120].filter { r in formats.contains { supportsFPS($0, Double(r)) } }
        return rates.isEmpty ? [24, 25, 30] : rates
    }

    // MARK: Video format selection

    static func colorSpace(for profile: VideoColorProfile) -> AVCaptureColorSpace? {
        switch profile {
        case .standard: return nil
        case .hlg: return .HLG_BT2020
        case .appleLog: return .appleLog
        }
    }

    /// Picks the best format for `settings`, relaxing fps then resolution when nothing matches exactly.
    /// Returns nil only if the requested colour profile is unsupported by every format.
    static func bestVideoFormat(for device: AVCaptureDevice,
                                settings: VideoFormatSettings) -> AVCaptureDevice.Format? {
        let fps = Double(settings.frameRate)
        let wantRAW = settings.codec.isRAW
        let cs = colorSpace(for: settings.color)

        func score(_ f: AVCaptureDevice.Format) -> Int {
            var s = 0
            if looksRAW(f) == wantRAW { s += 100 }
            if settings.codec.isProRes && !wantRAW {
                // ProRes 422 records from 10-bit 4:2:2 sources.
                if is10Bit422(f) { s += 50 }
            } else if is10Bit422(f) {
                s -= 5
            }
            if is10Bit(f) { s += 10 }
            return s
        }

        func pick(requireFPS: Bool, requireRes: Bool) -> AVCaptureDevice.Format? {
            let list = device.formats.filter { f in
                if let cs = cs, !supports(f, colorSpace: cs) { return false }
                if requireRes {
                    if !matchesResolution(f, is4K: settings.resolution4K) { return false }
                }
                if requireFPS && !supportsFPS(f, fps) { return false }
                return true
            }
            return list.max(by: { score($0) < score($1) })
        }

        return pick(requireFPS: true, requireRes: true)
            ?? pick(requireFPS: false, requireRes: true)
            ?? pick(requireFPS: true, requireRes: false)
            ?? pick(requireFPS: false, requireRes: false)
    }

    /// Describes how `format` deviates from the requested resolution / frame rate (nil when it matches).
    static func mismatchNote(_ f: AVCaptureDevice.Format, settings: VideoFormatSettings) -> String? {
        let resOK = matchesResolution(f, is4K: settings.resolution4K)
        let fpsOK = supportsFPS(f, Double(settings.frameRate))
        if resOK && fpsOK { return nil }
        let d = dimensions(f)
        let actualFPS = Int(clampedFPS(f, Double(settings.frameRate)).rounded())
        return "指定の組み合わせは利用できないため、最も近い設定（\(d.w)x\(d.h) / \(actualFPS)fps）を使用します"
    }

    // MARK: Misc

    static func range<T: Comparable>(_ a: T, _ b: T) -> ClosedRange<T> {
        a <= b ? a...b : b...a
    }

    static func temporaryMovieURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("luxcam-\(UUID().uuidString).mov")
    }

    /// Metadata items storing the look name inside the movie.
    static func lookMetadata(_ preset: LookPreset, gear: GearSelection? = nil) -> [AVMetadataItem] {
        var items: [AVMetadataItem] = []

        if let gear = gear {
            let g = AVMutableMetadataItem()
            g.keySpace = .quickTimeMetadata
            g.key = "com.luxcam.gear" as NSString
            g.value = "\(gear.body.rawValue)/\(gear.lens.rawValue)" as NSString
            g.dataType = kCMMetadataBaseDataType_UTF8 as String
            items.append(g)
        }

        let look = AVMutableMetadataItem()
        look.keySpace = .quickTimeMetadata
        look.key = "com.luxcam.look" as NSString
        look.value = preset.rawValue as NSString
        look.dataType = kCMMetadataBaseDataType_UTF8 as String
        items.append(look)

        let comment = AVMutableMetadataItem()
        comment.keySpace = .quickTimeUserData
        comment.key = AVMetadataKey.quickTimeUserDataKeyComment.rawValue as NSString
        comment.value = "LuxCam look: \(preset.title)" as NSString
        items.append(comment)

        return items
    }
}
