//  CameraScreen.swift
//  Main portrait layout: top bar, viewfinder, manual controls, mode strip, bottom bar.

import SwiftUI

struct CameraScreen: View {
    @ObservedObject var camera: CameraService

    @State private var showGrid = false
    @State private var reticlePoint: CGPoint = .zero
    @State private var reticleVisible = false
    @State private var reticleToken = UUID()
    @State private var flash = false
    @State private var dismissedError: String?

    private var state: CameraState { camera.state }

    var body: some View {
        ZStack {
            Theme.black.ignoresSafeArea()
            VStack(spacing: 0) {
                TopBarView(state: state)
                viewfinder
                controls
            }
            errorBanner
            // Shutter flash.
            Color.black.opacity(flash ? 1 : 0)
                .ignoresSafeArea()
                .allowsHitTesting(false)
        }
        .onChange(of: state.isCapturingPhoto) { _, capturing in
            guard capturing else { return }
            flash = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                withAnimation(.easeOut(duration: 0.2)) { flash = false }
            }
        }
    }

    // MARK: Viewfinder

    /// width / height
    private var aspect: CGFloat { state.mode.isVideo ? 9.0 / 16.0 : 3.0 / 4.0 }

    private var viewfinder: some View {
        ZStack {
            previewStack
                .aspectRatio(aspect, contentMode: state.mode.isVideo ? .fill : .fit)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .bottom) { ViewfinderHUD(state: state) }
        .clipped()
        .contentShape(Rectangle())
        .simultaneousGesture(swipeGesture)
        .animation(.easeInOut(duration: 0.25), value: state.mode)
    }

    private var previewStack: some View {
        ZStack {
            CameraPreviewView(
                frames: camera.frames,
                look: state.look,
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

    /// Horizontal swipe on the viewfinder switches mode.
    private var swipeGesture: some Gesture {
        DragGesture(minimumDistance: 40)
            .onEnded { g in
                guard !state.isRecording,
                      abs(g.translation.width) > abs(g.translation.height) * 1.5 else { return }
                let modes = CameraMode.allCases
                guard let i = modes.firstIndex(of: state.mode) else { return }
                let next = g.translation.width < 0 ? i + 1 : i - 1
                if modes.indices.contains(next) { camera.set(mode: modes[next]) }
            }
    }

    // MARK: Controls

    private var controls: some View {
        VStack(spacing: 8) {
            ManualControlsView(camera: camera)
            ModeStrip(camera: camera)
            bottomBar
        }
        .padding(.top, 10)
        .background(Theme.black)
    }

    private var bottomBar: some View {
        HStack {
            thumbnail.frame(maxWidth: .infinity, alignment: .leading)
            ShutterButton(mode: state.mode, isRecording: state.isRecording, isBusy: state.isCapturingPhoto) {
                if state.mode.isVideo { camera.toggleRecording() } else { camera.capturePhoto() }
            }
            gridButton.frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 28)
        .padding(.bottom, 6)
    }

    private var thumbnail: some View {
        Group {
            if let image = state.lastThumbnail {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Theme.panel
            }
        }
        .frame(width: 52, height: 52)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(Theme.hairline, lineWidth: 0.5))
        .accessibilityLabel("最新の撮影")
    }

    private var gridButton: some View {
        Button {
            showGrid.toggle()
        } label: {
            Image(systemName: "grid")
                .font(.system(size: 20, weight: .light))
                .foregroundStyle(showGrid ? Theme.red : Theme.text)
                .frame(width: 52, height: 52)
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
