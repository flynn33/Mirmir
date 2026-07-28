import Foundation

extension R13ReleaseUpscalerEngineService:
    R13CacheLocationConfiguring {
    func cacheLocationStatus() -> R13CacheLocationStatus {
        cacheLocationStore?.cacheLocationStatus()
            ?? R13CacheLocationStatus(
                selection: R13CacheLocationSelection(
                    displayPath: "Managed by the configured runtime",
                    isCustom: false
                ),
                availabilityError: nil
            )
    }

    func selectCacheLocation(_ url: URL) throws
        -> R13CacheLocationStatus {
        guard let cacheLocationStore else {
            throw R13CacheLocationError.configurationCorrupt
        }
        return try performCacheLocationChange {
            try cacheLocationStore.selectCacheLocation(url)
        }
    }

    func useDefaultCacheLocation() throws
        -> R13CacheLocationStatus {
        guard let cacheLocationStore else {
            throw R13CacheLocationError.configurationCorrupt
        }
        return try performCacheLocationChange {
            cacheLocationStore.useDefaultCacheLocation()
        }
    }
}
