import Foundation
import CoreVideo

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
        let nsError = error as NSError
        let errorCode = persistenceErrorCode(error)
        logger.error(
            "Diagnostic \(operation, privacy: .public) failed: \(errorCode, privacy: .public); domain=\(nsError.domain, privacy: .private) code=\(nsError.code, privacy: .public)"
        )
    }

    static func persistenceErrorCode(_ error: Error) -> String {
        switch error {
        case R12ChunkCheckpointError.unsafeFilesystemEntry:
            return "unsafe_filesystem_entry"
        case R12ChunkCheckpointError.atomicWriteFailed:
            return "atomic_write_failed"
        case R12ChunkCheckpointError.durabilityRollbackFailed:
            return "durability_rollback_failed"
        case R12ChunkCheckpointError.ledgerAlreadyExists:
            return "destination_already_exists"
        case R12ChunkCheckpointError.ledgerMissing:
            return "destination_missing"
        case R12ChunkCheckpointError.ledgerSizeLimitExceeded:
            return "size_limit_exceeded"
        case is R12ChunkCheckpointError:
            return "checkpoint_filesystem_failure"
        case MirmirDiagnosticFileSystemError.unsafeEntry:
            return "unsafe_filesystem_entry"
        case MirmirDiagnosticFileSystemError.ioFailure:
            return "io_failure"
        default:
            return "unknown_persistence_failure"
        }
    }
}

struct MirmirDiagnosticResourceInput: Sendable {
    let role: String
    let url: URL
    let location: MirmirDiagnosticResourceLocation
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

    private func currentTail() -> Task<Void, Never>? {
        lock.lock()
        defer { lock.unlock() }
        return tail
    }

    func rejectedSubmissionCount() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return droppedSubmissionCount
    }

    private func submissionCompleted() {
        lock.lock()
        pendingSubmissionCount = max(pendingSubmissionCount - 1, 0)
        lock.unlock()
    }
}

struct MirmirDiagnosticRecorder: Sendable {
    let store: MirmirDiagnosticStore?
    private let submissionQueue: MirmirDiagnosticSubmissionQueue

    init(store: MirmirDiagnosticStore?) {
        self.store = store
        self.submissionQueue =
            store?.diagnosticSubmissionQueue
            ?? MirmirDiagnosticSubmissionQueue()
    }

    func enqueue(
        severity: MirmirDiagnosticSeverity,
        subsystem: String,
        operation: String,
        code: String,
        correlationID: UUID? = nil,
        job: UpscaleJob? = nil,
        source: SourceProfile? = nil,
        progress: UpscaleProgress? = nil,
        frame: FrameRecord? = nil,
        expectedFrameResolution: VideoResolution? = nil,
        resources: [MirmirDiagnosticResourceInput] = [],
        additionalFields: [MirmirDiagnosticField] = [],
        error: Error? = nil,
        fileID: String = #fileID,
        line: UInt = #line
    ) {
        guard store != nil else { return }
        let recorder = self
        submissionQueue.enqueue {
            await recorder.record(
                severity: severity,
                subsystem: subsystem,
                operation: operation,
                code: code,
                correlationID: correlationID,
                job: job,
                source: source,
                progress: progress,
                frame: frame,
                expectedFrameResolution: expectedFrameResolution,
                resources: resources,
                additionalFields: additionalFields,
                error: error,
                fileID: fileID,
                line: line
            )
        }
    }

    func record(
        severity: MirmirDiagnosticSeverity,
        subsystem: String,
        operation: String,
        code: String,
        correlationID explicitCorrelationID: UUID? = nil,
        job: UpscaleJob? = nil,
        source: SourceProfile? = nil,
        progress: UpscaleProgress? = nil,
        frame: FrameRecord? = nil,
        expectedFrameResolution: VideoResolution? = nil,
        resources: [MirmirDiagnosticResourceInput] = [],
        additionalFields: [MirmirDiagnosticField] = [],
        error: Error? = nil,
        fileID: String = #fileID,
        line: UInt = #line
    ) async {
        guard let store else { return }
        do {
            let correlationID = explicitCorrelationID
                ?? job.flatMap { UUID(uuidString: $0.identifier) }
            var fields = try Self.contextFields(
                correlationID: correlationID,
                job: job,
                source: source,
                progress: progress,
                frame: frame,
                expectedFrameResolution: expectedFrameResolution,
                resources: resources,
                additionalFields: additionalFields
            )
            if let error {
                fields.append(contentsOf: try Self.errorFields(error))
            }
            let event = try MirmirDiagnosticEvent(
                severity: severity,
                subsystem: subsystem,
                operation: operation,
                code: code,
                correlationID: correlationID,
                fields: fields,
                error: error.map(Self.errorIdentity),
                source: try MirmirDiagnosticSourceLocation(
                    fileID: fileID,
                    line: line
                )
            )
            _ = try await store.record(event)
        } catch {
            Self.reportRecordingFailure(error, operation: operation)
        }
    }

    private static func contextFields(
        correlationID: UUID?,
        job: UpscaleJob?,
        source: SourceProfile?,
        progress: UpscaleProgress?,
        frame: FrameRecord?,
        expectedFrameResolution: VideoResolution?,
        resources: [MirmirDiagnosticResourceInput],
        additionalFields: [MirmirDiagnosticField]
    ) throws -> [MirmirDiagnosticField] {
        var fields = additionalFields
        if let job {
            fields.append(contentsOf: [
                try field(
                    "target_dimensions",
                    .dimensions(
                        width: job.targetResolution.width,
                        height: job.targetResolution.height
                    )
                ),
                try field("output_codec", .identifier(job.codec.rawValue)),
                try field("requested_mode", .identifier(job.mode.rawValue)),
                try field("preserve_audio", .boolean(job.preserveAudio))
            ])
            if let correlationID {
                fields.append(contentsOf: try resourceFields(
                    [
                        MirmirDiagnosticResourceInput(
                            role: "source_video",
                            url: job.inputURL,
                            location: .userSelected
                        ),
                        MirmirDiagnosticResourceInput(
                            role: "output_video",
                            url: job.outputURL,
                            location: .userSelected
                        )
                    ],
                    correlationID: correlationID
                ))
            }
        }
        if let source {
            fields.append(contentsOf: [
                try field(
                    "presentation_dimensions",
                    .dimensions(
                        width: source.resolution.width,
                        height: source.resolution.height
                    )
                ),
                try field(
                    "coded_dimensions",
                    .dimensions(
                        width: source.codedResolution.width,
                        height: source.codedResolution.height
                    )
                ),
                try field(
                    "estimated_frame_count",
                    .unsignedInteger(UInt64(max(source.estimatedFrameCount, 0)))
                ),
                try field("has_audio", .boolean(source.hasAudio)),
                try field(
                    "frame_rate",
                    .rational(
                        numerator: boundedRationalNumerator(
                            source.frameRate,
                            denominator: 1_000
                        ),
                        denominator: 1_000
                    )
                ),
                try field(
                    "duration",
                    .durationMilliseconds(
                        boundedMilliseconds(source.durationSeconds)
                    )
                )
            ])
            if let aspect = source.pixelAspectRatio {
                fields.append(
                    try field(
                        "pixel_aspect_ratio",
                        .rational(
                            numerator: Int64(aspect.horizontalSpacing),
                            denominator: Int64(aspect.verticalSpacing)
                        )
                    )
                )
            }
            if let codecHint = source.codecHint,
               MirmirDiagnosticToken.isValid(codecHint.lowercased()) {
                fields.append(
                    try field(
                        "source_codec",
                        .identifier(codecHint.lowercased())
                    )
                )
            }
        }
        if let progress {
            fields.append(contentsOf: [
                try field(
                    "processed_frame_count",
                    .unsignedInteger(UInt64(max(progress.framesProcessed, 0)))
                ),
                try field(
                    "reported_total_frame_count",
                    .unsignedInteger(UInt64(max(progress.totalFrames, 0)))
                )
            ])
        }
        if let frame {
            let pixelBuffer = frame.pixelBuffer
            fields.append(contentsOf: [
                try field(
                    "frame_index",
                    .signedInteger(Int64(frame.frameIndex))
                ),
                try field(
                    "actual_decoded_dimensions",
                    .dimensions(
                        width: CVPixelBufferGetWidth(pixelBuffer),
                        height: CVPixelBufferGetHeight(pixelBuffer)
                    )
                ),
                try field(
                    "decoded_pixel_format",
                    .unsignedInteger(
                        UInt64(CVPixelBufferGetPixelFormatType(pixelBuffer))
                    )
                ),
                try field(
                    "decoded_plane_count",
                    .unsignedInteger(
                        UInt64(CVPixelBufferGetPlaneCount(pixelBuffer))
                    )
                )
            ])
        }
        if let expectedFrameResolution {
            fields.append(
                try field(
                    "expected_normalized_dimensions",
                    .dimensions(
                        width: expectedFrameResolution.width,
                        height: expectedFrameResolution.height
                    )
                )
            )
        }
        if let correlationID {
            fields.append(
                contentsOf: try resourceFields(
                    resources,
                    correlationID: correlationID
                )
            )
        }
        return fields
    }

    private static func resourceFields(
        _ resources: [MirmirDiagnosticResourceInput],
        correlationID: UUID
    ) throws -> [MirmirDiagnosticField] {
        try resources.map { resource in
            try field(
                resource.role,
                .resource(
                    MirmirDiagnosticResourceReference(
                        role: resource.role,
                        correlationID: correlationID,
                        fileExtension: safeFileExtension(resource.url),
                        location: resource.location
                    )
                )
            )
        }
    }

    private static func errorFields(
        _ error: Error
    ) throws -> [MirmirDiagnosticField] {
        let category = errorCategory(error)
        var fields = [
            try field("failure_category", .identifier(category))
        ]
        fields.append(contentsOf: try backendFailureFields(error))
        if case let R03NV12ScalingError.invalidDimensions(
            expectedWidth,
            expectedHeight,
            actualWidth,
            actualHeight
        ) = error {
            fields.append(contentsOf: [
                try field(
                    "error_expected_dimensions",
                    .dimensions(
                        width: expectedWidth,
                        height: expectedHeight
                    )
                ),
                try field(
                    "error_actual_dimensions",
                    .dimensions(
                        width: actualWidth,
                        height: actualHeight
                    )
                )
            ])
        }
        if case let R03NV12ScalingError.invalidPixelFormat(
            expected,
            actual
        ) = error {
            fields.append(contentsOf: [
                try field(
                    "expected_pixel_format",
                    .unsignedInteger(UInt64(expected))
                ),
                try field(
                    "actual_pixel_format",
                    .unsignedInteger(UInt64(actual))
                )
            ])
        }
        if case let R03NV12ScalingError.invalidPlaneCount(
            expected,
            actual
        ) = error {
            fields.append(contentsOf: [
                try field(
                    "expected_plane_count",
                    .unsignedInteger(UInt64(max(expected, 0)))
                ),
                try field(
                    "actual_plane_count",
                    .unsignedInteger(UInt64(max(actual, 0)))
                )
            ])
        }
        if case let MediaPipelineError.unsupportedAudioTrackCount(count) = error {
            fields.append(
                try field(
                    "observed_audio_track_count",
                    .unsignedInteger(UInt64(max(count, 0)))
                )
            )
        }
        if case let MediaPipelineError.unsupportedAssetDimensions(
            resolution
        ) = error {
            fields.append(
                try field(
                    "unsupported_source_dimensions",
                    .dimensions(
                        width: max(resolution.width, 0),
                        height: max(resolution.height, 0)
                    )
                )
            )
        }
        if case let AtomicMediaOutputError.invalidTransition(
            from,
            to
        ) = error {
            fields.append(contentsOf: [
                try field(
                    "output_state_from",
                    .identifier(from.rawValue)
                ),
                try field(
                    "output_state_to",
                    .identifier(to.rawValue)
                )
            ])
        }
        if case let AtomicMediaOutputError.cleanupFailed(
            _,
            attempts,
            _
        ) = error {
            fields.append(
                try field(
                    "cleanup_attempt_count",
                    .unsignedInteger(UInt64(max(attempts, 0)))
                )
            )
        }
        if case let R13ReleaseHardeningError.diskReservationExceeded(
            requestedBytes,
            remainingBytes
        ) = error {
            fields.append(contentsOf: [
                try field(
                    "requested_bytes",
                    .byteCount(requestedBytes)
                ),
                try field(
                    "remaining_bytes",
                    .byteCount(remainingBytes)
                )
            ])
        }
        if case let R13ReleaseHardeningError.outputFrameCountMismatch(
            expected,
            actual
        ) = error {
            fields.append(contentsOf: [
                try field(
                    "expected_frame_count",
                    .unsignedInteger(UInt64(max(expected, 0)))
                ),
                try field(
                    "actual_frame_count",
                    .unsignedInteger(UInt64(max(actual, 0)))
                )
            ])
        }
        if case let R13RestartJobError.insufficientDiskSpace(
            requiredBytes,
            availableBytes
        ) = error {
            fields.append(contentsOf: [
                try field(
                    "required_bytes",
                    .byteCount(requiredBytes)
                ),
                try field(
                    "available_bytes",
                    .byteCount(availableBytes)
                )
            ])
        }
        if case let R13RestartJobError.invalidFrameIndex(
            expected,
            actual
        ) = error {
            fields.append(contentsOf: [
                try field(
                    "expected_frame_index",
                    .signedInteger(Int64(expected))
                ),
                try field(
                    "actual_frame_index",
                    .signedInteger(Int64(actual))
                )
            ])
        }
        if case let R13RestartJobError.invalidOutputGeometry(
            width,
            height
        ) = error {
            fields.append(contentsOf: [
                try field(
                    "invalid_output_width",
                    .signedInteger(Int64(width))
                ),
                try field(
                    "invalid_output_height",
                    .signedInteger(Int64(height))
                )
            ])
        }
        return fields
    }

    private static func backendFailureFields(
        _ error: Error
    ) throws -> [MirmirDiagnosticField] {
        guard let backendError =
            error as? R13BackendFrameProcessingError else {
            return []
        }
        var fields: [MirmirDiagnosticField] = []
        if MirmirDiagnosticToken.isValid(backendError.failure.reason) {
            fields.append(
                try field(
                    "backend_failure_reason",
                    .identifier(backendError.failure.reason)
                )
            )
        }
        guard let context = backendError.failure.context else {
            return fields
        }
        fields.append(
            try field(
                "backend_failure_stage",
                .identifier(context.stage.rawValue)
            )
        )
        if let statusCode = context.statusCode {
            fields.append(
                try field(
                    "backend_status_code",
                    .signedInteger(Int64(statusCode))
                )
            )
        }
        if let planeIndex = context.planeIndex {
            fields.append(
                try field(
                    "backend_plane_index",
                    .signedInteger(Int64(planeIndex))
                )
            )
        }
        return fields
    }

    private static func errorIdentity(
        _ error: Error
    ) -> MirmirDiagnosticErrorIdentity {
        MirmirDiagnosticErrorIdentity(
            errors: [error] + underlyingErrors(error)
        )
    }

    private static func underlyingErrors(_ error: Error) -> [Error] {
        switch error {
        case let MediaPipelineError.readerCreationFailed(_, underlying):
            return underlying.map { [$0] } ?? []
        case let MediaPipelineError.writerCreationFailed(_, underlying):
            return underlying.map { [$0] } ?? []
        case let MediaPipelineError.outputPreparationFailed(_, underlying):
            return [underlying]
        case let MediaPipelineError.audioBridgeFailed(underlying):
            return [underlying]
        case let MediaPipelineError.readerFailed(underlying):
            return underlying.map { [$0] } ?? []
        case let MediaPipelineError.writerFailed(underlying):
            return underlying.map { [$0] } ?? []
        case let backendError as R13BackendFrameProcessingError:
            return [backendError.failure]
        default:
            return []
        }
    }

    private static func errorCategory(_ error: Error) -> String {
        switch error {
        case is R13BackendFrameProcessingError:
            return "backend_frame_processing_failed"
        case R03NV12ScalingError.invalidDimensions:
            return "invalid_dimensions"
        case R03NV12ScalingError.invalidPixelFormat:
            return "invalid_pixel_format"
        case R03NV12ScalingError.invalidPlaneCount:
            return "invalid_plane_count"
        case R03NV12ScalingError.invalidPlaneDimensions:
            return "invalid_plane_dimensions"
        case R03NV12ScalingError.colorDescriptionMismatch:
            return "color_description_mismatch"
        case R03NV12ScalingError.colorAttachmentMismatch:
            return "color_attachment_mismatch"
        case R03NV12ScalingError.pixelBufferLockFailed:
            return "pixel_buffer_lock_failed"
        case R03NV12ScalingError.missingPlaneBaseAddress:
            return "missing_plane_base_address"
        case R03NV12ScalingError.scalingFailed:
            return "scaling_failed"
        case R03NV12ScalingError.runtimeUnavailable:
            return "scaling_runtime_unavailable"
        case R03NV12ScalingError.operationCancelled:
            return "operation_cancelled"
        case MediaPipelineError.noVideoTrack:
            return "no_video_track"
        case MediaPipelineError.readerCreationFailed:
            return "reader_creation_failed"
        case MediaPipelineError.writerCreationFailed:
            return "writer_creation_failed"
        case MediaPipelineError.inputOutputCollision:
            return "input_output_collision"
        case MediaPipelineError.cannotAddReaderOutput:
            return "reader_output_rejected"
        case MediaPipelineError.cannotAddWriterInput:
            return "writer_input_rejected"
        case MediaPipelineError.unsupportedAudioTrackCount:
            return "unsupported_audio_track_count"
        case MediaPipelineError.unsupportedAudioFormat:
            return "unsupported_audio_format"
        case MediaPipelineError.unsupportedOutputContainer:
            return "unsupported_output_container"
        case MediaPipelineError.unsupportedColorProfile:
            return "unsupported_color_profile"
        case MediaPipelineError.outputPreparationFailed:
            return "output_preparation_failed"
        case MediaPipelineError.outputVerificationFailed:
            return "output_verification_failed"
        case MediaPipelineError.invalidFrameTiming:
            return "invalid_frame_timing"
        case MediaPipelineError.partialCleanupFailed:
            return "partial_cleanup_failed"
        case MediaPipelineError.readerStartFailed:
            return "reader_start_failed"
        case MediaPipelineError.writerStartFailed:
            return "writer_start_failed"
        case MediaPipelineError.outputMetadataMismatch:
            return "output_metadata_mismatch"
        case MediaPipelineError.invalidAssetDimensions:
            return "invalid_asset_dimensions"
        case MediaPipelineError.unsupportedAssetDimensions:
            return "unsupported_asset_dimensions"
        case MediaPipelineError.audioBridgeFailed:
            return "audio_bridge_failed"
        case MediaPipelineError.readerFailed:
            return "reader_failed"
        case MediaPipelineError.writerFailed:
            return "writer_failed"
        case UpscalerEngineError.jobAlreadyRunning:
            return "job_already_running"
        case UpscalerEngineError.cancelled:
            return "job_cancelled"
        case UpscalerEngineError.inputOutputCollision:
            return "input_output_collision"
        case UpscalerEngineError.invalidJobIdentifier:
            return "invalid_job_identifier"
        case UpscalerEngineError.backendUnavailable:
            return "backend_unavailable"
        case UpscalerEngineError.modeUnavailable:
            return "mode_unavailable"
        case UpscalerEngineError.modelAssetsNotReady:
            return "model_assets_not_ready"
        case UpscalerEngineError.unsupportedSourceResolution:
            return "unsupported_source_resolution"
        case UpscalerEngineError.strategyFailed:
            return "strategy_failed"
        case AtomicMediaOutputError.invalidDestination:
            return "invalid_output_destination"
        case AtomicMediaOutputError.destinationAlreadyExists:
            return "output_destination_exists"
        case AtomicMediaOutputError.invalidTemporaryIdentifier:
            return "invalid_temporary_identifier"
        case AtomicMediaOutputError.invalidTransition:
            return "invalid_output_state_transition"
        case AtomicMediaOutputError.temporaryFileMissing:
            return "temporary_output_missing"
        case AtomicMediaOutputError.verifiedTemporaryFileChanged:
            return "verified_output_changed"
        case AtomicMediaOutputError.publishedDestinationCleanupFailed:
            return "published_output_cleanup_failed"
        case AtomicMediaOutputError.publishFailed:
            return "output_publish_failed"
        case AtomicMediaOutputError.cleanupFailed:
            return "temporary_output_cleanup_failed"
        case R13ReleaseHardeningError.resourceRejected:
            return "resource_rejected"
        case R13ReleaseHardeningError.resourceProbeFailed:
            return "resource_probe_failed"
        case R13ReleaseHardeningError.injectedFault:
            return "injected_fault"
        case R13ReleaseHardeningError.resourceLeaseUnavailable:
            return "resource_lease_unavailable"
        case R13ReleaseHardeningError.diskReservationExceeded:
            return "disk_reservation_exceeded"
        case R13ReleaseHardeningError.outputFrameCountMismatch:
            return "output_frame_count_mismatch"
        case R13ReleaseHardeningError.arithmeticOverflow:
            return "resource_arithmetic_overflow"
        case R13CacheLocationError.invalidDirectory:
            return "invalid_cache_directory"
        case R13CacheLocationError.bookmarkCreationFailed:
            return "cache_bookmark_creation_failed"
        case R13CacheLocationError.bookmarkResolutionFailed:
            return "cache_bookmark_resolution_failed"
        case R13CacheLocationError.securityScopeDenied:
            return "cache_security_scope_denied"
        case R13CacheLocationError.locationUnavailable:
            return "cache_location_unavailable"
        case R13CacheLocationError.locationNotWritable:
            return "cache_location_not_writable"
        case R13CacheLocationError.configurationCorrupt:
            return "cache_configuration_corrupt"
        case R13CacheLocationError.changeWhileJobRunning:
            return "cache_change_while_job_running"
        case R13RestartJobError.invalidIdentity:
            return "restart_invalid_identity"
        case R13RestartJobError.invalidSHA256:
            return "restart_invalid_sha256"
        case R13RestartJobError.invalidSourceByteCount:
            return "restart_invalid_source_byte_count"
        case R13RestartJobError.invalidFrameCount:
            return "restart_invalid_frame_count"
        case R13RestartJobError.invalidFrameIndex:
            return "restart_invalid_frame_index"
        case R13RestartJobError.invalidOutputGeometry:
            return "restart_invalid_output_geometry"
        case R13RestartJobError.invalidPixelFormat:
            return "restart_invalid_pixel_format"
        case R13RestartJobError.invalidRelativePath:
            return "restart_invalid_relative_path"
        case R13RestartJobError.invalidByteCount:
            return "restart_invalid_byte_count"
        case R13RestartJobError.jobAlreadyExists:
            return "restart_job_already_exists"
        case R13RestartJobError.jobMissing:
            return "restart_job_missing"
        case R13RestartJobError.initializationCleanupFailed:
            return "restart_initialization_cleanup_failed"
        case R13RestartJobError.immutableCoreMismatch:
            return "restart_immutable_core_mismatch"
        case R13RestartJobError.sourceDrift:
            return "restart_source_drift"
        case R13RestartJobError.staleHead:
            return "restart_stale_head"
        case R13RestartJobError.nonCanonicalDocument:
            return "restart_noncanonical_document"
        case R13RestartJobError.schemaMismatch:
            return "restart_schema_mismatch"
        case R13RestartJobError.recordChainMismatch:
            return "restart_record_chain_mismatch"
        case R13RestartJobError.headMismatch:
            return "restart_head_mismatch"
        case R13RestartJobError.cachedFrameMissing:
            return "restart_cached_frame_missing"
        case R13RestartJobError.cachedFrameCorrupt:
            return "restart_cached_frame_corrupt"
        case R13RestartJobError.cachedFrameGeometryMismatch:
            return "restart_cached_frame_geometry_mismatch"
        case R13RestartJobError.incompleteJob:
            return "restart_incomplete_job"
        case R13RestartJobError.prepublicationReceiptConflict:
            return "restart_prepublication_receipt_conflict"
        case R13RestartJobError.reauthorizationRequired:
            return "restart_reauthorization_required"
        case R13RestartJobError.bookmarkResolutionFailed:
            return "restart_bookmark_resolution_failed"
        case R13RestartJobError.securityScopeDenied:
            return "restart_security_scope_denied"
        case R13RestartJobError.insufficientDiskSpace:
            return "restart_insufficient_disk_space"
        case R13RestartJobError.arithmeticOverflow:
            return "restart_arithmetic_overflow"
        case R13RestartJobError.unsafeFilesystemEntry:
            return "restart_unsafe_filesystem_entry"
        case R13RestartJobError.fileTooLarge:
            return "restart_file_too_large"
        case R13RestartJobError.ioFailure:
            return "restart_io_failure"
        default:
            return "unclassified_error"
        }
    }

    private static func boundedRationalNumerator(
        _ value: Double,
        denominator: Int64
    ) -> Int64 {
        guard value.isFinite, value > 0 else { return 0 }
        let upperBound = Double(Int64.max) / Double(denominator)
        guard value < upperBound else { return Int64.max }
        return Int64((value * Double(denominator)).rounded())
    }

    private static func boundedMilliseconds(_ seconds: Double) -> UInt64 {
        guard seconds.isFinite, seconds > 0 else { return 0 }
        let upperBound = Double(Int64.max) / 1_000
        guard seconds < upperBound else { return UInt64(Int64.max) }
        return UInt64((seconds * 1_000).rounded())
    }

    private static func safeFileExtension(_ url: URL) -> String? {
        let candidate = url.pathExtension.lowercased()
        guard MirmirDiagnosticToken.isValid(candidate) else {
            return nil
        }
        return candidate
    }

    private static func field(
        _ key: String,
        _ value: MirmirDiagnosticFieldValue
    ) throws -> MirmirDiagnosticField {
        try MirmirDiagnosticField(key: key, value: value)
    }

    private static func reportRecordingFailure(
        _ error: Error,
        operation: String
    ) {
        let identity = MirmirDiagnosticErrorIdentity(error)
        let frame = identity.frames.first
        MirmirDiagnosticStore.logger.error(
            "Diagnostic event \(operation, privacy: .public) was not persisted; domain=\(frame?.domain ?? "untrusted", privacy: .private) code=\(frame?.code ?? 0, privacy: .public)"
        )
    }
}
