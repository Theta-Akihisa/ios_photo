//  MovieRecorder.swift
//  AVAssetWriter based recorder that renders the selected look into every video frame.

import AVFoundation
import AudioToolbox
import CoreImage
import CoreMedia
import CoreVideo

enum MovieRecorderError: Error {
    case cannotAddInput
    case writeFailed
}

final class MovieRecorder {

    let url: URL

    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let audioInput: AVAssetWriterInput?
    private let renderer: LookRendering
    private let context: CIContext
    private let width: Int
    private let height: Int
    private let outputColorSpace: CGColorSpace

    private let lock = NSLock()
    private var sessionStarted = false
    private var finished = false
    private var failed = false
    private var startTime = CMTime.invalid
    private var failureReported = false
    /// Called (asynchronously, once) when the writer fails while recording, so the owner can stop and clean up.
    var onFailure: (() -> Void)?

    private func reportFailureLocked() {
        failed = true
        guard !failureReported else { return }
        failureReported = true
        let handler = onFailure
        DispatchQueue.global(qos: .userInitiated).async { handler?() }
    }

    /// - Parameters:
    ///   - audioSettings: output settings for the audio input; nil with `hasAudio` uses AAC mono.
    ///   - rotationAngle: clockwise rotation in degrees (from RotationCoordinator) stored as the track transform.
    init(url: URL, width: Int, height: Int, frameRate: Int, rotationAngle: CGFloat,
         hasAudio: Bool, audioSettings: [String: Any]?,
         renderer: LookRendering, context: CIContext,
         metadata: [AVMetadataItem]) throws {
        self.url = url
        self.width = width
        self.height = height
        self.renderer = renderer
        self.context = context
        self.outputColorSpace = CGColorSpace(name: CGColorSpace.itur_709)
            ?? CGColorSpace(name: CGColorSpace.sRGB)
            ?? CGColorSpaceCreateDeviceRGB()

        let w = try AVAssetWriter(outputURL: url, fileType: .mov)
        w.metadata = metadata
        self.writer = w

        // HEVC video. Bitrate ~0.1 bit per pixel per frame.
        let bitrate = max(4_000_000, Int(Double(width * height) * Double(max(frameRate, 24)) * 0.1))
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevc.rawValue,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2
            ],
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitrate,
                AVVideoExpectedSourceFrameRateKey: frameRate
            ]
        ]
        let vIn = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        vIn.expectsMediaDataInRealTime = true
        // Sensor frames are landscape-right; rotate to the horizon-level angle chosen at record start.
        vIn.transform = CGAffineTransform(rotationAngle: rotationAngle * .pi / 180)
        self.videoInput = vIn

        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()
        ]
        self.adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: vIn,
                                                            sourcePixelBufferAttributes: attrs)
        guard w.canAdd(vIn) else { throw MovieRecorderError.cannotAddInput }
        w.add(vIn)

        if hasAudio {
            let settings: [String: Any] = audioSettings ?? [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVNumberOfChannelsKey: 1,
                AVSampleRateKey: 44_100,
                AVEncoderBitRateKey: 96_000
            ]
            let aIn = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
            aIn.expectsMediaDataInRealTime = true
            if w.canAdd(aIn) {
                w.add(aIn)
                self.audioInput = aIn
            } else {
                self.audioInput = nil
            }
        } else {
            self.audioInput = nil
        }
    }

    // MARK: Appending (called on the video data queue)

    func appendVideo(_ sample: CMSampleBuffer, pixelBuffer: CVPixelBuffer, look: LookPreset, gear: GearSelection, isLog: Bool) {
        lock.lock()
        defer { lock.unlock() }
        guard !finished, !failed else { return }

        // Frames must match the writer size (the output buffer mode may have just changed): drop stale ones.
        guard CVPixelBufferGetWidth(pixelBuffer) == width, CVPixelBufferGetHeight(pixelBuffer) == height else { return }

        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        if !sessionStarted {
            guard writer.startWriting() else { reportFailureLocked(); return }
            writer.startSession(atSourceTime: pts)
            startTime = pts
            sessionStarted = true
        }
        guard writer.status == .writing else { reportFailureLocked(); return }
        guard videoInput.isReadyForMoreMediaData, let pool = adaptor.pixelBufferPool else { return }

        var out: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out)
        guard let dst = out else { return }

        // Apple Log frames must not be linearised by Core Image before the Log cube runs.
        var image = isLog
            ? CIImage(cvPixelBuffer: pixelBuffer, options: [.colorSpace: NSNull()])
            : CIImage(cvPixelBuffer: pixelBuffer)
        let extent = image.extent
        if look != .native || isLog || !CaptureFormats.isNeutral(gear) {
            image = renderer.apply(look, gear: gear, aperture: nil, cheap: true,
                                   to: image, isLogSource: isLog)
        }
        context.render(image, to: dst, bounds: extent, colorSpace: outputColorSpace)

        if !adaptor.append(dst, withPresentationTime: pts) {
            reportFailureLocked()
        }
    }

    func appendAudio(_ sample: CMSampleBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard let audioInput = audioInput, sessionStarted, !finished, !failed,
              writer.status == .writing, audioInput.isReadyForMoreMediaData else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        // Drop audio that precedes the first video frame.
        if CMTimeCompare(pts, startTime) < 0 { return }
        if !audioInput.append(sample) { reportFailureLocked() }
    }

    // MARK: Finish

    /// Finalises the file. `completion` receives the URL on success.
    func finish(completion: @escaping (URL?, Error?) -> Void) {
        lock.lock()
        if finished {
            lock.unlock()
            completion(nil, nil)
            return
        }
        finished = true
        let canFinish = sessionStarted && !failed && writer.status == .writing
        if canFinish {
            videoInput.markAsFinished()
            audioInput?.markAsFinished()
        }
        lock.unlock()

        guard canFinish else {
            if writer.status == .writing { writer.cancelWriting() }
            try? FileManager.default.removeItem(at: url)
            var failure: Error? = writer.error
            if failure == nil && failed { failure = MovieRecorderError.writeFailed }
            completion(nil, failure)
            return
        }
        let w = writer
        let u = url
        w.finishWriting {
            if w.status == .completed {
                completion(u, nil)
            } else {
                try? FileManager.default.removeItem(at: u)
                completion(nil, w.error ?? MovieRecorderError.writeFailed)
            }
        }
    }
}
