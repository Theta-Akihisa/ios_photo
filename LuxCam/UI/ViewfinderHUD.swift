//  ViewfinderHUD.swift
//  Top bar (logo, look label, REC timer, format badge) and the live exposure readout.

import SwiftUI

struct TopBarView: View {
    let state: CameraState

    private var lookLabel: String {
        "\(state.look.family.title) · \(state.look.title)"
    }

    var body: some View {
        ZStack {
            HStack(spacing: 6) {
                RedDot()
                Text("LuxCam").luxCaps(11, weight: .semibold)
                Spacer()
            }
            Text(lookLabel)
                .luxCaps(10, color: Theme.dim)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .padding(.horizontal, 90)
            HStack {
                Spacer()
                if state.mode.isVideo { videoInfo }
                else if state.mode == .photo && state.photoFormat == .proRAW {
                    Text("RAW")
                        .font(Theme.mono(10, .semibold))
                        .foregroundStyle(Theme.red)
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .overlay(Rectangle().stroke(Theme.red, lineWidth: 0.5))
                }
            }
        }
        .padding(.horizontal, Theme.gutter)
        .frame(height: 44)
    }

    private var videoInfo: some View {
        VStack(alignment: .trailing, spacing: 2) {
            if state.isRecording {
                HStack(spacing: 5) {
                    // Blinking record dot.
                    TimelineView(.periodic(from: .now, by: 0.5)) { ctx in
                        let on = Int(ctx.date.timeIntervalSinceReferenceDate * 2) % 2 == 0
                        Circle().fill(Theme.red).frame(width: 7, height: 7).opacity(on ? 1 : 0.15)
                    }
                    Text(Fmt.mmss(state.recordingSeconds))
                        .font(Theme.mono(13, .medium))
                        .foregroundStyle(Theme.red)
                        .monospacedDigit()
                }
            }
            Text(state.video.badgeText)
                .font(Theme.mono(9))
                .foregroundStyle(Theme.dim)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .frame(maxWidth: 140, alignment: .trailing)
    }
}

/// "ISO 125  1/250  ƒ/2.8  AF 0.42" — values turn red while manually overridden.
struct ViewfinderHUD: View {
    let state: CameraState

    private var manualExposure: Bool { state.manual.exposure != .auto }
    private var manualFocus: Bool { state.manual.focus != .auto }
    private var showsAperture: Bool { state.mode == .portrait || state.mode == .cinematic }

    var body: some View {
        HStack(spacing: 12) {
            Text("ISO \(Fmt.iso(state.liveISO))").foregroundStyle(manualExposure ? Theme.red : Theme.text)
            Text(Fmt.shutter(state.liveShutterSeconds)).foregroundStyle(manualExposure ? Theme.red : Theme.text)
            if showsAperture {
                Text(Fmt.aperture(state.simulatedAperture)).foregroundStyle(Theme.text)
            }
            Text("\(manualFocus ? "MF" : "AF") \(Fmt.lens(state.liveLensPosition))")
                .foregroundStyle(manualFocus ? Theme.red : Theme.text)
        }
        .font(Theme.mono(11, .medium))
        .monospacedDigit()
        .padding(.horizontal, 12).padding(.vertical, 5)
        .background(Color.black.opacity(0.45), in: Capsule())
        .padding(.bottom, 8)
        .allowsHitTesting(false)
    }
}
