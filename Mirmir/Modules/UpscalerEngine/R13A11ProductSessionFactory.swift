import Foundation

enum R13A11ProductSessionFactory {
    static func makeSession(
        route: R03ScaleRoute
    ) async throws -> R13ReleaseUpscaleSessionBinding {
        let backend = try R03DeterministicBackend
            .makeProductQualifiedMPSLanczos(route: route)
        let outcome = await backend.makeSession(
            configuration: try backend.makeConfiguration(),
            context: try R03A11ProductAdmission.makeProductSessionContext()
        )
        switch outcome {
        case .created(let session):
            let sessionIdentity = await session.identity
            guard sessionIdentity == backend.routeIdentity else {
                await session.cancel()
                throw UpscalerEngineError.strategyFailed(
                    "A11 session identity did not match its admitted route."
                )
            }
            return R13ReleaseUpscaleSessionBinding(
                session: session,
                route: route,
                routeIdentity: backend.routeIdentity
            )
        case .unavailable(let unavailable):
            throw UpscalerEngineError.backendUnavailable(
                reason: unavailable.reason
            )
        case .rejected(let rejected):
            throw UpscalerEngineError.strategyFailed(
                "A11 session admission was rejected: \(rejected.reason)"
            )
        case .failed(let failure):
            throw UpscalerEngineError.strategyFailed(
                "A11 session creation failed: \(failure.reason)"
            )
        }
    }
}
