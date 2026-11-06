//  GearPickerView.swift
//  Sheet: camera body (family tabs + list) and lens list for the selected body.

import SwiftUI

struct GearPickerView: View {
    @ObservedObject var camera: CameraService
    @Environment(\.dismiss) private var dismiss
    /// Family currently browsed; nil follows the active body's family.
    @State private var browsedFamily: LookFamily?

    private static let families: [LookFamily] = [.native, .leica, .hasselblad]

    private var gear: GearSelection { camera.state.gear }
    private var family: LookFamily { browsedFamily ?? gear.body.family }

    var body: some View {
        ZStack {
            Theme.black.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    header
                    familyTabs
                    section("BODY") { bodyList }
                    section("LENS · \(gear.body.shortTitle)") { lensList }
                    Text("各社の描写傾向を参考にしたオリジナルのエミュレーションです（メーカー公認ではありません）")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.dim)
                }
                .padding(Theme.gutter)
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        HStack {
            HStack(spacing: 8) {
                RedDot()
                Text("GEAR").luxCaps(12, weight: .semibold)
            }
            Spacer()
            Button("閉じる") { dismiss() }
                .font(.system(size: 13))
                .foregroundStyle(Theme.text)
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).luxCaps(10, color: Theme.dim)
            Hairline()
            content()
        }
    }

    private var familyTabs: some View {
        HStack(spacing: 0) {
            ForEach(Self.families) { f in
                let on = f == family
                Button {
                    browsedFamily = f
                } label: {
                    VStack(spacing: 4) {
                        Text(f == .native ? "iPhone" : f.title)
                            .luxCaps(11, weight: on ? .semibold : .regular, color: on ? Theme.text : Theme.dim)
                        Rectangle().fill(on ? Theme.red : Color.clear).frame(height: 2)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: Bodies

    private var bodyList: some View {
        VStack(spacing: 0) {
            ForEach(CameraBody.bodies(in: family)) { b in
                bodyRow(b)
            }
        }
    }

    private func cropBadge(_ b: CameraBody) -> String? {
        let c = b.cropFactor
        if abs(c - 1) < 0.001 { return nil }
        let value = String(format: "%.2f", c)
        return c > 1 ? "APS-H ×\(value)" : "中判 ×\(value)"
    }

    private func bodyRow(_ b: CameraBody) -> some View {
        let selected = gear.body == b
        return VStack(spacing: 0) {
            Button {
                guard !selected else { return }
                camera.set(gear: GearSelection(body: b, lens: b.defaultLens).normalized())
            } label: {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Text(b.title.uppercased())
                                .font(Theme.mono(14, selected ? .semibold : .regular))
                                .foregroundStyle(selected ? Theme.text : Theme.dim)
                            if let badge = cropBadge(b) {
                                Text(badge)
                                    .font(Theme.mono(9))
                                    .foregroundStyle(Theme.dim)
                                    .padding(.horizontal, 5).padding(.vertical, 2)
                                    .overlay(Rectangle().stroke(Theme.hairline, lineWidth: 0.5))
                            }
                        }
                        Text(b.subtitle)
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.dim)
                            .multilineTextAlignment(.leading)
                    }
                    Spacer(minLength: 0)
                    if selected { RedDot(size: 7) }
                }
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Hairline()
        }
        .sensoryFeedback(.selection, trigger: selected)
    }

    // MARK: Lenses

    private var lensList: some View {
        VStack(spacing: 0) {
            ForEach(gear.body.lenses) { lens in
                lensRow(lens)
            }
        }
    }

    private func lensRow(_ lens: LensProfile) -> some View {
        let selected = gear.lens == lens
        let equivalent = Int(lens.equivalentFocalLength(on: gear.body).rounded())
        return VStack(spacing: 0) {
            Button {
                camera.set(gear: GearSelection(body: gear.body, lens: lens).normalized())
            } label: {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(lens.title)
                            .font(Theme.mono(13, selected ? .semibold : .regular))
                            .foregroundStyle(selected ? Theme.text : Theme.dim)
                            .multilineTextAlignment(.leading)
                        HStack(spacing: 10) {
                            Text(Fmt.aperture(lens.maxAperture))
                                .font(Theme.mono(11))
                                .foregroundStyle(Theme.dim)
                            Text("35mm 換算 \(equivalent)mm")
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.dim)
                        }
                    }
                    Spacer(minLength: 0)
                    if selected { RedDot(size: 7) }
                }
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Hairline()
        }
        .sensoryFeedback(.selection, trigger: selected)
    }
}
