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
                title: "Deterministic State",
                primary: viewModel.state.statusTitle,
                secondary: deterministicSecondary,
                symbolName: "point.3.connected.trianglepath.dotted",
                tone: stateTone,
                theme: theme
            )
            MirmirStatusCard(
                title: "Confidence",
                primary: confidencePrimary,
                secondary: confidenceSecondary,
                symbolName: "checkmark.shield",
                tone: confidenceTone,
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
        return "\(rate) - \(profile.hasAudio ? "Audio" : "No audio")"
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

    private var deterministicSecondary: String {
        switch viewModel.state {
        case .probing:
            return "Reading source metadata"
        case .running:
            return "Frame reconstruction active"
        case .finished:
            return "Output ready"
        case .failed(let reason):
            return reason
        default:
            return "Reproducible settings path"
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

    private var confidencePrimary: String {
        switch viewModel.state {
        case .ready, .running, .finished:
            return "Configured"
        case .failed:
            return "Blocked"
        default:
            return "Pending"
        }
    }

    private var confidenceSecondary: String {
        switch viewModel.state {
        case .ready, .running, .finished:
            return "Deterministic profile selected"
        case .failed:
            return "Review source or output"
        default:
            return "Analyze source first"
        }
    }

    private var confidenceTone: MirmirStatusTone {
        switch viewModel.state {
        case .failed:
            return .danger
        case .ready, .running, .finished:
            return .success
        default:
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
        }
    }
}
