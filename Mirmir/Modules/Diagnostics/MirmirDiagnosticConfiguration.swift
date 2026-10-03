import Darwin
import Foundation
import Metal

struct MirmirDiagnosticRuntimeIdentity: Equatable, Sendable {
    let applicationName: String
    let applicationVersion: String
    let applicationBuild: String
    let bundleIdentifier: String
    let operatingSystemVersion: String
    let operatingSystemBuild: String?
    let architecture: String
    let processName: String
    let processIdentifier: Int32
    let metalDeviceName: String?

    static func current() -> Self {
        let bundle = Bundle.main
        let process = ProcessInfo.processInfo
        return Self(
            applicationName: bundle.object(
                forInfoDictionaryKey: "CFBundleDisplayName"
            ) as? String
                ?? bundle.object(
                    forInfoDictionaryKey: "CFBundleName"
                ) as? String
                ?? process.processName,
            applicationVersion: bundle.object(
                forInfoDictionaryKey: "CFBundleShortVersionString"
            ) as? String ?? "unknown",
            applicationBuild: bundle.object(
                forInfoDictionaryKey: "CFBundleVersion"
            ) as? String ?? "unknown",
            bundleIdentifier: bundle.bundleIdentifier ?? "unknown",
            operatingSystemVersion: process.operatingSystemVersionString,
            operatingSystemBuild: systemString("kern.osversion"),
            architecture: currentArchitecture,
            processName: process.processName,
            processIdentifier: process.processIdentifier,
            metalDeviceName: MTLCreateSystemDefaultDevice()?.name
        )
    }

    private static var currentArchitecture: String {
#if arch(arm64)
        "arm64"
#elseif arch(x86_64)
        "x86_64"
#else
        "unknown"
#endif
    }

    private static func systemString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0,
              size > 1 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else {
            return nil
        }
        return String(cString: buffer)
    }
}

struct MirmirDiagnosticRetentionPolicy: Equatable, Sendable {
    static let production = MirmirDiagnosticRetentionPolicy(
        maximumAgeMilliseconds: 90 * 24 * 60 * 60 * 1_000,
        maximumRecords: 50_000,
        maximumTotalBytes: 128 * 1_024 * 1_024,
        maximumRecordBytes: 128 * 1_024,
        validated: true
    )

    let maximumAgeMilliseconds: Int64
    let maximumRecords: Int
    let maximumTotalBytes: Int
    let maximumRecordBytes: Int

    init(
        maximumAgeMilliseconds: Int64,
        maximumRecords: Int,
        maximumTotalBytes: Int,
        maximumRecordBytes: Int
    ) throws {
        guard maximumAgeMilliseconds > 0,
              maximumAgeMilliseconds <= 10 * 366 * 24 * 60 * 60 * 1_000,
              maximumRecords > 0,
              maximumRecords <= 1_000_000,
              maximumTotalBytes >= 512,
              maximumTotalBytes <= 512 * 1_024 * 1_024,
              maximumRecordBytes >= 128,
              maximumRecordBytes <= 128 * 1_024,
              maximumRecordBytes < maximumTotalBytes else {
            throw MirmirDiagnosticStoreError.invalidRetentionPolicy
        }
        self.init(
            maximumAgeMilliseconds: maximumAgeMilliseconds,
            maximumRecords: maximumRecords,
            maximumTotalBytes: maximumTotalBytes,
            maximumRecordBytes: maximumRecordBytes,
            validated: true
        )
    }

    private init(
        maximumAgeMilliseconds: Int64,
        maximumRecords: Int,
        maximumTotalBytes: Int,
        maximumRecordBytes: Int,
        validated: Bool
    ) {
        precondition(validated)
        self.maximumAgeMilliseconds = maximumAgeMilliseconds
        self.maximumRecords = maximumRecords
        self.maximumTotalBytes = maximumTotalBytes
        self.maximumRecordBytes = maximumRecordBytes
    }
}

struct MirmirDiagnosticClock: Sendable {
    let wallMilliseconds: @Sendable () -> Int64
    let uptimeNanoseconds: @Sendable () -> UInt64

    static let production = MirmirDiagnosticClock(
        wallMilliseconds: {
            let milliseconds = Date().timeIntervalSince1970 * 1_000
            return Int64(max(0, min(milliseconds, Double(Int64.max))).rounded(.down))
        },
        uptimeNanoseconds: {
            DispatchTime.now().uptimeNanoseconds
        }
    )
}

enum MirmirDiagnosticStoreError: Error, Equatable, Sendable {
    case invalidRetentionPolicy
    case recordExceedsByteLimit(observed: Int, maximum: Int)
    case journalCapacityInsufficient
    case sequenceExhausted
    case unsupportedJournalSchema(Int)
    case malformedJournal
    case persistenceFailure(operation: String)
}
