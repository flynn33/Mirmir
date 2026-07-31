import SwiftUI
import UniformTypeIdentifiers

struct VideoSelectionView: View {

    @ObservedObject var viewModel: MirmirViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Source")
                .font(.headline)

            Button {
                viewModel.chooseSourceFile()
            } label: {
                Label("Choose Video…", systemImage: "film.stack")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)

            DropZone(viewModel: viewModel)
                .frame(maxWidth: .infinity, minHeight: 80)

            if let profile = viewModel.sourceProfile {
                VStack(alignment: .leading, spacing: 6) {
                    detail("File", profile.url.lastPathComponent)
                    detail("Resolution", String(describing: profile.resolution))
                    detail("Scan", profile.scanStructure.displayName)
                    detail("Frame rate", String(format: "%.2f fps", profile.frameRate))
                    detail("Duration", String(format: "%.1f s", profile.durationSeconds))
                    if let codec = profile.codecHint {
                        detail("Codec", codec)
                    }
                    detail("Audio", profile.audioTrackDescription)
                    detail(
                        "Media inventory",
                        profile.mediaPreservationCapability
                            .inventorySummary
                    )
                    ForEach(
                        profile.mediaPreservationCapability.tracks
                    ) { track in
                        detail(
                            track.displayName,
                            track.displaySummary
                        )
                    }
                    ForEach(
                        profile.mediaPreservationCapability
                            .associations
                    ) { association in
                        detail(
                            "Association",
                            association.displaySummary
                        )
                    }
                    Text(
                        profile.mediaPreservationCapability
                            .failureReason(
                                preserveAudio:
                                    viewModel.preserveAudio,
                                preserveSubtitles: true,
                                preserveMetadata: true
                            )
                            ?? profile.mediaPreservationCapability
                                .verificationSummary
                    )
                    .foregroundStyle(
                        profile.mediaPreservationCapability
                            .failureReason(
                                preserveAudio:
                                    viewModel.preserveAudio,
                                preserveSubtitles: true,
                                preserveMetadata: true
                            ) == nil
                            ? Color.secondary
                            : Color.orange
                    )
                    .fixedSize(horizontal: false, vertical: true)
                }
                .font(.callout)
            } else {
                Text(
                    "Drop a source video below 2160p here, "
                        + "or use the button above."
                )
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
    }

    @ViewBuilder
    private func detail(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).fontDesign(.monospaced)
        }
    }
}

private struct DropZone: View {
    @ObservedObject var viewModel: MirmirViewModel
    @State private var isTargeted = false

    var body: some View {
        RoundedRectangle(cornerRadius: 10)
            .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [6]))
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isTargeted ? Color.accentColor.opacity(0.15) : Color.clear)
            )
            .overlay(
                Text(isTargeted ? "Release to load" : "Drag a video file here")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            )
            .onDrop(of: [UTType.fileURL], isTargeted: $isTargeted) { providers in
                guard let provider = providers.first else { return false }
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    if let url {
                        Task { @MainActor in viewModel.loadSource(url: url) }
                    }
                }
                return true
            }
    }
}
