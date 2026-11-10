//  LuxVideoPlayer.swift
//  Video playback for the media viewer with LuxCam's own controls.
//
//  SwiftUI's `VideoPlayer` showed its three round transport buttons without glyphs on iOS 26
//  in this viewer, so playback uses an AVPlayerLayer plus custom, always-visible controls:
//  −10 s / play-pause / +10 s, a scrubber and elapsed / total time.

import SwiftUI
import UIKit
import AVFoundation

/// Hosts an AVPlayerLayer (aspect-fit).
private struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer

    final class LayerView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }

    func makeUIView(context: Context) -> LayerView {
        let view = LayerView()
        view.backgroundColor = .black
        view.playerLayer.videoGravity = .resizeAspect
        view.playerLayer.player = player
        return view
    }

    func updateUIView(_ uiView: LayerView, context: Context) {
        if uiView.playerLayer.player !== player { uiView.playerLayer.player = player }
    }
}

/// Observes playback time / state of one AVPlayer and owns the observers' lifetime.
private final class PlaybackModel: ObservableObject {
    @Published var current: Double = 0
    @Published var duration: Double = 0
    @Published var isPlaying = false

    private weak var player: AVPlayer?
    private var timeToken: Any?
    private var endToken: NSObjectProtocol?
    private var rateObservation: NSKeyValueObservation?

    func attach(_ player: AVPlayer) {
        guard self.player !== player else { return }
        detach()
        self.player = player
        timeToken = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 10),
                                                   queue: .main) { [weak self, weak player] time in
            guard let self = self else { return }
            self.current = time.seconds.isFinite ? time.seconds : 0
            if let d = player?.currentItem?.duration.seconds, d.isFinite, d > 0 { self.duration = d }
        }
        rateObservation = player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] p, _ in
            let playing = p.timeControlStatus != .paused
            DispatchQueue.main.async { self?.isPlaying = playing }
        }
        endToken = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime,
                                                          object: player.currentItem, queue: .main) { [weak self] _ in
            self?.isPlaying = false
        }
    }

    func detach() {
        if let token = timeToken { player?.removeTimeObserver(token) }
        timeToken = nil
        if let token = endToken { NotificationCenter.default.removeObserver(token) }
        endToken = nil
        rateObservation?.invalidate()
        rateObservation = nil
        player = nil
    }

    deinit { detach() }
}

struct LuxVideoPlayer: View {
    let player: AVPlayer

    @StateObject private var model = PlaybackModel()
    @State private var showControls = true
    @State private var scrubValue: Double = 0
    @State private var isScrubbing = false
    @State private var hideToken = UUID()

    var body: some View {
        ZStack {
            PlayerLayerView(player: player)
                .contentShape(Rectangle())
                .onTapGesture { toggleControls() }

            if showControls {
                controls
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: showControls)
        .onAppear { model.attach(player) }
        .onDisappear {
            player.pause()
            model.detach()
        }
        .onChange(of: model.isPlaying) { _, playing in
            if playing { scheduleHide() } else { showControls = true }
        }
    }

    // MARK: Controls

    private var controls: some View {
        VStack(spacing: 0) {
            Spacer()
            HStack(spacing: 36) {
                roundButton("gobackward.10", size: 52) { seek(by: -10) }
                    .accessibilityLabel("10秒戻る")
                roundButton(model.isPlaying ? "pause.fill" : "play.fill", size: 68) { togglePlay() }
                    .accessibilityLabel(model.isPlaying ? "一時停止" : "再生")
                roundButton("goforward.10", size: 52) { seek(by: 10) }
                    .accessibilityLabel("10秒進む")
            }
            Spacer()
            scrubber
                .padding(.horizontal, Theme.gutter)
                .padding(.bottom, 12)
        }
    }

    private func roundButton(_ symbol: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: {
            action()
            scheduleHide()
        }) {
            Image(systemName: symbol)
                .font(.system(size: size * 0.38, weight: .medium))
                .foregroundStyle(Color.white)
                .frame(width: size, height: size)
                .background(Circle().fill(Color.black.opacity(0.55)))
                .overlay(Circle().stroke(Color.white.opacity(0.35), lineWidth: 0.75))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }

    private var scrubber: some View {
        HStack(spacing: 10) {
            Text(Fmt.mmss(isScrubbing ? scrubValue : model.current))
                .font(Theme.mono(11, .medium))
                .foregroundStyle(Theme.text)
                .monospacedDigit()
                .frame(minWidth: 44, alignment: .leading)
            Slider(value: Binding(get: { isScrubbing ? scrubValue : model.current },
                                  set: { scrubValue = $0 }),
                   in: 0...max(model.duration, 0.1),
                   onEditingChanged: { editing in
                       if editing {
                           isScrubbing = true
                           scrubValue = model.current
                       } else {
                           seek(to: scrubValue)
                           isScrubbing = false
                           scheduleHide()
                       }
                   })
                .tint(Theme.red)
            Text(Fmt.mmss(model.duration))
                .font(Theme.mono(11, .medium))
                .foregroundStyle(Theme.dim)
                .monospacedDigit()
                .frame(minWidth: 44, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.black.opacity(0.55), in: Capsule())
    }

    // MARK: Actions

    private func togglePlay() {
        if model.isPlaying {
            player.pause()
        } else {
            // Restart from the beginning when the clip has ended.
            if model.duration > 0, model.current >= model.duration - 0.1 {
                player.seek(to: .zero)
            }
            player.play()
        }
    }

    private func seek(by delta: Double) {
        let target = min(max(model.current + delta, 0), max(model.duration, 0))
        seek(to: target)
    }

    private func seek(to seconds: Double) {
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero)
        model.current = seconds
    }

    private func toggleControls() {
        showControls.toggle()
        if showControls { scheduleHide() }
    }

    /// Hides the controls 3 s after the last interaction while playing.
    private func scheduleHide() {
        let token = UUID()
        hideToken = token
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            if hideToken == token, model.isPlaying, !isScrubbing { showControls = false }
        }
    }
}
