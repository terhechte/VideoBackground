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

struct MovieExportResult: Sendable {
    let audioMuxed: Bool
    let mp3URL: URL?
}

enum MovieExporter {
    static func exportMovie(
        from processedVideoURL: URL,
        originalAudioURL: URL,
        timeSelection: VideoTimeSelection,
        to destinationURL: URL,
        codec: MovieExportCodec,
        exportOriginalAudioMP3: Bool,
        progress: @Sendable @escaping (MovieExportProgress) async -> Void
    ) async throws -> MovieExportResult {
        let fileManager = FileManager.default
        let workDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("VideoBackgroundExport-\(UUID().uuidString)", isDirectory: true)

        try fileManager.createDirectory(at: workDirectory, withIntermediateDirectories: true)

        defer {
            try? fileManager.removeItem(at: workDirectory)
        }

        let audioTrackCount = try await audioTrackCount(in: originalAudioURL)
        let hasSourceAudio = audioTrackCount > 0
        let videoOnlyURL: URL

        if codec == .proRes4444 {
            videoOnlyURL = processedVideoURL
        } else {
            videoOnlyURL = workDirectory.appendingPathComponent("video-\(codec.fileNameSuffix).mov")
            try await transcodeVideo(
                from: processedVideoURL,
                to: videoOnlyURL,
                codec: codec,
                progress: progress
            )
        }

        await progress(
            MovieExportProgress(
                message: hasSourceAudio ? "Adding original audio" : "Writing movie",
                fraction: 0.82
            )
        )

        let audioMuxed = try await muxMovie(
            videoURL: videoOnlyURL,
            originalAudioURL: hasSourceAudio ? originalAudioURL : nil,
            audioTimeSelection: timeSelection,
            to: destinationURL,
            progress: progress
        )

        var mp3URL: URL?

        if exportOriginalAudioMP3 {
            if audioMuxed {
                let destinationMP3URL = destinationURL
                    .deletingPathExtension()
                    .appendingPathExtension("mp3")

                await progress(
                    MovieExportProgress(
                        message: "Exporting original audio as MP3",
                        fraction: 0.94
                    )
                )

                try await exportMP3(
                    from: originalAudioURL,
                    timeSelection: timeSelection,
                    to: destinationMP3URL
                )
                mp3URL = destinationMP3URL
            } else {
                await progress(
                    MovieExportProgress(
                        message: "No original audio track found",
                        fraction: 1
                    )
                )
            }
        }

        await progress(
            MovieExportProgress(
                message: "Exported \(codec.displayName)",
                fraction: 1
            )
        )

        return MovieExportResult(audioMuxed: audioMuxed, mp3URL: mp3URL)
    }

    private static func transcodeVideo(
        from sourceURL: URL,
        to destinationURL: URL,
        codec: MovieExportCodec,
        progress: @Sendable @escaping (MovieExportProgress) async -> Void
    ) async throws {
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

        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
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

        let writer = try AVAssetWriter(outputURL: destinationURL, fileType: .mov)
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
                        fraction: 0.02 + progressFraction(
                            completedFrames: frameIndex,
                            estimatedFrames: estimatedFrameCount
                        ) * 0.78
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
    }

    private static func muxMovie(
        videoURL: URL,
        originalAudioURL: URL?,
        audioTimeSelection: VideoTimeSelection,
        to destinationURL: URL,
        progress: @Sendable @escaping (MovieExportProgress) async -> Void
    ) async throws -> Bool {
        let fileManager = FileManager.default
        let temporaryURL = destinationURL
            .deletingLastPathComponent()
            .appendingPathComponent(".\(UUID().uuidString)-\(destinationURL.lastPathComponent)")

        if fileManager.fileExists(atPath: temporaryURL.path) {
            try fileManager.removeItem(at: temporaryURL)
        }

        let composition = AVMutableComposition()
        let videoAsset = AVURLAsset(url: videoURL)
        let videoTracks = try await videoAsset.loadTracks(withMediaType: .video)

        guard let sourceVideoTrack = videoTracks.first,
              let compositionVideoTrack = composition.addMutableTrack(
                  withMediaType: .video,
                  preferredTrackID: kCMPersistentTrackID_Invalid
              ) else {
            throw MovieExportError.noVideoTrack
        }

        let videoDuration = try await videoAsset.load(.duration)
        let preferredTransform = try await sourceVideoTrack.load(.preferredTransform)

        try compositionVideoTrack.insertTimeRange(
            CMTimeRange(start: .zero, duration: videoDuration),
            of: sourceVideoTrack,
            at: .zero
        )
        compositionVideoTrack.preferredTransform = preferredTransform

        var insertedAudioTrackCount = 0

        if let originalAudioURL {
            let audioAsset = AVURLAsset(url: originalAudioURL)
            let audioTracks = try await audioAsset.loadTracks(withMediaType: .audio)
            let audioDuration = try await audioAsset.load(.duration)

            if let audioTimeRange = clippedAudioTimeRange(
                selection: audioTimeSelection,
                videoDuration: videoDuration,
                audioDuration: audioDuration
            ) {
                for sourceAudioTrack in audioTracks {
                    guard let compositionAudioTrack = composition.addMutableTrack(
                        withMediaType: .audio,
                        preferredTrackID: kCMPersistentTrackID_Invalid
                    ) else {
                        continue
                    }

                    try compositionAudioTrack.insertTimeRange(
                        audioTimeRange,
                        of: sourceAudioTrack,
                        at: .zero
                    )
                    insertedAudioTrackCount += 1
                }
            }
        }

        guard let exportSession = AVAssetExportSession(
            asset: composition,
            presetName: AVAssetExportPresetPassthrough
        ) else {
            throw MovieExportError.writerCannotStart("Could not create a passthrough movie exporter.")
        }

        exportSession.outputURL = temporaryURL
        exportSession.outputFileType = .mov
        exportSession.shouldOptimizeForNetworkUse = false

        await progress(MovieExportProgress(message: "Writing movie", fraction: 0.86))

        try await exportAsynchronously(exportSession)

        if exportSession.status == .failed || exportSession.status == .cancelled {
            throw MovieExportError.writerCannotStart(
                exportSession.error?.localizedDescription ?? "Movie export failed."
            )
        }

        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }

        try fileManager.moveItem(at: temporaryURL, to: destinationURL)

        return insertedAudioTrackCount > 0
    }

    private static func exportMP3(
        from sourceURL: URL,
        timeSelection: VideoTimeSelection,
        to destinationURL: URL
    ) async throws {
        try await Task.detached(priority: .userInitiated) {
            let fileManager = FileManager.default

            guard let ffmpegURL = findExecutable(
                named: "ffmpeg",
                candidates: [
                    "/opt/homebrew/bin/ffmpeg",
                    "/usr/local/bin/ffmpeg",
                    "/usr/bin/ffmpeg"
                ]
            ) else {
                throw MovieExportError.mp3ExportFailed("MP3 export requires ffmpeg to be installed.")
            }

            if fileManager.fileExists(atPath: destinationURL.path) {
                try fileManager.removeItem(at: destinationURL)
            }

            let process = Process()
            let outputPipe = Pipe()
            process.executableURL = ffmpegURL
            process.arguments = [
                "-y",
                "-ss", String(format: "%.6f", timeSelection.startSeconds),
                "-t", String(format: "%.6f", timeSelection.durationSeconds),
                "-i", sourceURL.path,
                "-vn",
                "-map", "0:a:0",
                "-codec:a", "libmp3lame",
                "-q:a", "2",
                destinationURL.path
            ]
            process.standardOutput = outputPipe
            process.standardError = outputPipe

            try process.run()
            process.waitUntilExit()

            guard process.terminationStatus == 0 else {
                let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
                let message = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                throw MovieExportError.mp3ExportFailed(message ?? "ffmpeg exited with status \(process.terminationStatus).")
            }
        }.value
    }

    private static func audioTrackCount(in url: URL) async throws -> Int {
        let asset = AVURLAsset(url: url)
        return try await asset.loadTracks(withMediaType: .audio).count
    }

    private static func findExecutable(named name: String, candidates: [String]) -> URL? {
        let fileManager = FileManager.default

        for candidate in candidates where fileManager.isExecutableFile(atPath: candidate) {
            return URL(fileURLWithPath: candidate)
        }

        let pathDirectories = ProcessInfo.processInfo.environment["PATH"]?
            .split(separator: ":")
            .map(String.init) ?? []

        for directory in pathDirectories {
            let candidate = URL(fileURLWithPath: directory).appendingPathComponent(name).path

            if fileManager.isExecutableFile(atPath: candidate) {
                return URL(fileURLWithPath: candidate)
            }
        }

        return nil
    }

    private static func clippedAudioTimeRange(
        selection: VideoTimeSelection,
        videoDuration: CMTime,
        audioDuration: CMTime
    ) -> CMTimeRange? {
        let requested = selection.cmTimeRange
        let requestedDuration = clippedDuration(
            videoDuration: videoDuration,
            audioDuration: requested.duration
        )

        guard CMTimeCompare(requestedDuration, .zero) > 0 else {
            return nil
        }

        guard audioDuration.isNumeric else {
            return CMTimeRange(start: requested.start, duration: requestedDuration)
        }

        guard CMTimeCompare(requested.start, audioDuration) < 0 else {
            return nil
        }

        let remainingAudioDuration = CMTimeSubtract(audioDuration, requested.start)
        let duration = clippedDuration(
            videoDuration: requestedDuration,
            audioDuration: remainingAudioDuration
        )

        guard CMTimeCompare(duration, .zero) > 0 else {
            return nil
        }

        return CMTimeRange(start: requested.start, duration: duration)
    }

    private static func clippedDuration(videoDuration: CMTime, audioDuration: CMTime) -> CMTime {
        guard videoDuration.isNumeric else {
            return audioDuration
        }

        guard audioDuration.isNumeric else {
            return videoDuration
        }

        return CMTimeMinimum(videoDuration, audioDuration)
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

        return min(Double(completedFrames) / Double(estimatedFrames), 1)
    }

    private static func finishWriting(_ writer: AVAssetWriter) async {
        await withCheckedContinuation { continuation in
            writer.finishWriting {
                continuation.resume()
            }
        }
    }

    private static func exportAsynchronously(_ exportSession: AVAssetExportSession) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            exportSession.exportAsynchronously {
                continuation.resume()
            }
        }
    }
}

private enum MovieExportError: LocalizedError {
    case noVideoTrack
    case readerCannotStart(String)
    case writerCannotStart(String)
    case mp3ExportFailed(String)

    var errorDescription: String? {
        switch self {
        case .noVideoTrack:
            "The generated movie does not contain a video track."
        case .readerCannotStart(let message):
            "Could not read the generated movie. \(message)"
        case .writerCannotStart(let message):
            "Could not write the movie export. \(message)"
        case .mp3ExportFailed(let message):
            "Could not export the MP3 file. \(message)"
        }
    }
}
