import Darwin
import Foundation

extension SourceProfile {
    func bindingSourceURL(_ url: URL) -> SourceProfile {
        SourceProfile(
            url: url,
            resolution: resolution,
            codedResolution: codedResolution,
            pixelAspectRatio: pixelAspectRatio,
            frameRate: frameRate,
            durationSeconds: durationSeconds,
            estimatedFrameCount: estimatedFrameCount,
            codecHint: codecHint,
            hasAudio: hasAudio
        )
    }
}

struct R13PreparedReleaseSource: Sendable {
    let source: SourceProfile
    let route: R03ScaleRoute
    let hardeningAttempt: R13ReleaseHardeningAttempt?
}

enum R13ReleaseSourceStaging {
    static func prepare(
        job: UpscaleJob,
        modeBinding: R13ReleaseModeBinding,
        hardeningRuntime: R13ReleaseHardeningRuntime?,
        media: MediaPipelineService
    ) async throws -> R13PreparedReleaseSource {
        try Task.checkCancellation()
        let stagedSource = try await hardeningRuntime?.stageSource(
            for: job
        )
        let processingSourceURL =
            stagedSource?.processingURL ?? job.inputURL
        let source: SourceProfile
        let route: R03ScaleRoute
        do {
            try Task.checkCancellation()
            source = try await media.probe(
                url: processingSourceURL
            ).bindingSourceURL(processingSourceURL)
            route = try R13ReleaseJobContracts.route(
                source: source.resolution,
                target: job.targetResolution
            )
            try Task.checkCancellation()
        } catch {
            if let stagedSource {
                _ = await hardeningRuntime?.discardStagedSource(
                    stagedSource,
                    jobID: job.identifier
                )
            }
            throw error
        }
        let attempt: R13ReleaseHardeningAttempt?
        if let hardeningRuntime, let stagedSource {
            attempt = try await hardeningRuntime.prepare(
                job: job,
                source: source,
                route: route,
                modeBinding: modeBinding,
                stagedSource: stagedSource
            )
        } else {
            attempt = nil
        }
        return R13PreparedReleaseSource(
            source: source,
            route: route,
            hardeningAttempt: attempt
        )
    }
}

struct R13RetainedSourceSnapshot: Sendable {
    let originalURL: URL
    let processingURL: URL
    let directoryURL: URL
    let identity: R13RestartSourceIdentity
    let storageByteCount: UInt64

    fileprivate let snapshotsRootURL: URL
}

protocol R13SourceSnapshotting: Sendable {
    func createSnapshot(
        sourceURL: URL,
        jobID: String,
        jobsRootURL: URL
    ) throws -> R13RetainedSourceSnapshot

    func discard(_ snapshot: R13RetainedSourceSnapshot) throws
}

protocol R13SourceSnapshotCopyBarrier: Sendable {
    func didCopy(
        byteCount: UInt64,
        from sourceURL: URL
    ) throws
}

struct R13NoOpSourceSnapshotCopyBarrier:
    R13SourceSnapshotCopyBarrier {
    func didCopy(
        byteCount _: UInt64,
        from _: URL
    ) throws {}
}

struct R13LocalSourceSnapshotter: R13SourceSnapshotting {
    private static let readSize = 1_048_576
    private static let rootName = ".source-snapshots"

    private let sourceMeasurer: any R13RestartSourceMeasuring
    private let fileSystem: any R13RestartFileSystem
    private let copyBarrier: any R13SourceSnapshotCopyBarrier
    private let capacityProbe: any R13AvailableCapacityProbing
    private let minimumFreeDiskBytes: UInt64

    init(
        sourceMeasurer: any R13RestartSourceMeasuring,
        fileSystem: any R13RestartFileSystem =
            R13LocalRestartFileSystem(),
        copyBarrier: any R13SourceSnapshotCopyBarrier =
            R13NoOpSourceSnapshotCopyBarrier(),
        capacityProbe: any R13AvailableCapacityProbing =
            R13FoundationAvailableCapacityProbe(),
        minimumFreeDiskBytes: UInt64 = 1
    ) {
        self.sourceMeasurer = sourceMeasurer
        self.fileSystem = fileSystem
        self.copyBarrier = copyBarrier
        self.capacityProbe = capacityProbe
        self.minimumFreeDiskBytes = minimumFreeDiskBytes
    }

    func createSnapshot(
        sourceURL: URL,
        jobID: String,
        jobsRootURL: URL
    ) throws -> R13RetainedSourceSnapshot {
        _ = try R13RestartValidation.jobID(jobID)
        let originalIdentity = try sourceMeasurer.measureSource(
            at: sourceURL
        )
        let safeJobsRoot = R13RestartPath.resolvingExistingAncestor(
            of: jobsRootURL
        )
        let (requiredBytes, overflow) = originalIdentity.byteCount
            .addingReportingOverflow(minimumFreeDiskBytes)
        guard !overflow else {
            throw R13RestartJobError.arithmeticOverflow(
                field: "source_snapshot_required_bytes"
            )
        }
        let availableBytes = try capacityProbe
            .availableCapacityForImportantUsage(at: safeJobsRoot)
        guard availableBytes >= requiredBytes else {
            throw R13RestartJobError.insufficientDiskSpace(
                requiredBytes: requiredBytes,
                availableBytes: availableBytes
            )
        }
        let snapshotsRoot = safeJobsRoot.appendingPathComponent(
            Self.rootName,
            isDirectory: true
        )
        let processingFileName = try snapshotFileName(for: sourceURL)
        try fileSystem.ensureDirectory(snapshotsRoot)
        let directoryURL = snapshotsRoot.appendingPathComponent(
            ".\(jobID).\(UUID().uuidString)",
            isDirectory: true
        )
        let processingURL = directoryURL.appendingPathComponent(
            processingFileName,
            isDirectory: false
        )

        do {
            try fileSystem.ensureDirectory(directoryURL)
            try copySource(
                at: sourceURL,
                to: processingURL,
                expectedByteCount: originalIdentity.byteCount
            )
            let sourceAfterCopy = try sourceMeasurer.measureSource(
                at: sourceURL
            )
            guard sourceAfterCopy == originalIdentity else {
                throw R13RestartJobError.sourceDrift(
                    expected: originalIdentity,
                    observed: sourceAfterCopy
                )
            }
            let snapshotIdentity = try sourceMeasurer.measureSource(
                at: processingURL
            )
            guard snapshotIdentity == originalIdentity else {
                throw R13RestartJobError.sourceDrift(
                    expected: originalIdentity,
                    observed: snapshotIdentity
                )
            }
            return R13RetainedSourceSnapshot(
                originalURL: sourceURL,
                processingURL: processingURL,
                directoryURL: directoryURL,
                identity: originalIdentity,
                storageByteCount: snapshotIdentity.byteCount,
                snapshotsRootURL: snapshotsRoot
            )
        } catch {
            guard fileSystem.exists(directoryURL) else {
                throw error
            }
            let cleanup = R13SourceSnapshotCleanup.run(
                directoryURL: directoryURL,
                triggerReason: String(describing: error)
            ) {
                try fileSystem.removeDirectory(directoryURL)
            }
            if let cleanupError = cleanup.error {
                throw cleanupError
            }
            throw error
        }
    }

    func discard(_ snapshot: R13RetainedSourceSnapshot) throws {
        let expectedParent = snapshot.snapshotsRootURL.standardizedFileURL
        guard snapshot.directoryURL
                .deletingLastPathComponent()
                .standardizedFileURL == expectedParent,
              expectedParent.lastPathComponent == Self.rootName,
              snapshot.directoryURL.lastPathComponent.hasPrefix(".") else {
            throw R13RestartJobError.unsafeFilesystemEntry(
                snapshot.directoryURL.path
            )
        }
        try fileSystem.removeDirectory(snapshot.directoryURL)
    }

    private func snapshotFileName(for sourceURL: URL) throws -> String {
        let pathExtension = sourceURL.pathExtension.lowercased()
        guard !pathExtension.isEmpty else {
            return "source"
        }
        guard pathExtension.count <= 16,
              pathExtension.unicodeScalars.allSatisfy({
                  ($0.value >= 0x30 && $0.value <= 0x39)
                      || ($0.value >= 0x61 && $0.value <= 0x7A)
              }) else {
            throw R13RestartJobError.unsafeFilesystemEntry(
                sourceURL.path
            )
        }
        return "source.\(pathExtension)"
    }

    private func copySource(
        at sourceURL: URL,
        to destinationURL: URL,
        expectedByteCount: UInt64
    ) throws {
        let resolvedSource = R13RestartPath.resolvingExistingAncestor(
            of: sourceURL
        )
        let sourceDescriptor = open(
            resolvedSource.path,
            O_RDONLY | O_NOFOLLOW | O_CLOEXEC
        )
        guard sourceDescriptor >= 0 else {
            throw R13RestartJobError.ioFailure(
                operation: "open_snapshot_source"
            )
        }
        defer { close(sourceDescriptor) }
        var sourceBefore = stat()
        guard fstat(sourceDescriptor, &sourceBefore) == 0,
              isSafeSource(sourceBefore),
              UInt64(sourceBefore.st_size) == expectedByteCount else {
            throw R13RestartJobError.unsafeFilesystemEntry(
                sourceURL.path
            )
        }

        let destinationDirectory = open(
            destinationURL.deletingLastPathComponent().path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard destinationDirectory >= 0 else {
            throw R13RestartJobError.unsafeFilesystemEntry(
                destinationURL.path
            )
        }
        defer { close(destinationDirectory) }
        let destinationDescriptor = openat(
            destinationDirectory,
            destinationURL.lastPathComponent,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            S_IRUSR | S_IWUSR
        )
        guard destinationDescriptor >= 0 else {
            throw R13RestartJobError.ioFailure(
                operation: "create_source_snapshot"
            )
        }
        var destinationSucceeded = false
        defer {
            close(destinationDescriptor)
            if !destinationSucceeded {
                _ = unlinkat(
                    destinationDirectory,
                    destinationURL.lastPathComponent,
                    0
                )
            }
        }

        let copiedByteCount = try copyBytes(
            from: sourceDescriptor,
            to: destinationDescriptor,
            sourceURL: sourceURL,
            expectedByteCount: expectedByteCount
        )
        var sourceAfter = stat()
        var sourcePathAfter = stat()
        guard fstat(sourceDescriptor, &sourceAfter) == 0,
              lstat(resolvedSource.path, &sourcePathAfter) == 0,
              sameSourceSnapshot(sourceBefore, sourceAfter),
              sameSourceSnapshot(sourceAfter, sourcePathAfter),
              copiedByteCount == expectedByteCount,
              fchmod(destinationDescriptor, S_IRUSR) == 0,
              fsync(destinationDescriptor) == 0,
              fsync(destinationDirectory) == 0 else {
            throw R13RestartJobError.ioFailure(
                operation: "source_changed_during_snapshot"
            )
        }
        destinationSucceeded = true
    }

    private func copyBytes(
        from sourceDescriptor: Int32,
        to destinationDescriptor: Int32,
        sourceURL: URL,
        expectedByteCount: UInt64
    ) throws -> UInt64 {
        var copiedByteCount: UInt64 = 0
        var buffer = [UInt8](repeating: 0, count: Self.readSize)
        while true {
            let readCount = Darwin.read(
                sourceDescriptor,
                &buffer,
                buffer.count
            )
            if readCount < 0 && errno == EINTR {
                continue
            }
            guard readCount >= 0 else {
                throw R13RestartJobError.ioFailure(
                    operation: "read_snapshot_source"
                )
            }
            guard readCount > 0 else { return copiedByteCount }
            let (updatedCount, overflow) = copiedByteCount
                .addingReportingOverflow(UInt64(readCount))
            guard !overflow else {
                throw R13RestartJobError.arithmeticOverflow(
                    field: "source_snapshot_bytes"
                )
            }
            guard updatedCount <= expectedByteCount else {
                throw R13RestartJobError.ioFailure(
                    operation: "source_changed_during_snapshot"
                )
            }
            try writeBytes(
                buffer,
                count: readCount,
                to: destinationDescriptor
            )
            copiedByteCount = updatedCount
            try copyBarrier.didCopy(
                byteCount: copiedByteCount,
                from: sourceURL
            )
        }
    }

    private func writeBytes(
        _ bytes: [UInt8],
        count: Int,
        to descriptor: Int32
    ) throws {
        try bytes.withUnsafeBytes { rawBytes in
            guard let baseAddress = rawBytes.baseAddress else {
                throw R13RestartJobError.ioFailure(
                    operation: "write_source_snapshot"
                )
            }
            var offset = 0
            while offset < count {
                let writeCount = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    count - offset
                )
                if writeCount < 0 && errno == EINTR {
                    continue
                }
                guard writeCount > 0 else {
                    throw R13RestartJobError.ioFailure(
                        operation: "write_source_snapshot"
                    )
                }
                offset += writeCount
            }
        }
    }

    private func isSafeSource(_ metadata: stat) -> Bool {
        (metadata.st_mode & S_IFMT) == S_IFREG
            && metadata.st_nlink == 1
            && metadata.st_size > 0
    }

    private func sameSourceSnapshot(
        _ lhs: stat,
        _ rhs: stat
    ) -> Bool {
        lhs.st_dev == rhs.st_dev
            && lhs.st_ino == rhs.st_ino
            && lhs.st_mode == rhs.st_mode
            && lhs.st_nlink == rhs.st_nlink
            && lhs.st_size == rhs.st_size
            && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec
            && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
            && lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec
            && lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
    }
}
