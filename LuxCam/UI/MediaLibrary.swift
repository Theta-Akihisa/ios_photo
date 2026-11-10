//  MediaLibrary.swift
//  Small Photos-framework helpers for the in-app viewer and the thumbnail button.

import Photos
import UIKit

enum MediaLibrary {
    static var canRead: Bool {
        let s = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        return s == .authorized || s == .limited
    }

    /// Fetches the assets for `ids`, preserving the order of `ids`. `missing` are IDs not found.
    static func fetch(ids: [String]) -> (assets: [PHAsset], missing: [String]) {
        guard !ids.isEmpty else { return ([], []) }
        let result = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
        var byID: [String: PHAsset] = [:]
        result.enumerateObjects { asset, _, _ in
            byID[asset.localIdentifier] = asset
        }
        var assets: [PHAsset] = []
        var missing: [String] = []
        for id in ids {
            if let a = byID[id] { assets.append(a) } else { missing.append(id) }
        }
        return (assets, missing)
    }

    /// Loads a small thumbnail without ever prompting for access. `completion` runs on the main queue.
    static func loadThumbnail(localIdentifier: String, completion: @escaping (UIImage?) -> Void) {
        guard canRead else { completion(nil); return }
        let result = PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil)
        guard let asset = result.firstObject else { completion(nil); return }
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = false
        PHImageManager.default().requestImage(
            for: asset,
            targetSize: CGSize(width: 240, height: 240),
            contentMode: .aspectFill,
            options: options
        ) { image, _ in
            DispatchQueue.main.async { completion(image) }
        }
    }

    static func hasRAW(_ asset: PHAsset) -> Bool {
        PHAssetResource.assetResources(for: asset).contains { $0.type == .alternatePhoto }
    }

    static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy.MM.dd HH:mm"
        return f
    }()

    static func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }

    static func openPhotosApp() {
        if let url = URL(string: "photos-redirect://") {
            UIApplication.shared.open(url)
        }
    }
}
