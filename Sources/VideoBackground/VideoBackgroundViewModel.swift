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
    @Published private(set) var frameCount = 0
    @Published private(set) var outputFramesDirectory: URL?
    @Published private(set) var outputWidth = 0
    @Published private(set) var outputHeight = 0
    @Published private(set) var durationSeconds = 0.0

    private var processingTask: Task<Void, Never>?

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

    var showProgress: Bool {
        isProcessing || progress > 0
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
            resetOutputState()
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
        resetOutputState()
        isProcessing = true
        statusText = "Preparing video"

        processingTask = Task { [weak self, selectedVideoURL] in
            let processor = VideoBackgroundProcessor()

            do {
                let result = try await processor.process(videoURL: selectedVideoURL) { [weak self] update in
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
        guard let outputVideoURL, canExport else {
            return
        }

        let panel = NSSavePanel()
        panel.title = "Export \(codec.displayName)"
        panel.prompt = "Export"
        panel.allowedContentTypes = [.quickTimeMovie]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = defaultMovieExportName(for: codec)

        guard panel.runModal() == .OK, let destinationURL = panel.url else {
            return
        }

        isExporting = true
        progress = 0
        statusText = "Exporting \(codec.displayName)"

        Task { [weak self, outputVideoURL, destinationURL, codec] in
            do {
                try await MovieExporter.exportMovie(
                    from: outputVideoURL,
                    to: destinationURL,
                    codec: codec
                ) { [weak self] update in
                    await self?.apply(update)
                }

                await MainActor.run {
                    self?.isExporting = false
                    self?.progress = 1
                    self?.statusText = "Exported \(codec.displayName)"
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

    private func resetOutputState() {
        player?.pause()
        player = nil
        outputVideoURL = nil
        outputFramesDirectory = nil
        frameCount = 0
        outputWidth = 0
        outputHeight = 0
        durationSeconds = 0
        progress = 0
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
