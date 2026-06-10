import AVKit
import AppKit
import Foundation
import UniformTypeIdentifiers

@MainActor
final class VideoBackgroundViewModel: ObservableObject {
    @Published var selectedVideoURL: URL?
    @Published var outputVideoURL: URL?
    @Published var player: AVPlayer?
    @Published var statusText = "Ready"
    @Published var progress: Double = 0
    @Published var isProcessing = false
    @Published var isExporting = false
    @Published var errorMessage: String?
    @Published var upscaleWithReplicate = false
    @Published var sourceDurationSeconds = 0.0
    @Published var trimStartSeconds = 0.0
    @Published var trimEndSeconds = 0.0
    @Published private(set) var frameCount = 0
    @Published private(set) var outputFramesDirectory: URL?
    @Published private(set) var outputWidth = 0
    @Published private(set) var outputHeight = 0
    @Published private(set) var durationSeconds = 0.0

    private var processingTask: Task<Void, Never>?
    private var metadataTask: Task<Void, Never>?
    private let minimumTrimDuration = 0.1

    var sourceTitle: String {
        selectedVideoURL?.lastPathComponent ?? "No video selected"
    }

    var outputTitle: String {
        outputVideoURL?.lastPathComponent ?? "None"
    }

    var frameCountText: String {
        frameCount == 0 ? "-" : frameCount.formatted()
    }

    var videoSizeText: String {
        outputWidth == 0 || outputHeight == 0 ? "-" : "\(outputWidth) x \(outputHeight)"
    }

    var durationText: String {
        durationSeconds == 0 ? "-" : DurationFormatter.string(from: durationSeconds)
    }

    var sourceDurationText: String {
        sourceDurationSeconds == 0 ? "-" : DurationFormatter.string(from: sourceDurationSeconds)
    }

    var trimStartText: String {
        DurationFormatter.string(from: trimStartSeconds)
    }

    var trimEndText: String {
        DurationFormatter.string(from: trimEndSeconds)
    }

    var selectedDurationSeconds: Double {
        max(trimEndSeconds - trimStartSeconds, 0)
    }

    var selectedDurationText: String {
        DurationFormatter.string(from: selectedDurationSeconds)
    }

    var canTrim: Bool {
        sourceDurationSeconds > minimumTrimDuration && !isProcessing && !isExporting
    }

    var canProcess: Bool {
        selectedVideoURL != nil && sourceDurationSeconds > minimumTrimDuration && !isProcessing && !isExporting
    }

    var canChangeProcessingOptions: Bool {
        !isProcessing && !isExporting
    }

    var previewLoopStartSeconds: Double {
        outputVideoURL == nil ? trimStartSeconds : 0
    }

    var previewLoopEndSeconds: Double {
        outputVideoURL == nil ? trimEndSeconds : max(durationSeconds, 0)
    }

    var showProgress: Bool {
        isProcessing || isExporting || progress > 0
    }

    var canExport: Bool {
        outputFramesDirectory != nil && outputVideoURL != nil && !isProcessing && !isExporting
    }

    func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else {
                return
            }

            selectedVideoURL = url
            loadSourceVideo(url)
            statusText = "Loaded \(url.lastPathComponent)"

        case .failure(let error):
            errorMessage = error.localizedDescription
        }
    }

    func processSelectedVideo() {
        guard let selectedVideoURL else {
            return
        }

        processingTask?.cancel()
        clearGeneratedOutput()
        isProcessing = true
        statusText = "Preparing video"
        let timeSelection = selectedTimeSelection()
        let upscaleWithReplicate = upscaleWithReplicate

        processingTask = Task { [weak self, selectedVideoURL, timeSelection, upscaleWithReplicate] in
            let processor = VideoBackgroundProcessor()

            do {
                let result = try await processor.process(
                    videoURL: selectedVideoURL,
                    timeSelection: timeSelection,
                    upscaleWithReplicate: upscaleWithReplicate
                ) { [weak self] update in
                    await self?.apply(update)
                }

                self?.apply(result)
            } catch is CancellationError {
                self?.markCancelled()
            } catch {
                self?.markFailed(error)
            }
        }
    }

    func cancelProcessing() {
        processingTask?.cancel()
    }

    func setTrimStart(_ seconds: Double) {
        guard sourceDurationSeconds > 0 else {
            return
        }

        let maximumStart = max(0, trimEndSeconds - minimumTrimDuration)
        trimStartSeconds = min(max(seconds, 0), maximumStart)
        resetProcessedOutputForTrimChange()
        seekPreview(to: trimStartSeconds)
    }

    func setTrimEnd(_ seconds: Double) {
        guard sourceDurationSeconds > 0 else {
            return
        }

        let minimumEnd = min(sourceDurationSeconds, trimStartSeconds + minimumTrimDuration)
        trimEndSeconds = min(max(seconds, minimumEnd), sourceDurationSeconds)
        resetProcessedOutputForTrimChange()
        seekPreview(to: trimStartSeconds)
    }

    func exportPNGFrames() {
        guard let outputFramesDirectory, canExport else {
            return
        }

        let panel = NSOpenPanel()
        panel.title = "Export PNG Frames"
        panel.prompt = "Export"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false

        guard panel.runModal() == .OK, let destinationURL = panel.url else {
            return
        }

        isExporting = true
        progress = 0
        statusText = "Exporting PNG frames"

        Task { [weak self, outputFramesDirectory, destinationURL] in
            do {
                let count = try await PNGFrameExporter.copyFrames(
                    from: outputFramesDirectory,
                    to: destinationURL
                )

                await MainActor.run {
                    self?.isExporting = false
                    self?.progress = 1
                    self?.statusText = "Exported \(count.formatted()) PNG frames"
                }
            } catch {
                await MainActor.run {
                    self?.isExporting = false
                    self?.errorMessage = error.localizedDescription
                }
            }
        }
    }

    func exportMovie(codec: MovieExportCodec) {
        guard let outputVideoURL, let selectedVideoURL, canExport else {
            return
        }

        let panel = NSSavePanel()
        panel.title = "Export \(codec.displayName)"
        panel.prompt = "Export"
        panel.allowedContentTypes = [.quickTimeMovie]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = defaultMovieExportName(for: codec)

        let mp3Checkbox = NSButton(
            checkboxWithTitle: "Also export original audio as MP3",
            target: nil,
            action: nil
        )
        mp3Checkbox.state = .off
        mp3Checkbox.sizeToFit()
        panel.accessoryView = mp3Checkbox

        guard panel.runModal() == .OK, let destinationURL = panel.url else {
            return
        }

        let exportOriginalAudioMP3 = mp3Checkbox.state == .on
        let timeSelection = selectedTimeSelection()

        isExporting = true
        progress = 0
        statusText = "Exporting \(codec.displayName)"

        Task { [weak self, outputVideoURL, selectedVideoURL, destinationURL, codec, exportOriginalAudioMP3, timeSelection] in
            do {
                let result = try await MovieExporter.exportMovie(
                    from: outputVideoURL,
                    originalAudioURL: selectedVideoURL,
                    timeSelection: timeSelection,
                    to: destinationURL,
                    codec: codec,
                    exportOriginalAudioMP3: exportOriginalAudioMP3
                ) { [weak self] update in
                    await self?.apply(update)
                }

                await MainActor.run {
                    self?.isExporting = false
                    self?.progress = 1
                    self?.statusText = self?.movieExportStatus(codec: codec, result: result) ?? "Exported \(codec.displayName)"
                }
            } catch {
                await MainActor.run {
                    self?.isExporting = false
                    self?.statusText = "Export failed"
                    self?.errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func loadSourceVideo(_ url: URL) {
        metadataTask?.cancel()
        player?.pause()
        player = AVPlayer(url: url)
        sourceDurationSeconds = 0
        trimStartSeconds = 0
        trimEndSeconds = 0
        clearGeneratedOutput()

        metadataTask = Task { [weak self, url] in
            do {
                let asset = AVURLAsset(url: url)
                let duration = try await asset.load(.duration)
                let seconds = duration.seconds.isFinite ? max(duration.seconds, 0) : 0

                await MainActor.run {
                    guard self?.selectedVideoURL == url else {
                        return
                    }

                    self?.sourceDurationSeconds = seconds
                    self?.trimStartSeconds = 0
                    self?.trimEndSeconds = seconds
                    self?.seekPreview(to: 0)
                }
            } catch {
                await MainActor.run {
                    self?.errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func clearGeneratedOutput() {
        outputVideoURL = nil
        outputFramesDirectory = nil
        frameCount = 0
        outputWidth = 0
        outputHeight = 0
        durationSeconds = 0
        progress = 0
    }

    private func resetProcessedOutputForTrimChange() {
        guard outputVideoURL != nil || outputFramesDirectory != nil else {
            return
        }

        clearGeneratedOutput()

        if let selectedVideoURL {
            player?.pause()
            player = AVPlayer(url: selectedVideoURL)
        }

        statusText = "Trim updated"
    }

    private func seekPreview(to seconds: Double) {
        let time = CMTime(seconds: seconds, preferredTimescale: 600)
        player?.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    private func selectedTimeSelection() -> VideoTimeSelection {
        let duration = max(selectedDurationSeconds, minimumTrimDuration)

        return VideoTimeSelection(
            startSeconds: trimStartSeconds,
            durationSeconds: duration
        )
    }

    private func apply(_ update: VideoProcessingProgress) {
        frameCount = update.completedFrames
        progress = update.fraction
        statusText = update.message
    }

    private func apply(_ result: VideoProcessingResult) {
        outputVideoURL = result.videoURL
        outputFramesDirectory = result.framesDirectory
        outputWidth = result.width
        outputHeight = result.height
        durationSeconds = result.durationSeconds
        frameCount = result.frameCount
        progress = 1
        statusText = "Finished \(result.frameCount.formatted()) frames"
        isProcessing = false

        let newPlayer = AVPlayer(url: result.videoURL)
        player = newPlayer
        newPlayer.play()
    }

    private func apply(_ update: MovieExportProgress) {
        progress = update.fraction
        statusText = update.message
    }

    private func markCancelled() {
        isProcessing = false
        statusText = "Cancelled"
    }

    private func markFailed(_ error: Error) {
        isProcessing = false
        statusText = "Failed"
        errorMessage = error.localizedDescription
    }

    private func defaultMovieExportName(for codec: MovieExportCodec) -> String {
        let sourceName = selectedVideoURL?
            .deletingPathExtension()
            .lastPathComponent ?? "background-removed"

        return "\(sourceName)-\(codec.fileNameSuffix).mov"
    }

    private func movieExportStatus(codec: MovieExportCodec, result: MovieExportResult) -> String {
        var parts = ["Exported \(codec.displayName)"]

        if result.audioMuxed {
            parts.append("with original audio")
        }

        if result.mp3URL != nil {
            parts.append("and MP3")
        }

        return parts.joined(separator: " ")
    }
}

private enum DurationFormatter {
    static func string(from seconds: Double) -> String {
        let roundedSeconds = Int(seconds.rounded())
        let minutes = roundedSeconds / 60
        let seconds = roundedSeconds % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

private enum PNGFrameExporter {
    static func copyFrames(from sourceDirectory: URL, to destinationDirectory: URL) async throws -> Int {
        try await Task.detached(priority: .userInitiated) {
            let fileManager = FileManager.default
            let files = try fileManager.contentsOfDirectory(
                at: sourceDirectory,
                includingPropertiesForKeys: nil
            )
            .filter { $0.pathExtension.lowercased() == "png" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

            for sourceURL in files {
                try Task.checkCancellation()

                let destinationURL = destinationDirectory.appendingPathComponent(sourceURL.lastPathComponent)

                if fileManager.fileExists(atPath: destinationURL.path) {
                    try fileManager.removeItem(at: destinationURL)
                }

                try fileManager.copyItem(at: sourceURL, to: destinationURL)
            }

            return files.count
        }.value
    }
}
