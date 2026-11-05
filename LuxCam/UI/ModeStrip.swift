//  ModeStrip.swift
//  CINEMATIC VIDEO PHOTO PORTRAIT, selected label centred with a red dot below.

import SwiftUI

struct ModeStrip: View {
    @ObservedObject var camera: CameraService

    var body: some View {
        GeometryReader { geo in
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 26) {
                        ForEach(CameraMode.allCases) { mode in
                            label(for: mode).id(mode)
                        }
                    }
                    .padding(.horizontal, max(0, geo.size.width / 2 - 40))
                }
                .scrollDisabled(true)
                .onAppear {
                    DispatchQueue.main.async { proxy.scrollTo(camera.state.mode, anchor: .center) }
                }
                .onChange(of: camera.state.mode) { _, new in
                    withAnimation(.easeInOut(duration: 0.25)) { proxy.scrollTo(new, anchor: .center) }
                }
            }
        }
        .frame(height: 34)
        .sensoryFeedback(.selection, trigger: camera.state.mode)
    }

    private func label(for mode: CameraMode) -> some View {
        let selected = camera.state.mode == mode
        return Button {
            camera.set(mode: mode)
        } label: {
            VStack(spacing: 5) {
                Text(mode.title)
                    .luxCaps(11, weight: selected ? .semibold : .regular,
                             color: selected ? Theme.text : Theme.dim)
                Circle().fill(Theme.red).frame(width: 4, height: 4)
                    .opacity(selected ? 1 : 0)
            }
            .frame(minHeight: 30)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(camera.state.isRecording)
        .opacity(camera.state.isRecording && !selected ? 0.3 : 1)
    }
}
