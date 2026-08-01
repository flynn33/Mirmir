import AVFoundation
import CoreMedia
import Darwin
import Foundation

private struct FinalMuxSourceTrack {
    let track: AVAssetTrack
    let sourceCopyTimeRange: CMTimeRange
    let destinationStart: CMTime
    let outputTimeRange: CMTimeRange
    let segments: [AVAssetTrackSegment]
    let exactTimeScale: CMTimeScale
    let metadataFormatDescriptions: [CMFormatDescription]?
    let preservation: SourceMediaTrackPreservationPlan?
}

extension AVFoundationMediaSession {
    func finish() async throws {
        try await finish(
            finalMetadata: outputProfile.timedMetadataTemplate,
            validatingBeforePublish: {}
        )
    }

    func finish(finalMetadata: [String: String]) async throws {
        try await finish(
            finalMetadata: finalMetadata,
            validatingBeforePublish: {}
        )
    }

    func finish(
        finalMetadata: [String: String],
        validatingBeforePublish: @escaping @Sendable () async throws -> Void
    ) async throws {
        try await finish(
            finalMetadata: finalMetadata,
            beforeReopen: {},
            validatingBeforePublish: validatingBeforePublish
        )
    }

    func finish(
        finalMetadata: [String: String],
        beforeReopen: @escaping @Sendable () async throws -> Void,
        validatingBeforePublish: @escaping @Sendable () async throws -> Void
    ) async throws {
        do {
            try checkCancellation()
            try outputTransaction.beginFinishing()
            videoInput.markAsFinished()
            let timing = timingLedgerSnapshot()
            guard let sessionEndTime = timing.sessionEndTime else {
                throw MediaPipelineError.invalidFrameTiming(
                    String(describing: FrameTimingLedgerError.empty)
                )
            }
            try await finishTimedMetadata(
                finalMetadata,
                sessionEndTime: sessionEndTime
            )
            await finishWriter(at: sessionEndTime)

            try checkCancellation()
            guard writer.status == .completed else {
                if writer.status == .cancelled { throw CancellationError() }
                throw MediaPipelineError.writerFailed(writer.error)
            }
            try await assembleFinalOutput()
            try removeMigrationArtifactsAfterAssembly()
            removeStagingFileAfterAssembly()

            try await beforeReopen()
            try checkCancellation()
            try outputTransaction.beginVerifying()
            let verification = try await verifyOutput(
                timing: timing,
                finalMetadata: finalMetadata
            )
            recordVerification(verification)
            try checkCancellation()
            try await validatingBeforePublish()
            try checkCancellation()
            try publishOutput()
        } catch {
            if error is CancellationError || sessionIsCancelled() {
                cancel()
                throw CancellationError()
            }
            throw failureAfterCleanup(error)
        }
    }

    func cancel() {
        var shouldCancelResources = false
        var shouldDiscardOutput = false

        lifecycleLock.lock()
        switch lifecycleState {
        case .active:
            lifecycleState = .cancelled
            shouldCancelResources = true
            shouldDiscardOutput = true
        case .cancelled, .failed:
            shouldDiscardOutput = true
        case .committed:
            break
        }
        lifecycleLock.unlock()

        if shouldCancelResources {
            if reader.status == .reading { reader.cancelReading() }
            if writer.status == .writing { writer.cancelWriting() }
        }
        if shouldDiscardOutput {
            var stagingError: Error?
            var migrationError: Error?
            var outputCleanup: AtomicMediaOutputCleanupResult?
            finalizationResourceLock.withLock {
                stagingError = stagingFile.cleanup()
                migrationError = sourceMediaPreservation
                    .cleanupMigrationArtifacts()
                outputCleanup = outputTransaction.cancel()
            }
            if let stagingError {
                retainStagingCleanupError(stagingError)
            }
            if let migrationError {
                retainMigrationCleanupError(migrationError)
            }
            if let outputCleanup {
                retainCleanupError(outputCleanup)
            }
        }
    }

    func failureAfterCleanup(_ error: Error) -> Error {
        lifecycleLock.lock()
        if case .committed = lifecycleState {
            lifecycleLock.unlock()
            return error
        }
        lifecycleState = .failed
        lifecycleLock.unlock()

        if reader.status == .reading { reader.cancelReading() }
        if writer.status == .writing { writer.cancelWriting() }
        var stagingError: Error?
        var migrationError: Error?
        var outputCleanup: AtomicMediaOutputCleanupResult?
        finalizationResourceLock.withLock {
            stagingError = stagingFile.cleanup()
            migrationError = sourceMediaPreservation
                .cleanupMigrationArtifacts()
            outputCleanup = outputTransaction.fail()
        }
        if let stagingError {
            retainStagingCleanupError(stagingError)
        }
        if let migrationError {
            retainMigrationCleanupError(migrationError)
        }
        if let outputCleanup {
            retainCleanupError(outputCleanup)
        }
        return error
    }

    func retainCleanupError(_ cleanup: AtomicMediaOutputCleanupResult) {
        guard let cleanupError = cleanup.error else { return }
        lifecycleLock.lock()
        if storedTerminalCleanupError == nil {
            storedTerminalCleanupError = MediaPipelineError.partialCleanupFailed(
                outputTransaction.temporaryURL,
                String(describing: cleanupError)
            )
        }
        lifecycleLock.unlock()
    }

    func retainStagingCleanupError(_ error: Error) {
        lifecycleLock.lock()
        if storedTerminalCleanupError == nil {
            storedTerminalCleanupError = MediaPipelineError.partialCleanupFailed(
                stagingFile.url,
                String(describing: error)
            )
        }
        lifecycleLock.unlock()
    }

    func retainMigrationCleanupError(_ error: Error) {
        let url = sourceMediaPreservation.migrationArtifacts.first?
            .assetURL ?? outputTransaction.temporaryURL
        lifecycleLock.lock()
        if storedTerminalCleanupError == nil {
            storedTerminalCleanupError = MediaPipelineError
                .partialCleanupFailed(
                    url,
                    String(describing: error)
                )
        }
        lifecycleLock.unlock()
    }

    private func removeMigrationArtifactsAfterAssembly() throws {
        guard let error = sourceMediaPreservation
                .cleanupMigrationArtifacts() else {
            return
        }
        let url = sourceMediaPreservation.migrationArtifacts.first?
            .assetURL ?? outputTransaction.temporaryURL
        throw MediaPipelineError.partialCleanupFailed(
            url,
            String(describing: error)
        )
    }

    private func removeStagingFileAfterAssembly() {
        if let error = finalizationResourceLock.withLock({
            stagingFile.cleanup()
        }) {
            retainStagingCleanupError(error)
            telemetry.recordMedia(ASHMediaObservation(
                kind: "staging_cleanup_deferred",
                details: [
                    "reason": "owned_stage_removal_failed"
                ]
            ))
        } else {
            telemetry.recordMedia(ASHMediaObservation(
                kind: "staging_cleanup_completed",
                details: [:]
            ))
        }
    }

    private func assembleFinalOutput() async throws {
        do {
            try await assembleFinalOutputContents()
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as MediaPipelineError {
            if case .finalMuxFailed = error {
                throw error
            }
            throw MediaPipelineError.finalMuxFailed(
                outputProfile.url,
                error
            )
        } catch {
            throw MediaPipelineError.finalMuxFailed(
                outputProfile.url,
                error
            )
        }
    }

    private func assembleFinalOutputContents() async throws {
        guard !expectedCompressedAACTrackIdentities.isEmpty else {
            try await assembleFinalOutputContents(
                stagingURL: stagingFile.url
            )
            return
        }

        let finalMuxSource = try MediaPipelineStagingFile(
            finalTemporaryURL: outputTransaction.temporaryURL,
            pathExtensionOverride: stagingFile.url.pathExtension,
            role: .finalMuxSource,
            fileSystem:
                outputTransaction.fileSystemForSiblingTemporaryFiles
        )
        do {
            try finalizationResourceLock.withLock {
                try checkCancellation()
                guard !FileManager.default.fileExists(
                    atPath: finalMuxSource.url.path
                ) else {
                    throw MediaPipelineError.metadataPreservationFailed(
                        "the neutral final-mux source already exists"
                    )
                }
                try FileManager.default.copyItem(
                    at: stagingFile.url,
                    to: finalMuxSource.url
                )
                try finalMuxSource.claimCreatedFileIfNeeded()
            }
            try await assembleFinalOutputContents(
                stagingURL: finalMuxSource.url
            )
        } catch {
            if let cleanupError = finalizationResourceLock.withLock({
                finalMuxSource.cleanup()
            }) {
                throw MediaPipelineError.partialCleanupFailed(
                    finalMuxSource.url,
                    "final-mux failure: \(error); neutral source cleanup: "
                        + String(describing: cleanupError)
                )
            }
            throw error
        }
        if let cleanupError = finalizationResourceLock.withLock({
            finalMuxSource.cleanup()
        }) {
            throw MediaPipelineError.partialCleanupFailed(
                finalMuxSource.url,
                String(describing: cleanupError)
            )
        }
    }

    // Preserve the ordered inspection, cancellation, sample-copy, and header gates.
    // swiftlint:disable:next function_body_length
    private func assembleFinalOutputContents(
        stagingURL: URL
    ) async throws {
        let stagingAsset = AVURLAsset(
            url: stagingURL,
            options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]
        )
        let stagingVideoTracks = try await stagingAsset.loadTracks(
            withMediaType: .video
        )
        guard stagingVideoTracks.count == 1,
              let stagingVideoTrack = stagingVideoTracks.first else {
            throw finalMuxError(
                .stagingVideoTrackCount(
                    expected: 1,
                    actual: stagingVideoTracks.count
                )
            )
        }
        let stagingMetadataTracks = try await stagingAsset.loadTracks(
            withMediaType: .metadata
        )
        let expectedMetadataTrackCount = outputProfile
            .timedMetadataTemplate
            .isEmpty ? 0 : 1
        guard stagingMetadataTracks.count == expectedMetadataTrackCount else {
            throw finalMuxError(
                .stagingMetadataTrackCount(
                    expected: expectedMetadataTrackCount,
                    actual: stagingMetadataTracks.count
                )
            )
        }

        let sourceVideoReference = OutputMediaTrackReference(
            mediaType: AVMediaType.video.rawValue,
            ordinal: 0
        )
        guard let sourceVideoPreservation = sourceMediaPreservation.tracks
            .first(where: {
                $0.expectation.reference == sourceVideoReference
            }) else {
            throw MediaPipelineError.metadataPreservationFailed(
                "the source video preservation plan is missing"
            )
        }
        var sourceTracks: [FinalMuxSourceTrack] = [
            try await makeFinalMuxSourceTrack(
                stagingVideoTrack,
                preservation: sourceVideoPreservation
            )
        ]
        sourceTracks.append(
            contentsOf: try await makeFinalMuxSourceTracks(
                stagingMetadataTracks
            )
        )
        for preservation in sourceMediaPreservation.tracks
        where preservation.expectation.reference
            != sourceVideoReference {
            try checkCancellation()
            if preservation.expectation.reference.mediaType
                == AVMediaType.audio.rawValue {
                let audioStage = telemetry.beginStage(.audioProcess)
                do {
                    sourceTracks.append(
                        try await makeFinalMuxSourceTrack(
                            preservation.track,
                            preservation: preservation
                        )
                    )
                    telemetry.endStage(audioStage)
                } catch {
                    telemetry.endStage(audioStage)
                    throw error
                }
            } else {
                sourceTracks.append(
                    try await makeFinalMuxSourceTrack(
                        preservation.track,
                        preservation: preservation
                    )
                )
            }
        }
        let exactBoundaryRanges = sourceTracks.flatMap { sourceTrack in
            var ranges = [
                sourceTrack.sourceCopyTimeRange,
                sourceTrack.outputTimeRange
            ]
            for segment in sourceTrack.segments {
                if segment.timeMapping.source.isValid {
                    ranges.append(segment.timeMapping.source)
                }
                if segment.timeMapping.target.isValid {
                    ranges.append(segment.timeMapping.target)
                }
            }
            return ranges
        }
        let movieTimeScale = try ExactVideoWriterTimeScale
            .commonBoundaryScale(exactBoundaryRanges)
        let fileType = try Self.writerFileType(for: outputProfile.url)
        telemetry.recordMedia(ASHMediaObservation(
            kind: "final_sample_copy_mux_started",
            details: [
                "track_count": String(sourceTracks.count),
                "movie_timescale": String(movieTimeScale),
                "preserved_audio":
                    String(!sourceAudioTracks.isEmpty),
                "preserved_audio_track_count":
                    String(sourceAudioTracks.count),
                "preserved_subtitle_tracks": String(
                    sourceMediaPreservation.tracks.filter {
                        [
                            AVMediaType.subtitle.rawValue,
                            AVMediaType.text.rawValue,
                            AVMediaType.closedCaption.rawValue
                        ].contains($0.expectation.reference.mediaType)
                    }.count
                ),
                "preserved_metadata_tracks": String(
                    sourceMediaPreservation.tracks.filter {
                        [
                            AVMediaType.metadata.rawValue,
                            AVMediaType.timecode.rawValue
                        ].contains($0.expectation.reference.mediaType)
                    }.count
                )
            ]
        ))

        if expectedCompressedAACTrackIdentities.isEmpty {
            try assembleFreshFinalMovie(
                sourceTracks: sourceTracks,
                movieTimeScale: movieTimeScale,
                fileType: fileType,
                seedSourceURL: stagingURL
            )
        } else {
            try await assembleSourceSeededFinalMovie(
                sourceTracks: sourceTracks,
                fileType: fileType
            )
        }
        telemetry.recordMedia(ASHMediaObservation(
            kind: "final_sample_copy_mux_completed",
            details: [
                "track_count": String(sourceTracks.count),
                "movie_timescale": String(movieTimeScale),
                "preserved_audio":
                    String(!sourceAudioTracks.isEmpty),
                "preserved_audio_track_count":
                    String(sourceAudioTracks.count),
                "preserved_association_count":
                    String(sourceMediaPreservation.associations.count)
            ]
        ))
    }

    private func assembleFreshFinalMovie(
        sourceTracks: [FinalMuxSourceTrack],
        movieTimeScale: CMTimeScale,
        fileType: AVFileType,
        seedSourceURL: URL
    ) throws {
        let sourceSeed = try MediaPipelineStagingFile(
            finalTemporaryURL: outputTransaction.temporaryURL,
            role: .sourceSeed,
            fileSystem:
                outputTransaction.fileSystemForSiblingTemporaryFiles
        )
        do {
            try finalizationResourceLock.withLock {
                try checkCancellation()
                try validateAbsentFinalTemporaryOutput()
                guard !FileManager.default.fileExists(
                    atPath: sourceSeed.url.path
                ) else {
                    throw MediaPipelineError.metadataPreservationFailed(
                        "the fresh final-mux source seed already exists"
                    )
                }
                try FileManager.default.copyItem(
                    at: seedSourceURL,
                    to: sourceSeed.url
                )
                try makeSourceSeedOwnerWritable(at: sourceSeed.url)
                try sourceSeed.claimCreatedFileIfNeeded()
                try buildFreshSeededMovie(
                    at: sourceSeed.url,
                    sourceTracks: sourceTracks,
                    movieTimeScale: movieTimeScale,
                    fileType: fileType
                )
            }

            try copySourceSeedToFinalOutput(sourceSeed.url)
        } catch {
            if let cleanupError = sourceSeed.cleanup() {
                throw MediaPipelineError.partialCleanupFailed(
                    sourceSeed.url,
                    "final-mux failure: \(error); fresh seed cleanup: "
                        + String(describing: cleanupError)
                )
            }
            throw error
        }
        if let cleanupError = sourceSeed.cleanup() {
            throw MediaPipelineError.partialCleanupFailed(
                sourceSeed.url,
                String(describing: cleanupError)
            )
        }
    }

    private func buildFreshSeededMovie(
        at sourceSeedURL: URL,
        sourceTracks: [FinalMuxSourceTrack],
        movieTimeScale: CMTimeScale,
        fileType: AVFileType
    ) throws {
        let movie = AVMutableMovie(
            url: sourceSeedURL,
            options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]
        )
        movie.timescale = movieTimeScale
        movie.metadata = sourceMediaPreservation.containerMetadata
        let mediaDataStorage = AVMediaDataStorage(
            url: sourceSeedURL,
            options: nil
        )
        movie.defaultMediaDataStorage = mediaDataStorage
        for track in movie.tracks {
            movie.removeTrack(track)
        }

        var destinationTracks:
            [OutputMediaTrackReference: AVMutableMovieTrack] = [:]
        var deferredVideoTracks:
            [(FinalMuxSourceTrack, AVMutableMovieTrack)] = []
        for sourceTrack in sourceTracks {
            let destinationTrack = try addFinalMuxTrack(
                sourceTrack,
                to: movie,
                mediaDataStorage: mediaDataStorage,
                destinationTracks: &destinationTracks,
                deferVideoSampleAppend: true
            )
            if sourceTrack.track.mediaType == .video {
                deferredVideoTracks.append(
                    (sourceTrack, destinationTrack)
                )
            }
        }
        for (sourceTrack, destinationTrack) in deferredVideoTracks {
            try copyFinalMuxVideoSamples(
                from: sourceTrack,
                to: destinationTrack
            )
        }
        try restoreFinalMuxAssociations(
            destinationTracks: destinationTracks,
            seededAudioReferences: []
        )
        try checkCancellation()
        do {
            try movie.writeHeader(
                to: sourceSeedURL,
                fileType: fileType,
                options: .addMovieHeaderToDestination
            )
        } catch {
            throw MediaPipelineError.metadataPreservationFailed(
                "writing the fresh source-seeded final-mux header failed: "
                    + String(describing: error)
            )
        }
    }

    private func assembleSourceSeededFinalMovie(
        sourceTracks: [FinalMuxSourceTrack],
        fileType: AVFileType
    ) async throws {
        let sourceSeed = try MediaPipelineStagingFile(
            finalTemporaryURL: outputTransaction.temporaryURL,
            role: .sourceSeed,
            fileSystem:
                outputTransaction.fileSystemForSiblingTemporaryFiles
        )
        do {
            try finalizationResourceLock.withLock {
                try checkCancellation()
                try validateAbsentFinalTemporaryOutput()
                guard !FileManager.default.fileExists(
                    atPath: sourceSeed.url.path
                ) else {
                    throw MediaPipelineError.metadataPreservationFailed(
                        "the final-mux source seed already exists"
                    )
                }
                try FileManager.default.copyItem(
                    at: sourceProfile.url,
                    to: sourceSeed.url
                )
                try makeSourceSeedOwnerWritable(at: sourceSeed.url)
                try sourceSeed.claimCreatedFileIfNeeded()
                try buildSourceSeededMovie(
                    at: sourceSeed.url,
                    sourceTracks: sourceTracks,
                    fileType: fileType
                )
            }

            try copySourceSeedToFinalOutput(sourceSeed.url)
        } catch {
            if let cleanupError = sourceSeed.cleanup() {
                throw MediaPipelineError.partialCleanupFailed(
                    sourceSeed.url,
                    "final-mux failure: \(error); source-seed cleanup: "
                        + String(describing: cleanupError)
                )
            }
            throw error
        }
        if let cleanupError = sourceSeed.cleanup() {
            throw MediaPipelineError.partialCleanupFailed(
                sourceSeed.url,
                String(describing: cleanupError)
            )
        }
    }

    private func makeSourceSeedOwnerWritable(at url: URL) throws {
        let descriptor = open(
            url.path,
            O_RDONLY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            throw MediaPipelineError.metadataPreservationFailed(
                "opening the owned final-mux source seed failed: "
                    + String(cString: strerror(errno))
            )
        }
        defer { close(descriptor) }

        var descriptorBefore = stat()
        var pathBefore = stat()
        guard fstat(descriptor, &descriptorBefore) == 0,
              lstat(url.path, &pathBefore) == 0,
              let descriptorIdentity = AtomicMediaPinnedFileIdentity(
                descriptorBefore,
                requirePopulatedFile: false
              ),
              let pathIdentity = AtomicMediaPinnedFileIdentity(
                pathBefore,
                requirePopulatedFile: false
              ),
              descriptorIdentity == pathIdentity else {
            throw MediaPipelineError.metadataPreservationFailed(
                "the owned final-mux source seed changed before permission update"
            )
        }
        guard fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else {
            throw MediaPipelineError.metadataPreservationFailed(
                "making the owned final-mux source seed writable failed: "
                    + String(cString: strerror(errno))
            )
        }

        var descriptorAfter = stat()
        var pathAfter = stat()
        guard fstat(descriptor, &descriptorAfter) == 0,
              lstat(url.path, &pathAfter) == 0,
              let descriptorIdentityAfter = AtomicMediaPinnedFileIdentity(
                descriptorAfter,
                requirePopulatedFile: false
              ),
              let pathIdentityAfter = AtomicMediaPinnedFileIdentity(
                pathAfter,
                requirePopulatedFile: false
              ),
              descriptorIdentityAfter == pathIdentityAfter,
              descriptorIdentity.refersToSameFileObject(
                as: descriptorIdentityAfter
              ),
              descriptorAfter.st_mode & mode_t(0o777)
                == mode_t(S_IRUSR | S_IWUSR) else {
            throw MediaPipelineError.metadataPreservationFailed(
                "the owned final-mux source seed permission update could not be verified"
            )
        }
    }

    private func buildSourceSeededMovie(
        at sourceSeedURL: URL,
        sourceTracks: [FinalMuxSourceTrack],
        fileType: AVFileType
    ) throws {
        let movie = AVMutableMovie(
            url: sourceSeedURL,
            options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]
        )
        movie.metadata = sourceMediaPreservation.containerMetadata
        let mediaDataStorage = AVMediaDataStorage(
            url: sourceSeedURL,
            options: nil
        )
        movie.defaultMediaDataStorage = mediaDataStorage

        let audioPlans = sourceMediaPreservation.tracks.filter {
            $0.expectation.reference.mediaType
                == AVMediaType.audio.rawValue
        }
        let seedAudioTracks = movie.tracks(withMediaType: .audio)
        guard !audioPlans.isEmpty,
              audioPlans.count == seedAudioTracks.count,
              audioPlans.count == sourceAudioTracks.count else {
            throw MediaPipelineError.metadataPreservationFailed(
                "the source-seeded audio inventory differs from preflight"
            )
        }
        var audioPlansByTrackID:
            [CMPersistentTrackID: SourceMediaTrackPreservationPlan] = [:]
        for plan in audioPlans {
            guard audioPlansByTrackID.updateValue(
                plan,
                forKey: plan.originalTrackID
            ) == nil else {
                throw MediaPipelineError.metadataPreservationFailed(
                    "the source-seeded audio plan contains a duplicate track identifier"
                )
            }
        }

        for track in movie.tracks where track.mediaType != .audio {
            movie.removeTrack(track)
        }
        var destinationTracks:
            [OutputMediaTrackReference: AVMutableMovieTrack] = [:]
        var deferredVideoTracks:
            [(FinalMuxSourceTrack, AVMutableMovieTrack)] = []
        var seededAudioReferences: Set<OutputMediaTrackReference> = []
        for track in seedAudioTracks {
            guard let preservation = audioPlansByTrackID.removeValue(
                forKey: track.trackID
            ) else {
                throw MediaPipelineError.metadataPreservationFailed(
                    "a source-seeded audio track has no preflight plan"
                )
            }
            try configureFinalMuxTrack(
                track,
                preservation: preservation,
                destinationTracks: &destinationTracks
            )
            seededAudioReferences.insert(
                preservation.expectation.reference
            )
        }
        guard audioPlansByTrackID.isEmpty else {
            throw MediaPipelineError.metadataPreservationFailed(
                "a preflight audio track is missing from the source seed"
            )
        }

        for sourceTrack in sourceTracks
        where sourceTrack.track.mediaType != .audio {
            let destinationTrack = try addFinalMuxTrack(
                sourceTrack,
                to: movie,
                mediaDataStorage: mediaDataStorage,
                destinationTracks: &destinationTracks,
                deferVideoSampleAppend: true
            )
            if sourceTrack.track.mediaType == .video {
                deferredVideoTracks.append(
                    (sourceTrack, destinationTrack)
                )
            }
        }
        for (sourceTrack, destinationTrack) in deferredVideoTracks {
            try copyFinalMuxVideoSamples(
                from: sourceTrack,
                to: destinationTrack
            )
        }
        try restoreFinalMuxAssociations(
            destinationTracks: destinationTracks,
            seededAudioReferences: seededAudioReferences
        )
        try checkCancellation()
        do {
            try movie.writeHeader(
                to: sourceSeedURL,
                fileType: fileType,
                options: .addMovieHeaderToDestination
            )
        } catch {
            throw MediaPipelineError.metadataPreservationFailed(
                "writing the source-seeded final-mux header failed: "
                    + String(describing: error)
            )
        }
    }

    private func addFinalMuxTrack(
        _ sourceTrack: FinalMuxSourceTrack,
        to movie: AVMutableMovie,
        mediaDataStorage: AVMediaDataStorage,
        destinationTracks: inout
            [OutputMediaTrackReference: AVMutableMovieTrack],
        deferVideoSampleAppend: Bool
    ) throws -> AVMutableMovieTrack {
        try checkCancellation()
        guard let destinationTrack = movie.addMutableTrack(
            withMediaType: sourceTrack.track.mediaType,
            copySettingsFrom: sourceTrack.track,
            options: nil
        ) else {
            throw finalMuxError(
                .destinationTrackCreationFailed(
                    trackKind: FinalMuxGuardError.TrackKind(
                        mediaType: sourceTrack.track.mediaType
                    )
                )
            )
        }
        destinationTrack.mediaDataStorage = mediaDataStorage
        if let preservation = sourceTrack.preservation {
            try configureFinalMuxTrack(
                destinationTrack,
                preservation: preservation,
                destinationTracks: &destinationTracks
            )
        }
        destinationTrack.timescale = sourceTrack.exactTimeScale
        if sourceTrack.track.mediaType == .video {
            if !deferVideoSampleAppend {
                try copyFinalMuxVideoSamples(
                    from: sourceTrack,
                    to: destinationTrack
                )
            }
        } else {
            do {
                try destinationTrack.insertTimeRange(
                    sourceTrack.sourceCopyTimeRange,
                    of: sourceTrack.track,
                    at: sourceTrack.destinationStart,
                    copySampleData: true
                )
            } catch {
                throw MediaPipelineError.metadataPreservationFailed(
                    "copying final-mux "
                        + sourceTrack.track.mediaType.rawValue
                        + " sample data failed: "
                        + String(describing: error)
                )
            }
        }
        if let metadataFormatDescriptions =
                sourceTrack.metadataFormatDescriptions {
            try preserveUnboundMetadataFormatDescriptions(
                metadataFormatDescriptions,
                on: destinationTrack,
                naturalTimeScale: sourceTrack.exactTimeScale
            )
        }
        if sourceTrack.track.mediaType == .closedCaption {
            try rebuildClosedCaptionEditList(
                from: sourceTrack,
                on: destinationTrack
            )
        }
        return destinationTrack
    }

    private func copyFinalMuxVideoSamples(
        from source: FinalMuxSourceTrack,
        to destination: AVMutableMovieTrack
    ) throws {
        // Tracks with a preflight sample identity must retain the source
        // access-unit duration and payload exactly. AVMutableMovieTrack's
        // append API normalizes the terminal duration for a clipped edit,
        // while sample-data insertion preserves the compressed identity.
        if source.preservation?.expectation.sampleIdentity != nil {
            try insertExactFinalMuxVideoSamples(
                from: source,
                to: destination
            )
        } else {
            try appendFinalMuxVideoSamples(
                from: source,
                to: destination
            )
        }
    }

    private func insertExactFinalMuxVideoSamples(
        from source: FinalMuxSourceTrack,
        to destination: AVMutableMovieTrack
    ) throws {
        do {
            try destination.insertTimeRange(
                source.sourceCopyTimeRange,
                of: source.track,
                at: source.destinationStart,
                copySampleData: true
            )
        } catch {
            throw MediaPipelineError.metadataPreservationFailed(
                "copying exact final-mux compressed-video sample data failed: "
                    + String(describing: error)
            )
        }
        let copiedTimeRange = destination.timeRange
        guard CMTimeCompare(
            copiedTimeRange.start,
            source.outputTimeRange.start
        ) == 0,
        CMTimeCompare(
            copiedTimeRange.duration,
            source.outputTimeRange.duration
        ) == 0 else {
            throw MediaPipelineError.metadataPreservationFailed(
                "the exact final-mux video copy differs from its source timeline"
            )
        }
    }

    private func appendFinalMuxVideoSamples(
        from source: FinalMuxSourceTrack,
        to destination: AVMutableMovieTrack
    ) throws {
        guard let sourceAsset = source.track.asset else {
            throw MediaPipelineError.metadataPreservationFailed(
                "the final-mux video track is detached from its source asset"
            )
        }
        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: sourceAsset)
        } catch {
            throw MediaPipelineError.metadataPreservationFailed(
                "creating the final-mux compressed-video reader failed: "
                    + String(describing: error)
            )
        }
        reader.timeRange = source.sourceCopyTimeRange
        let output = AVAssetReaderTrackOutput(
            track: source.track,
            outputSettings: nil
        )
        output.alwaysCopiesSampleData = true
        guard reader.canAdd(output) else {
            throw MediaPipelineError.metadataPreservationFailed(
                "the final-mux compressed-video reader rejected its track"
            )
        }
        reader.add(output)
        guard reader.startReading() else {
            throw MediaPipelineError.metadataPreservationFailed(
                "starting the final-mux compressed-video reader failed: "
                    + String(describing: reader.error)
            )
        }
        defer {
            if reader.status == .reading {
                reader.cancelReading()
            }
        }

        var appendedSampleCount = 0
        while let sampleBuffer = output.copyNextSampleBuffer() {
            try checkCancellation()
            let sampleCount = CMSampleBufferGetNumSamples(sampleBuffer)
            guard sampleCount > 0 else {
                // AVAssetReader emits zero-sample edit/drain markers around
                // compressed video. AVMutableMovieTrack accepts media-bearing
                // buffers only; the source edit map is rebuilt below.
                continue
            }
            do {
                // This API preserves the explicit decode timeline of the
                // compressed buffers. The macOS 26 CMReadySampleBuffer
                // overload rewrites this fixture's final packet duration.
                var decodeTime = CMTime.invalid
                var presentationTime = CMTime.invalid
                try destination.append(
                    sampleBuffer,
                    decodeTime: &decodeTime,
                    presentationTime: &presentationTime
                )
            } catch {
                throw MediaPipelineError.metadataPreservationFailed(
                    "appending final-mux compressed-video sample "
                        + "\(appendedSampleCount) failed: "
                        + String(describing: error)
                )
            }
            let (nextCount, overflowed) = appendedSampleCount
                .addingReportingOverflow(sampleCount)
            guard !overflowed else {
                throw MediaPipelineError.metadataPreservationFailed(
                    "the final-mux compressed-video sample count overflowed"
                )
            }
            appendedSampleCount = nextCount
        }
        guard reader.status == .completed else {
            throw MediaPipelineError.metadataPreservationFailed(
                "reading final-mux compressed-video samples failed: "
                    + String(describing: reader.error)
            )
        }
        guard appendedSampleCount > 0 else {
            throw MediaPipelineError.metadataPreservationFailed(
                "the final-mux compressed-video reader produced no samples"
            )
        }

        var insertedMediaMapping = false
        for segment in source.segments {
            try checkCancellation()
            if segment.isEmpty {
                destination.insertEmptyTimeRange(
                    segment.timeMapping.target
                )
            } else {
                guard destination.insertMediaTimeRange(
                    segment.timeMapping.source,
                    into: segment.timeMapping.target
                ) else {
                    throw MediaPipelineError.metadataPreservationFailed(
                        "the final-mux video edit map could not be rebuilt"
                    )
                }
                insertedMediaMapping = true
            }
        }
        guard insertedMediaMapping else {
            throw MediaPipelineError.metadataPreservationFailed(
                "the final-mux video track has no presented media segment"
            )
        }
        let rebuiltTimeRange = destination.timeRange
        guard CMTimeCompare(
            rebuiltTimeRange.start,
            source.outputTimeRange.start
        ) == 0,
        CMTimeCompare(
            rebuiltTimeRange.duration,
            source.outputTimeRange.duration
        ) == 0 else {
            throw MediaPipelineError.metadataPreservationFailed(
                "the rebuilt final-mux video edit map differs from its source"
            )
        }
    }

    private func configureFinalMuxTrack(
        _ destinationTrack: AVMutableMovieTrack,
        preservation: SourceMediaTrackPreservationPlan,
        destinationTracks: inout
            [OutputMediaTrackReference: AVMutableMovieTrack]
    ) throws {
        destinationTrack.isEnabled = preservation.expectation.isEnabled
        destinationTrack.languageCode =
            preservation.expectation.languageCode
        destinationTrack.extendedLanguageTag =
            preservation.expectation.extendedLanguageTag
        destinationTrack.metadata = preservation.metadata
        let reference = preservation.expectation.reference
        guard destinationTracks.updateValue(
            destinationTrack,
            forKey: reference
        ) == nil else {
            throw MediaPipelineError.metadataPreservationFailed(
                "duplicate destination track reference \(reference)"
            )
        }
    }

    private func restoreFinalMuxAssociations(
        destinationTracks:
            [OutputMediaTrackReference: AVMutableMovieTrack],
        seededAudioReferences: Set<OutputMediaTrackReference>
    ) throws {
        for association in sourceMediaPreservation.associations {
            try checkCancellation()
            if seededAudioReferences.contains(association.source),
               seededAudioReferences.contains(association.target) {
                continue
            }
            guard let sourceTrack = destinationTracks[association.source],
                  let targetTrack = destinationTracks[association.target]
            else {
                throw MediaPipelineError.metadataPreservationFailed(
                    "destination association mapping is incomplete for "
                        + association.associationType
                )
            }
            sourceTrack.addTrackAssociation(
                to: targetTrack,
                type: AVAssetTrack.AssociationType(
                    rawValue: association.associationType
                )
            )
        }
    }

    private func validateAbsentFinalTemporaryOutput() throws {
        try outputTransaction.validateActiveTransactionLease()
        guard !FileManager.default.fileExists(
            atPath: outputTransaction.temporaryURL.path
        ) else {
            throw finalMuxError(.temporaryOutputAlreadyExists)
        }
    }

    private func copySourceSeedToFinalOutput(
        _ sourceSeedURL: URL
    ) throws {
        try finalizationResourceLock.withLock {
            try checkCancellation()
            try validateAbsentFinalTemporaryOutput()
            do {
                try FileManager.default.copyItem(
                    at: sourceSeedURL,
                    to: outputTransaction.temporaryURL
                )
                try outputTransaction
                    .claimTemporaryFileForVerification()
                try checkCancellation()
            } catch {
                if FileManager.default.fileExists(
                    atPath: outputTransaction.temporaryURL.path
                ) {
                    try? outputTransaction
                        .claimTemporaryFileForVerification()
                }
                throw error
            }
        }
    }

    private func makeFinalMuxSourceTracks(
        _ tracks: [AVAssetTrack]
    ) async throws -> [FinalMuxSourceTrack] {
        var result: [FinalMuxSourceTrack] = []
        result.reserveCapacity(tracks.count)
        for track in tracks {
            try checkCancellation()
            result.append(
                try await makeFinalMuxSourceTrack(
                    track,
                    preservation: nil
                )
            )
        }
        return result
    }

    private func makeFinalMuxSourceTrack(
        _ track: AVAssetTrack,
        preservation: SourceMediaTrackPreservationPlan?
    ) async throws -> FinalMuxSourceTrack {
        let timeRange = try await track.load(.timeRange)
        let segments = try await track.load(.segments)
        let naturalTimeScale = try await track.load(.naturalTimeScale)
        let metadataFormatDescriptions = track.mediaType == .metadata
            ? try await track.load(.formatDescriptions)
            : nil
        let exactTimeScale: CMTimeScale
        if let preservation {
            // A migrated timed-metadata track can use a normalized private
            // timeline while its output is restored to the source timeline.
            // Use the scale proven against that output timeline by planning.
            exactTimeScale = preservation.expectation.naturalTimeScale
        } else {
            exactTimeScale = try ExactVideoWriterTimeScale.resolve(
                naturalTimeScale: naturalTimeScale,
                trackTimeRange: timeRange
            )
        }
        return FinalMuxSourceTrack(
            track: track,
            sourceCopyTimeRange:
                preservation?.sourceCopyTimeRange ?? timeRange,
            destinationStart:
                preservation?.destinationStart ?? timeRange.start,
            outputTimeRange:
                preservation?.expectation.timeRange ?? timeRange,
            segments: segments,
            exactTimeScale: exactTimeScale,
            metadataFormatDescriptions: metadataFormatDescriptions,
            preservation: preservation
        )
    }

    private func preserveUnboundMetadataFormatDescriptions(
        _ sourceDescriptions: [CMFormatDescription],
        on destination: AVMutableMovieTrack,
        naturalTimeScale: CMTimeScale
    ) throws {
        var remainingSourceDescriptions = sourceDescriptions
        let rawDestinationDescriptions = destination.formatDescriptions
        var destinationDescriptions: [CMFormatDescription] = []
        destinationDescriptions.reserveCapacity(
            rawDestinationDescriptions.count
        )
        for rawDescription in rawDestinationDescriptions {
            guard CFGetTypeID(rawDescription as CFTypeRef)
                    == CMFormatDescriptionGetTypeID() else {
                throw MediaPipelineError.metadataPreservationFailed(
                    "a destination metadata format description has an unsupported Core Foundation type"
                )
            }
            destinationDescriptions.append(
                rawDescription as! CMFormatDescription
            )
        }
        for destinationDescription in destinationDescriptions {
            let destinationIdentity = try
                OutputMediaMetadataFormatSchemaIdentityReader
                .canonicalFormatDescription(destinationDescription)
            guard let sourceIndex = try remainingSourceDescriptions
                .firstIndex(where: { sourceDescription in
                    try OutputMediaMetadataFormatSchemaIdentityReader
                        .canonicalFormatDescription(sourceDescription)
                        == destinationIdentity
                }) else {
                throw MediaPipelineError.metadataPreservationFailed(
                    "the destination metadata track contains an undeclared format description before final mux"
                )
            }
            remainingSourceDescriptions.remove(at: sourceIndex)
        }
        for sourceDescription in remainingSourceDescriptions {
            try checkCancellation()
            do {
                try OutputMediaMetadataFormatDescriptionAnchorWriter.append(
                    sourceDescription,
                    to: destination,
                    naturalTimeScale: naturalTimeScale
                )
            } catch {
                throw MediaPipelineError.metadataPreservationFailed(
                    "an unbound metadata format description could not be retained during final mux: \(error)"
                )
            }
        }
    }

    private func rebuildClosedCaptionEditList(
        from source: FinalMuxSourceTrack,
        on destination: AVMutableMovieTrack
    ) throws {
        let copiedMediaTimeRange = destination.mediaPresentationTimeRange
        let collapsedTimeRange = destination.timeRange
        destination.removeTimeRange(collapsedTimeRange)
        guard destination.mediaPresentationTimeRange
                == copiedMediaTimeRange else {
            throw MediaPipelineError.metadataPreservationFailed(
                "removing the collapsed closed-caption edit changed its "
                    + "copied media table"
            )
        }
        var insertedMediaMapping = false
        for segment in source.segments where !segment.isEmpty {
            try checkCancellation()
            guard destination.insertMediaTimeRange(
                segment.timeMapping.source,
                into: segment.timeMapping.target
            ) else {
                throw MediaPipelineError.metadataPreservationFailed(
                    "the source closed-caption edit map could not be rebuilt"
                )
            }
            insertedMediaMapping = true
        }
        guard insertedMediaMapping else {
            throw MediaPipelineError.metadataPreservationFailed(
                "the source closed-caption track has no presented media segment"
            )
        }
        let rebuiltTimeRange = destination.timeRange
        guard CMTimeCompare(
            rebuiltTimeRange.start,
            source.outputTimeRange.start
        ) == 0,
        CMTimeCompare(
            rebuiltTimeRange.duration,
            source.outputTimeRange.duration
        ) == 0 else {
            throw MediaPipelineError.metadataPreservationFailed(
                "the rebuilt closed-caption edit map differs before header "
                    + "(source \(source.outputTimeRange), rebuilt "
                    + "\(rebuiltTimeRange), appended media "
                    + "\(destination.mediaPresentationTimeRange))"
            )
        }
    }

    private func finalMuxError(
        _ guardError: FinalMuxGuardError
    ) -> MediaPipelineError {
        MediaPipelineError.finalMuxFailed(
            outputProfile.url,
            guardError
        )
    }

    private func finishTimedMetadata(
        _ finalMetadata: [String: String],
        sessionEndTime: CMTime
    ) async throws {
        guard let timedMetadataWriter else {
            guard finalMetadata.isEmpty else {
                throw MediaPipelineError.outputMetadataMismatch(
                    "final metadata was supplied without a configured writer input"
                )
            }
            return
        }
        guard Set(finalMetadata.keys) == timedMetadataWriter.expectedKeys,
              finalMetadata.values.allSatisfy({ !$0.isEmpty }) else {
            throw MediaPipelineError.outputMetadataMismatch(
                "final metadata keys or values differ from the preflight template"
            )
        }
        while !timedMetadataWriter.input.isReadyForMoreMediaData {
            try checkCancellation()
            guard writer.status == .writing else {
                if writer.status == .cancelled {
                    throw CancellationError()
                }
                throw MediaPipelineError.writerFailed(writer.error)
            }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        let group = Self.makeASHMetadataGroup(
            finalMetadata,
            timeRange: CMTimeRange(start: .zero, duration: sessionEndTime)
        )
        guard timedMetadataWriter.adaptor.append(group) else {
            throw MediaPipelineError.writerFailed(writer.error)
        }
        timedMetadataWriter.input.markAsFinished()
        telemetry.recordMedia(ASHMediaObservation(
            kind: "ash_output_identity_finalized",
            details: [
                "metadata_key_count": String(finalMetadata.count),
                "numerical_fallback_count": finalMetadata[
                    "com.mirmir.ash.numerical-fallback-count"
                ] ?? "not_applicable"
            ]
        ))
    }

    private func finishWriter(at sessionEndTime: CMTime) async {
        let finishStage = telemetry.beginStage(.writerFinish)
        writer.endSession(atSourceTime: sessionEndTime)
        await writer.finishWriting()
        telemetry.endStage(finishStage)
        telemetry.recordMedia(ASHMediaObservation(
            kind: "writer_finished",
            details: [
                "status": String(writer.status.rawValue),
                "session_end_value": String(sessionEndTime.value),
                "session_end_timescale": String(sessionEndTime.timescale)
            ]
        ))
    }

    private func verifyOutput(
        timing: FrameTimingLedgerSnapshot,
        finalMetadata: [String: String]
    ) async throws -> OutputMediaVerificationResult {
        let verificationStage = telemetry.beginStage(.reopenVerify)
        do {
            let result = try await outputVerifier.verify(
                url: outputTransaction.temporaryURL,
                expectation: OutputMediaVerificationExpectation(
                    resolution: outputProfile.resolution,
                    codec: outputProfile.codec,
                    timing: timing,
                    timedMetadata: finalMetadata,
                    videoColor: .preserving(
                        videoFormat,
                        codec: outputProfile.codec
                    ),
                    compressedAACTrackIdentities:
                        expectedCompressedAACTrackIdentities,
                    preferredTransform: expectedVideoTransform,
                    mediaPreservation:
                        sourceMediaPreservation.expectation,
                    scanStructure: .progressive,
                    requiresExplicitScanStructure: true
                ),
                cancellationCheck: {
                    try self.checkCancellation()
                }
            )
            telemetry.endStage(verificationStage)
            return result
        } catch is CancellationError {
            telemetry.endStage(verificationStage)
            throw CancellationError()
        } catch {
            telemetry.endStage(verificationStage)
            throw MediaPipelineError.outputVerificationFailed(
                outputProfile.url,
                error
            )
        }
    }

    private func recordVerification(_ verification: OutputMediaVerificationResult) {
        telemetry.recordMedia(ASHMediaObservation(
            kind: "output_reopen_verified",
            details: [
                "codec": verification.codec,
                "dimensions": verification.resolution.description,
                "scan_structure":
                    verification.scanStructure.rawValue,
                "frame_count": String(verification.frameCount),
                "duration_value": String(verification.duration.value),
                "duration_timescale": String(verification.duration.timescale),
                "luma_payload_bytes": String(verification.lumaPayloadBytes),
                "chroma_payload_bytes": String(
                    verification.chromaPayloadBytes
                ),
                "alpha_payload_bytes": String(
                    verification.alphaPayloadBytes
                )
            ]
        ))
    }

    private func publishOutput() throws {
        guard !Task.isCancelled else { throw CancellationError() }
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }

        guard case .active = lifecycleState,
              !Task.isCancelled else {
            throw CancellationError()
        }
        do {
            try outputTransaction.publish()
            lifecycleState = .committed
        } catch {
            lifecycleState = .failed
            if let cleanupError = outputTransaction.snapshot.cleanup?.error {
                storedTerminalCleanupError = MediaPipelineError.partialCleanupFailed(
                    outputTransaction.temporaryURL,
                    String(describing: cleanupError)
                )
                throw storedTerminalCleanupError ?? error
            }
            throw error
        }
    }

    private func timingLedgerSnapshot() -> FrameTimingLedgerSnapshot {
        timingLock.lock()
        defer { timingLock.unlock() }
        return timingLedger.snapshot
    }

    private func checkCancellation() throws {
        try Task.checkCancellation()
        if sessionIsCancelled() { throw CancellationError() }
    }

    func sessionIsCancelled() -> Bool {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        guard case .cancelled = lifecycleState else { return false }
        return true
    }
}

// Finalization and the final sample-copy mux are reviewed as one lifecycle.
// swiftlint:disable:this file_length
