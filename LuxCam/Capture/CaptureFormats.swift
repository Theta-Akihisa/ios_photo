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

    static func is10Bit(_ f: AVCaptureDevice.Format) -> Bool {
        let sub = CMFormatDescriptionGetMediaSubType(f.formatDescription)
        return sub == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
            || sub == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
    }

    /// Heuristic: any media subtype that is not a plain YpCbCr 4:2:0 layout is treated as a RAW/Bayer format.
    static func looksRAW(_ f: AVCaptureDevice.Format) -> Bool {
        let sub = CMFormatDescriptionGetMediaSubType(f.formatDescription)
        let yuv: [FourCharCode] = [
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
            kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
        ]
        return !yuv.contains(sub)
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
            if is10Bit(f) { s += 10 }
            return s
        }

        func pick(requireFPS: Bool, requireRes: Bool) -> AVCaptureDevice.Format? {
            let list = device.formats.filter { f in
                if let cs = cs, !supports(f, colorSpace: cs) { return false }
                if requireRes {
                    let d = dimensions(f)
                    let ok = settings.resolution4K ? (d.w >= 3840 && d.w <= 4096) : (d.w == 1920)
                    if !ok { return false }
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

    // MARK: Misc

    static func range<T: Comparable>(_ a: T, _ b: T) -> ClosedRange<T> {
        a <= b ? a...b : b...a
    }

    static func temporaryMovieURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("luxcam-\(UUID().uuidString).mov")
    }

    /// Metadata items storing the look name inside the movie.
    static func lookMetadata(_ preset: LookPreset) -> [AVMetadataItem] {
        var items: [AVMetadataItem] = []

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
