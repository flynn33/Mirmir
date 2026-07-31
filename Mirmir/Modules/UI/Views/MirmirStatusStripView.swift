import SwiftUI

struct MirmirStatusStrip: View {
    @ObservedObject var viewModel: MirmirViewModel
    let theme: MirmirThemeTokens

    var body: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 150), spacing: theme.spacing.space3)],
            spacing: theme.spacing.space3
        ) {
            MirmirStatusCard(
                title: "Source",
                primary: sourcePrimary,
                secondary: sourceSecondary,
                symbolName: "film",
                tone: sourceTone,
                theme: theme
            )
            MirmirStatusCard(
                title: "Output",
                primary: outputPrimary,
                secondary: outputSecondary,
                symbolName: "square.and.arrow.up",
                tone: outputTone,
                theme: theme
            )
            MirmirStatusCard(
                title: "Processing State",
                primary: viewModel.state.statusTitle,
                secondary: processingSecondary,
                symbolName: "point.3.connected.trianglepath.dotted",
                tone: stateTone,
                theme: theme
            )
            MirmirStatusCard(
                title: "Readiness",
                primary: readinessPrimary,
                secondary: readinessSecondary,
                symbolName: "checkmark.shield",
                tone: readinessTone,
                theme: theme
            )
            MirmirStatusCard(
                title: "Frames",
                primary: framesPrimary,
                secondary: framesSecondary,
                symbolName: "rectangle.stack",
                tone: viewModel.state.isRunning ? .active : .neutral,
                theme: theme
            )
        }
    }

    private var sourcePrimary: String {
        guard let profile = viewModel.sourceProfile else { return "No source" }
        return MirmirViewModel.fileLabel(for: profile.resolution)
    }

    private var sourceSecondary: String {
        guard let profile = viewModel.sourceProfile else { return "Choose Source" }
        let rate = String(format: "%.2f fps", profile.frameRate)
        return "\(rate) - \(profile.scanStructure.displayName) - "
            + profile.audioTrackDescription
    }

    private var sourceTone: MirmirStatusTone {
        viewModel.sourceProfile == nil ? .neutral : .success
    }

    private var outputPrimary: String {
        MirmirViewModel.fileLabel(for: viewModel.targetResolution)
    }

    private var outputSecondary: String {
        guard let outputURL = viewModel.outputURL else { return "Select Destination" }
        return outputURL.lastPathComponent
    }

    private var outputTone: MirmirStatusTone {
        viewModel.outputURL == nil ? .warning : .success
    }

    private var processingSecondary: String {
        switch viewModel.state {
        case .probing:
            return "Reading source metadata"
        case .running:
            return "\(viewModel.engineSelectionText) active"
        case .finished:
            return "Published output passed verification"
        case .failed(let reason):
            return reason
        default:
            return viewModel.engineSelectionText
        }
    }

    private var stateTone: MirmirStatusTone {
        switch viewModel.state {
        case .idle:
            return .neutral
        case .probing, .running:
            return .active
        case .ready:
            return .success
        case .finished:
            return .success
        case .failed:
            return .danger
        }
    }

    private var readinessPrimary: String {
        switch viewModel.state {
        case .ready:
            return viewModel.canStart ? "Ready to Start" : "Needs Input"
        case .running:
            return "Processing"
        case .finished:
            return "Output Verified"
        case .failed:
            return "Needs Attention"
        case .idle, .probing:
            return "Preparing"
        }
    }

    private var readinessSecondary: String {
        switch viewModel.state {
        case .ready:
            return viewModel.canStartFailureReason
                ?? "Source, destination, and processing are configured"
        case .running:
            return "The active job configuration is locked"
        case .finished:
            return "Reopened and validated before publication"
        case .failed:
            return "Review source or output"
        case .idle, .probing:
            return "Analyze source first"
        }
    }

    private var readinessTone: MirmirStatusTone {
        switch viewModel.state {
        case .failed:
            return .danger
        case .ready:
            return viewModel.canStart ? .success : .warning
        case .running, .finished:
            return .success
        case .idle, .probing:
            return .neutral
        }
    }

    private var framesPrimary: String {
        if let progress = viewModel.progress {
            return "\(progress.framesProcessed) / \(progress.totalFrames)"
        }
        guard let source = viewModel.sourceProfile else { return "0 / 0" }
        return "0 / \(source.estimatedFrameCount)"
    }

    private var framesSecondary: String {
        guard let progress = viewModel.progress else {
            return viewModel.state.isRunning ? "Starting progress" : "Progress appears when running"
        }
        let percent = String(format: "%.1f%% complete", progress.fraction * 100)
        let rate = String(format: "%.1f fps", progress.throughputFPS)
        if let eta = progress.etaSeconds, eta.isFinite {
            return "\(percent) - \(rate) - ETA \(format(eta: eta))"
        }
        return "\(percent) - \(rate)"
    }

    private func format(eta: Double) -> String {
        guard eta > 0 else { return "0s" }
        let totalSeconds = Int(eta.rounded())
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return minutes > 0 ? "\(minutes)m \(seconds)s" : "\(seconds)s"
    }
}

extension OutputCodec {
    var inspectorTitle: String {
        switch self {
        case .hevc:
            return "HEVC/H.265"
        case .h264:
            return "H.264"
        case .proRes422HQ:
            return "ProRes 422 HQ"
        case .proRes4444:
            return "ProRes 4444"
        }
    }
}
