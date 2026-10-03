@preconcurrency import AVFoundation
import AppKit
import AVKit
import SwiftUI
import UniformTypeIdentifiers

struct MirmirCompareWorkspace: View {
    let lastCompletedOriginalURL: URL?
    let lastCompletedUpscaledURL: URL?
    let theme: MirmirThemeTokens

    @State private var originalURL: URL?
    @State private var upscaledURL: URL?
    @State private var splitPosition = 0.5

    var body: some View {
        ScrollView {
            VStack(spacing: theme.spacing.space4) {
                MirmirProductPanel(theme: theme) {
                    VStack(alignment: .leading, spacing: theme.spacing.space4) {
                        HStack(alignment: .top, spacing: theme.spacing.space4) {
                            VStack(alignment: .leading, spacing: theme.spacing.space1) {
                                Text("Choose two movies")
                                    .font(theme.typography.headline)
                                Text(
                                    "Compare any original and upscaled movies with synchronized playback, scrubbing, and a draggable split."
                                )
                                .font(theme.typography.body)
                                .foregroundStyle(theme.textSecondary)
                            }
                            Spacer()
                            Button("Use Last Completed Job") {
                                useLastCompletedJob()
                            }
                            .buttonStyle(
                                MirmirProductSecondaryButtonStyle(theme: theme)
                            )
                            .disabled(!lastCompletedJobIsAvailable)
                            .accessibilityIdentifier(
                                "mirmir.compare.useLastCompleted"
                            )
                        }

                        HStack(spacing: theme.spacing.space3) {
                            fileSelection(
                                title: "Original",
                                url: originalURL,
                                identifier: "mirmir.compare.chooseOriginal"
                            ) {
                                if let selection = chooseMovie(
                                    title: "Choose Original Movie"
                                ) {
                                    originalURL = selection
                                }
                            }
                            fileSelection(
                                title: "Upscaled",
                                url: upscaledURL,
                                identifier: "mirmir.compare.chooseUpscaled"
                            ) {
                                if let selection = chooseMovie(
                                    title: "Choose Upscaled Movie"
                                ) {
                                    upscaledURL = selection
                                }
                            }
                        }
                    }
                }

                MirmirProductPanel(theme: theme) {
                    comparisonContent
                }
            }
            .padding(theme.spacing.space5)
        }
        .background(theme.background)
        .accessibilityIdentifier("mirmir.compare.workspace")
    }

    @ViewBuilder
    private var comparisonContent: some View {
        if let originalURL, let upscaledURL {
            MirmirCompletedComparisonPlaybackView(
                sourceURL: originalURL,
                completedOutputURL: upscaledURL,
                sourceResolutionText: originalURL.lastPathComponent,
                outputResolutionText: upscaledURL.lastPathComponent,
                theme: theme,
                splitPosition: $splitPosition
            )
        } else {
            RoundedRectangle(cornerRadius: theme.radius.xlarge)
                .fill(theme.surfaceInset)
                .frame(minHeight: 420)
                .overlay {
                    VStack(spacing: theme.spacing.space3) {
                        Image(systemName: "rectangle.split.2x1")
                            .font(.system(size: 42, weight: .light))
                            .foregroundStyle(theme.textTertiary)
                        Text("Select Original and Upscaled movies")
                            .font(theme.typography.subtitle)
                        Text(missingSelectionMessage)
                            .font(theme.typography.body)
                            .foregroundStyle(theme.textSecondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(theme.spacing.space6)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: theme.radius.xlarge)
                        .stroke(theme.borderSubtle, lineWidth: 1)
                }
                .accessibilityLabel(missingSelectionMessage)
        }
    }

    private func fileSelection(
        title: String,
        url: URL?,
        identifier: String,
        choose: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: theme.spacing.space2) {
            Text(title.uppercased())
                .font(theme.typography.micro)
                .foregroundStyle(theme.textTertiary)
            HStack(spacing: theme.spacing.space2) {
                Image(systemName: "film")
                    .foregroundStyle(theme.accentPrimary)
                Text(url?.lastPathComponent ?? "No movie selected")
                    .font(theme.typography.body)
                    .foregroundStyle(
                        url == nil ? theme.textTertiary : theme.textPrimary
                    )
                    .lineLimit(1)
                Spacer()
                Button("Choose", action: choose)
                    .buttonStyle(
                        MirmirProductSecondaryButtonStyle(theme: theme)
                    )
                    .accessibilityIdentifier(identifier)
            }
        }
        .padding(theme.spacing.space3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: theme.radius.medium)
                .fill(theme.surfaceInset)
        )
        .overlay {
            RoundedRectangle(cornerRadius: theme.radius.medium)
                .stroke(theme.borderSubtle, lineWidth: 1)
        }
    }

    private var lastCompletedJobIsAvailable: Bool {
        lastCompletedOriginalURL != nil && lastCompletedUpscaledURL != nil
    }

    private var missingSelectionMessage: String {
        switch (originalURL, upscaledURL) {
        case (nil, nil):
            return "Choose both movies to load the comparison player."
        case (nil, _):
            return "Choose the original movie to continue."
        case (_, nil):
            return "Choose the upscaled movie to continue."
        case (.some, .some):
            return "Loading comparison."
        }
    }

    private func useLastCompletedJob() {
        guard let lastCompletedOriginalURL,
              let lastCompletedUpscaledURL else { return }
        originalURL = lastCompletedOriginalURL
        upscaledURL = lastCompletedUpscaledURL
    }

    private func chooseMovie(title: String) -> URL? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.prompt = "Choose"
        panel.allowedContentTypes = [.movie]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        guard panel.runModal() == .OK else { return nil }
        return panel.url?.standardizedFileURL
    }
}

struct MirmirCompletedComparisonPlaybackView: View {
    let sourceURL: URL
    let completedOutputURL: URL
    let sourceResolutionText: String
    let outputResolutionText: String
    let theme: MirmirThemeTokens
    @Binding var splitPosition: Double

    @StateObject private var controller =
        MirmirSynchronizedPlaybackController()

    var body: some View {
        VStack(spacing: theme.spacing.space3) {
            HStack(spacing: theme.spacing.space2) {
                Label("Synchronized comparison", systemImage: "play.rectangle")
                    .font(theme.typography.captionEmphasis)
                    .foregroundStyle(theme.textSecondary)
                Spacer()
                Text(playbackStatusText)
                    .font(theme.typography.micro)
                    .foregroundStyle(theme.textTertiary)
            }
            playbackSurface
                .frame(minHeight: 360)
            playbackControls
        }
        .task(id: playbackIdentity) {
            controller.load(
                sourceURL: sourceURL,
                completedOutputURL: completedOutputURL
            )
        }
        .onDisappear {
            controller.tearDown()
        }
    }

    private var playbackSurface: some View {
        GeometryReader { proxy in
            let splitX = max(
                0,
                min(proxy.size.width, proxy.size.width * splitPosition)
            )

            ZStack(alignment: .leading) {
                Color.black

                MirmirAVPlayerSurface(player: controller.outputPlayer)
                    .frame(
                        width: proxy.size.width,
                        height: proxy.size.height
                    )
                    .allowsHitTesting(false)

                MirmirAVPlayerSurface(player: controller.sourcePlayer)
                    .frame(
                        width: proxy.size.width,
                        height: proxy.size.height
                    )
                    .mask(alignment: .leading) {
                        Rectangle()
                            .frame(width: splitX)
                    }
                    .allowsHitTesting(false)

                splitDivider(at: splitX)
                playbackLabels
                    .frame(
                        width: proxy.size.width,
                        height: proxy.size.height
                    )
                playbackOverlay
                    .frame(
                        width: proxy.size.width,
                        height: proxy.size.height
                    )
            }
            .overlay {
                RoundedRectangle(cornerRadius: theme.radius.xlarge)
                    .stroke(theme.borderSubtle, lineWidth: 1)
            }
            .clipShape(
                RoundedRectangle(cornerRadius: theme.radius.xlarge)
            )
            .accessibilityElement(children: .contain)
            .accessibilityLabel(
                "Synchronized original and upscaled video comparison"
            )
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        splitPosition = MirmirComparisonPresentation
                            .splitPosition(
                                locationX: value.location.x,
                                width: proxy.size.width
                            )
                    }
            )
        }
    }

    private var playbackControls: some View {
        HStack(spacing: theme.spacing.space3) {
            Button {
                controller.togglePlayback()
            } label: {
                Image(systemName: playbackButtonSymbol)
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(MirmirProductSecondaryButtonStyle(theme: theme))
            .disabled(!controller.timeline.isReady)
            .accessibilityLabel(playbackButtonLabel)

            Text(
                MirmirComparisonPresentation.timestamp(
                    seconds: controller.timeline.currentTime
                )
            )
            .font(theme.typography.caption.monospacedDigit())
            .foregroundStyle(theme.textSecondary)

            Slider(
                value: Binding(
                    get: { controller.timeline.currentTime },
                    set: { controller.scrub(to: $0) }
                ),
                in: 0...controller.timeline.scrubberUpperBound,
                onEditingChanged: { isEditing in
                    if isEditing {
                        controller.beginScrubbing()
                    } else {
                        controller.finishScrubbing()
                    }
                }
            )
            .disabled(!controller.timeline.isReady)
            .accessibilityLabel("Comparison timeline")

            Text(
                MirmirComparisonPresentation.timestamp(
                    seconds: controller.timeline.duration
                )
            )
            .font(theme.typography.caption.monospacedDigit())
            .foregroundStyle(theme.textSecondary)

            if case .failed = controller.timeline.loadState {
                Button("Retry Playback") {
                    controller.retry()
                }
                .buttonStyle(
                    MirmirProductSecondaryButtonStyle(theme: theme)
                )
            }
        }
    }

    @ViewBuilder
    private var playbackOverlay: some View {
        switch controller.timeline.loadState {
        case .idle, .loading:
            VStack(spacing: theme.spacing.space2) {
                ProgressView()
                    .controlSize(.small)
                Text("Loading original and upscaled movies…")
                    .font(theme.typography.body)
                    .foregroundStyle(theme.viewerOverlayText)
            }
            .padding(theme.spacing.space4)
            .background(
                RoundedRectangle(cornerRadius: theme.radius.medium)
                    .fill(theme.viewerOverlay)
            )
        case .failed(let message):
            VStack(spacing: theme.spacing.space2) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(theme.warning)
                Text("Comparison unavailable")
                    .font(theme.typography.captionEmphasis)
                Text(message)
                    .font(theme.typography.caption)
                    .multilineTextAlignment(.center)
            }
            .foregroundStyle(theme.viewerOverlayText)
            .padding(theme.spacing.space4)
            .background(
                RoundedRectangle(cornerRadius: theme.radius.medium)
                    .fill(theme.viewerOverlay)
            )
            .padding(theme.spacing.space4)
        case .ready:
            if controller.timeline.hasEnded {
                VStack(spacing: theme.spacing.space2) {
                    Image(systemName: "arrow.counterclockwise.circle")
                        .foregroundStyle(theme.accentPrimary)
                    Text("Playback ended")
                        .font(theme.typography.captionEmphasis)
                    Text("Use Replay or scrub to another point.")
                        .font(theme.typography.caption)
                }
                .foregroundStyle(theme.viewerOverlayText)
                .padding(theme.spacing.space4)
                .background(
                    RoundedRectangle(cornerRadius: theme.radius.medium)
                        .fill(theme.viewerOverlay)
                )
            }
        }
    }

    private func splitDivider(at splitX: CGFloat) -> some View {
        ZStack(alignment: .leading) {
            Rectangle()
                .fill(theme.accentSecondary)
                .frame(width: 1)
                .offset(x: splitX)

            Circle()
                .fill(theme.viewerOverlay)
                .frame(width: 34, height: 34)
                .overlay {
                    Image(systemName: "arrow.left.and.right")
                        .font(theme.typography.captionEmphasis)
                        .foregroundStyle(theme.viewerOverlayText)
                }
                .overlay {
                    Circle()
                        .stroke(theme.accentSecondary, lineWidth: 1)
                }
                .offset(x: splitX - 17)
        }
        .accessibilityHidden(true)
    }

    private var playbackLabels: some View {
        HStack(alignment: .top) {
            playbackLabel(
                "Original",
                subtitle: sourceResolutionText
            )
            Spacer()
            playbackLabel(
                "Upscaled",
                subtitle: outputResolutionText
            )
        }
        .padding(theme.spacing.space3)
    }

    private func playbackLabel(
        _ title: String,
        subtitle: String
    ) -> some View {
        VStack(alignment: .leading, spacing: theme.spacing.space1) {
            Text(title)
                .font(theme.typography.captionEmphasis)
            Text(subtitle)
                .font(theme.typography.micro.monospacedDigit())
        }
        .foregroundStyle(theme.viewerOverlayText)
        .padding(.horizontal, theme.spacing.space2)
        .padding(.vertical, theme.spacing.space1)
        .background(
            RoundedRectangle(cornerRadius: theme.radius.small)
                .fill(theme.viewerOverlay)
        )
    }

    private var playbackButtonSymbol: String {
        if controller.timeline.hasEnded {
            return "arrow.counterclockwise"
        }
        return controller.timeline.isPlaying ? "pause.fill" : "play.fill"
    }

    private var playbackButtonLabel: String {
        if controller.timeline.hasEnded {
            return "Replay completed comparison"
        }
        return controller.timeline.isPlaying
            ? "Pause completed comparison"
            : "Play completed comparison"
    }

    private var playbackIdentity: MirmirPlaybackAssetIdentity {
        MirmirPlaybackAssetIdentity(
            sourceURL: sourceURL,
            completedOutputURL: completedOutputURL
        )
    }

    private var playbackStatusText: String {
        switch controller.timeline.loadState {
        case .idle:
            return "IDLE"
        case .loading:
            return "LOADING"
        case .failed:
            return "FAILED"
        case .ready:
            return controller.timeline.hasEnded ? "ENDED" : "READY"
        }
    }
}

enum MirmirComparisonPresentation {
    static func splitPosition(
        locationX: CGFloat,
        width: CGFloat
    ) -> Double {
        let normalized = Double(locationX / max(width, 1))
        return min(0.95, max(0.05, normalized))
    }

    static func timestamp(seconds: Double) -> String {
        guard seconds.isFinite else { return "00:00:00" }
        let maximumSafeSeconds = Double(Int.max / 2)
        let totalSeconds = Int(
            min(max(seconds, 0).rounded(.down), maximumSafeSeconds)
        )
        let hours = totalSeconds / 3_600
        let minutes = (totalSeconds % 3_600) / 60
        let remainingSeconds = totalSeconds % 60
        return String(
            format: "%02d:%02d:%02d",
            hours,
            minutes,
            remainingSeconds
        )
    }
}

private struct MirmirAVPlayerSurface: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let playerView = MirmirPassivePlayerView()
        playerView.controlsStyle = .none
        playerView.videoGravity = .resizeAspect
        playerView.player = player
        return playerView
    }

    func updateNSView(
        _ playerView: AVPlayerView,
        context: Context
    ) {
        if playerView.player !== player {
            playerView.player = player
        }
    }

    static func dismantleNSView(
        _ playerView: AVPlayerView,
        coordinator: Void
    ) {
        playerView.player = nil
    }
}

private final class MirmirPassivePlayerView: AVPlayerView {
    override var acceptsFirstResponder: Bool {
        false
    }
}
