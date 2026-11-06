//  CameraScreen.swift
//  Main screen. Portrait: top bar, viewfinder, controls. Landscape (verticalSizeClass == .compact):
//  viewfinder on the leading side, control column on the trailing side.

import SwiftUI

struct CameraScreen: View {
    @ObservedObject var camera: CameraService
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    @State private var showGrid = false
    @State private var showGear = false
    @State private var reticlePoint: CGPoint = .zero
    @State private var reticleVisible = false
    @State private var reticleToken = UUID()
    @State private var flash = false
    @State private var dismissedError: String?

    private var state: CameraState { camera.state }
    private var isLandscape: Bool { verticalSizeClass == .compact }
    /// Width of the landscape control column (excluding the trailing safe area).
    private let columnWidth: CGFloat = 270

    var body: some View {
        ZStack {
            Theme.black.ignoresSafeArea()
            if isLandscape { landscapeLayout } else { portraitLayout }
            errorBanner
            // Shutter flash.
            Color.black.opacity(flash ? 1 : 0)
                .ignoresSafeArea()
                .allowsHitTesting(false)
        }
        .animation(.easeInOut(duration: 0.25), value: state.mode)
        .sheet(isPresented: $showGear) { GearPickerView(camera: camera) }
        .onChange(of: state.isCapturingPhoto) { _, capturing in
            guard capturing else { return }
            flash = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                withAnimation(.easeOut(duration: 0.2)) { flash = false }
            }
        }
    }

    /// Opaque black in photo modes, translucent over the full-bleed video preview.
    private var barBackground: Color {
        state.mode.isVideo ? Color.black.opacity(0.45) : Theme.black
    }

    /// Portrait photo aspect (width / height) of the emulated body: 3:2 -> 2:3, 4:3 -> 3:4.
    private var portraitPhotoAspect: CGFloat { 1 / state.gear.body.photoAspect }

    // MARK: Portrait layout

    private var portraitLayout: some View {
        ZStack {
            // VIDEO / CINEMATIC: like the stock Camera app, the 9:16 preview sits behind the
            // whole UI and the bars float over it on a translucent background.
            if state.mode.isVideo {
                GeometryReader { geo in
                    fittedPreview(in: geo.size, aspect: 9.0 / 16.0, swipeAxis: .horizontal)
                }
                .ignoresSafeArea()
                .transition(.opacity)
            }
            VStack(spacing: 0) {
                TopBarView(state: state, onGearTap: { showGear = true })
                    .background(barBackground)
                    .fixedSize(horizontal: false, vertical: true)
                portraitViewfinderSlot
                controls
                    .background(barBackground.ignoresSafeArea(edges: .bottom))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// The flexible area between the top bar and the controls. It always takes exactly the
    /// space that is left, so the preview can never push the controls off screen.
    @ViewBuilder
    private var portraitViewfinderSlot: some View {
        if state.mode.isVideo {
            // The preview is drawn behind (see portraitLayout); this slot only reserves space and shows
            // the HUD. Hit testing is off so taps and swipes reach the preview underneath.
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .bottom) { ViewfinderHUD(state: state) }
                .allowsHitTesting(false)
        } else {
            GeometryReader { geo in
                fittedPreview(in: geo.size, aspect: portraitPhotoAspect, swipeAxis: .horizontal)
                    .overlay(alignment: .bottom) { ViewfinderHUD(state: state) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var controls: some View {
        VStack(spacing: 8) {
            ManualControlsView(camera: camera)
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

    // MARK: Landscape layout

    private var landscapeLayout: some View {
        GeometryReader { geo in
            let insets = geo.safeAreaInsets
            ZStack {
                // Only the preview ignores the safe area.
                landscapePreviewLayer(insets: insets)
                    .ignoresSafeArea()
                HStack(spacing: 0) {
                    Spacer(minLength: 0)
                    landscapeColumn
                        .frame(width: columnWidth)
                        .background(barBackground.ignoresSafeArea())
                }
            }
        }
    }

    private func landscapePreviewLayer(insets: EdgeInsets) -> some View {
        GeometryReader { full in
            if state.mode.isVideo {
                // Full-bleed 16:9 behind the translucent column.
                let area = CGSize(width: max(full.size.width - columnWidth - insets.trailing, 1),
                                  height: full.size.height)
                ZStack(alignment: .topLeading) {
                    fittedPreview(in: full.size, aspect: 16.0 / 9.0, swipeAxis: .vertical)
                    Color.clear
                        .frame(width: area.width, height: area.height)
                        .overlay(alignment: .bottom) { ViewfinderHUD(state: state) }
                        .allowsHitTesting(false)
                }
            } else {
                let leading = insets.leading
                let area = CGSize(width: max(full.size.width - columnWidth - insets.trailing - leading, 1),
                                  height: full.size.height)
                fittedPreview(in: area, aspect: state.gear.body.photoAspect, swipeAxis: .vertical)
                    .overlay(alignment: .bottom) { ViewfinderHUD(state: state) }
                    .frame(width: area.width, height: area.height)
                    .offset(x: leading)
            }
        }
    }

    private var landscapeColumn: some View {
        VStack(spacing: 6) {
            LandscapeInfoView(state: state, onGearTap: { showGear = true })
                .padding(.top, 6)
            ScrollView(.vertical, showsIndicators: false) {
                ManualControlsView(camera: camera, compact: true)
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

    /// Lays out the preview at `aspect` (width / height), as large as fits in `size`, centred.
    /// The frame is computed explicitly, so the preview never influences the parent's layout.
    private func fittedPreview(in size: CGSize, aspect: CGFloat, swipeAxis: Axis) -> some View {
        let fitted: CGSize
        if size.width / max(size.height, 1) > aspect {
            fitted = CGSize(width: size.height * aspect, height: size.height)
        } else {
            fitted = CGSize(width: size.width, height: size.width / aspect)
        }
        return previewStack
            .frame(width: fitted.width, height: fitted.height)
            .clipped()
            .contentShape(Rectangle())
            .simultaneousGesture(swipeGesture(axis: swipeAxis))
            .position(x: size.width / 2, y: size.height / 2)
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

    /// Swipe on the viewfinder switches mode (horizontal in portrait, vertical in landscape).
    private func swipeGesture(axis: Axis) -> some Gesture {
        DragGesture(minimumDistance: 40)
            .onEnded { g in
                let primary = axis == .horizontal ? g.translation.width : g.translation.height
                let secondary = axis == .horizontal ? g.translation.height : g.translation.width
                guard !state.isRecording, abs(primary) > abs(secondary) * 1.5 else { return }
                let modes = CameraMode.allCases
                guard let i = modes.firstIndex(of: state.mode) else { return }
                let next = primary < 0 ? i + 1 : i - 1
                if modes.indices.contains(next) { camera.set(mode: modes[next]) }
            }
    }

    // MARK: Shared pieces

    private var shutter: some View {
        ShutterButton(mode: state.mode, isRecording: state.isRecording, isBusy: state.isCapturingPhoto) {
            if state.mode.isVideo { camera.toggleRecording() } else { camera.capturePhoto() }
        }
    }

    private func thumbnail(size: CGFloat) -> some View {
        Group {
            if let image = state.lastThumbnail {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Theme.panel
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(Theme.hairline, lineWidth: 0.5))
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
        if let message = state.errorMessage, message != dismissedError {
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
                .onTapGesture { dismissedError = message }
                Spacer()
            }
            .transition(.opacity)
        }
    }
}
