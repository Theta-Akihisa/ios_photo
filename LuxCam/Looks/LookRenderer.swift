//  LookRenderer.swift
//  Applies procedural looks (colour cubes) to CIImages. Thread-safe.

import CoreImage
import CoreImage.CIFilterBuiltins
import CoreGraphics
import Foundation

final class LookRenderer: LookRendering, @unchecked Sendable {
    static let shared = LookRenderer()

    static let cubeDimension = 33
    static let logCubeDimension = 65

    /// Subtle vignette for the Leica family. Cheap; can be switched off.
    var enableVignette: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _enableVignette }
        set { lock.lock(); _enableVignette = newValue; lock.unlock() }
    }

    private let lock = NSLock()
    private var _enableVignette = true
    private var cubeCache: [LookPreset: Data] = [:]
    private var logCube: Data?

    /// Cubes are interpreted in sRGB so gamma-encoded values pass through un-linearised.
    private static let cubeColorSpace = CGColorSpace(name: CGColorSpace.sRGB)

    init() {}

    // MARK: LookRendering

    func apply(_ preset: LookPreset, to image: CIImage, isLogSource: Bool) -> CIImage {
        var out = image
        if isLogSource {
            out = colorCube(out, data: logToDisplayCubeData(), dimension: Self.logCubeDimension)
        }
        guard preset != .native else { return out }
        out = colorCube(out, data: cubeData(for: preset), dimension: Self.cubeDimension)
        if preset.family == .leica && enableVignette {
            out = vignette(out)
        }
        return out
    }

    /// Generates all cubes up front (call off the render path, e.g. at launch).
    func prewarm() {
        _ = logToDisplayCubeData()
        for p in LookPreset.allCases { _ = cubeData(for: p) }
    }

    // MARK: Cube data (internal for tests)

    /// Float32 RGBA cube for `preset`, generated lazily once and cached.
    func cubeData(for preset: LookPreset) -> Data {
        lock.lock(); defer { lock.unlock() }
        if let d = cubeCache[preset] { return d }
        let params = preset.gradeParams
        let d = CubeBuilder.build(dimension: Self.cubeDimension) { rgb in
            params?.apply(rgb) ?? rgb
        }
        cubeCache[preset] = d
        return d
    }

    /// Apple Log -> display cube (same mapping per channel), cached.
    func logToDisplayCubeData() -> Data {
        lock.lock(); defer { lock.unlock() }
        if let d = logCube { return d }
        // Per-channel 1D table so the 3D build only does lookups.
        let n = Self.logCubeDimension
        let table = (0..<n).map { AppleLogCurve.toDisplay(Float($0) / Float(n - 1)) }
        let d = CubeBuilder.build(dimension: n) { rgb in
            // Grid points are exact multiples of 1/(n-1), so rounding recovers the index.
            func lut(_ v: Float) -> Float { table[min(max(Int((v * Float(n - 1)).rounded()), 0), n - 1)] }
            return SIMD3<Float>(lut(rgb.x), lut(rgb.y), lut(rgb.z))
        }
        logCube = d
        return d
    }

    // MARK: Filters (fresh instance per call: CIFilter is not thread-safe)

    private func colorCube(_ image: CIImage, data: Data, dimension: Int) -> CIImage {
        let f = CIFilter.colorCubeWithColorSpace()
        f.inputImage = image
        f.cubeDimension = Float(dimension)
        f.cubeData = data
        f.colorSpace = Self.cubeColorSpace
        return f.outputImage ?? image
    }

    private func vignette(_ image: CIImage) -> CIImage {
        let ext = image.extent
        guard !ext.isInfinite, !ext.isEmpty else { return image }
        // vignetteEffect takes a pixel radius, so it scales with the frame (CIVignette does not).
        let f = CIFilter.vignetteEffect()
        f.inputImage = image
        f.center = CGPoint(x: ext.midX, y: ext.midY)
        f.radius = Float(hypot(ext.width, ext.height) * 0.5 * 0.85)
        f.intensity = 0.4
        f.falloff = 0.5
        return (f.outputImage ?? image).cropped(to: ext)
    }
}
