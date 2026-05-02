import Foundation

public struct SemVer: Codable, Hashable, Comparable, Sendable {
    public let major: Int
    public let minor: Int
    public let patch: Int
    public let prerelease: String?

    public init(major: Int, minor: Int, patch: Int, prerelease: String? = nil) {
        self.major = major
        self.minor = minor
        self.patch = patch
        self.prerelease = prerelease?.isEmpty == true ? nil : prerelease
    }

    public init(parsing value: String) throws {
        let prereleaseSplit = value.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: true)
        let numericPart = prereleaseSplit.first.map(String.init) ?? value
        let numericComponents = numericPart.split(separator: ".", omittingEmptySubsequences: false)

        guard numericComponents.count == 3,
              let major = Int(numericComponents[0]),
              let minor = Int(numericComponents[1]),
              let patch = Int(numericComponents[2])
        else {
            throw SemVerParseError.invalidFormat(value)
        }

        self.init(
            major: major,
            minor: minor,
            patch: patch,
            prerelease: prereleaseSplit.count > 1 ? String(prereleaseSplit[1]) : nil
        )
    }

    public var description: String {
        if let prerelease {
            return "\(major).\(minor).\(patch)-\(prerelease)"
        }
        return "\(major).\(minor).\(patch)"
    }

    public static func < (lhs: SemVer, rhs: SemVer) -> Bool {
        if lhs.major != rhs.major {
            return lhs.major < rhs.major
        }
        if lhs.minor != rhs.minor {
            return lhs.minor < rhs.minor
        }
        if lhs.patch != rhs.patch {
            return lhs.patch < rhs.patch
        }

        switch (lhs.prerelease, rhs.prerelease) {
        case (nil, nil):
            return false
        case (nil, _):
            return false
        case (_, nil):
            return true
        case let (left?, right?):
            return left.localizedStandardCompare(right) == .orderedAscending
        }
    }
}

public enum SemVerParseError: Error, LocalizedError {
    case invalidFormat(String)

    public var errorDescription: String? {
        switch self {
        case let .invalidFormat(input):
            return "Invalid semantic version format: \(input). Expected MAJOR.MINOR.PATCH[-PRERELEASE]."
        }
    }
}
