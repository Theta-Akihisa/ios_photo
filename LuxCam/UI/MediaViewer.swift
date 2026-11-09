//  MediaViewer.swift
//  Full-screen viewer for LuxCam captures (photos & videos), Leica-style: black, monospaced.

import SwiftUI
import UIKit
import Photos
import AVKit
import UniformTypeIdentifiers

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
    let ids: [String]
    let onForget: ([String]) -> Void
    @Environment(\.dismiss) private var dismiss

    private enum Access { case checking, granted, denied }

    @State private var access: Access = .checking
    @State private var assets: [PHAsset] = []
    @State private var currentID: String = ""
    @State private var shareItem: ShareItem?
    @State private var isPreparingShare = false
    @State private var rawIDs: Set<String> = []
    @State private var showChrome = true

    private static let bottomBarHeight: CGFloat = 52

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
        // Read the bottom safe-area inset (home indicator) here, where the safe area is respected,
        // because the pager itself ignores the safe area.
        GeometryReader { geo in
            pager(bottomSafeInset: geo.safeAreaInsets.bottom)
        }
    }

    private func pager(bottomSafeInset: CGFloat) -> some View {
        ZStack {
            TabView(selection: $currentID) {
                ForEach(assets, id: \.localIdentifier) { asset in
                    page(for: asset, bottomSafeInset: bottomSafeInset)
                        .tag(asset.localIdentifier)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .ignoresSafeArea()

            if showChrome {
                VStack(spacing: 0) {
                    topBar
                    Spacer(minLength: 0)
                    bottomBar
                }
            }
        }
    }

    @ViewBuilder
    private func page(for asset: PHAsset, bottomSafeInset: CGFloat) -> some View {
        let isCurrent = asset.localIdentifier == currentID
        if asset.mediaType == .video {
            // Keep AVKit's transport controls above the bottom bar and the home indicator.
            VideoPageView(asset: asset, isCurrent: isCurrent,
                          bottomInset: (showChrome ? Self.bottomBarHeight : 0) + bottomSafeInset)
        } else {
            PhotoPageView(asset: asset, isCurrent: isCurrent, onTap: {
                withAnimation(.easeInOut(duration: 0.2)) { showChrome.toggle() }
            })
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
                        if rawIDs.contains(asset.localIdentifier) { badge("RAW") }
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
        .frame(height: Self.bottomBarHeight)
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
        let result = MediaLibrary.fetch(ids: ids)
        assets = result.assets
        rawIDs = Set(result.assets.filter { MediaLibrary.hasRAW($0) }.map { $0.localIdentifier })
        if !result.missing.isEmpty { onForget(result.missing) }
        if currentIndex == nil { currentID = assets.first?.localIdentifier ?? "" }
    }

    // MARK: Actions

    private func share() {
        guard let asset = currentAsset, !isPreparingShare else { return }
        isPreparingShare = true
        let resources = PHAssetResource.assetResources(for: asset)
        if asset.mediaType == .video {
            let resource = resources.first { $0.type == .fullSizeVideo }
                ?? resources.first { $0.type == .video }
            guard let resource else {
                isPreparingShare = false
                return
            }
            Self.export(resource) { url in
                isPreparingShare = false
                if let url { shareItem = ShareItem(items: [url]) }
            }
        } else {
            let dng = resources.first { $0.type == .alternatePhoto }
            let options = PHImageRequestOptions()
            options.isNetworkAccessAllowed = true
            options.version = .current
            PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { data, uti, _, _ in
                var photoURL: URL?
                if let data {
                    let ext = uti.flatMap { UTType($0)?.preferredFilenameExtension } ?? "jpg"
                    let dir = FileManager.default.temporaryDirectory
                        .appendingPathComponent(UUID().uuidString, isDirectory: true)
                    let url = dir.appendingPathComponent("LuxCam-\(Int(Date().timeIntervalSince1970)).\(ext)")
                    do {
                        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                        try data.write(to: url, options: .atomic)
                        photoURL = url
                    } catch {
                        photoURL = nil
                    }
                }
                DispatchQueue.main.async {
                    guard let dng else {
                        isPreparingShare = false
                        if let photoURL { shareItem = ShareItem(items: [photoURL]) }
                        return
                    }
                    Self.export(dng) { rawURL in
                        isPreparingShare = false
                        let urls = [photoURL, rawURL].compactMap { $0 }
                        if !urls.isEmpty { shareItem = ShareItem(items: urls) }
                    }
                }
            }
        }
    }

    /// Writes the original resource data to a temp file. `completion` runs on the main queue.
    private static func export(_ resource: PHAssetResource, completion: @escaping (URL?) -> Void) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let url = dir.appendingPathComponent(resource.originalFilename)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
        } catch {
            completion(nil)
            return
        }
        let opts = PHAssetResourceRequestOptions()
        opts.isNetworkAccessAllowed = true
        PHAssetResourceManager.default().writeData(for: resource, toFile: url, options: opts) { error in
            DispatchQueue.main.async { completion(error == nil ? url : nil) }
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
        onForget([id])
        if assets.isEmpty { dismiss() }
    }
}

// MARK: - Photo page

private struct PhotoPageView: View {
    let asset: PHAsset
    let isCurrent: Bool
    let onTap: () -> Void

    @Environment(\.displayScale) private var displayScale
    @State private var image: UIImage?
    @State private var failed = false
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
                } else if failed {
                    Text("表示できません")
                        .font(Theme.mono(14))
                        .foregroundStyle(Theme.dim)
                } else {
                    ProgressView().tint(Theme.text)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .contentShape(Rectangle())
            .onTapGesture { onTap() }
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
        ) { result, info in
            let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) == true
            DispatchQueue.main.async {
                if let result { image = result }
                if !degraded {
                    requestID = nil
                    if result == nil && image == nil { failed = true }
                }
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
    let bottomInset: CGFloat

    @State private var player: AVPlayer?
    @State private var requestID: PHImageRequestID?

    var body: some View {
        ZStack {
            Theme.black
            if let player {
                VideoPlayer(player: player)
                    .padding(.bottom, bottomInset)
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
