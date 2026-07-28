import AppKit
import Foundation
import UniformTypeIdentifiers

extension MirmirViewModel {
    var cacheLocationIsConfigurable: Bool {
        upscalerEngine is any R13CacheLocationConfiguring
    }

    var canChangeCacheLocation: Bool {
        !jobIsRunning && !recoveryIsProbing
    }

    var cacheLocationStatusMessage: String? {
        cacheLocationSelectionError ?? cacheLocationError
    }

    func chooseCacheLocation() {
        guard canChangeCacheLocation,
              let configurable =
                upscalerEngine as? any R13CacheLocationConfiguring else {
            return
        }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.title = "Select a cache folder or drive"
        panel.prompt = "Use for Cache"
        if cacheLocationIsCustom {
            panel.directoryURL = URL(
                fileURLWithPath: cacheLocationPath,
                isDirectory: true
            )
        }
        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }
        do {
            applyCacheLocationStatus(
                try configurable.selectCacheLocation(url)
            )
            cacheLocationSelectionError = nil
            reloadRecoverableJobsForCacheLocationChange()
        } catch {
            cacheLocationSelectionError =
                userFacingCacheLocationError(error)
        }
    }

    func useDefaultCacheLocation() {
        guard canChangeCacheLocation,
              let configurable =
                upscalerEngine as? any R13CacheLocationConfiguring else {
            return
        }
        do {
            applyCacheLocationStatus(
                try configurable.useDefaultCacheLocation()
            )
            cacheLocationSelectionError = nil
            reloadRecoverableJobsForCacheLocationChange()
        } catch {
            cacheLocationSelectionError =
                userFacingCacheLocationError(error)
        }
    }

    func refreshCacheLocation() {
        guard let configurable =
            upscalerEngine as? any R13CacheLocationConfiguring else {
            return
        }
        applyCacheLocationStatus(
            configurable.cacheLocationStatus()
        )
    }

    func defaultOutputURL(
        for source: SourceProfile,
        target: VideoResolution
    ) -> URL {
        defaultOutputURL(
            for: source,
            target: target,
            in: source.url.deletingLastPathComponent()
        )
    }

    func defaultOutputURL(
        for source: SourceProfile,
        target: VideoResolution,
        in directoryURL: URL
    ) -> URL {
        let base = source.url.deletingPathExtension().lastPathComponent
        return directoryURL.appendingPathComponent(
            "\(base)_mirmir_\(Self.fileLabel(for: target)).mp4"
        )
    }

    static var unsupportedFileMessage: String {
        "Unsupported video format. Choose an MP4, MOV, M4V, QT, AVI, MPG, or MPEG file."
    }

    static func fileLabel(for resolution: VideoResolution) -> String {
        switch resolution {
        case .p720:
            return "720p"
        case .p1080:
            return "1080p"
        case .p1440:
            return "1440p"
        case .p2160:
            return "2160p"
        default:
            return "\(resolution.width)x\(resolution.height)"
        }
    }

    static var sourceOutputConflictMessage: String {
        "The output file must be different from the source video."
    }

    static func urlsReferToSameFile(_ lhs: URL, _ rhs: URL) -> Bool {
        FileURLIdentity.refersToSameFile(lhs, rhs)
    }

    static func supportedContentTypes() -> [UTType] {
        let extensionTypes = supportedVideoExtensions.compactMap {
            UTType(filenameExtension: $0)
        }
        return Array(
            Set(
                extensionTypes
                    + [.movie, .video, .quickTimeMovie, .mpeg4Movie]
            )
        )
    }

    private func applyCacheLocationStatus(
        _ status: R13CacheLocationStatus
    ) {
        cacheLocationPath = status.selection.displayPath
        cacheLocationIsCustom = status.selection.isCustom
        cacheLocationError = status.availabilityError
    }

    private func reloadRecoverableJobsForCacheLocationChange() {
        cancelRecoveryProbe()
        recoverableJobs = []
        recoveryRejectedEntryCount = 0
        recoveryError = nil
        loadRecoverableJobs()
        refreshReleaseDiagnostics()
    }

    private func userFacingCacheLocationError(
        _ error: Error
    ) -> String {
        if let localized = error as? LocalizedError,
           let description = localized.errorDescription {
            return description
        }
        return R13CacheLocationError.locationUnavailable
            .localizedDescription
    }

    func clearOutputSelection() {
        outputURL = nil
        outputSelectionError = nil
    }

    func userFacingProbeError(_ error: Error) -> String {
        "Mirmir could not read this video. \(String(describing: error))"
    }

    func unsupportedResolutionMessage(
        _ resolution: VideoResolution
    ) -> String {
        "Mirmir supports 720p to 1080p and 1080p to 4K upscaling. "
            + "This source is \(resolution)."
    }
}
