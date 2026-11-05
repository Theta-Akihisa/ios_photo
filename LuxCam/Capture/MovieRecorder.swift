//  MovieRecorder.swift
//  AVAssetWriter based recorder that renders the selected look into every video frame.

import AVFoundation
import AudioToolbox
import CoreImage
import CoreMedia
import CoreVideo

enum MovieRecorderError: Error {
    case cannotAddInput
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

    /// - Parameters:
    ///   - audioSettings: output settings for the audio input; nil with `hasAudio` uses AAC mono.
    init(url: URL, width: Int, height: Int, frameRate: Int,
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
        // Sensor frames are landscape-right; rotate for portrait playback.
        vIn.transform = CGAffineTransform(rotationAngle: .pi / 2)
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

    func appendVideo(_ sample: CMSampleBuffer, pixelBuffer: CVPixelBuffer, look: LookPreset, isLog: Bool) {
        lock.lock()
        defer { lock.unlock() }
        guard !finished, !failed else { return }

        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        if !sessionStarted {
            guard writer.startWriting() else { failed = true; return }
            writer.startSession(atSourceTime: pts)
            startTime = pts
            sessionStarted = true
        }
        guard writer.status == .writing else { failed = true; return }
        guard videoInput.isReadyForMoreMediaData, let pool = adaptor.pixelBufferPool else { return }

        var out: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out)
        guard let dst = out else { return }

        var image = CIImage(cvPixelBuffer: pixelBuffer)
        let extent = image.extent
        if look != .native || isLog {
            image = renderer.apply(look, to: image, isLogSource: isLog)
        }
        context.render(image, to: dst, bounds: extent, colorSpace: outputColorSpace)

        if !adaptor.append(dst, withPresentationTime: pts) {
            failed = true
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
        if !audioInput.append(sample) { failed = true }
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
            completion(nil, writer.error)
            return
        }
        let w = writer
        let u = url
        w.finishWriting {
            if w.status == .completed {
                completion(u, nil)
            } else {
                try? FileManager.default.removeItem(at: u)
                completion(nil, w.error)
            }
        }
    }
}
