import SwiftUI
import AppKit

struct ProgressPanelView: View {

    @ObservedObject var viewModel: MirmirViewModel

    var body: some View {
        HStack(spacing: 16) {
            switch viewModel.state {
            case .idle:
                Text("Idle. Choose a source video to begin.")
                    .foregroundStyle(.secondary)
            case .probing:
                ProgressView("Probing source…")
                    .progressViewStyle(.linear)
            case .ready:
                if let profile = viewModel.sourceProfile {
                    let arrow = String(describing: profile.resolution) + " → " + String(describing: viewModel.targetResolution)
                    Text("Ready: " + arrow)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Ready").foregroundStyle(.secondary)
                }
            case .running:
                runningRow
            case .finished(let url):
                HStack(spacing: 12) {
                    Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                    Text("Finished: \(url.lastPathComponent)")
                    Spacer()
                    Button("Reveal in Finder") { revealInFinder(url) }
                }
            case .failed(let reason):
                HStack(spacing: 12) {
                    Image(systemName: "exclamationmark.octagon.fill").foregroundStyle(.red)
                    Text(reason).lineLimit(2)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var runningRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let progress = viewModel.progress {
                ProgressView(value: progress.fraction)
                    .progressViewStyle(.linear)
                HStack {
                    Text("\(progress.framesProcessed) / \(progress.totalFrames) frames")
                        .fontDesign(.monospaced)
                    Spacer()
                    Text(String(format: "%.1f fps", progress.throughputFPS))
                        .fontDesign(.monospaced)
                    if let eta = progress.etaSeconds, eta.isFinite {
                        Text("ETA " + format(eta: eta))
                            .fontDesign(.monospaced)
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.callout)
            } else {
                ProgressView("Starting…")
            }
        }
    }

    private func format(eta: Double) -> String {
        guard eta > 0 else { return "0s" }
        let totalSeconds = Int(eta.rounded())
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return minutes > 0 ? "\(minutes)m \(seconds)s" : "\(seconds)s"
    }

    private func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
