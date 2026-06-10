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
            .disabled(viewModel.selectedVideoURL == nil || viewModel.isProcessing)

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

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                infoRow("Frames", viewModel.frameCountText)
                infoRow("Size", viewModel.videoSizeText)
                infoRow("Duration", viewModel.durationText)
                infoRow("Output", viewModel.outputTitle)
            }

            Spacer(minLength: 0)
        }
        .padding(20)
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
                PlayerView(player: player)
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

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .floating
        view.videoGravity = .resizeAspect
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.clear.cgColor
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        if nsView.player !== player {
            nsView.player = player
        }
    }

    static func dismantleNSView(_ nsView: AVPlayerView, coordinator: ()) {
        nsView.player?.pause()
        nsView.player = nil
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
