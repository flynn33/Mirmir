import Foundation
import Darwin

// Match MirmirNotarizedSmokeFilesV4.canonicalData(_ value: Any).
do {
    let input = FileHandle.standardInput.readDataToEndOfFile()
    let value = try JSONSerialization.jsonObject(with: input)
    guard JSONSerialization.isValidJSONObject(value) else {
        throw NSError(domain: "PrivateSmokeCanonicalizer", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "invalid JSON object"])
    }
    let canonical = try JSONSerialization.data(
        withJSONObject: value,
        options: [.sortedKeys, .withoutEscapingSlashes]
    )
    FileHandle.standardOutput.write(canonical)
} catch {
    FileHandle.standardError.write(Data(("Foundation canonicalization failed: \(error)\n").utf8))
    exit(1)
}
