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
    private let maxConcurrentReplicateFrames = 4

    func process(
        videoURL: URL,
        timeSelection: VideoTimeSelection,
        upscaleWithReplicate: Bool = false,
        progress: @Sendable @escaping (VideoProcessingProgress) async -> Void
    ) async throws -> VideoProcessingResult {
        let fileManager = FileManager.default
        let workDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("VideoBackground-\(UUID().uuidString)", isDirectory: true)
        let framesDirectory = workDirectory.appendingPathComponent("PNGFrames", isDirectory: true)
        let outputVideoURL = workDirectory.appendingPathComponent("background-removed.mov")

        try fileManager.createDirectory(at: framesDirectory, withIntermediateDirectories: true)

        let upscaler: ReplicateImageUpscaler?

        if upscaleWithReplicate {
            await progress(
                VideoProcessingProgress(
                    message: "Preparing Replicate upscaler",
                    completedFrames: 0,
                    estimatedFrames: 0,
                    fraction: 0.01
                )
            )

            upscaler = try ReplicateImageUpscaler()
            try await upscaler?.prepare()
        } else {
            upscaler = nil
        }

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

        if let upscaler {
            return try await processWithReplicateUpscaling(
                asset: asset,
                videoTrack: videoTrack,
                assetDuration: assetDuration,
                preferredTransform: preferredTransform,
                sourceWidth: width,
                sourceHeight: height,
                timeSelection: timeSelection,
                estimatedFrameCount: estimatedFrameCount,
                framesDirectory: framesDirectory,
                outputVideoURL: outputVideoURL,
                rmbg: rmbg,
                upscaler: upscaler,
                progress: progress
            )
        }

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

    private func processWithReplicateUpscaling(
        asset: AVURLAsset,
        videoTrack: AVAssetTrack,
        assetDuration: CMTime,
        preferredTransform: CGAffineTransform,
        sourceWidth: Int,
        sourceHeight: Int,
        timeSelection: VideoTimeSelection,
        estimatedFrameCount: Int,
        framesDirectory: URL,
        outputVideoURL: URL,
        rmbg: RMBG2,
        upscaler: ReplicateImageUpscaler,
        progress: @Sendable @escaping (VideoProcessingProgress) async -> Void
    ) async throws -> VideoProcessingResult {
        await progress(
            VideoProcessingProgress(
                message: "Reading frames for Replicate upscaling",
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

        let sourceFramesDirectory = framesDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("SourcePNGFrames", isDirectory: true)

        try FileManager.default.createDirectory(at: sourceFramesDirectory, withIntermediateDirectories: true)

        defer {
            if reader.status == .reading {
                reader.cancelReading()
            }

            try? FileManager.default.removeItem(at: sourceFramesDirectory)
        }

        guard reader.startReading() else {
            throw VideoProcessingError.readerCannotStart(reader.error?.localizedDescription ?? "Unknown reader error.")
        }

        var sourceFrames: [SourceVideoFrame] = []
        sourceFrames.reserveCapacity(estimatedFrameCount)
        var frameIndex = 0
        var firstPresentationTime: CMTime?

        while let sampleBuffer = readerOutput.copyNextSampleBuffer() {
            try Task.checkCancellation()

            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
                continue
            }

            if firstPresentationTime == nil {
                firstPresentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            }

            let presentationTime = CMTimeSubtract(
                CMSampleBufferGetPresentationTimeStamp(sampleBuffer),
                firstPresentationTime ?? .zero
            )
            let sourceImage = try makeCGImage(from: pixelBuffer)
            let sourceFrameURL = sourceFramesDirectory.appendingPathComponent(
                String(format: "source_frame_%06d.png", frameIndex + 1)
            )

            try writePNG(sourceImage, to: sourceFrameURL)

            sourceFrames.append(
                SourceVideoFrame(
                    index: frameIndex,
                    presentationTime: presentationTime,
                    imageURL: sourceFrameURL
                )
            )
            frameIndex += 1

            if frameIndex == 1 || frameIndex.isMultiple(of: 10) {
                await progress(
                    VideoProcessingProgress(
                        message: "Extracted \(frameIndex.formatted()) of \(estimatedFrameCount.formatted()) frames for Replicate",
                        completedFrames: 0,
                        estimatedFrames: estimatedFrameCount,
                        fraction: 0.12
                    )
                )
            }
        }

        if reader.status == .failed {
            throw VideoProcessingError.readerCannotStart(reader.error?.localizedDescription ?? "Reader failed.")
        }

        let writer = ProcessedVideoFrameWriter(
            outputURL: outputVideoURL,
            framesDirectory: framesDirectory,
            sourceWidth: sourceWidth,
            sourceHeight: sourceHeight,
            preferredTransform: preferredTransform,
            estimatedFrameCount: estimatedFrameCount,
            progress: progress
        )

        do {
            try await Self.upscaleAndRemoveBackground(
                sourceFrames: sourceFrames,
                maxConcurrentFrames: maxConcurrentReplicateFrames,
                rmbg: rmbg,
                upscaler: upscaler,
                writer: writer
            )

            let writerResult = try await writer.finish()

            await progress(
                VideoProcessingProgress(
                    message: "Finished \(writerResult.frameCount.formatted()) frames",
                    completedFrames: writerResult.frameCount,
                    estimatedFrames: estimatedFrameCount,
                    fraction: 1
                )
            )

            return VideoProcessingResult(
                videoURL: outputVideoURL,
                framesDirectory: framesDirectory,
                frameCount: writerResult.frameCount,
                width: writerResult.width,
                height: writerResult.height,
                durationSeconds: timeSelection.durationSeconds
            )
        } catch {
            await writer.cancel()
            throw error
        }
    }

    private static func upscaleAndRemoveBackground(
        sourceFrames: [SourceVideoFrame],
        maxConcurrentFrames: Int,
        rmbg: RMBG2,
        upscaler: ReplicateImageUpscaler,
        writer: ProcessedVideoFrameWriter
    ) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            var nextFrameIndex = 0
            var inFlightFrames = 0

            func enqueueNextFrame() {
                let sourceFrame = sourceFrames[nextFrameIndex]
                nextFrameIndex += 1
                inFlightFrames += 1

                group.addTask {
                    try Task.checkCancellation()

                    let upscaledFrame = try await upscaler.upscaleFrame(
                        at: sourceFrame.imageURL,
                        index: sourceFrame.index
                    )
                    let upscaledImage = try Self.makeCGImage(from: upscaledFrame.pngData)
                    let result = try await rmbg.removeBackground(from: upscaledImage)

                    try await writer.accept(
                        ProcessedVideoFrame(
                            index: sourceFrame.index,
                            presentationTime: sourceFrame.presentationTime,
                            image: result.image
                        )
                    )
                }
            }

            while inFlightFrames < maxConcurrentFrames && nextFrameIndex < sourceFrames.count {
                enqueueNextFrame()
            }

            while inFlightFrames > 0 {
                try await group.next()
                inFlightFrames -= 1

                if nextFrameIndex < sourceFrames.count {
                    enqueueNextFrame()
                }
            }
        }
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

    private static func makeCGImage(from data: Data) throws -> CGImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw VideoProcessingError.cannotCreateImage
        }

        return image
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

private struct SourceVideoFrame: Sendable {
    let index: Int
    let presentationTime: CMTime
    let imageURL: URL
}

private struct ProcessedVideoFrame: Sendable {
    let index: Int
    let presentationTime: CMTime
    let image: CGImage
}

private struct ProcessedVideoFrameWriterResult: Sendable {
    let frameCount: Int
    let width: Int
    let height: Int
}

private struct VideoWriterContext {
    let writer: AVAssetWriter
    let input: AVAssetWriterInput
    let pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor
    let width: Int
    let height: Int
}

private actor ProcessedVideoFrameWriter {
    private let outputURL: URL
    private let framesDirectory: URL
    private let sourceWidth: Int
    private let sourceHeight: Int
    private let preferredTransform: CGAffineTransform
    private let estimatedFrameCount: Int
    private let progress: @Sendable (VideoProcessingProgress) async -> Void
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private lazy var imageContext = CIContext(options: [.workingColorSpace: colorSpace])

    private var writerContext: VideoWriterContext?
    private var pendingFrames: [Int: ProcessedVideoFrame] = [:]
    private var nextFrameToWrite = 0
    private var completedFrames = 0
    private var outputWidth: Int
    private var outputHeight: Int

    init(
        outputURL: URL,
        framesDirectory: URL,
        sourceWidth: Int,
        sourceHeight: Int,
        preferredTransform: CGAffineTransform,
        estimatedFrameCount: Int,
        progress: @Sendable @escaping (VideoProcessingProgress) async -> Void
    ) {
        self.outputURL = outputURL
        self.framesDirectory = framesDirectory
        self.sourceWidth = sourceWidth
        self.sourceHeight = sourceHeight
        self.preferredTransform = preferredTransform
        self.estimatedFrameCount = estimatedFrameCount
        self.progress = progress
        self.outputWidth = sourceWidth
        self.outputHeight = sourceHeight
    }

    func accept(_ processedFrame: ProcessedVideoFrame) async throws {
        pendingFrames[processedFrame.index] = processedFrame
        try await writeReadyFrames()
    }

    func finish() async throws -> ProcessedVideoFrameWriterResult {
        if writerContext == nil {
            writerContext = try makeWriterContext(width: sourceWidth, height: sourceHeight)
        }

        guard let writerContext else {
            throw VideoProcessingError.writerCannotStart("Could not create video writer.")
        }

        writerContext.input.markAsFinished()
        await finishWriting(writerContext.writer)

        if writerContext.writer.status == .failed || writerContext.writer.status == .cancelled {
            throw VideoProcessingError.writerCannotStart(
                writerContext.writer.error?.localizedDescription ?? "Writer failed."
            )
        }

        return ProcessedVideoFrameWriterResult(
            frameCount: completedFrames,
            width: outputWidth,
            height: outputHeight
        )
    }

    func cancel() {
        if writerContext?.writer.status == .writing {
            writerContext?.writer.cancelWriting()
        }
    }

    private func writeReadyFrames() async throws {
        while let processedFrame = pendingFrames.removeValue(forKey: nextFrameToWrite) {
            if writerContext == nil {
                outputWidth = processedFrame.image.width
                outputHeight = processedFrame.image.height
                writerContext = try makeWriterContext(width: outputWidth, height: outputHeight)
            }

            guard let writerContext else {
                throw VideoProcessingError.writerCannotStart("Could not create video writer.")
            }

            let frameURL = framesDirectory.appendingPathComponent(
                String(format: "frame_%06d.png", processedFrame.index + 1)
            )

            try writePNG(processedFrame.image, to: frameURL)
            try await append(processedFrame, writerContext: writerContext)

            nextFrameToWrite += 1
            completedFrames += 1

            await progress(
                VideoProcessingProgress(
                    message: "Upscaled and processed \(completedFrames.formatted()) of \(estimatedFrameCount.formatted()) frames",
                    completedFrames: completedFrames,
                    estimatedFrames: estimatedFrameCount,
                    fraction: progressFraction(
                        completedFrames: completedFrames,
                        estimatedFrames: estimatedFrameCount
                    )
                )
            )
        }
    }

    private func makeWriterContext(width: Int, height: Int) throws -> VideoWriterContext {
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
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

        writer.startSession(atSourceTime: .zero)

        return VideoWriterContext(
            writer: writer,
            input: writerInput,
            pixelBufferAdaptor: pixelBufferAdaptor,
            width: width,
            height: height
        )
    }

    private func append(
        _ processedFrame: ProcessedVideoFrame,
        writerContext: VideoWriterContext
    ) async throws {
        let outputPixelBuffer = try makePixelBuffer(
            from: processedFrame.image,
            width: writerContext.width,
            height: writerContext.height,
            pool: writerContext.pixelBufferAdaptor.pixelBufferPool
        )

        while !writerContext.input.isReadyForMoreMediaData {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(10))
        }

        guard writerContext.pixelBufferAdaptor.append(
            outputPixelBuffer,
            withPresentationTime: processedFrame.presentationTime
        ) else {
            throw VideoProcessingError.writerCannotStart(
                writerContext.writer.error?.localizedDescription ?? "Could not append processed frame."
            )
        }
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
