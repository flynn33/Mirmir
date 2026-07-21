import Foundation

final class UnavailableUpscalerEngineService: UpscalerEngineService, @unchecked Sendable {
    static let roadmapTransitionReason =
        "No production-default backend is enabled; product routing remains unavailable."

    let availability: UpscalerEngineAvailability

    init(reason: String = roadmapTransitionReason) {
        availability = .unavailable(reason: reason)
    }

    func submit(_: UpscaleJob) throws -> UpscalerJobHandle {
        guard case .unavailable(let reason) = availability else {
            preconditionFailure("UnavailableUpscalerEngineService requires an unavailable state.")
        }
        throw UpscalerEngineError.backendUnavailable(reason: reason)
    }

    func start() {}
    func stop() {}
}
