//  CameraPreviewView.swift
//  Metal-backed live preview: latest camera frame -> look -> aspect-fill drawable.

import CoreImage
import ImageIO
import MetalKit
import SwiftUI
import UIKit

struct CameraPreviewView: UIViewRepresentable {
    let frames: PreviewFrameSource
    let look: LookPreset
    let gear: GearSelection
    let aperture: Float?
    let renderer: LookRendering
    let onTap: (_ devicePoint: CGPoint) -> Void
    let onTapViewPoint: ((CGPoint) -> Void)?

    init(frames: PreviewFrameSource, look: LookPreset, gear: GearSelection = GearSelection(),
         aperture: Float? = nil, renderer: LookRendering,
         onTap: @escaping (_ devicePoint: CGPoint) -> Void,
         onTapViewPoint: ((CGPoint) -> Void)? = nil) {
        self.frames = frames
        self.look = look
        self.gear = gear
        self.aperture = aperture
        self.renderer = renderer
        self.onTap = onTap
        self.onTapViewPoint = onTapViewPoint
    }

    /// Set to true if the preview appears upside down on device.
    /// `CIContext.render(_:to: MTLTexture, ...)` is expected to map Core Image's bottom-left origin
    /// so upright CIImages display upright, hence no explicit flip by default. Tap mapping follows this flag.
    private static let flipVertically = false

    func makeCoordinator() -> Coordinator {
        Coordinator(frames: frames, look: look, gear: gear, aperture: aperture, renderer: renderer,
                    onTap: onTap, onTapViewPoint: onTapViewPoint)
    }

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: context.coordinator.device)
        view.framebufferOnly = false
        view.isPaused = false
        view.enableSetNeedsDisplay = false
        view.preferredFramesPerSecond = 60
        view.colorPixelFormat = .bgra8Unorm
        view.backgroundColor = .black
        view.isOpaque = true
        view.delegate = context.coordinator

        let tap = UITapGestureRecognizer(target: context.coordinator,
                                         action: #selector(Coordinator.handleTap(_:)))
        view.addGestureRecognizer(tap)
        context.coordinator.view = view
        return view
    }

    func updateUIView(_ uiView: MTKView, context: Context) {
        let c = context.coordinator
        c.frames = frames
        c.look = look
        c.gear = gear
        c.aperture = aperture
        c.renderer = renderer
        c.onTap = onTap
        c.onTapViewPoint = onTapViewPoint
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, MTKViewDelegate {
        var frames: PreviewFrameSource
        var look: LookPreset
        var gear: GearSelection
        var aperture: Float?
        var renderer: LookRendering
        var onTap: (CGPoint) -> Void
        var onTapViewPoint: ((CGPoint) -> Void)?
        weak var view: MTKView?

        // Shared across instances so recreating the view is cheap.
        private static let sharedDevice: MTLDevice? = MTLCreateSystemDefaultDevice()
        private static let sharedQueue: MTLCommandQueue? = sharedDevice?.makeCommandQueue()
        private static let sharedContext: CIContext? = sharedDevice.map {
            CIContext(mtlDevice: $0, options: [.cacheIntermediates: false])
        }
        var device: MTLDevice? { Self.sharedDevice }
        private var commandQueue: MTLCommandQueue? { Self.sharedQueue }
        private var ciContext: CIContext? { Self.sharedContext }

        // Change tracking so identical content is not re-rendered.
        private var lastBuffer: UnsafeMutableRawPointer?
        private var lastLook: LookPreset?
        private var lastGear: GearSelection?
        private var lastAperture: Float?
        private var lastOrientation: CGImagePropertyOrientation?
        /// Orientation used for the last drawn frame (tap mapping).
        private var drawnOrientation: CGImagePropertyOrientation = .right
        private var lastIsLog = false
        private var lastDrawableSize: CGSize = .zero
        /// Size of the oriented (portrait) source image, used for tap mapping.
        private var orientedSize = CGSize(width: 3, height: 4)

        init(frames: PreviewFrameSource, look: LookPreset, gear: GearSelection, aperture: Float?,
             renderer: LookRendering,
             onTap: @escaping (CGPoint) -> Void, onTapViewPoint: ((CGPoint) -> Void)?) {
            self.frames = frames
            self.look = look
            self.gear = gear
            self.aperture = aperture
            self.renderer = renderer
            self.onTap = onTap
            self.onTapViewPoint = onTapViewPoint
            super.init()
        }

        // MARK: MTKViewDelegate

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
            lastBuffer = nil // force a redraw at the new size
        }

        func draw(in view: MTKView) {
            guard let ciContext = ciContext, let queue = commandQueue,
                  let (buffer, isLog) = frames.latest() else { return }

            let size = view.drawableSize
            guard size.width > 0, size.height > 0 else { return }

            let ptr = Unmanaged.passUnretained(buffer).toOpaque()
            let currentLook = look
            let currentGear = gear
            let currentAperture = aperture
            let orientation = Self.currentOrientation(for: view)
            if ptr == lastBuffer, currentLook == lastLook, isLog == lastIsLog, size == lastDrawableSize,
               currentGear == lastGear, currentAperture == lastAperture, orientation == lastOrientation {
                return // nothing changed
            }

            // Sensor frames are landscape-right; rotate for portrait UI.
            // Apple Log frames: disable colour management so Core Image does not linearise them
            // before the Log monitoring cube is applied.
            let base = isLog
                ? CIImage(cvPixelBuffer: buffer, options: [.colorSpace: NSNull()])
                : CIImage(cvPixelBuffer: buffer)
            let oriented = base.oriented(orientation)
            let ow = oriented.extent.width, oh = oriented.extent.height
            guard ow > 0, oh > 0 else { return }
            orientedSize = oriented.extent.size
            drawnOrientation = orientation

            // Downscale to roughly the drawable size BEFORE the look/gear (much cheaper bloom/grain/cube).
            let fill = max(size.width / ow, size.height / oh)
            var source = oriented
            if fill < 0.9 {
                let s = fill * 1.1
                source = oriented
                    .transformed(by: CGAffineTransform(translationX: -oriented.extent.origin.x,
                                                       y: -oriented.extent.origin.y))
                    .transformed(by: CGAffineTransform(scaleX: s, y: s))
            }
            let looked = renderer.apply(currentLook, gear: currentGear, aperture: currentAperture,
                                        cheap: false, to: source, isLogSource: isLog)

            let extent = source.extent // the look must not change geometry; use source extent
            guard extent.width > 0, extent.height > 0 else { return }

            // Aspect-fill: move origin to 0, scale to cover, center (optionally flipping Y, see flipVertically).
            let scale = max(size.width / extent.width, size.height / extent.height)
            let scaledW = extent.width * scale
            let scaledH = extent.height * scale
            let tx = (size.width - scaledW) / 2
            let ty = (size.height - scaledH) / 2
            var t = CGAffineTransform(translationX: -extent.origin.x, y: -extent.origin.y)
            t = t.concatenating(CGAffineTransform(scaleX: scale, y: scale))
            t = t.concatenating(CGAffineTransform(translationX: tx, y: ty))
            if CameraPreviewView.flipVertically {
                t = t.concatenating(CGAffineTransform(scaleX: 1, y: -1))
                t = t.concatenating(CGAffineTransform(translationX: 0, y: size.height))
            }

            let bounds = CGRect(origin: .zero, size: size)
            let output = looked.transformed(by: t).cropped(to: bounds)

            guard let drawable = view.currentDrawable,
                  let cb = queue.makeCommandBuffer() else { return }

            ciContext.render(output, to: drawable.texture, commandBuffer: cb,
                             bounds: bounds, colorSpace: CGColorSpaceCreateDeviceRGB())
            cb.present(drawable)
            cb.commit()

            lastBuffer = ptr
            lastLook = currentLook
            lastGear = currentGear
            lastAperture = currentAperture
            lastOrientation = orientation
            lastIsLog = isLog
            lastDrawableSize = size
        }

        // MARK: Orientation

        /// Sensor frames are landscape-right. Read on the main thread (display link).
        private static func currentOrientation(for view: UIView) -> CGImagePropertyOrientation {
            switch view.window?.windowScene?.interfaceOrientation {
            case .landscapeRight: return .up
            case .landscapeLeft: return .down
            default: return .right
            }
        }

        // MARK: Tap handling

        @objc func handleTap(_ gr: UITapGestureRecognizer) {
            guard let view = gr.view else { return }
            let p = gr.location(in: view)
            let b = view.bounds
            guard b.width > 0, b.height > 0 else { return }

            // Aspect-fill geometry of the oriented image inside the view.
            let iw = max(orientedSize.width, 1), ih = max(orientedSize.height, 1)
            let scale = max(b.width / iw, b.height / ih)
            let dispW = iw * scale, dispH = ih * scale
            let offX = (b.width - dispW) / 2, offY = (b.height - dispH) / 2

            let xNorm = min(max((p.x - offX) / dispW, 0), 1)
            var yNorm = min(max((p.y - offY) / dispH, 0), 1)
            if CameraPreviewView.flipVertically { yNorm = 1 - yNorm } // image is drawn flipped

            // Oriented image -> landscape-right sensor point of interest.
            let device: CGPoint
            switch drawnOrientation {
            case .up: device = CGPoint(x: xNorm, y: yNorm)
            case .down: device = CGPoint(x: 1 - xNorm, y: 1 - yNorm)
            default: device = CGPoint(x: yNorm, y: 1 - xNorm)   // .right (portrait)
            }
            onTapViewPoint?(p)
            onTap(device)
        }
    }
}
