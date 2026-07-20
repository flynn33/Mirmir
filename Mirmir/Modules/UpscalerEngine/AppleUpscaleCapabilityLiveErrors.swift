import Foundation

enum R01LiveReportError: Error, CustomStringConvertible {
    case metricsNotClosed
    case measurementsNotClosed
    case fixtureCatalogNotClosed
    case fixtureGeneratorDrift(String)
    case fixtureMissing(String)
    case capabilityRecordNotClosed(String)
    case reportNotClosed
    case commandFailed(String)
    case commandOutputNotClosed(String)
    case preregistrationNotFrozen
    case anchorAssignmentMissing(String)
    case hostAssignmentMismatch(String)
    case repositoryBindingDrift(String)
    case sourceNotPublished
    case sourceTreeDirty
    case unsafeRepositoryPath(String)
    case outputAlreadyExists
    case outputNotRegular
    case privacyViolation
    case adapterUnavailable(String)
    case adapterSetupFailed(String)
    case adapterProcessingFailed(String)
    case adapterResourceFailed(String)
    case sessionTimedOut
    case workerExecutableUnavailable
    case workerProcessTimedOut(String)
    case workerProcessFailed(String)
    case workerResponseNotClosed(String)

    var description: String {
        switch self {
        case .metricsNotClosed: return "R01 metric keys or values are not closed."
        case .measurementsNotClosed: return "R01 measurements violate the frozen session contract."
        case .fixtureCatalogNotClosed: return "R01 fixture catalog differs from the frozen contract."
        case .fixtureGeneratorDrift(let fixture):
            return "R01 deterministic fixture generation differs for \(fixture)."
        case .fixtureMissing(let fixture): return "R01 fixture is missing: \(fixture)."
        case .capabilityRecordNotClosed(let capability):
            return "R01 capability record is not closed: \(capability)."
        case .reportNotClosed: return "R01 raw host report is not closed."
        case .commandFailed(let command): return "R01 allowlisted command failed: \(command)."
        case .commandOutputNotClosed(let fact):
            return "R01 allowlisted command output is not closed: \(fact)."
        case .preregistrationNotFrozen: return "R01 live assignments are not frozen."
        case .anchorAssignmentMissing(let anchor):
            return "R01 frozen assignment is missing for anchor \(anchor)."
        case .hostAssignmentMismatch(let fact):
            return "R01 current host/toolchain differs from frozen fact \(fact)."
        case .repositoryBindingDrift(let path):
            return "R01 repository binding differs from the published source: \(path)."
        case .sourceNotPublished: return "R01 source commit is not present in an origin tracking ref."
        case .sourceTreeDirty: return "R01 tracked source tree differs from HEAD."
        case .unsafeRepositoryPath(let path): return "R01 repository path is unsafe: \(path)."
        case .outputAlreadyExists: return "R01 refuses to overwrite an existing raw report."
        case .outputNotRegular: return "R01 raw report output is not a regular file."
        case .privacyViolation: return "R01 report contains a disallowed private value."
        case .adapterUnavailable(let capability):
            return "R01 execution adapter is unavailable for \(capability)."
        case .adapterSetupFailed(let capability):
            return "R01 execution adapter setup failed for \(capability)."
        case .adapterProcessingFailed(let capability):
            return "R01 execution adapter processing failed for \(capability)."
        case .adapterResourceFailed(let capability):
            return "R01 execution adapter exhausted resources for \(capability)."
        case .sessionTimedOut: return "R01 session reached the 120-second stop condition."
        case .workerExecutableUnavailable:
            return "R01 isolated capability worker executable is unavailable."
        case .workerProcessTimedOut(let capability):
            return "R01 isolated capability worker reached its outer stop condition for \(capability)."
        case .workerProcessFailed(let capability):
            return "R01 isolated capability worker failed for \(capability)."
        case .workerResponseNotClosed(let capability):
            return "R01 isolated capability worker response is not closed for \(capability)."
        }
    }
}
