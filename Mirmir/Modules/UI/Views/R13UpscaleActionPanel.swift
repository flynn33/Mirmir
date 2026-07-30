import SwiftUI

struct R13UpscaleActionPanel: View {
    @ObservedObject var viewModel: MirmirViewModel
    let theme: MirmirThemeTokens

    @State private var discardCandidate: R13RecoverableUpscaleJob?
    @State private var confirmsDiscardAll = false

    var body: some View {
        content
            .confirmationDialog(
                "Discard interrupted upscale?",
                isPresented: showsDiscardConfirmation,
                titleVisibility: .visible
            ) {
                if let discardCandidate {
                    Button("Discard", role: .destructive) {
                        viewModel.discardRecoverableJob(
                            id: discardCandidate.id
                        )
                        self.discardCandidate = nil
                    }
                }
                Button("Cancel", role: .cancel) {
                    discardCandidate = nil
                }
            } message: {
                Text(
                    "Cached frames and recovery permissions for this "
                        + "interrupted upscale will be permanently removed."
                )
            }
            .confirmationDialog(
                "Discard all interrupted upscales?",
                isPresented: $confirmsDiscardAll,
                titleVisibility: .visible
            ) {
                Button("Discard All", role: .destructive) {
                    viewModel.discardAllRecoverableJobs()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(
                    "All cached interrupted-job data and recovery "
                        + "permissions will be permanently removed."
                )
            }
    }

    @ViewBuilder
    private var content: some View {
        if !viewModel.recoverableJobs.isEmpty
            || viewModel.recoveryRejectedEntryCount > 0 {
            VStack(alignment: .leading, spacing: theme.spacing.space2) {
                HStack(spacing: theme.spacing.space2) {
                    Label(
                        "Interrupted upscales",
                        systemImage: "arrow.clockwise.circle"
                    )
                    .font(theme.typography.caption.weight(.semibold))

                    Spacer(minLength: 0)

                    Button("Discard All", role: .destructive) {
                        confirmsDiscardAll = true
                    }
                    .buttonStyle(
                        MirmirSecondaryButtonStyle(theme: theme)
                    )
                    .disabled(recoveryActionsAreDisabled)
                    .accessibilityLabel(
                        "Discard all interrupted upscales"
                    )
                }

                ForEach(viewModel.recoverableJobs) { interrupted in
                    VStack(
                        alignment: .leading,
                        spacing: theme.spacing.space1
                    ) {
                        Text(interrupted.outputFilename)
                            .font(theme.typography.caption)
                            .foregroundStyle(theme.textTertiary)
                            .lineLimit(1)

                        Text(recoveryDetail(interrupted))
                            .font(theme.typography.micro.monospacedDigit())
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

                            if viewModel.recoveryRequiresReauthorization(
                                id: interrupted.id
                            ) {
                                Button {
                                    viewModel.reauthorizeRecoverableJob(
                                        id: interrupted.id
                                    )
                                } label: {
                                    Label(
                                        "Reauthorize",
                                        systemImage:
                                            "folder.badge.questionmark"
                                    )
                                }
                                .buttonStyle(
                                    MirmirSecondaryButtonStyle(theme: theme)
                                )
                            }

                            Button("Discard", role: .destructive) {
                                discardCandidate = interrupted
                            }
                            .buttonStyle(
                                MirmirSecondaryButtonStyle(theme: theme)
                            )
                            .accessibilityLabel(
                                "Discard interrupted upscale "
                                    + shortIdentifier(interrupted.id)
                            )
                        }
                        .disabled(recoveryActionsAreDisabled)
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
            viewModel.canStart || viewModel.jobIsRunning
                ? theme.textTertiary
                : theme.warning
        )
        .fixedSize(horizontal: false, vertical: true)
    }

    private var recoveryActionsAreDisabled: Bool {
        viewModel.jobIsRunning
            || viewModel.recoveryIsProbing
            || viewModel.recoveryMutationIsInProgress
    }

    private var showsDiscardConfirmation: Binding<Bool> {
        Binding(
            get: { discardCandidate != nil },
            set: { isPresented in
                if !isPresented {
                    discardCandidate = nil
                }
            }
        )
    }

    private func recoveryDetail(
        _ interrupted: R13RecoverableUpscaleJob
    ) -> String {
        let frames = interrupted.cachedFrameCount
        return "\(frames) cached frame\(frames == 1 ? "" : "s")"
            + " · Job \(shortIdentifier(interrupted.id))"
    }

    private func shortIdentifier(_ identifier: String) -> String {
        String(identifier.prefix(8)).uppercased()
    }
}
