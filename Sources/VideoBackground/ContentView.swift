import AVKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var viewModel = VideoBackgroundViewModel()
    @State private var isImportingVideo = false

    var body: some View {
        VStack(spacing: 0) {
            topBar

            Divider()

            HSplitView {
                sidePanel
                    .frame(minWidth: 300, idealWidth: 340, maxWidth: 440)

                preview
                    .frame(minWidth: 520, minHeight: 420)
            }
        }
        .frame(minWidth: 900, minHeight: 620)
        .fileImporter(
            isPresented: $isImportingVideo,
            allowedContentTypes: [.mpeg4Movie, .movie],
            allowsMultipleSelection: false
        ) { result in
            viewModel.handleImport(result)
        }
        .alert(
            "Processing failed",
            isPresented: Binding(
                get: { viewModel.errorMessage != nil },
                set: { if !$0 { viewModel.errorMessage = nil } }
            ),
            actions: {
                Button("OK") {
                    viewModel.errorMessage = nil
                }
            },
            message: {
                Text(viewModel.errorMessage ?? "")
            }
        )
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            Button {
                isImportingVideo = true
            } label: {
                Label("Load MP4", systemImage: "folder")
            }

            Text(viewModel.sourceTitle)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)

            if viewModel.isProcessing {
                Button {
                    viewModel.cancelProcessing()
                } label: {
                    Label("Cancel", systemImage: "stop.fill")
                }
            }

            Button {
                viewModel.processSelectedVideo()
            } label: {
                Label("Process", systemImage: "wand.and.rays")
            }
            .disabled(!viewModel.canProcess)

            Menu {
                Button {
                    viewModel.exportPNGFrames()
                } label: {
                    Label("PNGs", systemImage: "photo.stack")
                }

                Divider()

                Button {
                    viewModel.exportMovie(codec: .proRes4444)
                } label: {
                    Label("Apple ProRes 4444 (.mov)", systemImage: "film")
                }

                Button {
                    viewModel.exportMovie(codec: .proRes4444XQ)
                } label: {
                    Label("Apple ProRes 4444 XQ (.mov)", systemImage: "film.fill")
                }
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            .disabled(!viewModel.canExport)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.bar)
    }

    private var sidePanel: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Status")
                    .font(.headline)

                Text(viewModel.statusText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                ProgressView(value: viewModel.progress)
                    .opacity(viewModel.showProgress ? 1 : 0.35)
            }

            if viewModel.selectedVideoURL != nil {
                Divider()

                trimPanel
            }

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                infoRow("Frames", viewModel.frameCountText)
                infoRow("Size", viewModel.videoSizeText)
                infoRow("Source", viewModel.sourceDurationText)
                infoRow("Selection", viewModel.selectedDurationText)
                infoRow("Output Duration", viewModel.durationText)
                infoRow("Output", viewModel.outputTitle)
            }

            Spacer(minLength: 0)
        }
        .padding(20)
    }

    private var trimPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Trim")
                .font(.headline)

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Start")
                    Spacer()
                    Text(viewModel.trimStartText)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .font(.callout)

                Slider(
                    value: Binding(
                        get: { viewModel.trimStartSeconds },
                        set: { viewModel.setTrimStart($0) }
                    ),
                    in: 0...max(viewModel.sourceDurationSeconds, 0.1)
                )
                .disabled(!viewModel.canTrim)
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("End")
                    Spacer()
                    Text(viewModel.trimEndText)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .font(.callout)

                Slider(
                    value: Binding(
                        get: { viewModel.trimEndSeconds },
                        set: { viewModel.setTrimEnd($0) }
                    ),
                    in: 0...max(viewModel.sourceDurationSeconds, 0.1)
                )
                .disabled(!viewModel.canTrim)
            }
        }
    }

    private func infoRow(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .textCase(.uppercase)

            Text(value)
                .font(.callout)
                .foregroundStyle(.primary)
                .lineLimit(2)
                .truncationMode(.middle)
        }
    }

    private var preview: some View {
        ZStack {
            CheckerboardView()

            if let player = viewModel.player {
                PlayerView(
                    player: player,
                    loopStartSeconds: viewModel.previewLoopStartSeconds,
                    loopEndSeconds: viewModel.previewLoopEndSeconds
                )
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "film")
                        .font(.system(size: 40, weight: .regular))
                        .foregroundStyle(.secondary)

                    Text("No preview")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                }
            }

            if viewModel.isProcessing || viewModel.isExporting {
                VStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.large)
                    Text(viewModel.statusText)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                }
                .padding(20)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }
}

private struct PlayerView: NSViewRepresentable {
    let player: AVPlayer
    let loopStartSeconds: Double
    let loopEndSeconds: Double

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .floating
        view.videoGravity = .resizeAspect
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.clear.cgColor
        context.coordinator.configure(
            player: player,
            loopStartSeconds: loopStartSeconds,
            loopEndSeconds: loopEndSeconds
        )
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        if nsView.player !== player {
            nsView.player = player
        }

        context.coordinator.configure(
            player: player,
            loopStartSeconds: loopStartSeconds,
            loopEndSeconds: loopEndSeconds
        )
    }

    static func dismantleNSView(_ nsView: AVPlayerView, coordinator: Coordinator) {
        coordinator.stop()
        nsView.player?.pause()
        nsView.player = nil
    }

    final class Coordinator: @unchecked Sendable {
        private weak var player: AVPlayer?
        private var timeObserver: Any?
        private var itemEndObserver: NSObjectProtocol?
        private var loopStartSeconds = 0.0
        private var loopEndSeconds = 0.0
        private var isSeeking = false

        func configure(player: AVPlayer, loopStartSeconds: Double, loopEndSeconds: Double) {
            let start = max(loopStartSeconds, 0)
            let end = max(loopEndSeconds, start)
            let playerChanged = self.player !== player
            let loopChanged = self.loopStartSeconds != start || self.loopEndSeconds != end

            guard playerChanged || loopChanged else {
                return
            }

            stop()
            self.player = player
            self.loopStartSeconds = start
            self.loopEndSeconds = end

            if end > start {
                clampCurrentTimeIfNeeded()
            }

            timeObserver = player.addPeriodicTimeObserver(
                forInterval: CMTime(seconds: 0.05, preferredTimescale: 600),
                queue: .main
            ) { [weak self] time in
                self?.handleTimeUpdate(time)
            }

            itemEndObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: player.currentItem,
                queue: .main
            ) { [weak self] _ in
                self?.seekToLoopStart(shouldPlay: true)
            }
        }

        func stop() {
            if let timeObserver, let player {
                player.removeTimeObserver(timeObserver)
            }

            if let itemEndObserver {
                NotificationCenter.default.removeObserver(itemEndObserver)
            }

            timeObserver = nil
            itemEndObserver = nil
            player = nil
        }

        private func handleTimeUpdate(_ time: CMTime) {
            guard !isSeeking, loopEndSeconds > loopStartSeconds else {
                return
            }

            let seconds = time.seconds

            guard seconds.isFinite else {
                return
            }

            if seconds >= loopEndSeconds || seconds < loopStartSeconds {
                seekToLoopStart(shouldPlay: player?.rate != 0)
            }
        }

        private func clampCurrentTimeIfNeeded() {
            guard let player else {
                return
            }

            let seconds = player.currentTime().seconds

            guard seconds.isFinite else {
                return
            }

            if seconds < loopStartSeconds || seconds >= loopEndSeconds {
                seekToLoopStart(shouldPlay: false)
            }
        }

        private func seekToLoopStart(shouldPlay: Bool) {
            guard let player else {
                return
            }

            isSeeking = true
            let time = CMTime(seconds: loopStartSeconds, preferredTimescale: 600)
            player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self, weak player] _ in
                guard let self else {
                    return
                }

                self.isSeeking = false

                if shouldPlay {
                    player?.play()
                }
            }
        }
    }
}

private struct CheckerboardView: View {
    private let tileSize: CGFloat = 24

    var body: some View {
        GeometryReader { proxy in
            Canvas { context, size in
                let columns = Int(ceil(size.width / tileSize))
                let rows = Int(ceil(size.height / tileSize))
                let light = Color(nsColor: .windowBackgroundColor)
                let dark = Color(nsColor: .separatorColor).opacity(0.35)

                context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(light))

                for row in 0...rows {
                    for column in 0...columns where (row + column).isMultiple(of: 2) {
                        let rect = CGRect(
                            x: CGFloat(column) * tileSize,
                            y: CGFloat(row) * tileSize,
                            width: tileSize,
                            height: tileSize
                        )
                        context.fill(Path(rect), with: .color(dark))
                    }
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
    }
}
