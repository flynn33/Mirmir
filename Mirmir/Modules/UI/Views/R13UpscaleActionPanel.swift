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
        if viewModel.modelAssetsShowsPreparationControl {
            modelAssetsPreparation
        }

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
                    let resumeFailureReason =
                        viewModel.recoverableJobResumeFailureReason(
                            id: interrupted.id
                        )
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
                            .disabled(resumeFailureReason != nil)
                            .help(
                                resumeFailureReason
                                    ?? "Resume this interrupted upscale."
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

                        if let resumeFailureReason {
                            Text(resumeFailureReason)
                                .font(theme.typography.caption)
                                .foregroundStyle(theme.warning)
                                .fixedSize(
                                    horizontal: false,
                                    vertical: true
                                )
                        }
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

        switch viewModel.state {
        case .running:
            Button {
                viewModel.cancelUpscale()
            } label: {
                Label("Cancel Processing", systemImage: "stop.fill")
            }
            .buttonStyle(MirmirSecondaryButtonStyle(theme: theme))
            .accessibilityLabel("Cancel Processing")

            actionStatus("Upscale in progress.", warning: false)
        case .finished:
            Button {
                viewModel.revealOutputInFinder()
            } label: {
                Label("Reveal Output", systemImage: "folder")
            }
            .buttonStyle(MirmirPrimaryButtonStyle(theme: theme))

            Button {
                viewModel.upscaleAnotherVideo()
            } label: {
                Label(
                    "Upscale Another Video",
                    systemImage: "plus.circle"
                )
            }
            .buttonStyle(MirmirSecondaryButtonStyle(theme: theme))

            if let error = viewModel.completedOutputRevealError {
                actionStatus(error, warning: true)
            } else {
                actionStatus(
                    "The completed output was verified and published.",
                    warning: false
                )
            }
        case .failed(let reason):
            Button("Retry Same Settings") {
                viewModel.retryFailedUpscale()
            }
            .buttonStyle(MirmirPrimaryButtonStyle(theme: theme))
            .disabled(!viewModel.canRetryFailedUpscale)
            .help(
                viewModel.retrySameSettingsFailureReason
                    ?? "Retries the same job identity and exact processing "
                        + "configuration so verified cached frames can be "
                        + "reused."
            )

            Button("Retry with Current Settings") {
                viewModel.retryFailedUpscaleWithCurrentSettings()
            }
            .buttonStyle(MirmirSecondaryButtonStyle(theme: theme))
            .disabled(
                !viewModel.canRetryFailedUpscaleWithCurrentSettings
            )
            .help(
                viewModel.retryWithCurrentSettingsFailureReason
                    ?? "Starts a new job using the settings currently shown "
                        + "in the inspector."
            )

            Button("Dismiss") {
                viewModel.dismissTerminalJob()
            }
            .buttonStyle(MirmirSecondaryButtonStyle(theme: theme))
            .disabled(viewModel.recoveryMutationIsInProgress)

            if let correctiveText =
                viewModel.retryCorrectiveActionText {
                actionStatus(correctiveText, warning: true)
            }

            actionStatus(reason, warning: true)
        case .idle, .probing, .ready:
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

            actionStatus(
                viewModel.canStartFailureReason
                    ?? "Ready to start with "
                        + "\(viewModel.engineSelectionText).",
                warning: !viewModel.canStart
            )
        }
    }

    private var modelAssetsPreparation: some View {
        VStack(alignment: .leading, spacing: theme.spacing.space2) {
            Label(
                viewModel.modelAssetsStatusText,
                systemImage: modelAssetsSystemImage
            )
            .font(theme.typography.caption.weight(.semibold))

            Text(viewModel.modelAssetsDetailText)
                .font(theme.typography.caption)
                .foregroundStyle(theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

            if case .downloading(let progress) = viewModel.modelStatus {
                ProgressView(value: min(max(progress, 0), 1))
                    .progressViewStyle(.linear)
                    .accessibilityLabel("Model download progress")
                    .accessibilityValue(
                        "\(Int((progress * 100).rounded())) percent"
                    )
            }

            if viewModel.modelAssetsCanPrepare {
                Button {
                    viewModel.ensureModelsReady()
                } label: {
                    Label(
                        viewModel.modelAssetsPreparationActionTitle,
                        systemImage: "arrow.down.circle"
                    )
                }
                .buttonStyle(MirmirSecondaryButtonStyle(theme: theme))
                .disabled(viewModel.jobIsRunning)
                .accessibilityLabel(
                    viewModel.modelAssetsPreparationActionTitle
                )
            }
        }
    }

    private var modelAssetsSystemImage: String {
        switch viewModel.modelStatus {
        case .unknown:
            return "questionmark.circle"
        case .notRequired:
            return "checkmark.circle"
        case .downloadRequired:
            return "arrow.down.circle"
        case .downloading:
            return "arrow.down.circle.fill"
        case .ready:
            return "checkmark.circle.fill"
        case .failed:
            return "exclamationmark.triangle"
        }
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

    private func actionStatus(
        _ text: String,
        warning: Bool
    ) -> some View {
        Text(text)
            .font(theme.typography.caption)
            .foregroundStyle(
                warning ? theme.warning : theme.textTertiary
            )
            .fixedSize(horizontal: false, vertical: true)
    }
}
