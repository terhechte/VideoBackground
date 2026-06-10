import AVFoundation
import Foundation

enum MovieExportCodec: Sendable {
    case proRes4444
    case proRes4444XQ

    var displayName: String {
        switch self {
        case .proRes4444:
            "Apple ProRes 4444"
        case .proRes4444XQ:
            "Apple ProRes 4444 XQ"
        }
    }

    var fileNameSuffix: String {
        switch self {
        case .proRes4444:
            "prores-4444"
        case .proRes4444XQ:
            "prores-4444-xq"
        }
    }

    var avVideoCodec: AVVideoCodecType {
        switch self {
        case .proRes4444:
            .proRes4444
        case .proRes4444XQ:
            AVVideoCodecType(rawValue: "ap4x")
        }
    }
}

struct MovieExportProgress: Sendable {
    let message: String
    let fraction: Double
}

enum MovieExporter {
    static func exportMovie(
        from sourceURL: URL,
        to destinationURL: URL,
        codec: MovieExportCodec,
        progress: @Sendable @escaping (MovieExportProgress) async -> Void
    ) async throws {
        if codec == .proRes4444 {
            try await copyMovie(from: sourceURL, to: destinationURL)
            await progress(MovieExportProgress(message: "Exported \(codec.displayName)", fraction: 1))
            return
        }

        try await transcodeMovie(
            from: sourceURL,
            to: destinationURL,
            codec: codec,
            progress: progress
        )
    }

    private static func copyMovie(from sourceURL: URL, to destinationURL: URL) async throws {
        try await Task.detached(priority: .userInitiated) {
            let fileManager = FileManager.default
            let source = sourceURL.standardizedFileURL
            let destination = destinationURL.standardizedFileURL

            guard source != destination else {
                return
            }

            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }

            try fileManager.copyItem(at: source, to: destination)
        }.value
    }

    private static func transcodeMovie(
        from sourceURL: URL,
        to destinationURL: URL,
        codec: MovieExportCodec,
        progress: @Sendable @escaping (MovieExportProgress) async -> Void
    ) async throws {
        try await Task.detached(priority: .userInitiated) {
            let asset = AVURLAsset(url: sourceURL)
            let tracks = try await asset.loadTracks(withMediaType: .video)

            guard let videoTrack = tracks.first else {
                throw MovieExportError.noVideoTrack
            }

            let duration = try await asset.load(.duration)
            let naturalSize = try await videoTrack.load(.naturalSize)
            let preferredTransform = try await videoTrack.load(.preferredTransform)
            let nominalFrameRate = try await videoTrack.load(.nominalFrameRate)
            let width = max(1, Int(naturalSize.width.rounded()))
            let height = max(1, Int(naturalSize.height.rounded()))
            let estimatedFrameCount = estimatedFrames(
                duration: duration,
                nominalFrameRate: nominalFrameRate
            )

            let fileManager = FileManager.default
            let temporaryURL = destinationURL
                .deletingLastPathComponent()
                .appendingPathComponent(".\(UUID().uuidString)-\(destinationURL.lastPathComponent)")

            if fileManager.fileExists(atPath: temporaryURL.path) {
                try fileManager.removeItem(at: temporaryURL)
            }

            await progress(
                MovieExportProgress(
                    message: "Preparing \(codec.displayName)",
                    fraction: 0.02
                )
            )

            let reader = try AVAssetReader(asset: asset)
            let readerOutput = AVAssetReaderTrackOutput(
                track: videoTrack,
                outputSettings: [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
                ]
            )
            readerOutput.alwaysCopiesSampleData = false

            guard reader.canAdd(readerOutput) else {
                throw MovieExportError.readerCannotStart("Could not add video track output.")
            }
            reader.add(readerOutput)

            let writer = try AVAssetWriter(outputURL: temporaryURL, fileType: .mov)
            let writerInput = AVAssetWriterInput(
                mediaType: .video,
                outputSettings: [
                    AVVideoCodecKey: codec.avVideoCodec,
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
                throw MovieExportError.writerCannotStart("Could not add video writer input.")
            }
            writer.add(writerInput)

            guard writer.startWriting() else {
                throw MovieExportError.writerCannotStart(writer.error?.localizedDescription ?? "Unknown writer error.")
            }

            defer {
                if reader.status == .reading {
                    reader.cancelReading()
                }

                if writer.status == .writing {
                    writer.cancelWriting()
                }

                if fileManager.fileExists(atPath: temporaryURL.path) {
                    try? fileManager.removeItem(at: temporaryURL)
                }
            }

            guard reader.startReading() else {
                throw MovieExportError.readerCannotStart(reader.error?.localizedDescription ?? "Unknown reader error.")
            }

            writer.startSession(atSourceTime: .zero)

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

                while !writerInput.isReadyForMoreMediaData {
                    try Task.checkCancellation()
                    try await Task.sleep(for: .milliseconds(10))
                }

                guard pixelBufferAdaptor.append(pixelBuffer, withPresentationTime: presentationTime) else {
                    throw MovieExportError.writerCannotStart(
                        writer.error?.localizedDescription ?? "Could not append frame."
                    )
                }

                frameIndex += 1

                if frameIndex == 1 || frameIndex.isMultiple(of: 10) {
                    await progress(
                        MovieExportProgress(
                            message: "Exporting \(codec.displayName): \(frameIndex.formatted()) of \(estimatedFrameCount.formatted()) frames",
                            fraction: progressFraction(
                                completedFrames: frameIndex,
                                estimatedFrames: estimatedFrameCount
                            )
                        )
                    )
                }
            }

            if reader.status == .failed {
                throw MovieExportError.readerCannotStart(reader.error?.localizedDescription ?? "Reader failed.")
            }

            writerInput.markAsFinished()
            await finishWriting(writer)

            if writer.status == .failed || writer.status == .cancelled {
                throw MovieExportError.writerCannotStart(writer.error?.localizedDescription ?? "Writer failed.")
            }

            if fileManager.fileExists(atPath: destinationURL.path) {
                try fileManager.removeItem(at: destinationURL)
            }

            try fileManager.moveItem(at: temporaryURL, to: destinationURL)

            await progress(
                MovieExportProgress(
                    message: "Exported \(codec.displayName)",
                    fraction: 1
                )
            )
        }.value
    }

    private static func estimatedFrames(duration: CMTime, nominalFrameRate: Float) -> Int {
        guard duration.seconds.isFinite, duration.seconds > 0 else {
            return 0
        }

        let framesPerSecond = max(Double(nominalFrameRate), 1)
        return max(1, Int((duration.seconds * framesPerSecond).rounded()))
    }

    private static func progressFraction(completedFrames: Int, estimatedFrames: Int) -> Double {
        guard estimatedFrames > 0 else {
            return 0.1
        }

        let frameProgress = min(Double(completedFrames) / Double(estimatedFrames), 1)
        return 0.02 + (frameProgress * 0.96)
    }

    private static func finishWriting(_ writer: AVAssetWriter) async {
        await withCheckedContinuation { continuation in
            writer.finishWriting {
                continuation.resume()
            }
        }
    }
}

private enum MovieExportError: LocalizedError {
    case noVideoTrack
    case readerCannotStart(String)
    case writerCannotStart(String)

    var errorDescription: String? {
        switch self {
        case .noVideoTrack:
            "The generated movie does not contain a video track."
        case .readerCannotStart(let message):
            "Could not read the generated movie. \(message)"
        case .writerCannotStart(let message):
            "Could not write the movie export. \(message)"
        }
    }
}
