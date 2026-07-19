import Foundation

final class UnavailableUpscalerEngineService: UpscalerEngineService, @unchecked Sendable {
    static let roadmapTransitionReason =
        "No roadmap-qualified backend is available; capability and baseline work continue in R01–R03."

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
