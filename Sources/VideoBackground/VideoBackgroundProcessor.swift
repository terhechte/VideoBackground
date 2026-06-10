import AVFoundation
import CoreImage
import Foundation
import ImageIO
import RMBG2Swift
import UniformTypeIdentifiers

struct VideoProcessingProgress: Sendable {
    let message: String
    let completedFrames: Int
    let estimatedFrames: Int
    let fraction: Double
}

struct VideoProcessingResult: Sendable {
    let videoURL: URL
    let framesDirectory: URL
    let frameCount: Int
    let width: Int
    let height: Int
    let durationSeconds: Double
}

actor VideoBackgroundProcessor {
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private lazy var imageContext = CIContext(options: [.workingColorSpace: colorSpace])

    func process(
        videoURL: URL,
        timeSelection: VideoTimeSelection,
        progress: @Sendable @escaping (VideoProcessingProgress) async -> Void
    ) async throws -> VideoProcessingResult {
        let fileManager = FileManager.default
        let workDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("VideoBackground-\(UUID().uuidString)", isDirectory: true)
        let framesDirectory = workDirectory.appendingPathComponent("PNGFrames", isDirectory: true)
        let outputVideoURL = workDirectory.appendingPathComponent("background-removed.mov")

        try fileManager.createDirectory(at: framesDirectory, withIntermediateDirectories: true)

        await progress(
            VideoProcessingProgress(
                message: "Loading RMBG-2 model",
                completedFrames: 0,
                estimatedFrames: 0,
                fraction: 0.02
            )
        )

        let rmbg = try await RMBG2 { modelProgress, status in
            Task {
                await progress(
                    VideoProcessingProgress(
                        message: status,
                        completedFrames: 0,
                        estimatedFrames: 0,
                        fraction: max(0.02, min(0.12, modelProgress * 0.12))
                    )
                )
            }
        }

        let asset = AVURLAsset(url: videoURL)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)

        guard let videoTrack = videoTracks.first else {
            throw VideoProcessingError.noVideoTrack
        }

        let assetDuration = try await asset.load(.duration)
        let naturalSize = try await videoTrack.load(.naturalSize)
        let preferredTransform = try await videoTrack.load(.preferredTransform)
        let nominalFrameRate = try await videoTrack.load(.nominalFrameRate)
        let width = max(1, Int(naturalSize.width.rounded()))
        let height = max(1, Int(naturalSize.height.rounded()))
        let estimatedFrameCount = estimatedFrames(
            duration: timeSelection.cmTimeRange.duration,
            nominalFrameRate: nominalFrameRate
        )

        await progress(
            VideoProcessingProgress(
                message: "Reading frames",
                completedFrames: 0,
                estimatedFrames: estimatedFrameCount,
                fraction: 0.12
            )
        )

        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = clippedTimeRange(timeSelection.cmTimeRange, assetDuration: assetDuration)

        let readerOutput = AVAssetReaderTrackOutput(
            track: videoTrack,
            outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ]
        )
        readerOutput.alwaysCopiesSampleData = false

        guard reader.canAdd(readerOutput) else {
            throw VideoProcessingError.readerCannotStart("Could not add video track output.")
        }
        reader.add(readerOutput)

        let writer = try AVAssetWriter(outputURL: outputVideoURL, fileType: .mov)
        let writerInput = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.proRes4444,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height
            ]
        )
        writerInput.expectsMediaDataInRealTime = false
        writerInput.transform = preferredTransform

        let pixelBufferAdaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: writerInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferCGImageCompatibilityKey as String: true,
                kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
            ]
        )

        guard writer.canAdd(writerInput) else {
            throw VideoProcessingError.writerCannotStart("Could not add video writer input.")
        }
        writer.add(writerInput)

        guard writer.startWriting() else {
            throw VideoProcessingError.writerCannotStart(writer.error?.localizedDescription ?? "Unknown writer error.")
        }

        defer {
            if reader.status == .reading {
                reader.cancelReading()
            }

            if writer.status == .writing {
                writer.cancelWriting()
            }
        }

        guard reader.startReading() else {
            throw VideoProcessingError.readerCannotStart(reader.error?.localizedDescription ?? "Unknown reader error.")
        }

        writer.startSession(atSourceTime: .zero)

        var frameIndex = 0
        var firstPresentationTime: CMTime?

        while let sampleBuffer = readerOutput.copyNextSampleBuffer() {
            try Task.checkCancellation()

            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
                continue
            }

            let sourceImage = try makeCGImage(from: pixelBuffer)
            let result = try await rmbg.removeBackground(from: sourceImage)
            let processedImage = result.image
            let frameURL = framesDirectory.appendingPathComponent(
                String(format: "frame_%06d.png", frameIndex + 1)
            )

            try writePNG(processedImage, to: frameURL)

            if firstPresentationTime == nil {
                firstPresentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            }

            let presentationTime = CMTimeSubtract(
                CMSampleBufferGetPresentationTimeStamp(sampleBuffer),
                firstPresentationTime ?? .zero
            )

            let outputPixelBuffer = try makePixelBuffer(
                from: processedImage,
                width: width,
                height: height,
                pool: pixelBufferAdaptor.pixelBufferPool
            )

            while !writerInput.isReadyForMoreMediaData {
                try Task.checkCancellation()
                try await Task.sleep(for: .milliseconds(10))
            }

            guard pixelBufferAdaptor.append(outputPixelBuffer, withPresentationTime: presentationTime) else {
                throw VideoProcessingError.writerCannotStart(
                    writer.error?.localizedDescription ?? "Could not append processed frame."
                )
            }

            frameIndex += 1

            let normalizedProgress = progressFraction(
                completedFrames: frameIndex,
                estimatedFrames: estimatedFrameCount
            )

            await progress(
                VideoProcessingProgress(
                    message: "Processed \(frameIndex.formatted()) of \(estimatedFrameCount.formatted()) frames",
                    completedFrames: frameIndex,
                    estimatedFrames: estimatedFrameCount,
                    fraction: normalizedProgress
                )
            )
        }

        if reader.status == .failed {
            throw VideoProcessingError.readerCannotStart(reader.error?.localizedDescription ?? "Reader failed.")
        }

        writerInput.markAsFinished()
        await finishWriting(writer)

        if writer.status == .failed || writer.status == .cancelled {
            throw VideoProcessingError.writerCannotStart(writer.error?.localizedDescription ?? "Writer failed.")
        }

        await progress(
            VideoProcessingProgress(
                message: "Finished \(frameIndex.formatted()) frames",
                completedFrames: frameIndex,
                estimatedFrames: estimatedFrameCount,
                fraction: 1
            )
        )

        return VideoProcessingResult(
            videoURL: outputVideoURL,
            framesDirectory: framesDirectory,
            frameCount: frameIndex,
            width: width,
            height: height,
            durationSeconds: timeSelection.durationSeconds
        )
    }

    private func makeCGImage(from pixelBuffer: CVPixelBuffer) throws -> CGImage {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let image = CIImage(cvPixelBuffer: pixelBuffer)

        guard let cgImage = imageContext.createCGImage(
            image,
            from: CGRect(x: 0, y: 0, width: width, height: height)
        ) else {
            throw VideoProcessingError.cannotCreateImage
        }

        return cgImage
    }

    private func makePixelBuffer(
        from image: CGImage,
        width: Int,
        height: Int,
        pool: CVPixelBufferPool?
    ) throws -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?

        if let pool {
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer)
        } else {
            let attributes: [String: Any] = [
                kCVPixelBufferCGImageCompatibilityKey as String: true,
                kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ]
            CVPixelBufferCreate(
                nil,
                width,
                height,
                kCVPixelFormatType_32BGRA,
                attributes as CFDictionary,
                &pixelBuffer
            )
        }

        guard let pixelBuffer else {
            throw VideoProcessingError.cannotCreatePixelBuffer
        }

        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        var ciImage = CIImage(cgImage: image)

        if image.width != width || image.height != height {
            ciImage = ciImage.transformed(
                by: CGAffineTransform(
                    scaleX: CGFloat(width) / CGFloat(image.width),
                    y: CGFloat(height) / CGFloat(image.height)
                )
            )
        }

        imageContext.render(ciImage, to: pixelBuffer, bounds: bounds, colorSpace: colorSpace)

        return pixelBuffer
    }

    private func writePNG(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw VideoProcessingError.cannotCreatePNGDestination
        }

        CGImageDestinationAddImage(destination, image, nil)

        guard CGImageDestinationFinalize(destination) else {
            throw VideoProcessingError.cannotCreatePNGDestination
        }
    }

    private func estimatedFrames(duration: CMTime, nominalFrameRate: Float) -> Int {
        guard duration.seconds.isFinite, duration.seconds > 0 else {
            return 0
        }

        let framesPerSecond = max(Double(nominalFrameRate), 1)
        return max(1, Int((duration.seconds * framesPerSecond).rounded()))
    }

    private func clippedTimeRange(_ timeRange: CMTimeRange, assetDuration: CMTime) -> CMTimeRange {
        guard assetDuration.isNumeric else {
            return timeRange
        }

        guard CMTimeCompare(timeRange.start, assetDuration) < 0 else {
            return CMTimeRange(start: .zero, duration: assetDuration)
        }

        let requestedEnd = CMTimeAdd(timeRange.start, timeRange.duration)
        let end = CMTimeMinimum(requestedEnd, assetDuration)
        let duration = CMTimeSubtract(end, timeRange.start)

        return CMTimeRange(start: timeRange.start, duration: duration)
    }

    private func progressFraction(completedFrames: Int, estimatedFrames: Int) -> Double {
        guard estimatedFrames > 0 else {
            return 0.12
        }

        let frameProgress = min(Double(completedFrames) / Double(estimatedFrames), 1)
        return 0.12 + (frameProgress * 0.86)
    }

    private func finishWriting(_ writer: AVAssetWriter) async {
        await withCheckedContinuation { continuation in
            writer.finishWriting {
                continuation.resume()
            }
        }
    }
}

private enum VideoProcessingError: LocalizedError {
    case noVideoTrack
    case cannotCreateImage
    case cannotCreatePixelBuffer
    case cannotCreatePNGDestination
    case readerCannotStart(String)
    case writerCannotStart(String)

    var errorDescription: String? {
        switch self {
        case .noVideoTrack:
            "The selected file does not contain a video track."
        case .cannotCreateImage:
            "Could not create an image from a video frame."
        case .cannotCreatePixelBuffer:
            "Could not create a video frame buffer."
        case .cannotCreatePNGDestination:
            "Could not write a PNG frame."
        case .readerCannotStart(let message):
            "Could not read the video. \(message)"
        case .writerCannotStart(let message):
            "Could not write the preview video. \(message)"
        }
    }
}
