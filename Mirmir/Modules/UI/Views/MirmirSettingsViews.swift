import Foundation
import SwiftUI
import UniformTypeIdentifiers

struct MirmirSettingsView: View {
    @ObservedObject var viewModel: MirmirViewModel

    var body: some View {
        TabView {
            generalSettings
                .tabItem { Text("General") }

            MirmirAboutView(viewModel: viewModel, showsTechnicalDetails: false)
                .tabItem { Text("About Mirmir") }

            technicalDetails
                .tabItem { Text("Technical Details") }
        }
        .padding(20)
    }

    private var generalSettings: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("General")
                .font(.title3.weight(.semibold))

            Picker("Default Mode", selection: $viewModel.selectedMode) {
                ForEach(UpscaleMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .help(viewModel.selectedModeSummary)
            .pickerStyle(.segmented)

            Picker("Default Codec", selection: $viewModel.codec) {
                ForEach(OutputCodec.allCases) { codec in
                    Text(codec.rawValue.uppercased()).tag(codec)
                }
            }
            .pickerStyle(.segmented)

            MirmirCacheLocationSettings(viewModel: viewModel)

            Text(viewModel.engineReadinessText)
                .font(.callout)
                .foregroundStyle(.secondary)

            Spacer()
        }
    }

    private var technicalDetails: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Technical Details")
                .font(.title3.weight(.semibold))

            Text("Runtime: Mirmir module runtime")
            Text("Upscaling: \(viewModel.engineSelectionText)")
            Text("Processing status: \(viewModel.engineReadinessText)")
            if let reason = viewModel.engineAvailabilityReason {
                Text(reason)
            }
            Text("Model assets: \(viewModel.modelAssetsStatusText)")
            Text(viewModel.modelAssetsDetailText)
            Text(viewModel.modelSpecializationText)

            Spacer()
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }
}

struct MirmirCacheLocationSettings: View {
    @ObservedObject var viewModel: MirmirViewModel
    var showsTitle = true

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if showsTitle {
                Text("Cache Location")
                    .font(.headline)
            }
            Text(viewModel.cacheLocationPath)
                .font(.callout.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .textSelection(.enabled)

            if viewModel.cacheLocationIsConfigurable {
                HStack {
                    Button("Choose…") {
                        viewModel.chooseCacheLocation()
                    }
                    if viewModel.cacheLocationIsCustom {
                        Button("Use Internal Storage") {
                            viewModel.useDefaultCacheLocation()
                        }
                    }
                }
                .disabled(!viewModel.canChangeCacheLocation)
            }

            if let message = viewModel.cacheLocationStatusMessage {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text(
                "Choose any writable folder on an internal disk, "
                    + "external drive, or mounted network share."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}

struct MirmirAboutView: View {
    @ObservedObject var viewModel: MirmirViewModel
    let showsTechnicalDetails: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Mirmir")
                .font(.title2.weight(.semibold))
            Text("Mirmir upscales supported 720p and 1080p SDR video with its qualified Apple MPS Lanczos path and verifies completed output before publication.")
                .fixedSize(horizontal: false, vertical: true)

            if let reason = viewModel.engineAvailabilityReason {
                Text(reason)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if showsTechnicalDetails {
                Divider()
                Text("Technical Details")
                    .font(.headline)
                Text("The Mirmir module runtime owns application composition.")
                Text("ASH remains a directly testable reference and research implementation.")
                Text(viewModel.engineReadinessText)
            }

            Spacer()
        }
        .padding(20)
    }
}

struct MirmirDiagnosticSettingsView: View {
    let store: MirmirDiagnosticStore

    @State private var snapshot: MirmirDiagnosticSnapshot?
    @State private var persistenceHealth:
        MirmirDiagnosticPersistenceHealth?
    @State private var renderedLog = ""
    @State private var isRefreshing = false
    @State private var isExporting = false
    @State private var statusMessage: String?
    @State private var failureMessage: String?
    @State private var exportDocument = MirmirDiagnosticExportDocument()
    @State private var exportContentType = UTType.json
    @State private var exportFilename = "Mirmir-Diagnostics.json"
    @State private var presentsExporter = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            storageStatus
            retentionSummary
            exportControls
            logViewer
            operationStatus
        }
        .padding(20)
        .frame(
            minWidth: 720,
            idealWidth: 840,
            minHeight: 560,
            idealHeight: 680
        )
        .task {
            guard snapshot == nil else { return }
            await refresh()
        }
        .fileExporter(
            isPresented: $presentsExporter,
            document: exportDocument,
            contentType: exportContentType,
            defaultFilename: exportFilename
        ) { result in
            completeExport(result)
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Diagnostic Log")
                    .font(.title2.weight(.semibold))
                Text(
                    "Review the privacy-filtered local log or export it "
                        + "for troubleshooting."
                )
                .font(.callout)
                .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                Task { await refresh() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .keyboardShortcut("r", modifiers: [.command])
            .disabled(isRefreshing || isExporting)
        }
    }

    @ViewBuilder
    private var storageStatus: some View {
        switch store.storageKind {
        case .persistent:
            if let persistenceHealth {
                if persistenceHealth.failedOperationCount > 0 {
                    Label(
                        "Persistent storage encountered "
                            + "\(persistenceHealth.failedOperationCount) failed "
                            + "operation(s). Last failure: "
                            + "\(persistenceHealth.lastFailedOperation ?? "unknown").",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
                } else {
                    Label(
                        "Persistent storage is active.",
                        systemImage: "externaldrive.fill.badge.checkmark"
                    )
                    .foregroundStyle(.green)
                }
            } else {
                Label(
                    "Checking persistent storage health…",
                    systemImage: "externaldrive.badge.questionmark"
                )
                .foregroundStyle(.secondary)
            }
        case .memoryOnly:
            Label(
                "Persistent storage is unavailable. "
                    + "This session's log will be lost when Mirmir exits.",
                systemImage: "exclamationmark.triangle.fill"
            )
            .foregroundStyle(.orange)
        }
    }

    @ViewBuilder
    private var retentionSummary: some View {
        GroupBox("Retention") {
            if let snapshot {
                Grid(
                    alignment: .leading,
                    horizontalSpacing: 24,
                    verticalSpacing: 8
                ) {
                    GridRow {
                        metric("Retained records", snapshot.retainedRecordCount)
                        metric(
                            "Retained size",
                            snapshot.retainedByteCount.formatted(
                                .byteCount(style: .file)
                            )
                        )
                    }
                    GridRow {
                        metric("Pruned records", snapshot.prunedRecordCount)
                        metric("Rejected records", snapshot.rejectedRecordCount)
                    }
                    GridRow {
                        metric(
                            "Recovered corrupt tails",
                            snapshot.recoveredCorruptTailCount
                        )
                        metric(
                            "Recovered corrupt bytes",
                            snapshot.recoveredCorruptByteCount.formatted(
                                .byteCount(style: .file)
                            )
                        )
                    }
                    GridRow {
                        metric(
                            "Persistence failures",
                            snapshot.persistenceFailureCount
                        )
                        metric(
                            "Last failed operation",
                            snapshot.lastPersistenceFailureOperation ?? "None"
                        )
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else if isRefreshing {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text("No snapshot has been loaded.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var exportControls: some View {
        HStack {
            Text("Export")
                .font(.headline)

            Spacer()

            Button("JSON…") {
                prepareExport(.json)
            }
            .disabled(isRefreshing || isExporting)

            Button("Markdown…") {
                prepareExport(.markdown)
            }
            .disabled(isRefreshing || isExporting)
        }
    }

    private var logViewer: some View {
        GroupBox("Records") {
            ScrollView([.horizontal, .vertical]) {
                Text(logDisplayText)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(
                        maxWidth: .infinity,
                        alignment: .topLeading
                    )
                    .padding(8)
            }
            .frame(minHeight: 300)
            .background(.background.secondary)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(.separator, lineWidth: 1)
            }
        }
    }

    @ViewBuilder
    private var operationStatus: some View {
        if let failureMessage {
            Label(failureMessage, systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(.red)
                .textSelection(.enabled)
        } else if let statusMessage {
            Text(statusMessage)
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }

    private var logDisplayText: String {
        if !renderedLog.isEmpty {
            return renderedLog
        }
        if isRefreshing {
            return "Loading the diagnostic log…"
        }
        return "No diagnostic records are available."
    }

    private func metric<Value: CustomStringConvertible>(
        _ title: String,
        _ value: Value
    ) -> some View {
        LabeledContent(title) {
            Text(value.description)
                .monospacedDigit()
                .textSelection(.enabled)
        }
    }

    @MainActor
    private func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        failureMessage = nil
        statusMessage = nil
        persistenceHealth = await store.persistenceHealth()

        do {
            let loadedSnapshot = try await store.snapshot()
            let markdownData = try await Task.detached(priority: .utility) {
                try MirmirDiagnosticExport.markdown(loadedSnapshot)
            }.value
            guard !Task.isCancelled else { return }

            snapshot = loadedSnapshot
            persistenceHealth = await store.persistenceHealth()
            renderedLog = String(decoding: markdownData, as: UTF8.self)
            statusMessage =
                "Snapshot loaded at "
                + MirmirDiagnosticExport.utcTimestamp(
                    loadedSnapshot.exportedAtUnixMilliseconds
                )
                + "."
        } catch is CancellationError {
            return
        } catch {
            persistenceHealth = await store.persistenceHealth()
            failureMessage = Self.failureDescription(
                error,
                action: "read the diagnostic log"
            )
        }
    }

    @MainActor
    private func prepareExport(_ format: MirmirDiagnosticExportFormat) {
        guard !isExporting else { return }
        isExporting = true
        failureMessage = nil
        statusMessage = "Preparing \(format.displayName) export…"

        Task {
            do {
                let data: Data
                switch format {
                case .json:
                    data = try await store.exportJSON()
                case .markdown:
                    data = try await store.exportMarkdown()
                }
                persistenceHealth = await store.persistenceHealth()
                guard !Task.isCancelled else {
                    isExporting = false
                    return
                }

                exportDocument = MirmirDiagnosticExportDocument(data: data)
                exportContentType = format.contentType
                exportFilename = format.defaultFilename
                statusMessage = nil
                presentsExporter = true
            } catch is CancellationError {
                isExporting = false
            } catch {
                persistenceHealth = await store.persistenceHealth()
                isExporting = false
                failureMessage = Self.failureDescription(
                    error,
                    action: "prepare the \(format.displayName) export"
                )
            }
        }
    }

    @MainActor
    private func completeExport(_ result: Result<URL, Error>) {
        isExporting = false
        switch result {
        case .success:
            failureMessage = nil
            statusMessage = "Diagnostic log exported."
        case .failure(let error as CocoaError)
            where error.code == .userCancelled:
            statusMessage = "Export cancelled."
        case .failure(let error):
            failureMessage = Self.failureDescription(
                error,
                action: "write the diagnostic export"
            )
        }
    }

    private static func failureDescription(
        _ error: Error,
        action: String
    ) -> String {
        let identity = error as NSError
        return "Unable to \(action). "
            + "\(identity.domain) error \(identity.code)."
    }
}

private enum MirmirDiagnosticExportFormat {
    case json
    case markdown

    static let markdownContentType =
        UTType(filenameExtension: "md") ?? .plainText

    var displayName: String {
        switch self {
        case .json:
            return "JSON"
        case .markdown:
            return "Markdown"
        }
    }

    var contentType: UTType {
        switch self {
        case .json:
            return .json
        case .markdown:
            return Self.markdownContentType
        }
    }

    var defaultFilename: String {
        switch self {
        case .json:
            return "Mirmir-Diagnostics.json"
        case .markdown:
            return "Mirmir-Diagnostics.md"
        }
    }
}

private struct MirmirDiagnosticExportDocument: FileDocument {
    static var readableContentTypes: [UTType] {
        [.json, MirmirDiagnosticExportFormat.markdownContentType]
    }

    let data: Data

    init(data: Data = Data()) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.data = data
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
