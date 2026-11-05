//  LookPickerView.swift
//  Family selector + horizontally scrolling preset cards. Selected card gets a red underline.

import SwiftUI

struct LookPickerView: View {
    @ObservedObject var camera: CameraService
    /// Family currently browsed; nil follows the active look's family.
    @State private var browsedFamily: LookFamily?

    private var family: LookFamily { browsedFamily ?? camera.state.look.family }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            familySelector
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(LookPreset.presets(in: family)) { preset in
                        card(preset)
                    }
                }
            }
        }
    }

    private var familySelector: some View {
        HStack(spacing: 18) {
            ForEach(LookFamily.allCases) { f in
                Button {
                    browsedFamily = f
                } label: {
                    Text(f.title)
                        .luxCaps(10, weight: f == family ? .semibold : .regular,
                                 color: f == family ? Theme.text : Theme.dim)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
    }

    private func card(_ preset: LookPreset) -> some View {
        let selected = camera.state.look == preset
        return Button {
            camera.set(look: preset)
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                Text(preset.title).luxCaps(11, weight: .semibold, color: selected ? Theme.text : Theme.dim)
                Text(preset.shortDescription)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.dim)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Rectangle()
                    .fill(selected ? Theme.red : Color.clear)
                    .frame(height: 2)
            }
            .padding(10)
            .frame(width: 150, height: 78, alignment: .topLeading)
            .background(Theme.panel)
            .overlay(Rectangle().stroke(Theme.hairline, lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.selection, trigger: selected)
    }
}
