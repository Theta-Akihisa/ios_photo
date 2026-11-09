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
                    presetButton
                    section("CODEC") { codecList }
                    section("COLOR") { colorRow }
                    section("RESOLUTION") { resolutionRow }
                    section("FPS") { fpsRow }
                    if !video.bakesLook {
                        Text("HDR / LOG / ProRes / RAW / 60fps 以上ではルックはプレビューのみ（メタデータに記録）")
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
        caps.supportedCodecs.contains(codec)
    }

    private var canApplyRecommended: Bool {
        caps.supportedCodecs.contains(.proRes422HQ) && caps.appleLog && caps.supportedFrameRates.contains(30)
    }

    private var presetButton: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                update {
                    $0.codec = .proRes422HQ
                    $0.color = .appleLog
                    $0.resolution4K = true
                    $0.frameRate = 30
                }
            } label: {
                HStack {
                    Text("おすすめ (iPhone 16 Pro)").font(.system(size: 13, weight: .medium))
                    Spacer()
                    Text("ProRes 422 HQ · LOG · 4K · 30").font(Theme.mono(10))
                }
                .foregroundStyle(canApplyRecommended ? Theme.text : Theme.faint)
                .padding(12)
                .overlay(Rectangle().stroke(canApplyRecommended ? Theme.red : Theme.hairline, lineWidth: 0.5))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!canApplyRecommended)
            Text("iPhone 16 Pro では ProRes RAW 非対応のため、ProRes 422 HQ + Apple Log が最もグレーディング耐性の高い設定です。4K60/120 の ProRes は外部 SSD が必要な場合があります。")
                .font(.system(size: 11))
                .foregroundStyle(Theme.dim)
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
        VStack(alignment: .leading, spacing: 0) {
            codecGroup("HEVC", [.hevc])
            codecGroup("ProRes", [.proRes422HQ, .proRes422, .proRes422LT, .proRes422Proxy])
            codecGroup("RAW", [.proResRAW, .proResRAWHQ], caption: "iPhone 17 Pro 以降")
        }
    }

    private func codecGroup(_ title: String, _ codecs: [VideoCodecOption], caption: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(title).luxCaps(9, color: Theme.dim)
                if let caption {
                    Text(caption).font(.system(size: 10)).foregroundStyle(Theme.faint)
                }
            }
            .padding(.top, 10).padding(.bottom, 2)
            ForEach(codecs) { codec in codecRow(codec) }
        }
    }

    private func codecRow(_ codec: VideoCodecOption) -> some View {
        let ok = isSupported(codec)
        return VStack(spacing: 0) {
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

    private var colorRow: some View {
        segmented(VideoColorProfile.allCases, selected: video.color,
                  title: { $0.title }, enabled: { isSupported($0) }) { c in update { $0.color = c } }
    }

    private var resolutionRow: some View {
        segmented([true, false], selected: video.resolution4K,
                  title: { $0 ? "4K" : "HD" }, enabled: { _ in true }) { r in update { $0.resolution4K = r } }
    }

    private var fpsRow: some View {
        segmented([24, 25, 30, 60, 120], selected: video.frameRate,
                  title: { "\($0)" }, enabled: { caps.supportedFrameRates.contains($0) }) { f in update { $0.frameRate = f } }
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
