//  ViewfinderHUD.swift
//  Top bar (logo, look label, REC timer, format badge) and the live exposure readout.

import SwiftUI

/// "M9 · SUMMILUX 35"
private func gearLabel(_ state: CameraState) -> String {
    "\(state.gear.body.shortTitle) · \(state.gear.lens.shortTitle)"
}

private func lookLabel(_ state: CameraState) -> String {
    "\(state.look.family.title) · \(state.look.title)"
}

private struct RAWBadge: View {
    var body: some View {
        Text("RAW")
            .font(Theme.mono(10, .semibold))
            .foregroundStyle(Theme.red)
            .padding(.horizontal, 5).padding(.vertical, 2)
            .overlay(Rectangle().stroke(Theme.red, lineWidth: 0.5))
    }
}

private struct RecordingTimer: View {
    let seconds: Double
    var body: some View {
        HStack(spacing: 5) {
            // Blinking record dot.
            TimelineView(.periodic(from: .now, by: 0.5)) { ctx in
                let on = Int(ctx.date.timeIntervalSinceReferenceDate * 2) % 2 == 0
                Circle().fill(Theme.red).frame(width: 7, height: 7).opacity(on ? 1 : 0.15)
            }
            Text(Fmt.mmss(seconds))
                .font(Theme.mono(13, .medium))
                .foregroundStyle(Theme.red)
                .monospacedDigit()
        }
    }
}

/// REC timer + format badge (video) or RAW badge (photo with ProRAW).
private struct FormatInfo: View {
    let state: CameraState
    var alignment: HorizontalAlignment = .trailing

    var body: some View {
        if state.mode.isVideo {
            VStack(alignment: alignment, spacing: 2) {
                if state.isRecording { RecordingTimer(seconds: state.recordingSeconds) }
                Text(state.video.badgeText)
                    .font(Theme.mono(9))
                    .foregroundStyle(Theme.dim)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
        } else if state.mode == .photo && state.photoFormat == .proRAW {
            RAWBadge()
        }
    }
}

/// Portrait top bar: logo, gear + look label (tap the gear label for the picker), REC / format.
struct TopBarView: View {
    let state: CameraState
    var onGearTap: () -> Void = {}

    var body: some View {
        ZStack {
            HStack(spacing: 6) {
                RedDot()
                Text("LuxCam").luxCaps(11, weight: .semibold)
                Spacer()
            }
            VStack(spacing: 2) {
                Button(action: onGearTap) {
                    Text(gearLabel(state))
                        .luxCaps(10, weight: .semibold, color: Theme.text)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(state.isRecording)
                .opacity(state.isRecording ? 0.35 : 1)
                .accessibilityLabel("ギア選択")
                Text(lookLabel(state))
                    .luxCaps(9, color: Theme.dim)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
            .padding(.horizontal, 100)
            HStack {
                Spacer()
                FormatInfo(state: state)
                    .frame(maxWidth: 140, alignment: .trailing)
            }
        }
        .padding(.horizontal, Theme.gutter)
        .frame(height: 44)
    }
}

/// Landscape control-column header: logo, gear, look, REC / format.
struct LandscapeInfoView: View {
    let state: CameraState
    var onGearTap: () -> Void = {}

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    RedDot(size: 7)
                    Text("LuxCam").luxCaps(10, weight: .semibold)
                }
                Button(action: onGearTap) {
                    Text(gearLabel(state))
                        .luxCaps(9, weight: .semibold, color: Theme.text)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(state.isRecording)
                .opacity(state.isRecording ? 0.35 : 1)
                .accessibilityLabel("ギア選択")
                Text(lookLabel(state))
                    .luxCaps(8, color: Theme.dim)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
            Spacer(minLength: 0)
            FormatInfo(state: state)
                .frame(maxWidth: 110, alignment: .trailing)
        }
        .padding(.horizontal, 12)
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
            if state.liveZoomFactor > 1.01 {
                Text(String(format: "%.1f×", Double(state.liveZoomFactor))).foregroundStyle(Theme.text)
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
