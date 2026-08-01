import SwiftUI

// Screen implementations remain co-located with their shared private helpers.
// swiftlint:disable file_length

private extension MirmirWorkTerminalResult {
    var title: String {
        switch self {
        case .completed:
            return "Completed"
        case .failed:
            return "Failed"
        case .cancelled:
            return "Cancelled"
        case .interrupted:
            return "Interrupted"
        }
    }

    var symbolName: String {
        switch self {
        case .completed:
            return "checkmark.circle"
        case .failed:
            return "exclamationmark.triangle"
        case .cancelled:
            return "stop.circle"
        case .interrupted:
            return "arrow.clockwise.circle"
        }
    }
}

private extension MirmirWorkHistoryRecord {
    var scanStructureHistoryDescription: String {
        sourceScanStructure?.displayName
            ?? "Source scan structure unavailable"
    }

    var audioHistoryDescription: String {
        guard let sourceAudioTrackCount else {
            return "Source audio-track count unavailable"
        }
        guard sourceAudioTrackCount > 0 else {
            return "No source audio tracks"
        }
        let noun = sourceAudioTrackCount == 1
            ? "audio track"
            : "audio tracks"
        let disposition: String
        if terminalResult == .completed {
            disposition = preserveAudio ? "preserved" : "omitted"
        } else {
            disposition = preserveAudio
                ? "preservation requested"
                : "omission requested"
        }
        return "\(sourceAudioTrackCount) source \(noun) \(disposition)"
    }
}

struct MirmirDashboardScreen: View {
    @ObservedObject var viewModel: MirmirViewModel
    let theme: MirmirThemeTokens

    var body: some View {
        MirmirScreenScaffold(theme: theme) {
            MirmirPanel(theme: theme) {
                VStack(alignment: .leading, spacing: theme.spacing.space4) {
                    screenHeader("Dashboard", "Recent work, active processing, and system readiness.", theme: theme)

                    HStack(spacing: theme.spacing.space3) {
                        dashboardMetric(
                            "Persistent queue",
                            queueSummary,
                            "Queue"
                        )
                        dashboardMetric("Readiness", viewModel.engineReadinessText, "Status")
                        dashboardMetric(
                            "Saved terminal jobs",
                            "\(viewModel.workHistoryRecords.count)",
                            "History"
                        )
                    }
                }
            }

            MirmirPanel(theme: theme) {
                VStack(alignment: .leading, spacing: theme.spacing.space3) {
                    screenHeader(
                        "Recent work",
                        "The newest completed, failed, and cancelled jobs.",
                        theme: theme
                    )
                    if viewModel.workHistoryIsLoading {
                        ProgressView("Loading work history…")
                    } else if viewModel.workHistoryRecords.isEmpty {
                        Text(
                            "No terminal jobs have been recorded yet. "
                                + "Configured work appears here after it "
                                + "completes, fails, or is cancelled."
                        )
                        .font(theme.typography.body)
                        .foregroundStyle(theme.textSecondary)
                    } else {
                        ForEach(
                            Array(viewModel.workHistoryRecords.prefix(5))
                        ) { record in
                            HStack {
                                VStack(
                                    alignment: .leading,
                                    spacing: theme.spacing.space1
                                ) {
                                    Text(record.outputDisplayName)
                                        .font(theme.typography.bodyEmphasis)
                                    Text(historyDetail(record))
                                        .font(theme.typography.caption)
                                        .foregroundStyle(
                                            theme.textSecondary
                                        )
                                }
                                Spacer()
                                Text(record.terminalResult.title)
                                    .font(theme.typography.captionEmphasis)
                                    .foregroundStyle(
                                        record.terminalResult
                                            == .completed
                                            ? theme.success
                                            : theme.warning
                                    )
                            }
                        }
                    }
                    historyNotice
                }
            }
        }
    }

    private var queueSummary: String {
        if viewModel.pendingQueueIsLoading {
            return "Loading…"
        }
        let pendingCount = viewModel.pendingWorkRecords.filter {
            $0.state == .pending
        }.count
        let hasStartedQueueItem =
            viewModel.pendingWorkRecords.first?.state == .started
        if hasStartedQueueItem {
            let status = viewModel.jobIsRunning
                ? "1 running"
                : "1 ready to resume"
            guard pendingCount > 0 else { return status }
            return "\(status) · \(pendingCount) pending"
        }
        if pendingCount > 0 {
            return "\(pendingCount) pending"
        }
        return viewModel.jobIsRunning ? "Direct job running" : "None"
    }

    private func dashboardMetric(_ title: String, _ value: String, _ caption: String) -> some View {
        VStack(alignment: .leading, spacing: theme.spacing.space2) {
            Text(caption)
                .font(theme.typography.captionEmphasis)
                .foregroundStyle(theme.textTertiary)
            Text(value)
                .font(theme.typography.subtitle)
                .foregroundStyle(theme.textPrimary)
                .lineLimit(1)
            Text(title)
                .font(theme.typography.caption)
                .foregroundStyle(theme.textSecondary)
        }
        .padding(theme.spacing.space3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: theme.radius.large)
                .fill(theme.surface)
        )
        .overlay {
            RoundedRectangle(cornerRadius: theme.radius.large)
                .stroke(theme.borderSubtle, lineWidth: 1)
        }
    }

    private func historyDetail(
        _ record: MirmirWorkHistoryRecord
    ) -> String {
        "\(record.sourceDisplayName) · "
            + "\(MirmirViewModel.fileLabel(for: record.targetResolution))"
            + " · \(record.scanStructureHistoryDescription)"
            + " · \(record.audioHistoryDescription)"
            + " · "
            + record.completedAt.formatted(
                date: .abbreviated,
                time: .shortened
            )
    }

    @ViewBuilder
    private var historyNotice: some View {
        if let notice = viewModel.workHistoryRecoveryNotice {
            Text(notice)
                .font(theme.typography.caption)
                .foregroundStyle(theme.warning)
        }
        if let error = viewModel.workHistoryError {
            Text(error)
                .font(theme.typography.caption)
                .foregroundStyle(theme.danger)
        }
    }
}

struct MirmirLibraryScreen: View {
    @ObservedObject var viewModel: MirmirViewModel
    let theme: MirmirThemeTokens

    var body: some View {
        MirmirScreenScaffold(theme: theme) {
            MirmirPanel(theme: theme) {
                VStack(alignment: .leading, spacing: theme.spacing.space4) {
                    HStack {
                        screenHeader(
                            "Library",
                            "Durable job history with exact processing "
                                + "configuration and output state.",
                            theme: theme
                        )
                        Spacer()
                        Button("Refresh") {
                            viewModel.refreshWorkHistory()
                        }
                        .buttonStyle(
                            MirmirSecondaryButtonStyle(theme: theme)
                        )
                        .disabled(viewModel.workHistoryIsLoading)
                    }

                    if viewModel.workHistoryIsLoading {
                        ProgressView("Loading library…")
                    } else if viewModel.workHistoryRecords.isEmpty {
                        emptyMessage(
                            "No saved work yet. Terminal upscale jobs "
                                + "appear here automatically.",
                            theme: theme
                        )
                    } else {
                        ForEach(viewModel.workHistoryRecords) { record in
                            libraryRow(record)
                        }
                    }

                    if let notice = viewModel.workHistoryRecoveryNotice {
                        Text(notice)
                            .font(theme.typography.caption)
                            .foregroundStyle(theme.warning)
                    }
                    if let error = viewModel.workHistoryError {
                        Text(error)
                            .font(theme.typography.caption)
                            .foregroundStyle(theme.danger)
                    }
                }
            }
        }
    }

    private func libraryRow(
        _ record: MirmirWorkHistoryRecord
    ) -> some View {
        let reprocessFailureReason =
            viewModel.workHistoryReprocessFailureReason(id: record.id)
        let revealFailureReason =
            viewModel.workHistoryRevealFailureReason(id: record.id)
        let locationNeedsAttention =
            viewModel.workHistoryLocationStates[record.id].map {
                $0.source != .available || $0.output != .available
            } ?? true
        return HStack(spacing: theme.spacing.space3) {
            Image(systemName: record.terminalResult.symbolName)
                .foregroundStyle(theme.accentPrimary)
            VStack(alignment: .leading, spacing: theme.spacing.space1) {
                Text(record.outputDisplayName)
                    .font(theme.typography.bodyEmphasis)
                Text(libraryDetail(record))
                    .font(theme.typography.caption)
                    .foregroundStyle(theme.textSecondary)
                Text(
                    viewModel.workHistoryLocationStatusText(id: record.id)
                )
                .font(theme.typography.captionEmphasis)
                .foregroundStyle(
                    locationNeedsAttention ? theme.warning : theme.success
                )
                if record.terminalResult == .completed,
                   let revealFailureReason,
                   revealFailureReason != reprocessFailureReason {
                    Text(revealFailureReason)
                        .font(theme.typography.caption)
                        .foregroundStyle(theme.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let reprocessFailureReason {
                    Text(reprocessFailureReason)
                        .font(theme.typography.caption)
                        .foregroundStyle(theme.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()

            if record.terminalResult == .completed {
                Button("Reveal") {
                    viewModel.revealWorkHistoryOutput(id: record.id)
                }
                .buttonStyle(
                    MirmirSecondaryButtonStyle(theme: theme)
                )
                .disabled(revealFailureReason != nil)
                .help(
                    revealFailureReason
                        ?? "Reveal the verified completed output in Finder."
                )
            }

            Button("Reprocess") {
                viewModel.reprocessWorkHistoryRecord(id: record.id)
            }
            .buttonStyle(MirmirSecondaryButtonStyle(theme: theme))
            .disabled(reprocessFailureReason != nil)
            .help(
                reprocessFailureReason
                    ?? "Create a new upscale from this saved source and "
                        + "processing configuration."
            )

            Button("Reauthorize") {
                viewModel.reauthorizeWorkHistoryRecord(id: record.id)
            }
            .buttonStyle(MirmirSecondaryButtonStyle(theme: theme))
            .disabled(
                viewModel.jobIsRunning
                    || viewModel.workHistoryReprocessInProgressID != nil
            )
            .help(
                "Choose the saved source and output folder again so Mirmir "
                    + "can reprocess this history item."
            )

            Button("Remove", role: .destructive) {
                viewModel.removeWorkHistoryRecord(id: record.id)
            }
            .buttonStyle(MirmirSecondaryButtonStyle(theme: theme))
            .disabled(
                viewModel.workHistoryReprocessInProgressID != nil
            )

            if viewModel.workHistoryReprocessInProgressID == record.id {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Preparing reprocess")
            }
        }
        .padding(theme.spacing.space3)
        .background(
            RoundedRectangle(cornerRadius: theme.radius.medium)
                .fill(theme.surface)
        )
    }

    private func libraryDetail(
        _ record: MirmirWorkHistoryRecord
    ) -> String {
        "\(record.terminalResult.title) · \(record.sourceDisplayName)"
            + " · \(MirmirViewModel.fileLabel(for: record.sourceResolution))"
            + " → \(MirmirViewModel.fileLabel(for: record.targetResolution))"
            + " · \(record.requestedMode.title)"
            + " · \(record.scanStructureHistoryDescription)"
            + " · \(record.audioHistoryDescription)"
            + " · "
            + record.completedAt.formatted(
                date: .abbreviated,
                time: .shortened
            )
    }
}

struct MirmirQueueScreen: View {
    @ObservedObject var viewModel: MirmirViewModel
    let theme: MirmirThemeTokens

    @State private var confirmsDiscardAll = false
    @State private var confirmsClearPending = false
    @State private var discardRecoveryCandidate:
        R13RecoverableUpscaleJob?

    var body: some View {
        MirmirScreenScaffold(theme: theme) {
            MirmirPanel(theme: theme) {
                VStack(alignment: .leading, spacing: theme.spacing.space4) {
                    HStack {
                        screenHeader(
                            "Queue",
                            "Persistent serial work, active processing, and "
                                + "interrupted-job recovery.",
                            theme: theme
                        )
                        Spacer()

                        Button("Add Videos…") {
                            viewModel.chooseVideosForQueue()
                        }
                        .buttonStyle(
                            MirmirSecondaryButtonStyle(theme: theme)
                        )
                        .disabled(
                            viewModel.pendingQueueMutationIsInProgress
                        )

                        Button(startNextButtonTitle) {
                            viewModel.startNextPendingWork()
                        }
                        .buttonStyle(
                            MirmirPrimaryButtonStyle(theme: theme)
                        )
                        .disabled(
                            viewModel.pendingWorkRecords.isEmpty
                                || viewModel.jobIsRunning
                                || viewModel.state == .probing
                                || viewModel.pendingQueueMutationIsInProgress
                        )

                        if !viewModel.pendingWorkRecords.isEmpty {
                            Button(
                                "Clear Pending",
                                role: .destructive
                            ) {
                                confirmsClearPending = true
                            }
                            .buttonStyle(
                                MirmirSecondaryButtonStyle(theme: theme)
                            )
                            .disabled(
                                viewModel.pendingQueueMutationIsInProgress
                                    || viewModel.pendingWorkRecords
                                        .contains {
                                            $0.state == .started
                                        }
                            )
                        }

                        if !viewModel.recoverableJobs.isEmpty
                            || viewModel.recoveryRejectedEntryCount > 0 {
                            Button(
                                "Discard All Interrupted",
                                role: .destructive
                            ) {
                                confirmsDiscardAll = true
                            }
                            .buttonStyle(
                                MirmirSecondaryButtonStyle(theme: theme)
                            )
                            .disabled(recoveryActionsAreDisabled)
                        }

                        Button("Dismiss Completed") {
                            viewModel.dismissTerminalJob()
                        }
                            .buttonStyle(MirmirSecondaryButtonStyle(theme: theme))
                            .disabled(!jobIsFinished)
                    }

                    queueContent
                }
            }
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
        .confirmationDialog(
            "Clear all pending videos?",
            isPresented: $confirmsClearPending,
            titleVisibility: .visible
        ) {
            Button("Clear Pending Videos", role: .destructive) {
                viewModel.clearPendingWork()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "The queued entries will be removed. Source videos and "
                + "completed output files will not be deleted."
            )
        }
        .confirmationDialog(
            "Discard interrupted upscale?",
            isPresented: showsRecoveryDiscardConfirmation,
            titleVisibility: .visible
        ) {
            if let discardRecoveryCandidate {
                Button("Discard", role: .destructive) {
                    viewModel.discardRecoverableJob(
                        id: discardRecoveryCandidate.id
                    )
                    self.discardRecoveryCandidate = nil
                }
            }
            Button("Cancel", role: .cancel) {
                discardRecoveryCandidate = nil
            }
        } message: {
            Text(
                "Cached frames and recovery permissions for this "
                    + "interrupted upscale will be permanently removed."
            )
        }
    }

    @ViewBuilder
    private var queueContent: some View {
        if viewModel.pendingQueueIsLoading {
            ProgressView("Loading pending work…")
        }

        if let preparation =
                viewModel.pendingQueueModelPreparation {
            VStack(alignment: .leading, spacing: theme.spacing.space2) {
                Text(
                    preparation.isPreparing
                        ? "Preparing VideoToolbox Quality for "
                            + preparation.displayName
                        : "VideoToolbox Quality preparation failed for "
                            + preparation.displayName
                )
                .font(theme.typography.caption.weight(.semibold))
                if preparation.isPreparing {
                    Text(viewModel.modelAssetsDetailText)
                        .font(theme.typography.caption)
                        .foregroundStyle(theme.textTertiary)
                    if case .downloading(let progress) =
                        viewModel.modelStatus {
                        ProgressView(
                            value: min(max(progress, 0), 1)
                        )
                        .accessibilityLabel(
                            "Queued VideoToolbox model download progress"
                        )
                    } else {
                        ProgressView()
                            .accessibilityLabel(
                                "Preparing queued VideoToolbox model"
                            )
                    }
                } else if let failureReason =
                            preparation.failureReason {
                    Text(failureReason)
                        .font(theme.typography.caption)
                        .foregroundStyle(theme.warning)
                    Text(
                        "Select Retry Model & Start to prepare the model "
                            + "again. The queued video remains pending."
                    )
                    .font(theme.typography.caption)
                    .foregroundStyle(theme.textTertiary)
                }
            }
            .padding(theme.spacing.space3)
            .background(
                theme.surfaceElevated,
                in: RoundedRectangle(cornerRadius: theme.radius.medium)
            )
        }

        ForEach(
            Array(viewModel.pendingWorkRecords.enumerated()),
            id: \.element.id
        ) { index, pending in
            MirmirPendingQueueRow(
                pending: pending,
                index: index,
                totalCount: viewModel.pendingWorkRecords.count,
                startedHeadExists:
                    viewModel.pendingWorkRecords.first?.state == .started,
                jobIsRunning: viewModel.jobIsRunning,
                mutationIsInProgress:
                    viewModel.pendingQueueMutationIsInProgress,
                theme: theme,
                moveUp: {
                    viewModel.movePendingWork(
                        id: pending.id,
                        offset: -1
                    )
                },
                moveDown: {
                    viewModel.movePendingWork(
                        id: pending.id,
                        offset: 1
                    )
                },
                reauthorize: {
                    viewModel.reauthorizePendingWork(id: pending.id)
                },
                remove: {
                    viewModel.removePendingWork(id: pending.id)
                }
            )
        }

        if let notice = viewModel.pendingQueueRecoveryNotice {
            Text(notice)
                .font(theme.typography.caption)
                .foregroundStyle(theme.warning)
        }
        if let error = viewModel.pendingQueueError {
            Text("Pending queue needs attention: \(error)")
                .font(theme.typography.caption)
                .foregroundStyle(theme.warning)
        }

        ForEach(viewModel.recoverableJobs) { interrupted in
            MirmirQueueRecoveryRow(
                interrupted: interrupted,
                requiresReauthorization:
                    viewModel.recoveryRequiresReauthorization(
                        id: interrupted.id
                    ),
                resumeFailureReason:
                    viewModel.recoverableJobResumeFailureReason(
                        id: interrupted.id
                    ),
                actionsAreDisabled: recoveryActionsAreDisabled,
                theme: theme,
                resume: {
                    viewModel.resumeRecoverableJob(id: interrupted.id)
                },
                reauthorize: {
                    viewModel.reauthorizeRecoverableJob(
                        id: interrupted.id
                    )
                },
                requestDiscard: {
                    discardRecoveryCandidate = interrupted
                }
            )
        }
        if viewModel.recoveryRejectedEntryCount > 0 {
            queueRow(
                "Unreadable interrupted data",
                detail:
                    "\(viewModel.recoveryRejectedEntryCount) record(s) "
                    + "could not be verified. Discard All removes them.",
                tone: .warning
            )
        }

        switch viewModel.state {
        case .running:
            queueRow("Active", detail: sourceDetail, tone: .active)
            Button("Cancel Processing") {
                viewModel.cancelUpscale()
            }
            .buttonStyle(MirmirSecondaryButtonStyle(theme: theme))
        case .finished:
            queueRow("Completed", detail: sourceDetail, tone: .success)
            HStack(spacing: theme.spacing.space2) {
                Button("Reveal Output") {
                    viewModel.revealOutputInFinder()
                }
                .buttonStyle(MirmirSecondaryButtonStyle(theme: theme))

                Button("Upscale Another Video") {
                    viewModel.upscaleAnotherVideo()
                }
                .buttonStyle(MirmirSecondaryButtonStyle(theme: theme))
            }
            if let error = viewModel.completedOutputRevealError {
                queueRow(
                    "Output needs attention",
                    detail: error,
                    tone: .warning
                )
            }
        case .failed(let reason):
            queueRow("Failed", detail: reason, tone: .danger)
            HStack(spacing: theme.spacing.space2) {
                Button("Retry Same Settings") {
                    viewModel.retryFailedUpscale()
                }
                .buttonStyle(MirmirSecondaryButtonStyle(theme: theme))
                .disabled(!viewModel.canRetryFailedUpscale)
                .help(
                    viewModel.retrySameSettingsFailureReason
                        ?? "Retry the same job identity and exact settings."
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
                        ?? "Start a new retry with the settings currently "
                            + "shown."
                )

                Button("Dismiss") {
                    viewModel.dismissTerminalJob()
                }
                .buttonStyle(MirmirSecondaryButtonStyle(theme: theme))
                .disabled(viewModel.recoveryMutationIsInProgress)
            }
            if let correctiveText =
                viewModel.retryCorrectiveActionText {
                queueRow(
                    "Retry needs attention",
                    detail: correctiveText,
                    tone: .warning
                )
            }
        default:
            if viewModel.pendingWorkRecords.isEmpty
                && viewModel.recoverableJobs.isEmpty
                && viewModel.recoveryRejectedEntryCount == 0 {
                emptyMessage(
                    "No queued work. Start an upscale from the Upscale "
                        + "workspace.",
                    theme: theme
                )
            }
        }
    }

    private var startNextButtonTitle: String {
        if viewModel.pendingQueueModelPreparation?.failureReason != nil {
            return "Retry Model & Start"
        }
        if viewModel.pendingWorkRecords.first?.state == .started {
            return "Resume Queue Head"
        }
        return "Start Next"
    }

    private var sourceDetail: String {
        viewModel.sourceProfile?.url.lastPathComponent ?? "Current source"
    }

    private var jobIsFinished: Bool {
        if case .finished = viewModel.state { return true }
        return false
    }

    private var recoveryActionsAreDisabled: Bool {
        viewModel.jobIsRunning
            || viewModel.recoveryIsProbing
            || viewModel.recoveryMutationIsInProgress
    }

    private var showsRecoveryDiscardConfirmation: Binding<Bool> {
        Binding(
            get: { discardRecoveryCandidate != nil },
            set: { isPresented in
                if !isPresented {
                    discardRecoveryCandidate = nil
                }
            }
        )
    }

    private func queueRow(_ title: String, detail: String, tone: MirmirStatusTone) -> some View {
        MirmirQueueCard(
            title: title,
            detail: detail,
            tone: tone,
            theme: theme
        )
    }
}

private struct MirmirPendingQueueRow: View {
    let pending: MirmirPendingWorkRecord
    let index: Int
    let totalCount: Int
    let startedHeadExists: Bool
    let jobIsRunning: Bool
    let mutationIsInProgress: Bool
    let theme: MirmirThemeTokens
    let moveUp: () -> Void
    let moveDown: () -> Void
    let reauthorize: () -> Void
    let remove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: theme.spacing.space2) {
            MirmirQueueCard(
                title: title,
                detail: detail,
                tone: tone,
                theme: theme
            )
            HStack(spacing: theme.spacing.space2) {
                Button(action: moveUp) {
                    Label("Move Up", systemImage: "arrow.up")
                }
                .buttonStyle(
                    MirmirSecondaryButtonStyle(theme: theme)
                )
                .disabled(
                    index == 0
                        || (index == 1 && startedHeadExists)
                        || pending.state == .started
                        || mutationIsInProgress
                )

                Button(action: moveDown) {
                    Label("Move Down", systemImage: "arrow.down")
                }
                .buttonStyle(
                    MirmirSecondaryButtonStyle(theme: theme)
                )
                .disabled(
                    index == totalCount - 1
                        || pending.state == .started
                        || mutationIsInProgress
                )

                Button("Reauthorize", action: reauthorize)
                    .buttonStyle(
                        MirmirSecondaryButtonStyle(theme: theme)
                    )
                    .disabled(
                        pending.state == .started
                            || mutationIsInProgress
                    )

                Button(
                    "Remove",
                    role: .destructive,
                    action: remove
                )
                .buttonStyle(
                    MirmirSecondaryButtonStyle(theme: theme)
                )
                .disabled(
                    pending.state == .started
                        || mutationIsInProgress
                )
            }
        }
    }

    private var title: String {
        guard pending.state == .started else {
            return "Pending \(index + 1)"
        }
        return jobIsRunning ? "Running" : "Ready to Resume"
    }

    private var detail: String {
        pending.bookmarks.sourceDisplayName
            + " → \(pending.bookmarks.outputDisplayName)"
            + " · "
            + MirmirViewModel.fileLabel(
                for: pending.settings.targetResolution
            )
            + " · \(pending.settings.requestedMode.title)"
    }

    private var tone: MirmirStatusTone {
        guard pending.state == .started else { return .neutral }
        return jobIsRunning ? .active : .warning
    }
}

private struct MirmirQueueCard: View {
    let title: String
    let detail: String
    let tone: MirmirStatusTone
    let theme: MirmirThemeTokens

    var body: some View {
        HStack(spacing: theme.spacing.space3) {
            Image(systemName: "list.bullet.rectangle")
                .foregroundStyle(tone.color(theme: theme))
            VStack(alignment: .leading, spacing: theme.spacing.space1) {
                Text(title)
                    .font(theme.typography.bodyEmphasis)
                Text(detail)
                    .font(theme.typography.caption)
                    .foregroundStyle(theme.textSecondary)
                    .lineLimit(2)
            }
            Spacer()
        }
        .padding(theme.spacing.space3)
        .background(
            RoundedRectangle(cornerRadius: theme.radius.medium)
                .fill(theme.surface)
        )
        .overlay {
            RoundedRectangle(cornerRadius: theme.radius.medium)
                .stroke(tone.borderColor(theme: theme), lineWidth: 1)
        }
    }
}

private struct MirmirQueueRecoveryRow: View {
    let interrupted: R13RecoverableUpscaleJob
    let requiresReauthorization: Bool
    let resumeFailureReason: String?
    let actionsAreDisabled: Bool
    let theme: MirmirThemeTokens
    let resume: () -> Void
    let reauthorize: () -> Void
    let requestDiscard: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: theme.spacing.space2) {
            MirmirQueueCard(
                title: "Interrupted",
                detail: detail,
                tone: .warning,
                theme: theme
            )

            HStack(spacing: theme.spacing.space2) {
                Button(action: resume) {
                    Label("Resume", systemImage: "play.circle")
                }
                .buttonStyle(
                    MirmirSecondaryButtonStyle(theme: theme)
                )
                .disabled(resumeFailureReason != nil)
                .help(
                    resumeFailureReason
                        ?? "Resume this interrupted upscale."
                )

                if requiresReauthorization {
                    Button(action: reauthorize) {
                        Label(
                            "Reauthorize",
                            systemImage: "folder.badge.questionmark"
                        )
                    }
                    .buttonStyle(
                        MirmirSecondaryButtonStyle(theme: theme)
                    )
                }

                Button(
                    "Discard",
                    role: .destructive,
                    action: requestDiscard
                )
                .buttonStyle(
                    MirmirSecondaryButtonStyle(theme: theme)
                )
            }
            .disabled(actionsAreDisabled)

            if let resumeFailureReason {
                Text(resumeFailureReason)
                    .font(theme.typography.caption)
                    .foregroundStyle(theme.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var detail: String {
        let frames = interrupted.cachedFrameCount
        let identifier = String(interrupted.id.prefix(8)).uppercased()
        return interrupted.outputFilename
            + " · \(frames) cached frame\(frames == 1 ? "" : "s")"
            + " · Job \(identifier)"
    }
}

struct MirmirModesScreen: View {
    @ObservedObject var viewModel: MirmirViewModel
    let theme: MirmirThemeTokens

    var body: some View {
        MirmirScreenScaffold(theme: theme) {
            MirmirPanel(theme: theme) {
                VStack(alignment: .leading, spacing: theme.spacing.space4) {
                    screenHeader(
                        "Release Modes",
                        "Each mode has an explicit scaler and recorded "
                            + "processing identity; Auto records its resolved mode.",
                        theme: theme
                    )

                    ForEach(UpscaleMode.allCases) { mode in
                        modeRow(mode)
                    }
                }
            }
        }
    }

    private func modeRow(_ mode: UpscaleMode) -> some View {
        let availability = viewModel.upscalerEngine.availability(for: mode)
        let isAvailable = availability == .available
        let isSelected = viewModel.selectedMode == mode
        let status = isAvailable
            ? (isSelected ? "Selected" : "Available")
            : "Unavailable"

        return Button {
            viewModel.selectModeForPendingJob(mode)
        } label: {
            HStack(spacing: theme.spacing.space3) {
                Image(
                    systemName: isSelected
                        ? "checkmark.circle.fill"
                        : "circle"
                )
                .foregroundStyle(
                    isSelected ? theme.success : theme.textTertiary
                )
                VStack(alignment: .leading, spacing: theme.spacing.space1) {
                    Text(mode.title)
                        .font(theme.typography.bodyEmphasis)
                    Text(mode.summary)
                        .font(theme.typography.caption)
                        .foregroundStyle(theme.textSecondary)
                }
                Spacer()
                Text(status)
                    .font(theme.typography.captionEmphasis)
                    .foregroundStyle(
                        isAvailable ? theme.textSecondary : theme.warning
                    )
            }
        }
        .buttonStyle(.plain)
        .disabled(
            !isAvailable || !viewModel.jobConfigurationIsEditable
        )
        .help(availability.unavailableReason ?? mode.summary)
        .accessibilityValue(status)
        .padding(theme.spacing.space3)
        .background(
            RoundedRectangle(cornerRadius: theme.radius.medium)
                .fill(theme.surface)
        )
    }
}

struct MirmirSettingsScreen: View {
    @ObservedObject var viewModel: MirmirViewModel
    let theme: MirmirThemeTokens
    @Binding var appearanceMode: MirmirAppearanceMode

    var body: some View {
        MirmirScreenScaffold(theme: theme) {
            MirmirPanel(theme: theme) {
                VStack(alignment: .leading, spacing: theme.spacing.space5) {
                    screenHeader("Settings", "Appearance, defaults, processing, output, diagnostics, and advanced options.", theme: theme)

                    MirmirFieldRow("Appearance", theme: theme) {
                        Picker("Appearance", selection: $appearanceMode) {
                            ForEach(MirmirAppearanceMode.allCases) { mode in
                                Text(mode.title).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                    }

                    MirmirFieldRow("Default Mode", theme: theme) {
                        Picker("Default Mode", selection: modeSelection) {
                            ForEach(UpscaleMode.allCases) { mode in
                                Text(mode.releasePickerTitle).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                        .help(
                            viewModel.persistedDefaults.mode.summary
                        )
                    }

                    if viewModel.persistedDefaults.mode
                        == .smoothMotion {
                        MirmirFieldRow(
                            "Default Smooth Motion Cadence",
                            theme: theme
                        ) {
                            Picker(
                                "Default Smooth Motion Cadence",
                                selection: smoothMotionCadenceSelection
                            ) {
                                ForEach(
                                    SmoothMotionCadence.allCases
                                ) { cadence in
                                    Text(cadence.title).tag(cadence)
                                }
                            }
                            .pickerStyle(.segmented)
                        }

                        MirmirFieldRow(
                            "Default Scene Cut Protection",
                            theme: theme
                        ) {
                            Picker(
                                "Default Scene Cut Protection",
                                selection:
                                    smoothMotionSceneCutSelection
                            ) {
                                ForEach(
                                    SmoothMotionSceneCutSensitivity
                                        .allCases
                                ) { sensitivity in
                                    Text(sensitivity.title)
                                        .tag(sensitivity)
                                }
                            }
                            .pickerStyle(.segmented)
                        }
                    }

                    MirmirFieldRow("Default Output Format", theme: theme) {
                        Picker("Default Output Format", selection: codecSelection) {
                            ForEach(OutputCodec.allCases) { codec in
                                Text(codec.inspectorTitle).tag(codec)
                            }
                        }
                        .pickerStyle(.segmented)
                    }

                    MirmirFieldRow("Default Engine", theme: theme) {
                        Picker(
                            "Default Engine",
                            selection: engineSelection
                        ) {
                            ForEach(
                                UpscaleEnginePreference.allCases
                            ) { preference in
                                Text(preference.title).tag(preference)
                            }
                        }
                        .pickerStyle(.menu)
                    }

                    MirmirFieldRow("Default Strategy", theme: theme) {
                        Picker(
                            "Default Strategy",
                            selection: strategySelection
                        ) {
                            ForEach(
                                UpscaleStrategyPreference.allCases
                            ) { preference in
                                Text(preference.title).tag(preference)
                            }
                        }
                        .pickerStyle(.menu)
                    }

                    MirmirFieldRow(
                        "Default Temporal Consistency",
                        theme: theme
                    ) {
                        Toggle(
                            "Enable for new jobs",
                            isOn: temporalConsistencySelection
                        )
                    }

                    MirmirFieldRow(
                        "Default Edge Fidelity",
                        theme: theme
                    ) {
                        Picker(
                            "Default Edge Fidelity",
                            selection: edgeFidelitySelection
                        ) {
                            ForEach(
                                MirmirAdjustmentLevel.allCases
                            ) { level in
                                Text(level.title).tag(level)
                            }
                        }
                        .pickerStyle(.segmented)
                    }

                    MirmirFieldRow(
                        "Default Detail Recovery",
                        theme: theme
                    ) {
                        Picker(
                            "Default Detail Recovery",
                            selection: detailRecoverySelection
                        ) {
                            ForEach(
                                MirmirAdjustmentLevel.allCases
                            ) { level in
                                Text(level.title).tag(level)
                            }
                        }
                        .pickerStyle(.segmented)
                    }

                    MirmirFieldRow(
                        "Default Edge Preservation",
                        theme: theme
                    ) {
                        Toggle(
                            "Enable for new jobs",
                            isOn: edgePreservationSelection
                        )
                    }

                    MirmirFieldRow(
                        "Default Compression Cleanup",
                        theme: theme
                    ) {
                        Toggle(
                            "Enable for new jobs",
                            isOn: compressionCleanupSelection
                        )
                    }

                    MirmirFieldRow(
                        "Default Texture / Grain Protection",
                        theme: theme
                    ) {
                        Toggle(
                            "Enable for new jobs",
                            isOn: textureGrainProtectionSelection
                        )
                    }

                    MirmirFieldRow(
                        "Default Temporal Stability",
                        theme: theme
                    ) {
                        Toggle(
                            "Enable for new jobs",
                            isOn: temporalStabilitySelection
                        )
                    }

                    MirmirFieldRow("Cache Location", theme: theme) {
                        MirmirCacheLocationSettings(
                            viewModel: viewModel,
                            showsTitle: false
                        )
                    }

                    settingsNote(
                        "Processing Defaults",
                        "These values initialize newly selected sources. "
                            + "Current and interrupted jobs retain their "
                            + "own exact configuration."
                    )
                    MirmirFieldRow("Diagnostic Log", theme: theme) {
                        VStack(alignment: .leading, spacing: theme.spacing.space2) {
                            Text(
                                "View the persistent, privacy-filtered log and "
                                    + "export it as JSON or Markdown."
                            )
                            .font(theme.typography.body)
                            .foregroundStyle(theme.textTertiary)

                            SettingsLink {
                                Label(
                                    "Open Diagnostic Log Settings…",
                                    systemImage: "doc.text.magnifyingglass"
                                )
                            }
                        }
                    }
                    settingsNote(
                        "Advanced",
                        "Engine, strategy, temporal consistency, edge "
                            + "fidelity, and detail recovery defaults are "
                            + "available above."
                    )
                }
            }
        }
    }

    private var modeSelection: Binding<UpscaleMode> {
        Binding(
            get: { viewModel.persistedDefaults.mode },
            set: { viewModel.selectDefaultMode($0) }
        )
    }

    private var codecSelection: Binding<OutputCodec> {
        Binding(
            get: { viewModel.persistedDefaults.outputCodec },
            set: { viewModel.selectDefaultOutputCodec($0) }
        )
    }

    private var smoothMotionCadenceSelection:
        Binding<SmoothMotionCadence> {
        Binding(
            get: { viewModel.persistedDefaults.smoothMotion.cadence },
            set: {
                viewModel.selectDefaultSmoothMotionCadence($0)
            }
        )
    }

    private var smoothMotionSceneCutSelection:
        Binding<SmoothMotionSceneCutSensitivity> {
        Binding(
            get: {
                viewModel.persistedDefaults.smoothMotion
                    .sceneCutSensitivity
            },
            set: {
                viewModel
                    .selectDefaultSmoothMotionSceneCutSensitivity($0)
            }
        )
    }

    private var engineSelection:
        Binding<UpscaleEnginePreference> {
        Binding(
            get: { viewModel.persistedDefaults.enginePreference },
            set: { viewModel.selectDefaultEngine($0) }
        )
    }

    private var strategySelection:
        Binding<UpscaleStrategyPreference> {
        Binding(
            get: { viewModel.persistedDefaults.strategyPreference },
            set: { viewModel.selectDefaultStrategy($0) }
        )
    }

    private var temporalConsistencySelection: Binding<Bool> {
        Binding(
            get: {
                viewModel.persistedDefaults
                    .temporalConsistencyEnabled
            },
            set: { viewModel.setDefaultTemporalConsistency($0) }
        )
    }

    private var edgeFidelitySelection:
        Binding<MirmirAdjustmentLevel> {
        Binding(
            get: { viewModel.persistedDefaults.edgeFidelityLevel },
            set: { viewModel.selectDefaultEdgeFidelity($0) }
        )
    }

    private var detailRecoverySelection:
        Binding<MirmirAdjustmentLevel> {
        Binding(
            get: { viewModel.persistedDefaults.detailRecoveryLevel },
            set: { viewModel.selectDefaultDetailRecovery($0) }
        )
    }

    private var edgePreservationSelection: Binding<Bool> {
        Binding(
            get: {
                viewModel.persistedDefaults.effects
                    .edgePreservationEnabled
            },
            set: { viewModel.setDefaultEdgePreservation($0) }
        )
    }

    private var compressionCleanupSelection: Binding<Bool> {
        Binding(
            get: {
                viewModel.persistedDefaults.effects
                    .compressionCleanupEnabled
            },
            set: { viewModel.setDefaultCompressionCleanup($0) }
        )
    }

    private var textureGrainProtectionSelection: Binding<Bool> {
        Binding(
            get: {
                viewModel.persistedDefaults.effects
                    .textureGrainProtectionEnabled
            },
            set: {
                viewModel.setDefaultTextureGrainProtection($0)
            }
        )
    }

    private var temporalStabilitySelection: Binding<Bool> {
        Binding(
            get: {
                viewModel.persistedDefaults.effects
                    .temporalStabilityEnabled
            },
            set: { viewModel.setDefaultTemporalStability($0) }
        )
    }

    private func settingsNote(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: theme.spacing.space1) {
            Text(title)
                .font(theme.typography.captionEmphasis)
                .foregroundStyle(theme.textSecondary)
            Text(detail)
                .font(theme.typography.body)
                .foregroundStyle(theme.textTertiary)
        }
    }
}

struct MirmirAboutWorkspaceScreen: View {
    @ObservedObject var viewModel: MirmirViewModel
    let theme: MirmirThemeTokens

    var body: some View {
        MirmirScreenScaffold(theme: theme) {
            MirmirPanel(theme: theme) {
                MirmirAboutView(viewModel: viewModel, showsTechnicalDetails: true)
            }
        }
    }
}

struct MirmirDiagnosticsScreen: View {
    @ObservedObject var viewModel: MirmirViewModel
    let theme: MirmirThemeTokens

    var body: some View {
        MirmirScreenScaffold(theme: theme) {
            MirmirPanel(theme: theme) {
                VStack(alignment: .leading, spacing: theme.spacing.space4) {
                    screenHeader("Diagnostics", "Local processing readiness and recent state.", theme: theme)
                    diagnosticRow("Processing status", viewModel.engineReadinessText)
                    if let reason = viewModel.engineAvailabilityReason {
                        diagnosticRow("Availability", reason)
                    }
                    diagnosticRow("Model assets", viewModel.modelAssetsStatusText)
                    diagnosticRow("Model specialization", viewModel.modelSpecializationText)
                    diagnosticRow("Workflow state", viewModel.state.statusTitle)
                    diagnosticRow(
                        "Release events",
                        viewModel.releaseDiagnosticsText
                    )
                    ForEach(
                        viewModel.releaseDiagnosticLines,
                        id: \.self
                    ) { line in
                        Text(line)
                            .font(.caption.monospaced())
                            .foregroundStyle(theme.textSecondary)
                            .textSelection(.enabled)
                    }
                }
            }
        }
        .task {
            viewModel.refreshReleaseDiagnostics()
        }
    }

    private func diagnosticRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
                .foregroundStyle(theme.textSecondary)
            Spacer()
            Text(value)
                .font(theme.typography.bodyEmphasis.monospacedDigit())
                .foregroundStyle(theme.textPrimary)
        }
        .font(theme.typography.body)
    }
}

struct MirmirScreenScaffold<Content: View>: View {
    let theme: MirmirThemeTokens
    let content: Content

    init(theme: MirmirThemeTokens, @ViewBuilder content: () -> Content) {
        self.theme = theme
        self.content = content()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: theme.spacing.space4) {
                content
            }
            .padding(theme.spacing.space5)
            .frame(maxWidth: 960, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(theme.background)
    }
}

@ViewBuilder
func screenHeader(_ title: String, _ subtitle: String, theme: MirmirThemeTokens) -> some View {
    VStack(alignment: .leading, spacing: theme.spacing.space1) {
        Text(title)
            .font(theme.typography.subtitle)
            .foregroundStyle(theme.textPrimary)
        Text(subtitle)
            .font(theme.typography.body)
            .foregroundStyle(theme.textSecondary)
    }
}

@ViewBuilder
func emptyMessage(_ message: String, theme: MirmirThemeTokens) -> some View {
    Text(message)
        .font(theme.typography.body)
        .foregroundStyle(theme.textSecondary)
        .padding(.vertical, theme.spacing.space2)
}

// swiftlint:enable file_length
