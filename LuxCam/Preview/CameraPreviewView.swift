//  CameraPreviewView.swift
//  Metal-backed live preview: latest camera frame -> look -> aspect-fill drawable.

import CoreImage
import MetalKit
import SwiftUI
import UIKit

struct CameraPreviewView: UIViewRepresentable {
    let frames: PreviewFrameSource
    let look: LookPreset
    let renderer: LookRendering
    let onTap: (_ devicePoint: CGPoint) -> Void
    let onTapViewPoint: ((CGPoint) -> Void)?

    init(frames: PreviewFrameSource, look: LookPreset, renderer: LookRendering,
         onTap: @escaping (_ devicePoint: CGPoint) -> Void,
         onTapViewPoint: ((CGPoint) -> Void)? = nil) {
        self.frames = frames
        self.look = look
        self.renderer = renderer
        self.onTap = onTap
        self.onTapViewPoint = onTapViewPoint
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(frames: frames, look: look, renderer: renderer,
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
        c.renderer = renderer
        c.onTap = onTap
        c.onTapViewPoint = onTapViewPoint
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, MTKViewDelegate {
        var frames: PreviewFrameSource
        var look: LookPreset
        var renderer: LookRendering
        var onTap: (CGPoint) -> Void
        var onTapViewPoint: ((CGPoint) -> Void)?
        weak var view: MTKView?

        let device: MTLDevice?
        private let commandQueue: MTLCommandQueue?
        private let ciContext: CIContext?

        // Change tracking so identical content is not re-rendered.
        private var lastBuffer: UnsafeMutableRawPointer?
        private var lastLook: LookPreset?
        private var lastIsLog = false
        private var lastDrawableSize: CGSize = .zero
        /// Size of the oriented (portrait) source image, used for tap mapping.
        private var orientedSize = CGSize(width: 3, height: 4)

        init(frames: PreviewFrameSource, look: LookPreset, renderer: LookRendering,
             onTap: @escaping (CGPoint) -> Void, onTapViewPoint: ((CGPoint) -> Void)?) {
            self.frames = frames
            self.look = look
            self.renderer = renderer
            self.onTap = onTap
            self.onTapViewPoint = onTapViewPoint
            let dev = MTLCreateSystemDefaultDevice()
            self.device = dev
            self.commandQueue = dev?.makeCommandQueue()
            if let dev = dev {
                self.ciContext = CIContext(mtlDevice: dev, options: [.cacheIntermediates: false])
            } else {
                self.ciContext = nil
            }
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
            if ptr == lastBuffer, currentLook == lastLook, isLog == lastIsLog, size == lastDrawableSize {
                return // nothing changed
            }

            // Sensor frames are landscape-right; rotate for portrait UI.
            let source = CIImage(cvPixelBuffer: buffer).oriented(.right)
            let looked = renderer.apply(currentLook, to: source, isLogSource: isLog)

            let extent = source.extent // the look must not change geometry; use source extent
            guard extent.width > 0, extent.height > 0 else { return }
            orientedSize = extent.size

            // Aspect-fill: move origin to 0, scale to cover, center, then flip Y
            // (CIImage is bottom-left origin, Metal texture is top-left).
            let scale = max(size.width / extent.width, size.height / extent.height)
            let scaledW = extent.width * scale
            let scaledH = extent.height * scale
            let tx = (size.width - scaledW) / 2
            let ty = (size.height - scaledH) / 2
            var t = CGAffineTransform(translationX: -extent.origin.x, y: -extent.origin.y)
            t = t.concatenating(CGAffineTransform(scaleX: scale, y: scale))
            t = t.concatenating(CGAffineTransform(translationX: tx, y: ty))
            // Vertical flip within the drawable.
            t = t.concatenating(CGAffineTransform(scaleX: 1, y: -1))
            t = t.concatenating(CGAffineTransform(translationX: 0, y: size.height))

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
            lastIsLog = isLog
            lastDrawableSize = size
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
            let yNorm = min(max((p.y - offY) / dispH, 0), 1)

            // Oriented-right portrait -> landscape-right sensor point of interest.
            let device = CGPoint(x: yNorm, y: 1 - xNorm)
            onTapViewPoint?(p)
            onTap(device)
        }
    }
}
