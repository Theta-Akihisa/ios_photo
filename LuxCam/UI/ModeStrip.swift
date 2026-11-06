//  ModeStrip.swift
//  CINEMATIC VIDEO PHOTO PORTRAIT, selected label centred with a red dot (below when horizontal, beside when vertical).

import SwiftUI

struct ModeStrip: View {
    @ObservedObject var camera: CameraService
    var axis: Axis = .horizontal

    private var scrollAxes: Axis.Set { axis == .horizontal ? .horizontal : .vertical }

    var body: some View {
        GeometryReader { geo in
            ScrollViewReader { proxy in
                ScrollView(scrollAxes, showsIndicators: false) {
                    if axis == .horizontal {
                        HStack(spacing: 26) {
                            ForEach(CameraMode.allCases) { mode in
                                label(for: mode).id(mode)
                            }
                        }
                        .padding(.horizontal, max(0, geo.size.width / 2 - 40))
                    } else {
                        VStack(spacing: 4) {
                            ForEach(CameraMode.allCases) { mode in
                                label(for: mode).id(mode)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, max(0, geo.size.height / 2 - 17))
                    }
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
        .frame(width: axis == .vertical ? 112 : nil, height: axis == .horizontal ? 34 : 150)
        .sensoryFeedback(.selection, trigger: camera.state.mode)
    }

    @ViewBuilder
    private func labelContent(for mode: CameraMode, selected: Bool) -> some View {
        let text = Text(mode.title)
            .luxCaps(11, weight: selected ? .semibold : .regular,
                     color: selected ? Theme.text : Theme.dim)
        let dot = Circle().fill(Theme.red).frame(width: 4, height: 4).opacity(selected ? 1 : 0)
        if axis == .horizontal {
            VStack(spacing: 5) { text; dot }
        } else {
            HStack(spacing: 6) { dot; text }
        }
    }

    private func label(for mode: CameraMode) -> some View {
        let selected = camera.state.mode == mode
        return Button {
            camera.set(mode: mode)
        } label: {
            labelContent(for: mode, selected: selected)
                .frame(minHeight: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(camera.state.isRecording)
        .opacity(camera.state.isRecording && !selected ? 0.3 : 1)
    }
}
