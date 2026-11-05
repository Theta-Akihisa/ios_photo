//  LibrarySaver.swift
//  Saving photos / videos to the Photos library and thumbnail helpers.

import AVFoundation
import ImageIO
import Photos
import UIKit

enum LibrarySaver {

    static func savePhoto(data: Data, completion: @escaping (Bool, Error?) -> Void) {
        PHPhotoLibrary.shared().performChanges({
            let request = PHAssetCreationRequest.forAsset()
            request.addResource(with: .photo, data: data, options: PHAssetResourceCreationOptions())
        }, completionHandler: { ok, error in
            completion(ok, error)
        })
    }

    /// Saves the movie (moving the file into the library) and removes the temp file afterwards.
    static func saveVideo(url: URL, completion: @escaping (Bool, Error?) -> Void) {
        PHPhotoLibrary.shared().performChanges({
            let options = PHAssetResourceCreationOptions()
            options.shouldMoveFile = true
            let request = PHAssetCreationRequest.forAsset()
            request.addResource(with: .video, fileURL: url, options: options)
        }, completionHandler: { ok, error in
            try? FileManager.default.removeItem(at: url)
            completion(ok, error)
        })
    }

    // MARK: Thumbnails

    static func photoThumbnail(from data: Data, maxPixel: Int = 240) -> UIImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: cg)
    }

    /// Synchronous; call from a background queue.
    static func videoThumbnail(url: URL, maxPixel: CGFloat = 240) -> UIImage? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxPixel, height: maxPixel)
        guard let cg = try? generator.copyCGImage(at: .zero, actualTime: nil) else { return nil }
        return UIImage(cgImage: cg)
    }
}
