import Foundation

enum ASHLockedVideoMappingV2Error: Error, Equatable, Sendable {
    case hashMismatch
    case nonCanonicalEncoding
    case fieldSetMismatch
    case invalidValue
}

enum ASHLockedArtifactStatusV2: String, Equatable, Sendable {
    case calibrationCandidate = "calibration_candidate"
    case lockedBeforeP07 = "locked_before_p07"
}

enum ASHLockedVideoMappingValidationV2 {
    static func validConfigurationID(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard (3...128).contains(bytes.count),
              let first = bytes.first,
              (first >= 97 && first <= 122) || (first >= 48 && first <= 57) else {
            return false
        }
        return bytes.allSatisfy {
            ($0 >= 97 && $0 <= 122)
                || ($0 >= 48 && $0 <= 57)
                || [45, 46, 95].contains($0)
        }
    }

    static func validatePhysicalCandidateItems(
        _ value: ASHLUTStrictJSONValueV2?
    ) throws {
        guard case .array(let items)? = value, items.count == 48 else {
            throw ASHLockedVideoMappingV2Error.invalidValue
        }
        var names = Set<String>()
        for item in items {
            guard case .array(let pair) = item, pair.count == 2,
                  case .string(let name) = pair[0], !name.isEmpty,
                  names.insert(name).inserted else {
                throw ASHLockedVideoMappingV2Error.invalidValue
            }
            switch pair[1] {
            case .integer, .string:
                break
            default:
                throw ASHLockedVideoMappingV2Error.invalidValue
            }
        }
    }
}
