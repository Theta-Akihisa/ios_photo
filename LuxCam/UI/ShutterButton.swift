//  ShutterButton.swift
//  Photo: white ring + white disk. Video: white ring + red disk that morphs into a rounded square while recording.

import SwiftUI

struct ShutterButton: View {
    let mode: CameraMode
    let isRecording: Bool
    var isBusy: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().strokeBorder(Color.white, lineWidth: 3).frame(width: 74, height: 74)
                RoundedRectangle(cornerRadius: isRecording ? 7 : 29, style: .continuous)
                    .fill(mode.isVideo ? Theme.red : Color.white)
                    .frame(width: isRecording ? 30 : 58, height: isRecording ? 30 : 58)
            }
            .frame(width: 80, height: 80)
            .contentShape(Circle())
        }
        .buttonStyle(ShutterPressStyle())
        .disabled(isBusy)
        .animation(.spring(response: 0.3, dampingFraction: 0.75), value: isRecording)
        .animation(.easeInOut(duration: 0.2), value: mode)
        .accessibilityLabel(mode.isVideo ? (isRecording ? "録画を停止" : "録画を開始") : "撮影")
    }
}

private struct ShutterPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

#Preview {
    HStack(spacing: 30) {
        ShutterButton(mode: .photo, isRecording: false) {}
        ShutterButton(mode: .video, isRecording: false) {}
        ShutterButton(mode: .video, isRecording: true) {}
    }
    .padding()
    .background(Color.black)
}
