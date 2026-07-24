import SwiftUI

struct R13UpscaleActionPanel: View {
    @ObservedObject var viewModel: MirmirViewModel
    let theme: MirmirThemeTokens

    var body: some View {
        if !viewModel.recoverableJobs.isEmpty {
            VStack(alignment: .leading, spacing: theme.spacing.space2) {
                Label(
                    "Interrupted upscales",
                    systemImage: "arrow.clockwise.circle"
                )
                .font(theme.typography.caption.weight(.semibold))

                ForEach(viewModel.recoverableJobs) { interrupted in
                    VStack(
                        alignment: .leading,
                        spacing: theme.spacing.space1
                    ) {
                        Text(interrupted.outputFilename)
                            .font(theme.typography.caption)
                            .foregroundStyle(theme.textTertiary)
                            .lineLimit(1)

                        HStack(spacing: theme.spacing.space2) {
                            Button {
                                viewModel.resumeRecoverableJob(
                                    id: interrupted.id
                                )
                            } label: {
                                Label(
                                    "Resume",
                                    systemImage: "play.circle"
                                )
                            }
                            .buttonStyle(
                                MirmirSecondaryButtonStyle(theme: theme)
                            )

                            Button {
                                viewModel.reauthorizeRecoverableJob(
                                    id: interrupted.id
                                )
                            } label: {
                                Label(
                                    "Reauthorize",
                                    systemImage: "folder.badge.questionmark"
                                )
                            }
                            .buttonStyle(
                                MirmirSecondaryButtonStyle(theme: theme)
                            )
                        }
                        .disabled(
                            viewModel.jobIsRunning
                                || viewModel.recoveryIsProbing
                        )
                    }
                }
            }
        }

        if viewModel.recoveryRejectedEntryCount > 0 {
            Text(
                "\(viewModel.recoveryRejectedEntryCount) interrupted "
                    + "job record(s) could not be verified and were ignored."
            )
            .font(theme.typography.caption)
            .foregroundStyle(theme.warning)
            .fixedSize(horizontal: false, vertical: true)
        }

        if let recoveryError = viewModel.recoveryError {
            Text("Recovery needs attention: \(recoveryError)")
                .font(theme.typography.caption)
                .foregroundStyle(theme.warning)
                .fixedSize(horizontal: false, vertical: true)
        }

        Button {
            viewModel.startUpscale()
        } label: {
            Label("Start Upscale", systemImage: "play.fill")
        }
        .buttonStyle(MirmirPrimaryButtonStyle(theme: theme))
        .disabled(!viewModel.canStart)
        .opacity(viewModel.canStart ? 1 : 0.48)
        .help(viewModel.canStartFailureReason ?? "Start Upscale")
        .accessibilityLabel("Start Upscale")

        if viewModel.state.isRunning {
            Button {
                viewModel.cancelUpscale()
            } label: {
                Label("Cancel Processing", systemImage: "stop.fill")
            }
            .buttonStyle(MirmirSecondaryButtonStyle(theme: theme))
            .accessibilityLabel("Cancel Processing")
        }

        Text(
            viewModel.canStartFailureReason
                ?? "Ready to start deterministic processing."
        )
        .font(theme.typography.caption)
        .foregroundStyle(
            viewModel.canStart ? theme.textTertiary : theme.warning
        )
        .fixedSize(horizontal: false, vertical: true)
    }
}
