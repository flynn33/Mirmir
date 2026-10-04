import CoreMedia
import CoreVideo
import Darwin
import Foundation

extension MirmirDiagnosticStore {
    static func persistenceBoundary<T>(
        operation: String,
        _ body: () throws -> T
    ) throws -> T {
        do {
            return try body()
        } catch let error as MirmirDiagnosticStoreError {
            throw error
        } catch {
            reportPersistenceFailure(error, operation: operation)
            throw MirmirDiagnosticStoreError.persistenceFailure(
                operation: operation
            )
        }
    }

    static func reportPersistenceFailure(
        _ error: Error,
        operation: String
    ) {
        let identity = error as NSError
        logger.error(
            "Diagnostic \(operation, privacy: .public) failed; domain=\(identity.domain, privacy: .public) code=\(identity.code, privacy: .public)"
        )
    }
}

struct MirmirDiagnosticExecutionContext: Equatable, Sendable {
    let jobID: String
    let workflowID: String
    let queueItemID: String
}

struct MirmirDiagnosticProcessingContext: Sendable {
    let request: UpscaleRequest
    let source: VideoInfo
    let actualBackendID: UpscaleBackendID
    let fallbackOccurred: Bool
    let effectiveSourceAttributes: PixelBufferAttributes
    let effectiveDestinationAttributes: PixelBufferAttributes
    let durable: MirmirDiagnosticDurableContext
    let audio: MirmirDiagnosticAudioContext
}

enum MirmirDiagnosticScope {
    @TaskLocal static var executionContext: MirmirDiagnosticExecutionContext?
    @TaskLocal static var processingContext: MirmirDiagnosticProcessingContext?
    @TaskLocal static var recorder = MirmirDiagnosticRecorder.application
}

struct MirmirDiagnosticTimingContext: Sendable {
    var nominalFrameDuration: CMTime?
    var sampleIndex: Int64?
    var observedPresentationTime: CMTime?
    var expectedPresentationTime: CMTime?
    var observedDuration: CMTime?
    var expectedDuration: CMTime?
    var siteID: String?
    var exactBoundary: CMTime?
    var admittedBoundary: CMTime?
    var clockTimescale: CMTimeScale?

    init(
        nominalFrameDuration: CMTime? = nil,
        sampleIndex: Int64? = nil,
        observedPresentationTime: CMTime? = nil,
        expectedPresentationTime: CMTime? = nil,
        observedDuration: CMTime? = nil,
        expectedDuration: CMTime? = nil,
        siteID: String? = nil,
        exactBoundary: CMTime? = nil,
        admittedBoundary: CMTime? = nil,
        clockTimescale: CMTimeScale? = nil
    ) {
        self.nominalFrameDuration = nominalFrameDuration
        self.sampleIndex = sampleIndex
        self.observedPresentationTime = observedPresentationTime
        self.expectedPresentationTime = expectedPresentationTime
        self.observedDuration = observedDuration
        self.expectedDuration = expectedDuration
        self.siteID = siteID
        self.exactBoundary = exactBoundary
        self.admittedBoundary = admittedBoundary
        self.clockTimescale = clockTimescale
    }
}

struct MirmirDiagnosticDurableContext: Sendable {
    var nextInputSampleIndex: Int64?
    var segmentOrdinal: Int?
    var segmentCount: Int?
    var isComplete: Bool?
    var checkpointSchema: String?
    var publishAttempted: Bool?
    var atomicPublicationFailed: Bool?
    var checkpointURL: URL?

    init(
        nextInputSampleIndex: Int64? = nil,
        segmentOrdinal: Int? = nil,
        segmentCount: Int? = nil,
        isComplete: Bool? = nil,
        checkpointSchema: String? = nil,
        publishAttempted: Bool? = nil,
        atomicPublicationFailed: Bool? = nil,
        checkpointURL: URL? = nil
    ) {
        self.nextInputSampleIndex = nextInputSampleIndex
        self.segmentOrdinal = segmentOrdinal
        self.segmentCount = segmentCount
        self.isComplete = isComplete
        self.checkpointSchema = checkpointSchema
        self.publishAttempted = publishAttempted
        self.atomicPublicationFailed = atomicPublicationFailed
        self.checkpointURL = checkpointURL
    }
}

struct MirmirDiagnosticAudioContext: Sendable {
    var openedTrackCount: Int
    var codecs: [String]
    var alternateGroupFlags: [Bool]
    var readerDrainMode: String

    init(
        openedTrackCount: Int,
        codecs: [String],
        alternateGroupFlags: [Bool],
        readerDrainMode: String
    ) {
        self.openedTrackCount = openedTrackCount
        self.codecs = codecs
        self.alternateGroupFlags = alternateGroupFlags
        self.readerDrainMode = readerDrainMode
    }
}

final class MirmirDiagnosticSubmissionQueue: @unchecked Sendable {
    private static let maximumPendingSubmissions = 1_024

    private let lock = NSLock()
    private var tail: Task<Void, Never>?
    private var pendingSubmissionCount = 0
    private var droppedSubmissionCount: UInt64 = 0

    @discardableResult
    func enqueue(
        _ operation: @escaping @Sendable () async -> Void
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard pendingSubmissionCount < Self.maximumPendingSubmissions else {
            if droppedSubmissionCount < UInt64.max {
                droppedSubmissionCount += 1
            }
            MirmirDiagnosticStore.logger.warning(
                "Diagnostic submission queue reached its bounded capacity"
            )
            return false
        }
        pendingSubmissionCount += 1
        let predecessor = tail
        tail = Task.detached(priority: .utility) { [weak self] in
            _ = await predecessor?.result
            await operation()
            self?.submissionCompleted()
        }
        return true
    }

    func flush() async {
        _ = await currentTail()?.result
    }

    func rejectedSubmissionCount() -> UInt64 {
        lock.withLock { droppedSubmissionCount }
    }

    private func currentTail() -> Task<Void, Never>? {
        lock.withLock { tail }
    }

    private func submissionCompleted() {
        lock.withLock {
            pendingSubmissionCount = max(pendingSubmissionCount - 1, 0)
        }
    }
}

struct MirmirDiagnosticRecorder: Sendable {
    static let application = Self(store: .application)

    let store: MirmirDiagnosticStore?
    private let submissionQueue: MirmirDiagnosticSubmissionQueue

    init(store: MirmirDiagnosticStore?) {
        self.store = store
        submissionQueue = store?.diagnosticSubmissionQueue
            ?? MirmirDiagnosticSubmissionQueue()
    }

    func enqueue(
        severity: MirmirDiagnosticSeverity,
        subsystem: String,
        operation: String,
        code: String,
        correlationID: UUID? = nil,
        executionContext: MirmirDiagnosticExecutionContext? =
            MirmirDiagnosticScope.executionContext,
        fields: [MirmirDiagnosticField] = [],
        error: Error? = nil,
        fileID: String = #fileID,
        function: String = #function,
        line: UInt = #line
    ) {
        guard store != nil else { return }
        submissionQueue.enqueue {
            await record(
                severity: severity,
                subsystem: subsystem,
                operation: operation,
                code: code,
                correlationID: correlationID,
                executionContext: executionContext,
                fields: fields,
                error: error,
                fileID: fileID,
                function: function,
                line: line
            )
        }
    }

    func record(
        severity: MirmirDiagnosticSeverity,
        subsystem: String,
        operation: String,
        code: String,
        correlationID: UUID? = nil,
        executionContext: MirmirDiagnosticExecutionContext? =
            MirmirDiagnosticScope.executionContext,
        fields: [MirmirDiagnosticField] = [],
        error: Error? = nil,
        fileID: String = #fileID,
        function: String = #function,
        line: UInt = #line
    ) async {
        guard let store else { return }
        do {
            var completeFields: [MirmirDiagnosticField] = []
            if let executionContext {
                completeFields = try Self.executionFields(executionContext)
            }
            Self.appendUnique(fields, to: &completeFields)
            if let error {
                Self.appendUnique(
                    try Self.errorFields(error),
                    to: &completeFields
                )
            }
            let event = try MirmirDiagnosticEvent(
                severity: severity,
                subsystem: subsystem,
                operation: operation,
                code: code,
                correlationID: correlationID,
                fields: completeFields,
                error: error.map(MirmirDiagnosticErrorIdentity.init),
                source: try MirmirDiagnosticSourceLocation(
                    fileID: fileID,
                    function: function,
                    line: line
                )
            )
            _ = try await store.record(event)
        } catch {
            Self.reportRecordingFailure(error, operation: operation)
        }
    }

    func recordProcessingFailure(
        subsystem: String,
        operation: String,
        executionContext: MirmirDiagnosticExecutionContext? =
            MirmirDiagnosticScope.executionContext,
        request: UpscaleRequest,
        source: VideoInfo,
        actualBackendID: UpscaleBackendID,
        fallbackOccurred: Bool,
        effectiveSourceAttributes: PixelBufferAttributes? = nil,
        effectiveDestinationAttributes: PixelBufferAttributes? = nil,
        timing: MirmirDiagnosticTimingContext = .init(),
        durable: MirmirDiagnosticDurableContext = .init(),
        audio: MirmirDiagnosticAudioContext? = nil,
        error: Error,
        additionalFields: [MirmirDiagnosticField] = [],
        fileID: String = #fileID,
        function: String = #function,
        line: UInt = #line
    ) {
        do {
            var fields = try Self.processingFields(
                request: request,
                source: source,
                actualBackendID: actualBackendID,
                fallbackOccurred: fallbackOccurred,
                effectiveSourceAttributes: effectiveSourceAttributes,
                effectiveDestinationAttributes:
                    effectiveDestinationAttributes
            )
            fields.append(contentsOf: try Self.timingFields(timing))
            fields.append(contentsOf: try Self.durableFields(durable))
            if let audio {
                fields.append(contentsOf: try Self.audioFields(audio))
            }
            fields.append(contentsOf: try Self.diskFields(
                destinationURL: request.outputURL,
                checkpointURL: durable.checkpointURL
            ))
            fields.append(contentsOf: additionalFields)
            let submittedFields = fields
            let recorder = self
            submissionQueue.enqueue {
                await recorder.record(
                    severity: .error,
                    subsystem: subsystem,
                    operation: operation,
                    code: Self.failureCode(error),
                    executionContext: executionContext,
                    fields: submittedFields,
                    error: error,
                    fileID: fileID,
                    function: function,
                    line: line
                )
            }
        } catch {
            Self.reportRecordingFailure(error, operation: operation)
        }
    }

    func recordTimingFailure(
        subsystem: String,
        operation: String,
        executionContext: MirmirDiagnosticExecutionContext? =
            MirmirDiagnosticScope.executionContext,
        processingContext: MirmirDiagnosticProcessingContext?,
        timing: MirmirDiagnosticTimingContext,
        durable: MirmirDiagnosticDurableContext = .init(),
        error: Error,
        fileID: String = #fileID,
        function: String = #function,
        line: UInt = #line
    ) {
        if let processingContext {
            recordProcessingFailure(
                subsystem: subsystem,
                operation: operation,
                executionContext: executionContext,
                request: processingContext.request,
                source: processingContext.source,
                actualBackendID: processingContext.actualBackendID,
                fallbackOccurred: processingContext.fallbackOccurred,
                effectiveSourceAttributes:
                    processingContext.effectiveSourceAttributes,
                effectiveDestinationAttributes:
                    processingContext.effectiveDestinationAttributes,
                timing: timing,
                durable: durable,
                audio: processingContext.audio,
                error: error,
                fileID: fileID,
                function: function,
                line: line
            )
            return
        }

        do {
            var fields = try Self.timingFields(timing)
            fields.append(contentsOf: try Self.durableFields(durable))
            enqueue(
                severity: .error,
                subsystem: subsystem,
                operation: operation,
                code: Self.failureCode(error),
                executionContext: executionContext,
                fields: fields,
                error: error,
                fileID: fileID,
                function: function,
                line: line
            )
        } catch {
            Self.reportRecordingFailure(error, operation: operation)
        }
    }

    func recordCheckpoint(
        subsystem: String,
        operation: String,
        executionContext: MirmirDiagnosticExecutionContext?,
        durable: MirmirDiagnosticDurableContext,
        destinationURL: URL?,
        processingContext: MirmirDiagnosticProcessingContext? = nil,
        fields additionalFields: [MirmirDiagnosticField] = [],
        error: Error? = nil,
        fileID: String = #fileID,
        function: String = #function,
        line: UInt = #line
    ) {
        guard store != nil else { return }
        if error == nil,
           (subsystem == "durable_checkpoint"
                && operation == "publish_boundary")
                || (subsystem == "durable_coordinator"
                    && operation == "commit_checkpoint") {
            return
        }
        do {
            var fields = try Self.durableFields(durable)
            if let destinationURL,
               error != nil || subsystem != "workflow_application_coordinator"
                    || operation != "continue_processing" {
                fields.append(contentsOf: try Self.diskFields(
                    destinationURL: destinationURL,
                    checkpointURL: durable.checkpointURL
                ))
            }
            if let processingContext {
                fields.append(contentsOf: try Self.processingFields(
                    request: processingContext.request,
                    source: processingContext.source,
                    actualBackendID: processingContext.actualBackendID,
                    fallbackOccurred:
                        processingContext.fallbackOccurred,
                    effectiveSourceAttributes:
                        processingContext.effectiveSourceAttributes,
                    effectiveDestinationAttributes:
                        processingContext.effectiveDestinationAttributes
                ))
                fields.append(contentsOf: try Self.audioFields(
                    processingContext.audio
                ))
                fields.append(contentsOf: try Self.timeFields(
                    prefix: "nominal_frame_duration",
                    processingContext.source.minimumFrameDuration
                ))
            }
            fields.append(contentsOf: additionalFields)
            let submittedFields = fields
            let recorder = self
            submissionQueue.enqueue {
                await recorder.record(
                    severity: error == nil ? .notice : .error,
                    subsystem: subsystem,
                    operation: operation,
                    code: error.map(Self.failureCode)
                        ?? "durable_checkpoint_committed",
                    executionContext: executionContext,
                    fields: submittedFields,
                    error: error,
                    fileID: fileID,
                    function: function,
                    line: line
                )
            }
        } catch {
            Self.reportRecordingFailure(error, operation: operation)
        }
    }

    func recordJobStarted(
        executionContext: MirmirDiagnosticExecutionContext,
        request: UpscaleRequest,
        source: VideoInfo,
        actualBackendID: UpscaleBackendID,
        maximumInputFramesPerBoundary: Int,
        startingInputFrameIndex: Int
    ) {
        guard store != nil else { return }
        do {
            var fields = [
                try Self.textField("source_path", request.inputURL.path),
                try Self.textField("output_path", request.outputURL.path),
                try Self.textField("requested_backend", request.backendID.rawValue),
                try Self.textField("actual_backend", actualBackendID.rawValue),
                try Self.field("source_geometry", .dimensions(
                    width: Self.diagnosticDimension(source.displaySize.width),
                    height: Self.diagnosticDimension(source.displaySize.height)
                )),
                try Self.field("requested_geometry", .dimensions(
                    width: request.targetWidth, height: request.targetHeight
                )),
                try Self.textField("requested_output_codec", request.outputCodec.rawValue),
                try Self.field("maximum_input_frames_per_boundary", .signedInteger(
                    Int64(maximumInputFramesPerBoundary)
                )),
                try Self.field("next_input_sample_index", .signedInteger(
                    Int64(startingInputFrameIndex)
                ))
            ]
            fields.append(contentsOf: try Self.timeFields(
                prefix: "source_frame_duration", source.minimumFrameDuration
            ))
            fields.append(contentsOf: try Self.timeFields(
                prefix: "source_duration", source.duration
            ))
            enqueue(
                severity: .notice,
                subsystem: "workflow_application_coordinator",
                operation: "prepare_job",
                code: startingInputFrameIndex == 0
                    ? "workflow_job_started" : "workflow_job_resumed",
                executionContext: executionContext,
                fields: fields
            )
        } catch {
            Self.reportRecordingFailure(error, operation: "prepare_job")
        }
    }

    static func performanceFields(
        elapsedNanoseconds: UInt64,
        processingDurationSeconds: TimeInterval,
        completedInputFrames: Int,
        sourceAuthenticationNanoseconds: UInt64 = 0,
        segmentProcessingNanoseconds: UInt64 = 0,
        checkpointCommitNanoseconds: UInt64 = 0
    ) throws -> [MirmirDiagnosticField] {
        var fields = [
            try field("run_elapsed_ms", .durationMilliseconds(
                elapsedNanoseconds / 1_000_000
            )),
            try field("completed_input_frames", .signedInteger(
                Int64(completedInputFrames)
            )),
            try field("source_authentication_ms", .durationMilliseconds(
                sourceAuthenticationNanoseconds / 1_000_000
            )),
            try field("segment_processing_ms", .durationMilliseconds(
                segmentProcessingNanoseconds / 1_000_000
            )),
            try field("checkpoint_commit_ms", .durationMilliseconds(
                checkpointCommitNanoseconds / 1_000_000
            ))
        ]
        let processingMilliseconds = processingDurationSeconds * 1_000
        if processingMilliseconds.isFinite,
           processingMilliseconds >= 0,
           processingMilliseconds < Double(UInt64.max) {
            fields.append(try field("processing_duration_ms", .durationMilliseconds(
                UInt64(processingMilliseconds)
            )))
        }
        if elapsedNanoseconds > 0 {
            let rate = Double(completedInputFrames) * 100_000_000_000
                / Double(elapsedNanoseconds)
            if rate.isFinite, rate >= 0, rate < Double(UInt64.max) {
                fields.append(try field("frames_per_second_hundredths", .unsignedInteger(
                    UInt64(rate.rounded())
                )))
            }
        }
        return fields
    }

    func recordProgress(
        executionContext: MirmirDiagnosticExecutionContext,
        durable: MirmirDiagnosticDurableContext,
        elapsedNanoseconds: UInt64,
        processingDurationSeconds: TimeInterval,
        completedInputFrames: Int,
        sourceAuthenticationNanoseconds: UInt64,
        segmentProcessingNanoseconds: UInt64,
        checkpointCommitNanoseconds: UInt64
    ) {
        guard store != nil else { return }
        do {
            let fields = try Self.performanceFields(
                elapsedNanoseconds: elapsedNanoseconds,
                processingDurationSeconds: processingDurationSeconds,
                completedInputFrames: completedInputFrames,
                sourceAuthenticationNanoseconds: sourceAuthenticationNanoseconds,
                segmentProcessingNanoseconds: segmentProcessingNanoseconds,
                checkpointCommitNanoseconds: checkpointCommitNanoseconds
            )
            recordCheckpoint(
                subsystem: "workflow_application_coordinator",
                operation: "continue_processing",
                executionContext: executionContext,
                durable: durable,
                destinationURL: nil,
                fields: fields
            )
        } catch {
            Self.reportRecordingFailure(error, operation: "continue_processing")
        }
    }

    static func field(
        _ key: String,
        _ value: MirmirDiagnosticFieldValue
    ) throws -> MirmirDiagnosticField {
        try MirmirDiagnosticField(key: key, value: value)
    }

    static func textField(
        _ key: String,
        _ value: String
    ) throws -> MirmirDiagnosticField {
        try field(key, .text(value))
    }

    static func timeFields(
        prefix: String,
        _ time: CMTime?
    ) throws -> [MirmirDiagnosticField] {
        guard let time else { return [] }
        return [
            try field(
                "\(prefix)_value",
                .signedInteger(time.value)
            ),
            try field(
                "\(prefix)_timescale",
                .signedInteger(Int64(time.timescale))
            ),
            try field(
                "\(prefix)_epoch",
                .signedInteger(time.epoch)
            ),
            try field(
                "\(prefix)_flags",
                .unsignedInteger(UInt64(time.flags.rawValue))
            )
        ]
    }

    private static func appendUnique(
        _ additions: [MirmirDiagnosticField],
        to fields: inout [MirmirDiagnosticField]
    ) {
        var keys = Set(fields.map(\.key))
        for field in additions where keys.insert(field.key).inserted {
            fields.append(field)
        }
    }

    private static func executionFields(
        _ context: MirmirDiagnosticExecutionContext
    ) throws -> [MirmirDiagnosticField] {
        [
            try textField("job_id", context.jobID),
            try textField("workflow_id", context.workflowID),
            try textField("queue_item_id", context.queueItemID)
        ]
    }

    private static func processingFields(
        request: UpscaleRequest,
        source: VideoInfo,
        actualBackendID: UpscaleBackendID,
        fallbackOccurred: Bool,
        effectiveSourceAttributes: PixelBufferAttributes?,
        effectiveDestinationAttributes: PixelBufferAttributes?
    ) throws -> [MirmirDiagnosticField] {
        let effectiveWidth = pixelBufferInteger(
            kCVPixelBufferWidthKey,
            in: effectiveDestinationAttributes
        ) ?? request.targetWidth
        let effectiveHeight = pixelBufferInteger(
            kCVPixelBufferHeightKey,
            in: effectiveDestinationAttributes
        ) ?? request.targetHeight
        var fields = [
            try textField("source_path", request.inputURL.path),
            try textField("output_path", request.outputURL.path),
            try textField("requested_backend", request.backendID.rawValue),
            try textField("actual_backend", actualBackendID.rawValue),
            try field("fallback_occurred", .boolean(fallbackOccurred)),
            try field(
                "source_geometry",
                .dimensions(
                    width: diagnosticDimension(source.displaySize.width),
                    height: diagnosticDimension(source.displaySize.height)
                )
            ),
            try field(
                "requested_geometry",
                .dimensions(
                    width: request.targetWidth,
                    height: request.targetHeight
                )
            ),
            try field(
                "effective_geometry",
                .dimensions(
                    width: effectiveWidth,
                    height: effectiveHeight
                )
            ),
            try textField(
                "requested_output_codec",
                request.outputCodec.rawValue
            ),
            try textField(
                "effective_output_codec",
                request.outputCodec.rawValue
            ),
            try textField(
                "requested_color_policy",
                "preserve_source"
            ),
            try textField(
                "requested_hdr_policy",
                "preserve_source"
            ),
            try textField(
                "source_color_primaries",
                source.color.colorPrimaries ?? "unknown"
            ),
            try textField(
                "effective_color_primaries",
                source.color.colorPrimaries ?? "unknown"
            ),
            try textField(
                "source_transfer_function",
                source.color.transferFunction ?? "unknown"
            ),
            try textField(
                "effective_transfer_function",
                source.color.transferFunction ?? "unknown"
            ),
            try textField(
                "source_ycbcr_matrix",
                source.color.yCbCrMatrix ?? "unknown"
            ),
            try textField(
                "effective_ycbcr_matrix",
                source.color.yCbCrMatrix ?? "unknown"
            ),
            try textField(
                "source_dynamic_range",
                source.color.dynamicRange.rawValue
            ),
            try textField(
                "effective_dynamic_range",
                source.color.dynamicRange.rawValue
            ),
            try field(
                "source_hdr",
                .boolean(source.color.isHDR == true)
            ),
            try field(
                "effective_hdr",
                .boolean(source.color.isHDR == true)
            ),
            try field(
                "mastering_display_metadata",
                .boolean(source.color.hasMasteringDisplayMetadata)
            ),
            try field(
                "content_light_level_metadata",
                .boolean(source.color.hasContentLightLevelMetadata)
            ),
            try field(
                "audio_track_count_probed",
                .signedInteger(Int64(source.audioTrackCount))
            )
        ]
        if let pixelFormat = source.color.pixelFormat {
            fields.append(try textField(
                "source_pixel_format",
                fourCC(pixelFormat)
            ))
        }
        if let pixelFormat = pixelBufferInteger(
            kCVPixelBufferPixelFormatTypeKey,
            in: effectiveSourceAttributes
        ) {
            fields.append(try textField(
                "effective_source_pixel_format",
                fourCC(OSType(pixelFormat))
            ))
        }
        if let pixelFormat = pixelBufferInteger(
            kCVPixelBufferPixelFormatTypeKey,
            in: effectiveDestinationAttributes
        ) {
            fields.append(try textField(
                "effective_output_pixel_format",
                fourCC(OSType(pixelFormat))
            ))
        }
        if let bitDepth = source.color.bitDepth {
            fields.append(try field(
                "source_bit_depth",
                .signedInteger(Int64(bitDepth))
            ))
        }
        fields.append(contentsOf: try timeFields(
            prefix: "nominal_frame_duration",
            source.minimumFrameDuration
        ))
        return fields
    }

    private static func pixelBufferInteger(
        _ key: CFString,
        in attributes: PixelBufferAttributes?
    ) -> Int? {
        (attributes?.values[key as String] as? NSNumber)?.intValue
    }

    private static func diagnosticDimension(_ value: CGFloat) -> Int {
        guard value.isFinite, value > 0, value <= CGFloat(Int.max) else {
            return 0
        }
        return Int(value.rounded())
    }

    private static func timingFields(
        _ timing: MirmirDiagnosticTimingContext
    ) throws -> [MirmirDiagnosticField] {
        var fields: [MirmirDiagnosticField] = []
        if let siteID = timing.siteID {
            fields.append(try textField("timing_site_id", siteID))
        }
        if let sampleIndex = timing.sampleIndex {
            fields.append(try field(
                "sample_index",
                .signedInteger(sampleIndex)
            ))
        }
        fields.append(contentsOf: try timeFields(
            prefix: "nominal_frame_duration",
            timing.nominalFrameDuration
        ))
        fields.append(contentsOf: try timeFields(
            prefix: "observed_presentation_time",
            timing.observedPresentationTime
        ))
        fields.append(contentsOf: try timeFields(
            prefix: "expected_presentation_time",
            timing.expectedPresentationTime
        ))
        fields.append(contentsOf: try timeFields(
            prefix: "observed_duration",
            timing.observedDuration
        ))
        fields.append(contentsOf: try timeFields(
            prefix: "expected_duration",
            timing.expectedDuration
        ))
        fields.append(contentsOf: try timeFields(
            prefix: "exact_boundary",
            timing.exactBoundary
        ))
        fields.append(contentsOf: try timeFields(
            prefix: "admitted_boundary",
            timing.admittedBoundary
        ))
        if let clockTimescale = timing.clockTimescale {
            fields.append(try field(
                "boundary_clock_timescale",
                .signedInteger(Int64(clockTimescale))
            ))
        }
        return fields
    }

    private static func durableFields(
        _ durable: MirmirDiagnosticDurableContext
    ) throws -> [MirmirDiagnosticField] {
        var fields: [MirmirDiagnosticField] = []
        if let value = durable.nextInputSampleIndex {
            fields.append(try field(
                "next_input_sample_index",
                .signedInteger(value)
            ))
        }
        if let value = durable.segmentOrdinal {
            fields.append(try field(
                "segment_ordinal",
                .signedInteger(Int64(value))
            ))
        }
        if let value = durable.segmentCount {
            fields.append(try field(
                "segment_count",
                .signedInteger(Int64(value))
            ))
        }
        if let value = durable.isComplete {
            fields.append(try field("is_complete", .boolean(value)))
        }
        if let value = durable.checkpointSchema {
            fields.append(try textField("checkpoint_schema", value))
        }
        if let value = durable.publishAttempted {
            fields.append(try field("publish", .boolean(value)))
        }
        if let value = durable.atomicPublicationFailed {
            fields.append(try field(
                "atomic_publication_failed",
                .boolean(value)
            ))
        }
        if let value = durable.checkpointURL {
            fields.append(try textField("checkpoint_path", value.path))
        }
        return fields
    }

    private static func audioFields(
        _ audio: MirmirDiagnosticAudioContext
    ) throws -> [MirmirDiagnosticField] {
        [
            try field(
                "audio_tracks_opened",
                .signedInteger(Int64(audio.openedTrackCount))
            ),
            try textField(
                "audio_codecs",
                audio.codecs.isEmpty
                    ? "none" : audio.codecs.joined(separator: ",")
            ),
            try textField(
                "audio_alternate_group_flags",
                audio.alternateGroupFlags.map { $0 ? "true" : "false" }
                    .joined(separator: ",")
            ),
            try textField("audio_reader_drain_mode", audio.readerDrainMode)
        ]
    }

    private static func diskFields(
        destinationURL: URL,
        checkpointURL: URL?
    ) throws -> [MirmirDiagnosticField] {
        var fields = try volumeFields(
            role: "destination",
            url: destinationURL
        )
        if let checkpointURL {
            fields.append(contentsOf: try volumeFields(
                role: "checkpoint",
                url: checkpointURL
            ))
        }
        return fields
    }

    private static func volumeFields(
        role: String,
        url: URL
    ) throws -> [MirmirDiagnosticField] {
        let existing = existingAncestor(of: url)
        let values = try? existing.resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeUUIDStringKey,
            .volumeNameKey
        ])
        var fields = [
            try textField("\(role)_volume_path", existing.path)
        ]
        if let free = values?.volumeAvailableCapacityForImportantUsage,
           free >= 0 {
            fields.append(try field(
                "\(role)_volume_free_bytes",
                .byteCount(UInt64(free))
            ))
        }
        if let uuid = values?.volumeUUIDString {
            fields.append(try textField(
                "\(role)_volume_uuid",
                uuid
            ))
        } else if let name = values?.volumeName {
            fields.append(try textField(
                "\(role)_volume_identity",
                name
            ))
        }
        return fields
    }

    private static func existingAncestor(of url: URL) -> URL {
        var candidate = url.standardizedFileURL
        var isDirectory: ObjCBool = false
        while !FileManager.default.fileExists(
            atPath: candidate.path,
            isDirectory: &isDirectory
        ), candidate.path != "/" {
            candidate.deleteLastPathComponent()
        }
        return candidate
    }

    private static func errorFields(
        _ error: Error
    ) throws -> [MirmirDiagnosticField] {
        let nsError = error as NSError
        var fields = [
            try textField("failure_kind", failureCode(error)),
            try textField("error_domain", nsError.domain),
            try field(
                "error_code",
                .signedInteger(Int64(nsError.code))
            )
        ]
        if let errno = posixErrno(error) {
            fields.append(try field(
                "errno",
                .signedInteger(Int64(errno))
            ))
        }
        if case let DeterministicV4MediaSegmentError
            .invalidSampleTiming(site) = error {
            fields.append(try textField(
                "timing_site_id",
                site.rawValue
            ))
        }
        return fields
    }

    static func failureCode(_ error: Error) -> String {
        if error is CancellationError || error as? MirmirError == .cancelled {
            return "cancelled"
        }
        if posixErrno(error) == ENOSPC {
            return "enospc"
        }
        if case WorkflowSegmentCheckpointStoreV4Error
            .atomicPublicationFailed = error {
            return "atomic_publication_failed"
        }
        if error is MirmirAtomicPublicationError {
            return "atomic_publication_failed"
        }
        if case DeterministicV4MediaSegmentError
            .invalidSampleTiming = error {
            return "invalid_sample_timing"
        }
        let description = String(reflecting: type(of: error)).lowercased()
        if description.contains("geometry")
            || description.contains("resolution") {
            return "geometry_rejected"
        }
        return "processing_failed"
    }

    static func posixErrno(_ error: Error) -> Int32? {
        var current: NSError? = error as NSError
        var observed = Set<ObjectIdentifier>()
        while let candidate = current,
              observed.insert(ObjectIdentifier(candidate)).inserted {
            if candidate.domain == NSPOSIXErrorDomain {
                return Int32(exactly: candidate.code)
            }
            if candidate.domain == NSCocoaErrorDomain,
               let underlying = candidate.userInfo[
                   NSUnderlyingErrorKey
               ] as? NSError,
               underlying.domain == NSPOSIXErrorDomain {
                return Int32(exactly: underlying.code)
            }
            current = candidate.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        if case let WorkflowSegmentCheckpointStoreV4Error
            .atomicPublicationFailed(_, code) = error {
            return code
        }
        return nil
    }

    private static func fourCC(_ value: OSType) -> String {
        let bytes: [UInt8] = [
            UInt8((value >> 24) & 0xff),
            UInt8((value >> 16) & 0xff),
            UInt8((value >> 8) & 0xff),
            UInt8(value & 0xff)
        ]
        let printable = bytes.map {
            (32...126).contains($0) ? Character(UnicodeScalar($0)) : "?"
        }
        return String(printable)
            + String(format: " (0x%08x)", value)
    }

    private static func reportRecordingFailure(
        _ error: Error,
        operation: String
    ) {
        let identity = error as NSError
        MirmirDiagnosticStore.logger.error(
            "Unable to record \(operation, privacy: .public); domain=\(identity.domain, privacy: .public) code=\(identity.code, privacy: .public)"
        )
    }
}
