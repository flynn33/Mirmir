import Foundation

enum MirmirTimedMetadataPolicy {
    static let namespace = "com.mirmir."

    static func validate(_ metadata: [String: String]) throws {
        for (key, value) in metadata {
            guard isValidKey(key) else {
                throw MediaPipelineError.outputMetadataMismatch(
                    "timed metadata key \(key) is outside the controlled \(namespace) namespace"
                )
            }
            guard !value.isEmpty else {
                throw MediaPipelineError.outputMetadataMismatch(
                    "timed metadata value for \(key) is empty"
                )
            }
        }
    }

    static func isValidKey(_ key: String) -> Bool {
        guard key.hasPrefix(namespace),
              key.count > namespace.count else {
            return false
        }
        return key.unicodeScalars.allSatisfy { scalar in
            !CharacterSet.whitespacesAndNewlines.contains(scalar)
                && !CharacterSet.controlCharacters.contains(scalar)
        }
    }
}
