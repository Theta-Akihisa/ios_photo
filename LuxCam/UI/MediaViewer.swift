//  MediaViewer.swift
//  Full-screen viewer for LuxCam captures (photos & videos), Leica-style: black, monospaced.

import SwiftUI
import UIKit
import Photos
import AVKit

// MARK: - Share sheet

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

private struct ShareItem: Identifiable {
    let id = UUID()
    let items: [Any]
}

// MARK: - Viewer

struct MediaViewerView: View {
    @ObservedObject var camera: CameraService
    @Environment(\.dismiss) private var dismiss

    private enum Access { case checking, granted, denied }

    @State private var access: Access = .checking
    @State private var assets: [PHAsset] = []
    @State private var currentID: String = ""
    @State private var shareItem: ShareItem?
    @State private var isPreparingShare = false

    private var currentIndex: Int? {
        assets.firstIndex { $0.localIdentifier == currentID }
    }

    private var currentAsset: PHAsset? {
        currentIndex.map { assets[$0] }
    }

    var body: some View {
        ZStack {
            Theme.black.ignoresSafeArea()
            switch access {
            case .checking:
                ProgressView().tint(Theme.text)
            case .denied:
                deniedView
            case .granted:
                if assets.isEmpty { emptyView } else { content }
            }
            if access != .granted || assets.isEmpty {
                VStack {
                    HStack { closeButton; Spacer() }
                        .padding(.horizontal, Theme.gutter)
                        .padding(.top, 8)
                    Spacer()
                }
            }
        }
        .preferredColorScheme(.dark)
        .onAppear { checkAccess() }
        .sheet(item: $shareItem) { item in
            ShareSheet(items: item.items)
        }
    }

    // MARK: States

    private var emptyView: some View {
        Text("まだ撮影した写真はありません")
            .font(Theme.mono(14))
            .foregroundStyle(Theme.dim)
            .multilineTextAlignment(.center)
            .padding(Theme.gutter)
    }

    private var deniedView: some View {
        VStack(spacing: 18) {
            Text("写真へのアクセスが許可されていません。設定アプリで許可してください。")
                .font(Theme.mono(14))
                .foregroundStyle(Theme.text)
                .multilineTextAlignment(.center)
            Button { MediaLibrary.openSettings() } label: {
                Text("設定を開く").font(Theme.mono(14, .medium))
                    .foregroundStyle(Theme.text)
                    .padding(.horizontal, 20).padding(.vertical, 10)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.hairline, lineWidth: 0.5))
            }
            Button { MediaLibrary.openPhotosApp() } label: {
                Text("写真アプリで開く").font(Theme.mono(14, .medium))
                    .foregroundStyle(Theme.text)
                    .padding(.horizontal, 20).padding(.vertical, 10)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.hairline, lineWidth: 0.5))
            }
        }
        .padding(Theme.gutter)
    }

    private var content: some View {
        ZStack {
            TabView(selection: $currentID) {
                ForEach(assets, id: \.localIdentifier) { asset in
                    page(for: asset)
                        .tag(asset.localIdentifier)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .ignoresSafeArea()

            VStack(spacing: 0) {
                topBar
                Spacer(minLength: 0)
                bottomBar
            }
        }
    }

    @ViewBuilder
    private func page(for asset: PHAsset) -> some View {
        let isCurrent = asset.localIdentifier == currentID
        if asset.mediaType == .video {
            VideoPageView(asset: asset, isCurrent: isCurrent)
        } else {
            PhotoPageView(asset: asset, isCurrent: isCurrent)
        }
    }

    // MARK: Bars

    private var closeButton: some View {
        Button { dismiss() } label: {
            Image(systemName: "xmark")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Theme.text)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("閉じる")
    }

    private var topBar: some View {
        HStack(spacing: 10) {
            closeButton
            if let index = currentIndex {
                Text("\(index + 1) / \(assets.count)")
                    .font(Theme.mono(13, .medium))
                    .foregroundStyle(Theme.text)
            }
            Spacer(minLength: 4)
            if let asset = currentAsset {
                VStack(alignment: .trailing, spacing: 3) {
                    if let date = asset.creationDate {
                        Text(MediaLibrary.dateFormatter.string(from: date))
                            .font(Theme.mono(12))
                            .foregroundStyle(Theme.text)
                    }
                    HStack(spacing: 6) {
                        if MediaLibrary.hasRAW(asset) { badge("RAW") }
                        if asset.mediaType == .video {
                            badge("VIDEO " + Fmt.mmss(asset.duration))
                        }
                    }
                }
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            }
        }
        .padding(.horizontal, Theme.gutter - 8)
        .padding(.vertical, 4)
        .background(Color.black.opacity(0.55))
    }

    private func badge(_ text: String) -> some View {
        Text(text)
            .font(Theme.mono(10, .medium))
            .foregroundStyle(Theme.text)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(Theme.hairline, lineWidth: 0.5))
    }

    private var bottomBar: some View {
        HStack {
            Button { share() } label: {
                Group {
                    if isPreparingShare {
                        ProgressView().tint(Theme.text)
                    } else {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
                .font(.system(size: 20))
                .foregroundStyle(Theme.text)
                .frame(width: 48, height: 44)
            }
            .disabled(isPreparingShare)
            .accessibilityLabel("共有")

            Spacer()

            Button { MediaLibrary.openPhotosApp() } label: {
                Text("写真アプリで開く")
                    .font(Theme.mono(12, .medium))
                    .foregroundStyle(Theme.text)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.hairline, lineWidth: 0.5))
            }

            Spacer()

            Button { deleteCurrent() } label: {
                Image(systemName: "trash")
                    .font(.system(size: 20))
                    .foregroundStyle(Theme.red)
                    .frame(width: 48, height: 44)
            }
            .accessibilityLabel("削除")
        }
        .padding(.horizontal, Theme.gutter - 8)
        .padding(.vertical, 4)
        .background(Color.black.opacity(0.55))
    }

    // MARK: Access & data

    private func checkAccess() {
        switch PHPhotoLibrary.authorizationStatus(for: .readWrite) {
        case .authorized, .limited:
            access = .granted
            reload()
        case .notDetermined:
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
                DispatchQueue.main.async {
                    if status == .authorized || status == .limited {
                        access = .granted
                        reload()
                    } else {
                        access = .denied
                    }
                }
            }
        default:
            access = .denied
        }
    }

    private func reload() {
        let result = MediaLibrary.fetch(ids: camera.state.recentAssetIDs)
        assets = result.assets
        if !result.missing.isEmpty { camera.forgetAssets(result.missing) }
        if currentIndex == nil { currentID = assets.first?.localIdentifier ?? "" }
    }

    // MARK: Actions

    private func share() {
        guard let asset = currentAsset, !isPreparingShare else { return }
        isPreparingShare = true
        if asset.mediaType == .video {
            let options = PHVideoRequestOptions()
            options.isNetworkAccessAllowed = true
            PHImageManager.default().requestAVAsset(forVideo: asset, options: options) { avAsset, _, _ in
                let url = (avAsset as? AVURLAsset)?.url
                DispatchQueue.main.async {
                    isPreparingShare = false
                    if let url { shareItem = ShareItem(items: [url]) }
                }
            }
        } else {
            let options = PHImageRequestOptions()
            options.isNetworkAccessAllowed = true
            options.version = .current
            PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { data, _, _, _ in
                let image = data.flatMap { UIImage(data: $0) }
                DispatchQueue.main.async {
                    isPreparingShare = false
                    if let image { shareItem = ShareItem(items: [image]) }
                }
            }
        }
    }

    private func deleteCurrent() {
        guard let asset = currentAsset else { return }
        let id = asset.localIdentifier
        PHPhotoLibrary.shared().performChanges({
            PHAssetChangeRequest.deleteAssets([asset] as NSArray)
        }, completionHandler: { success, _ in
            DispatchQueue.main.async {
                guard success else { return }
                removeAsset(id: id)
            }
        })
    }

    private func removeAsset(id: String) {
        if let idx = assets.firstIndex(where: { $0.localIdentifier == id }) {
            var next = assets
            next.remove(at: idx)
            if currentID == id {
                if next.isEmpty {
                    currentID = ""
                } else {
                    currentID = next[min(idx, next.count - 1)].localIdentifier
                }
            }
            assets = next
        }
        camera.forgetAssets([id])
        if assets.isEmpty { dismiss() }
    }
}

// MARK: - Photo page

private struct PhotoPageView: View {
    let asset: PHAsset
    let isCurrent: Bool

    @Environment(\.displayScale) private var displayScale
    @State private var image: UIImage?
    @State private var requestID: PHImageRequestID?
    @State private var scale: CGFloat = 1
    @State private var baseScale: CGFloat = 1

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Theme.black
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(width: geo.size.width, height: geo.size.height)
                        .scaleEffect(scale)
                        .gesture(
                            MagnificationGesture()
                                .onChanged { value in
                                    scale = min(4, max(1, baseScale * value))
                                }
                                .onEnded { _ in
                                    baseScale = scale
                                }
                        )
                        .onTapGesture(count: 2) {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                scale = scale > 1.01 ? 1 : 2.5
                                baseScale = scale
                            }
                        }
                } else {
                    ProgressView().tint(Theme.text)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
            .onAppear { load(viewSize: geo.size) }
        }
        .onChange(of: isCurrent) { _, current in
            if !current { scale = 1; baseScale = 1 }
        }
        .onDisappear { cancel() }
    }

    private func load(viewSize: CGSize) {
        guard requestID == nil, image == nil else { return }
        let side = max(viewSize.width, viewSize.height, 1) * displayScale
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.isNetworkAccessAllowed = true
        requestID = PHImageManager.default().requestImage(
            for: asset,
            targetSize: CGSize(width: side, height: side),
            contentMode: .aspectFit,
            options: options
        ) { result, _ in
            DispatchQueue.main.async {
                if let result { image = result }
            }
        }
    }

    private func cancel() {
        if let id = requestID {
            PHImageManager.default().cancelImageRequest(id)
        }
        requestID = nil
    }
}

// MARK: - Video page

private struct VideoPageView: View {
    let asset: PHAsset
    let isCurrent: Bool

    @State private var player: AVPlayer?
    @State private var requestID: PHImageRequestID?

    var body: some View {
        ZStack {
            Theme.black
            if let player {
                VideoPlayer(player: player)
            } else {
                ProgressView().tint(Theme.text)
            }
        }
        .onAppear { if isCurrent { load() } }
        .onChange(of: isCurrent) { _, current in
            if current { load() } else { player?.pause() }
        }
        .onDisappear {
            player?.pause()
            if let id = requestID {
                PHImageManager.default().cancelImageRequest(id)
                requestID = nil
            }
        }
    }

    private func load() {
        guard player == nil, requestID == nil else { return }
        let options = PHVideoRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .automatic
        requestID = PHImageManager.default().requestPlayerItem(forVideo: asset, options: options) { item, _ in
            DispatchQueue.main.async {
                requestID = nil
                if let item { player = AVPlayer(playerItem: item) }
            }
        }
    }
}
