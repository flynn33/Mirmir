@preconcurrency import AVFoundation
import AVKit
import SwiftUI

struct MirmirCompletedComparisonPlaybackView: View {
    let sourceURL: URL
    let completedOutputURL: URL
    let sourceResolutionText: String
    let outputResolutionText: String
    let theme: MirmirThemeTokens
    @Binding var splitPosition: Double
    let showLibrary: () -> Void

    @StateObject private var controller =
        MirmirSynchronizedPlaybackController()

    var body: some View {
        VStack(spacing: theme.spacing.space3) {
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
                "Synchronized before and after completed video comparison"
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
            .buttonStyle(MirmirSecondaryButtonStyle(theme: theme))
            .disabled(!controller.timeline.isReady)
            .accessibilityLabel(playbackButtonLabel)

            Text(
                MirmirPreviewPresentation.timestamp(
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
            .accessibilityLabel("Completed comparison timeline")

            Text(
                MirmirPreviewPresentation.timestamp(
                    seconds: controller.timeline.duration
                )
            )
            .font(theme.typography.caption.monospacedDigit())
            .foregroundStyle(theme.textSecondary)

            if case .failed = controller.timeline.loadState {
                Button("Retry Playback") {
                    controller.retry()
                }
                .buttonStyle(MirmirSecondaryButtonStyle(theme: theme))

                Button("Open Library", action: showLibrary)
                    .buttonStyle(MirmirSecondaryButtonStyle(theme: theme))
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
                Text("Loading source and verified completed output…")
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
                Text("Completed comparison unavailable")
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
            EmptyView()
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
                "Before",
                subtitle: sourceResolutionText
            )
            Spacer()
            playbackLabel(
                "After",
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
