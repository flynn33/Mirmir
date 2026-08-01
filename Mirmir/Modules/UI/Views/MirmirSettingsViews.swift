import AppKit
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

            MirmirDiagnosticSettingsView(
                store: viewModel.diagnosticStore
            )
            .tabItem { Text("Diagnostics") }
        }
        .padding(20)
    }

    private var generalSettings: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("General")
                .font(.title3.weight(.semibold))

            Picker("Appearance", selection: appearanceSelection) {
                ForEach(MirmirAppearanceMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            Picker("Default Mode", selection: defaultModeSelection) {
                ForEach(UpscaleMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .help(viewModel.persistedDefaults.mode.summary)
            .pickerStyle(.segmented)

            if viewModel.persistedDefaults.mode == .smoothMotion {
                Picker(
                    "Default Smooth Motion Cadence",
                    selection: defaultSmoothMotionCadenceSelection
                ) {
                    ForEach(SmoothMotionCadence.allCases) { cadence in
                        Text(cadence.title).tag(cadence)
                    }
                }
                .pickerStyle(.segmented)

                Picker(
                    "Default Scene Cut Protection",
                    selection: defaultSmoothMotionSceneCutSelection
                ) {
                    ForEach(
                        SmoothMotionSceneCutSensitivity.allCases
                    ) { sensitivity in
                        Text(sensitivity.title).tag(sensitivity)
                    }
                }
                .pickerStyle(.segmented)
            }

            Picker("Default Codec", selection: defaultCodecSelection) {
                ForEach(OutputCodec.allCases) { codec in
                    Text(codec.displayName).tag(codec)
                }
            }
            .pickerStyle(.segmented)

            Picker("Default Engine", selection: defaultEngineSelection) {
                ForEach(
                    UpscaleEnginePreference.allCases
                ) { preference in
                    Text(preference.title).tag(preference)
                }
            }
            .pickerStyle(.menu)

            Picker(
                "Default Strategy",
                selection: defaultStrategySelection
            ) {
                ForEach(
                    UpscaleStrategyPreference.allCases
                ) { preference in
                    Text(preference.title).tag(preference)
                }
            }
            .pickerStyle(.menu)

            Toggle(
                "Default Temporal Consistency",
                isOn: defaultTemporalConsistencySelection
            )

            Picker(
                "Default Edge Fidelity",
                selection: defaultEdgeFidelitySelection
            ) {
                ForEach(MirmirAdjustmentLevel.allCases) { level in
                    Text(level.title).tag(level)
                }
            }
            .pickerStyle(.segmented)

            Picker(
                "Default Detail Recovery",
                selection: defaultDetailRecoverySelection
            ) {
                ForEach(MirmirAdjustmentLevel.allCases) { level in
                    Text(level.title).tag(level)
                }
            }
            .pickerStyle(.segmented)

            Group {
                Toggle(
                    "Default Edge Preservation",
                    isOn: defaultEdgePreservationSelection
                )
                Toggle(
                    "Default Compression Cleanup",
                    isOn: defaultCompressionCleanupSelection
                )
                Toggle(
                    "Default Texture / Grain Protection",
                    isOn: defaultTextureGrainProtectionSelection
                )
                Toggle(
                    "Default Temporal Stability",
                    isOn: defaultTemporalStabilitySelection
                )
            }

            Text(
                "Defaults apply to newly selected sources. Current and "
                    + "interrupted jobs retain their exact configuration."
            )
            .font(.caption)
            .foregroundStyle(.secondary)

            MirmirCacheLocationSettings(viewModel: viewModel)

            Text(viewModel.engineReadinessText)
                .font(.callout)
                .foregroundStyle(.secondary)

            Spacer()
        }
    }

    private var appearanceSelection: Binding<MirmirAppearanceMode> {
        Binding(
            get: { viewModel.appearanceMode },
            set: { viewModel.selectAppearanceMode($0) }
        )
    }

    private var defaultModeSelection: Binding<UpscaleMode> {
        Binding(
            get: { viewModel.persistedDefaults.mode },
            set: { viewModel.selectDefaultMode($0) }
        )
    }

    private var defaultCodecSelection: Binding<OutputCodec> {
        Binding(
            get: { viewModel.persistedDefaults.outputCodec },
            set: { viewModel.selectDefaultOutputCodec($0) }
        )
    }

    private var defaultSmoothMotionCadenceSelection:
        Binding<SmoothMotionCadence> {
        Binding(
            get: { viewModel.persistedDefaults.smoothMotion.cadence },
            set: {
                viewModel.selectDefaultSmoothMotionCadence($0)
            }
        )
    }

    private var defaultSmoothMotionSceneCutSelection:
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

    private var defaultEngineSelection:
        Binding<UpscaleEnginePreference> {
        Binding(
            get: { viewModel.persistedDefaults.enginePreference },
            set: { viewModel.selectDefaultEngine($0) }
        )
    }

    private var defaultStrategySelection:
        Binding<UpscaleStrategyPreference> {
        Binding(
            get: { viewModel.persistedDefaults.strategyPreference },
            set: { viewModel.selectDefaultStrategy($0) }
        )
    }

    private var defaultTemporalConsistencySelection: Binding<Bool> {
        Binding(
            get: {
                viewModel.persistedDefaults
                    .temporalConsistencyEnabled
            },
            set: { viewModel.setDefaultTemporalConsistency($0) }
        )
    }

    private var defaultEdgeFidelitySelection:
        Binding<MirmirAdjustmentLevel> {
        Binding(
            get: { viewModel.persistedDefaults.edgeFidelityLevel },
            set: { viewModel.selectDefaultEdgeFidelity($0) }
        )
    }

    private var defaultDetailRecoverySelection:
        Binding<MirmirAdjustmentLevel> {
        Binding(
            get: { viewModel.persistedDefaults.detailRecoveryLevel },
            set: { viewModel.selectDefaultDetailRecovery($0) }
        )
    }

    private var defaultEdgePreservationSelection: Binding<Bool> {
        Binding(
            get: {
                viewModel.persistedDefaults.effects
                    .edgePreservationEnabled
            },
            set: { viewModel.setDefaultEdgePreservation($0) }
        )
    }

    private var defaultCompressionCleanupSelection: Binding<Bool> {
        Binding(
            get: {
                viewModel.persistedDefaults.effects
                    .compressionCleanupEnabled
            },
            set: { viewModel.setDefaultCompressionCleanup($0) }
        )
    }

    private var defaultTextureGrainProtectionSelection:
        Binding<Bool> {
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

    private var defaultTemporalStabilitySelection: Binding<Bool> {
        Binding(
            get: {
                viewModel.persistedDefaults.effects
                    .temporalStabilityEnabled
            },
            set: { viewModel.setDefaultTemporalStability($0) }
        )
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
                "Choose a compatible writable folder on an internal disk, "
                    + "external drive, or mounted network share. Mirmir "
                    + "verifies the required atomic file operations before "
                    + "using it."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}

struct MirmirASHPinnedNoticeIdentity: Equatable, Sendable {
    static let current = MirmirASHPinnedNoticeIdentity(
        sourceRevision: "8782886a8cca9fa63f7d44b529add6eac80a50f8",
        licenseSHA256:
            "213910e1405c0866a1200da12f1dcd5a"
            + "4f41ed3d4a82c9c78acf85e6f5f304a6",
        licenseResourceName: "ASH-Model-LICENSE",
        licenseResourceExtension: "txt",
        citation:
            "Daley, J. (2026). \"Adinkra-Stabilized Hypercube Model "
            + "(ASH Model): Canonical Computational Specification and "
            + "Reference Implementation,\" version 1.1.0."
    )

    let sourceRevision: String
    let licenseSHA256: String
    let licenseResourceName: String
    let licenseResourceExtension: String
    let citation: String
}

private final class MirmirAboutResourceBundleToken: NSObject {}

struct MirmirAboutView: View {
    static let productSummary =
        "Mirmir upscales local videos supported by AVFoundation "
        + "through 2160p with Auto, Quality, Fast, Deterministic, "
        + "or Smooth Motion processing. It preserves supported "
        + "8- and 10-bit SDR, BT.2020 PQ and HLG HDR, and HEVC "
        + "alpha video; applies the selected fidelity and cleanup "
        + "effects; preserves compatible AAC, Apple Lossless, and "
        + "Linear PCM audio, "
        + "subtitles, closed captions, timecode, and metadata; and "
        + "reopens every completed file for verification before "
        + "atomic publication."

    static let routingTechnicalSummary =
        "With Automatic engine selection, Auto, Quality, and Fast "
        + "use ASH content and resource analysis to select among "
        + "available Apple-native routes for each frame. "
        + "Deterministic locks the processing route to MPS Lanczos."

    static let identityTechnicalSummary =
        "Completed output records the routes and fallbacks actually "
        + "used, model readiness, source format, and effect configuration."

    static let ashNoticeIdentity = MirmirASHPinnedNoticeIdentity.current

    static let ashAcknowledgement =
        "Mirmir incorporates computational assets from ASH Model "
        + "version 1.1.0 by James Daley. The exact pinned license is "
        + "bundled with Mirmir as ASH-Model-LICENSE.txt."

    static let ashCitation = ashNoticeIdentity.citation
    static let ashSourceRevision = ashNoticeIdentity.sourceRevision

    static let ashLicenseURL = URL(
        string: "https://github.com/flynn33/ASH-Model/blob/"
            + ashSourceRevision
            + "/LICENSE"
    )

    static let ashSourceURL = URL(
        string: "https://github.com/flynn33/ASH-Model/tree/"
            + ashSourceRevision
    )

    static let bundledASHLicenseURL: URL? = {
        if let licenseURL = Bundle.main.url(
            forResource: ashNoticeIdentity.licenseResourceName,
            withExtension: ashNoticeIdentity.licenseResourceExtension
        ) {
            return licenseURL
        }
        return Bundle(for: MirmirAboutResourceBundleToken.self).url(
            forResource: ashNoticeIdentity.licenseResourceName,
            withExtension: ashNoticeIdentity.licenseResourceExtension
        )
    }()

    static let bundledASHLicenseText: String = {
        guard let licenseURL = bundledASHLicenseURL,
              let text = try? String(
                  contentsOf: licenseURL,
                  encoding: .utf8
              ) else {
            return "The bundled ASH Model license could not be read. "
                + "Reinstall Mirmir to restore the required legal notice."
        }
        return text
    }()

    @ObservedObject var viewModel: MirmirViewModel
    let showsTechnicalDetails: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Mirmir")
                .font(.title2.weight(.semibold))
            Text(Self.productSummary)
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
                Text(Self.routingTechnicalSummary)
                Text(Self.identityTechnicalSummary)
                Text(viewModel.engineReadinessText)
            }

            Divider()
            Text("Acknowledgements & Licenses")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
                .accessibilityLabel("Acknowledgements & Licenses")
            Text(Self.ashAcknowledgement)
                .fixedSize(horizontal: false, vertical: true)
            Text(Self.ashCitation)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Text("ASH Model source revision: \(Self.ashSourceRevision)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            DisclosureGroup("Bundled ASH Model License") {
                ScrollView {
                    Text(Self.bundledASHLicenseText)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(
                            maxWidth: .infinity,
                            alignment: .leading
                        )
                }
                .frame(minHeight: 120, maxHeight: 240)
            }
            .accessibilityLabel("Bundled ASH Model License")

            if let ashLicenseURL = Self.ashLicenseURL {
                Link(
                    "View pinned ASH Model license online",
                    destination: ashLicenseURL
                )
                .accessibilityLabel(
                    "View pinned ASH Model license online"
                )
            }

            if let ashSourceURL = Self.ashSourceURL {
                Link(
                    "View pinned ASH Model source",
                    destination: ashSourceURL
                )
                .accessibilityLabel("View pinned ASH Model source")
            }

            Spacer()
        }
        .padding(20)
    }
}

struct MirmirStartupDiagnosticSettingsView: View {
    let store: MirmirDiagnosticStore
    let reason: String

    var body: some View {
        VStack(spacing: 0) {
            startupFailureContext
                .padding([.horizontal, .top], 20)

            MirmirDiagnosticSettingsView(store: store)
        }
    }

    private var startupFailureContext: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Label(
                    "Mirmir could not finish starting. "
                        + "Diagnostic logging remains available.",
                    systemImage: "exclamationmark.octagon.fill"
                )
                .font(.headline)
                .foregroundStyle(.red)

                Text(reason)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
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
            MirmirDiagnosticLogTextView(text: logDisplayText)
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

struct MirmirDiagnosticLogTextView: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = Self.makeScrollView()
        Self.update(scrollView, text: text)
        return scrollView
    }

    func updateNSView(
        _ scrollView: NSScrollView,
        context: Context
    ) {
        Self.update(scrollView, text: text)
    }

    @MainActor
    static func makeScrollView() -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        guard let textView = scrollView.documentView as? NSTextView else {
            return scrollView
        }
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.usesFindBar = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.font = NSFont.monospacedSystemFont(
            ofSize: NSFont.smallSystemFontSize,
            weight: .regular
        )
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.containerSize = NSSize(
            width: scrollView.contentSize.width,
            height: .greatestFiniteMagnitude
        )
        textView.textContainer?.widthTracksTextView = true
        textView.setAccessibilityLabel("Diagnostic records")
        return scrollView
    }

    @MainActor
    static func update(
        _ scrollView: NSScrollView,
        text: String
    ) {
        guard let textView = scrollView.documentView as? NSTextView,
              textView.string != text else {
            return
        }
        let visibleOrigin = scrollView.contentView.bounds.origin
        textView.string = text
        scrollView.contentView.scroll(to: visibleOrigin)
        scrollView.reflectScrolledClipView(scrollView.contentView)
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
