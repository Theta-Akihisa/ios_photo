//  VideoFormatView.swift
//  Sheet for codec / colour / resolution / frame-rate selection.

import SwiftUI

struct VideoFormatView: View {
    @ObservedObject var camera: CameraService
    @Environment(\.dismiss) private var dismiss

    private var video: VideoFormatSettings { camera.state.video }
    private var caps: DeviceCapabilities { camera.state.capabilities }

    var body: some View {
        ZStack {
            Theme.black.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    header
                    section("CODEC") { codecList }
                    section("COLOR") { colorRow }
                    section("RESOLUTION") { resolutionRow }
                    section("FPS") { fpsRow }
                    if !video.bakesLook {
                        Text("RAW / LOG / ProRes ではルックはプレビューのみ（メタデータに記録）")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.dim)
                            .padding(.top, 4)
                    }
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
                Text("FORMAT").luxCaps(12, weight: .semibold)
            }
            Spacer()
            Text(video.badgeText).font(Theme.mono(11)).foregroundStyle(Theme.dim)
            Button("閉じる") { dismiss() }
                .font(.system(size: 13))
                .foregroundStyle(Theme.text)
                .padding(.leading, 8)
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).luxCaps(10, color: Theme.dim)
            Hairline()
            content()
        }
    }

    // MARK: Support checks

    private func isSupported(_ codec: VideoCodecOption) -> Bool {
        switch codec {
        case .hevc: return true
        case .proRes422HQ: return caps.proRes422HQ
        case .proResRAW, .proResRAWHQ: return caps.proResRAW
        }
    }

    private func isSupported(_ color: VideoColorProfile) -> Bool {
        switch color {
        case .standard: return true
        case .hlg: return caps.hlg
        case .appleLog: return caps.appleLog
        }
    }

    private func update(_ change: (inout VideoFormatSettings) -> Void) {
        var v = camera.state.video
        change(&v)
        camera.set(video: v)
    }

    // MARK: Sections

    private var codecList: some View {
        VStack(spacing: 0) {
            ForEach(VideoCodecOption.allCases) { codec in
                let ok = isSupported(codec)
                Button {
                    update { $0.codec = codec }
                } label: {
                    HStack {
                        Text(codec.title).font(Theme.mono(14, video.codec == codec ? .semibold : .regular))
                        Spacer()
                        if !ok {
                            Text("非対応").font(.system(size: 11))
                        } else if video.codec == codec {
                            RedDot(size: 7)
                        }
                    }
                    .foregroundStyle(ok ? (video.codec == codec ? Theme.text : Theme.dim) : Theme.faint)
                    .padding(.vertical, 12)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!ok)
                Hairline()
            }
        }
    }

    private var colorRow: some View {
        segmented(VideoColorProfile.allCases, selected: video.color,
                  title: { $0.title }, enabled: { isSupported($0) }) { c in update { $0.color = c } }
    }

    private var resolutionRow: some View {
        segmented([true, false], selected: video.resolution4K,
                  title: { $0 ? "4K" : "HD" }, enabled: { _ in true }) { r in update { $0.resolution4K = r } }
    }

    private var fpsRow: some View {
        segmented([24, 25, 30, 60], selected: video.frameRate,
                  title: { "\($0)" }, enabled: { _ in true }) { f in update { $0.frameRate = f } }
    }

    /// Equal-width option row with a red underline on the selected item.
    private func segmented<T: Hashable>(_ items: [T], selected: T,
                                        title: @escaping (T) -> String,
                                        enabled: @escaping (T) -> Bool,
                                        onSelect: @escaping (T) -> Void) -> some View {
        HStack(spacing: 0) {
            ForEach(items, id: \.self) { item in
                let ok = enabled(item)
                Button {
                    onSelect(item)
                } label: {
                    VStack(spacing: 4) {
                        Text(title(item)).font(Theme.mono(14, item == selected ? .semibold : .regular))
                        Text(ok ? " " : "非対応").font(.system(size: 9))
                        Rectangle().fill(item == selected ? Theme.red : Color.clear).frame(height: 2)
                    }
                    .foregroundStyle(ok ? (item == selected ? Theme.text : Theme.dim) : Theme.faint)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!ok)
            }
        }
    }
}
