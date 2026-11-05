//  CinematicSupport.swift
//  Isolated iOS 26 Cinematic Video support. Everything goes through responds(to:) + KVC so the
//  file compiles regardless of the exact SDK symbol names, and never raises on older systems.

import AVFoundation
import CoreMedia

enum CinematicSupport {

    /// True if `format` reports Cinematic Video capture support (iOS 26+).
    static func formatSupportsCinematic(_ format: AVCaptureDevice.Format) -> Bool {
        guard #available(iOS 26.0, *) else { return false }
        let getter = NSSelectorFromString("isCinematicVideoCaptureSupported")
        guard format.responds(to: getter) else { return false }
        return (format.value(forKey: "cinematicVideoCaptureSupported") as? Bool) ?? false
    }

    static func deviceSupportsCinematic(_ device: AVCaptureDevice) -> Bool {
        device.formats.contains { formatSupportsCinematic($0) }
    }

    /// Best cinematic-capable format (prefers 30 fps support, then width).
    static func bestFormat(for device: AVCaptureDevice) -> AVCaptureDevice.Format? {
        let supported = device.formats.filter { formatSupportsCinematic($0) }
        func score(_ f: AVCaptureDevice.Format) -> Int {
            let w = CaptureFormats.dimensions(f).w
            return w + (CaptureFormats.supportsFPS(f, 30) ? 100_000 : 0)
        }
        return supported.max(by: { score($0) < score($1) })
    }

    /// Enables cinematic capture on the input (falling back to the device). Returns true on success.
    /// Call only when the device's active format supports cinematic capture.
    @discardableResult
    static func setEnabled(_ enabled: Bool, input: AVCaptureDeviceInput, device: AVCaptureDevice) -> Bool {
        guard #available(iOS 26.0, *) else { return false }
        guard formatSupportsCinematic(device.activeFormat) else { return false }
        if setValueIfSupported(input, key: "cinematicVideoCaptureEnabled", value: enabled) { return true }
        return setValueIfSupported(device, key: "cinematicVideoCaptureEnabled", value: enabled)
    }

    /// Sets the simulated aperture (f-number) if the input / device expose it.
    @discardableResult
    static func setAperture(_ aperture: Float, input: AVCaptureDeviceInput, device: AVCaptureDevice) -> Bool {
        guard #available(iOS 26.0, *) else { return false }
        if setValueIfSupported(input, key: "simulatedAperture", value: aperture) { return true }
        return setValueIfSupported(device, key: "simulatedAperture", value: aperture)
    }

    // MARK: KVC helper

    private static func setValueIfSupported(_ object: NSObject, key: String, value: Any) -> Bool {
        let capitalized = key.prefix(1).uppercased() + key.dropFirst()
        let setter = NSSelectorFromString("set\(capitalized):")
        guard object.responds(to: setter) else { return false }
        object.setValue(value, forKey: key)
        return true
    }
}
