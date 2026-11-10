//  CameraScreen.swift
//  Main screen. Portrait: top bar, viewfinder, controls. Landscape (physical, via CoreMotion):
//  overlay laid out in a rotated canvas; viewfinder on the leading side, control column on the trailing side.

import SwiftUI
import UIKit

struct CameraScreen: View {
    @ObservedObject var camera: CameraService
    @StateObject private var orientationObserver = DeviceOrientationObserver()

    @State private var showGrid = false
    @State private var reticlePoint: CGPoint = .zero
    @State private var reticleVisible = false
    @State private var reticleToken = UUID()
    @State private var flash = false
    @State private var showViewer = false
    @State private var errorToken: UUID?
    @State private var fallbackThumbnail: UIImage?
    @StateObject private var manualModel = ManualControlsModel()
    /// Portrait viewfinder slot (global coordinates), reported by the overlay layout.
    @State private var slotFrame: CGRect = .zero

    private var state: CameraState { camera.state }
    private var orientation: PhysicalOrientation { orientationObserver.orientation }
    private var isLandscape: Bool { orientation != .portrait }
    /// Canvas rotation (SwiftUI, positive = clockwise): right side down (user's up = screen -x) -> -90,
    /// left side down -> +90.
    private var canvasDegrees: Double { orientation == .landscapeLeftSideDown ? 90 : -90 }
    /// Width of the landscape control column (excluding the trailing safe area).
    private let columnWidth: CGFloat = 270

    var body: some View {
        GeometryReader { outer in
            let insets = outer.safeAreaInsets
            let screen = CGSize(width: outer.size.width + insets.leading + insets.trailing,
                                height: outer.size.height + insets.top + insets.bottom)
            ZStack {
                Theme.black.ignoresSafeArea()
                // One preview instance for both orientations: only its frame changes.
                previewLayer(insets: insets)
                    .ignoresSafeArea()
                if isLandscape {
                    // Identity per orientation: flipping between the two landscapes cross-fades
                    // instead of spinning the overlay 180°.
                    landscapeOverlay(screen: screen, insets: insets)
                        .id(orientation)
                        .transition(.opacity)
                } else {
                    portraitOverlay
                    errorBanner
                }
                // Shutter flash.
                Color.black.opacity(flash ? 1 : 0)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: state.mode)
        .animation(.easeInOut(duration: 0.25), value: orientation)
        .onAppear { orientationObserver.start() }
        .onDisappear { orientationObserver.stop() }
        .sheet(isPresented: $manualModel.showGear) { GearPickerView(camera: camera) }
        .fullScreenCover(isPresented: $showViewer) {
            MediaViewerView(ids: camera.state.recentAssetIDs, onForget: { camera.forgetAssets($0) })
        }
        .onAppear { loadFallbackThumbnail() }
        .onChange(of: showViewer) { _, shown in
            if shown {
                camera.suspendForViewer()
            } else {
                camera.resumeFromViewer()
                loadFallbackThumbnail()
            }
        }
        .onChange(of: state.errorMessage) { _, message in
            errorToken = message == nil ? nil : UUID()
        }
        .task(id: errorToken) {
            guard errorToken != nil else { return }
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            if !Task.isCancelled { camera.clearError() }
        }
        .onChange(of: state.lastThumbnail == nil) { _, isNil in
            if isNil { loadFallbackThumbnail() }
        }
        .onChange(of: state.recentAssetIDs) { _, _ in loadFallbackThumbnail() }
        // Flash + haptic at the real shutter moment (willCapturePhoto), not at the button press.
        .onChange(of: state.shutterCount) { _, _ in
            flash = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                withAnimation(.easeOut(duration: 0.15)) { flash = false }
            }
        }
        .sensoryFeedback(.impact(weight: .light), trigger: state.shutterCount)
    }

    /// Opaque black in photo modes, translucent over the full-bleed video preview.
    private var barBackground: Color {
        state.mode.isVideo ? Color.black.opacity(0.45) : Theme.black
    }

    /// Portrait photo aspect (width / height) of the emulated body: 3:2 -> 2:3, 4:3 -> 3:4.
    private var portraitPhotoAspect: CGFloat { 1 / state.gear.body.photoAspect }

    // MARK: Portrait overlay

    private var portraitOverlay: some View {
        VStack(spacing: 0) {
            TopBarView(state: state, onGearTap: { manualModel.showGear = true })
                .background(barBackground)
                .fixedSize(horizontal: false, vertical: true)
            // The flexible area between the top bar and the controls. It only reserves space and
            // reports its frame; the persistent preview is drawn underneath.
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(
                    GeometryReader { g in
                        Color.clear.preference(key: SlotFramePreference.self, value: g.frame(in: .global))
                    })
                .allowsHitTesting(false)
            controls
                .background(barBackground.ignoresSafeArea(edges: .bottom))
                .fixedSize(horizontal: false, vertical: true)
        }
        .onPreferenceChange(SlotFramePreference.self) { f in
            if f != slotFrame { slotFrame = f }
        }
    }

    private var controls: some View {
        VStack(spacing: 8) {
            ManualControlsView(camera: camera, model: manualModel)
            ModeStrip(camera: camera)
            bottomBar
        }
        .padding(.top, 10)
        // Background is applied by the caller (opaque in photo modes, translucent in video).
    }

    private var bottomBar: some View {
        HStack {
            thumbnail(size: 52).frame(maxWidth: .infinity, alignment: .leading)
            shutter
            gridButton(size: 52).frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 28)
        .padding(.bottom, 6)
    }

    // MARK: Landscape overlay

    /// Canvas geometry (landscape canvas coordinates: size = (screenH, screenW)).
    private func landscapeGeometry(screen: CGSize, insets: EdgeInsets)
        -> (canvas: CGSize, lead: CGFloat, trail: CGFloat, viewfinder: CGRect) {
        let canvas = CGSize(width: screen.height, height: screen.width)
        // -90: canvas trailing = screen top, leading = screen bottom. +90: swapped.
        let lead = orientation == .landscapeLeftSideDown ? insets.top : insets.bottom
        let trail = orientation == .landscapeLeftSideDown ? insets.bottom : insets.top
        let area = CGRect(x: lead, y: 0,
                          width: max(canvas.width - columnWidth - trail - lead, 1),
                          height: canvas.height)
        let aspect: CGFloat = state.mode.isVideo ? 16.0 / 9.0 : state.gear.body.photoAspect
        return (canvas, lead, trail, fitted(in: area, aspect: aspect))
    }

    private func landscapeOverlay(screen: CGSize, insets: EdgeInsets) -> some View {
        let g = landscapeGeometry(screen: screen, insets: insets)
        return ZStack {
            ViewfinderHUD(state: state)
                .frame(width: g.viewfinder.width, height: g.viewfinder.height, alignment: .bottom)
                .position(x: g.viewfinder.midX, y: g.viewfinder.midY)
                .allowsHitTesting(false)
            // Error banner inside the rotated canvas so it reads in landscape, over the viewfinder only.
            errorBanner
                .frame(width: g.viewfinder.width, height: g.canvas.height)
                .position(x: g.viewfinder.midX, y: g.canvas.height / 2)
            HStack(spacing: 0) {
                Spacer(minLength: 0).allowsHitTesting(false)
                landscapeColumn
                    .padding(.trailing, g.trail)
                    .frame(width: columnWidth + g.trail)
                    .background(barBackground)
            }
        }
        .frame(width: g.canvas.width, height: g.canvas.height)
        .rotationEffect(.degrees(canvasDegrees))
        .position(x: screen.width / 2, y: screen.height / 2)
        .ignoresSafeArea()
    }

    private var landscapeColumn: some View {
        VStack(spacing: 6) {
            LandscapeInfoView(state: state, onGearTap: { manualModel.showGear = true })
                .padding(.top, 6)
            ScrollView(.vertical, showsIndicators: false) {
                ManualControlsView(camera: camera, model: manualModel, compact: true)
                    .frame(maxWidth: .infinity)
            }
            .frame(maxHeight: .infinity)
            HStack(alignment: .center, spacing: 0) {
                ModeStrip(camera: camera, axis: .vertical)
                    .frame(maxWidth: .infinity)
                shutterRail
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(.trailing, 8)
        }
        .padding(.bottom, 4)
    }

    /// Thumbnail above, shutter, grid toggle below.
    private var shutterRail: some View {
        VStack(spacing: 4) {
            thumbnail(size: 36)
            shutter
            gridButton(size: 36)
        }
        .frame(width: 84)
    }

    // MARK: Viewfinder

    /// Largest rect of `aspect` (width / height) that fits in `area`, centred.
    private func fitted(in area: CGRect, aspect: CGFloat) -> CGRect {
        let size: CGSize
        if area.width / max(area.height, 1) > aspect {
            size = CGSize(width: area.height * aspect, height: area.height)
        } else {
            size = CGSize(width: area.width, height: area.width / aspect)
        }
        return CGRect(x: area.midX - size.width / 2, y: area.midY - size.height / 2,
                      width: size.width, height: size.height)
    }

    /// Preview and HUD rects in the full-screen coordinate space of `previewLayer`.
    /// In landscape the HUD lives in the rotated canvas, so `hud` is unused there.
    private func layoutRects(full: CGSize, insets: EdgeInsets, origin: CGPoint) -> (preview: CGRect, hud: CGRect) {
        let screen = CGRect(origin: .zero, size: full)
        if isLandscape {
            let g = landscapeGeometry(screen: full, insets: insets)
            let r = canvasRectToScreen(g.viewfinder, canvas: g.canvas, screen: full, degrees: canvasDegrees)
            return (r, r)
        }
        var slot = slotFrame.offsetBy(dx: -origin.x, dy: -origin.y)
        if slotFrame == .zero || slot.width < 1 || slot.height < 1 { slot = screen }
        if state.mode.isVideo {
            return (fitted(in: screen, aspect: 9.0 / 16.0), slot)
        }
        let r = fitted(in: slot, aspect: portraitPhotoAspect)
        return (r, r)
    }

    /// The single, persistent preview (plus HUD). Its frame is computed from orientation and mode.
    private func previewLayer(insets: EdgeInsets) -> some View {
        GeometryReader { full in
            let origin = full.frame(in: .global).origin
            let r = layoutRects(full: full.size, insets: insets, origin: origin)
            ZStack {
                previewStack
                    .frame(width: r.preview.width, height: r.preview.height)
                    .clipped()
                    .contentShape(Rectangle())
                    .simultaneousGesture(swipeGesture())
                    .position(x: r.preview.midX, y: r.preview.midY)
                if !isLandscape {
                    ViewfinderHUD(state: state)
                        .frame(width: r.hud.width, height: r.hud.height, alignment: .bottom)
                        .position(x: r.hud.midX, y: r.hud.midY)
                        .allowsHitTesting(false)
                }
            }
        }
    }

    private var previewStack: some View {
        ZStack {
            CameraPreviewView(
                frames: camera.frames,
                look: state.look,
                gear: state.gear,
                aperture: (state.mode == .portrait || state.mode == .cinematic) ? state.simulatedAperture : nil,
                renderer: LookRenderer.shared,
                onTap: { devicePoint in camera.focus(at: devicePoint) },
                onTapViewPoint: { viewPoint in showReticle(at: viewPoint) })
            if showGrid { GridOverlay().allowsHitTesting(false) }
            if state.mode == .photo { FrameLinesOverlay().allowsHitTesting(false) }
            FocusReticle(position: reticlePoint, visible: reticleVisible).allowsHitTesting(false)
        }
    }

    private func showReticle(at point: CGPoint) {
        reticlePoint = point
        reticleVisible = true
        let token = UUID()
        reticleToken = token
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            if reticleToken == token { reticleVisible = false }
        }
    }

    /// Swipe on the viewfinder switches mode. Portrait: screen horizontal. Landscape: along the user's
    /// vertical axis = screen x; canvas height = screen x for -90, -screen x for +90.
    private func swipeGesture() -> some Gesture {
        DragGesture(minimumDistance: 40)
            .onEnded { g in
                let primary: CGFloat
                let secondary: CGFloat
                switch orientation {
                case .portrait:
                    primary = g.translation.width; secondary = g.translation.height
                case .landscapeRightSideDown:
                    primary = g.translation.width; secondary = g.translation.height
                case .landscapeLeftSideDown:
                    primary = -g.translation.width; secondary = g.translation.height
                }
                guard !state.isRecording, abs(primary) > abs(secondary) * 1.5 else { return }
                let modes = CameraMode.allCases
                guard let i = modes.firstIndex(of: state.mode) else { return }
                let next = primary < 0 ? i + 1 : i - 1
                if modes.indices.contains(next) { camera.set(mode: modes[next]) }
            }
    }

    // MARK: Shared pieces

    private var shutter: some View {
        ShutterButton(mode: state.mode, isRecording: state.isRecording, isBusy: !state.mode.isVideo && !state.canCapturePhoto) {
            if state.mode.isVideo { camera.toggleRecording() } else { camera.capturePhoto() }
        }
    }

    private var hasMedia: Bool {
        state.lastThumbnail != nil || !state.recentAssetIDs.isEmpty
    }

    private func loadFallbackThumbnail() {
        guard state.lastThumbnail == nil, let id = state.recentAssetIDs.first else {
            fallbackThumbnail = nil
            return
        }
        MediaLibrary.loadThumbnail(localIdentifier: id) { image in
            fallbackThumbnail = image
        }
    }

    private func thumbnail(size: CGFloat) -> some View {
        Button {
            showViewer = true
        } label: {
            Group {
                if let image = state.lastThumbnail ?? fallbackThumbnail {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    Theme.panel
                }
            }
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(Theme.hairline, lineWidth: 0.5))
            .opacity(hasMedia ? 1 : 0.4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!hasMedia || state.isRecording || state.isCapturingPhoto)
        .accessibilityLabel("最新の撮影")
    }

    private func gridButton(size: CGFloat) -> some View {
        Button {
            showGrid.toggle()
        } label: {
            Image(systemName: "grid")
                .font(.system(size: 20, weight: .light))
                .foregroundStyle(showGrid ? Theme.red : Theme.text)
                .frame(width: size, height: size)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.selection, trigger: showGrid)
        .accessibilityLabel("グリッド")
    }

    // MARK: Error

    @ViewBuilder
    private var errorBanner: some View {
        if let message = state.errorMessage {
            VStack {
                HStack(spacing: 10) {
                    RedDot(size: 7)
                    Text(message)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.text)
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 0)
                    Text("閉じる").luxCaps(9, color: Theme.dim)
                }
                .padding(12)
                .background(Color.black.opacity(0.9))
                .overlay(Rectangle().stroke(Theme.red, lineWidth: 0.5))
                .padding(.horizontal, Theme.gutter)
                .padding(.top, 48)
                .onTapGesture { camera.clearError() }
                Spacer()
            }
            .transition(.opacity)
        }
    }
}

private struct SlotFramePreference: PreferenceKey {
    static var defaultValue: CGRect = .zero
    /// Sibling views that don't set this preference contribute `defaultValue` (.zero) here.
    /// Ignore those, otherwise the measured slot is overwritten and the layout falls back to
    /// the full screen (preview hidden under the controls, HUD at the very bottom).
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if next != .zero { value = next }
    }
}
