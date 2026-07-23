import Foundation

enum R09ResidualValidation {
    static func identity(_ value: String, field: String) throws -> String {
        let allowed = CharacterSet(
            charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._:-"
        )
        guard !value.isEmpty,
              value.count <= 128,
              value.unicodeScalars.allSatisfy(allowed.contains) else {
            throw R09ResidualContractError.invalidIdentity(field: field)
        }
        return value
    }

    static func sha256(_ value: String, field: String) throws -> String {
        let lowercaseHex = CharacterSet(charactersIn: "0123456789abcdef")
        guard value.count == 64,
              value.unicodeScalars.allSatisfy(lowercaseHex.contains) else {
            throw R09ResidualContractError.invalidSHA256(field: field)
        }
        return value
    }

    static func sampleCount(
        id: R09ResidualPlaneID,
        width: Int,
        height: Int
    ) throws -> Int {
        guard width > 0,
              height > 0,
              width <= R09UnsignedPlaneQ16.maximumDimension,
              height <= R09UnsignedPlaneQ16.maximumDimension else {
            throw R09ResidualContractError.invalidDimension(
                plane: id,
                width: width,
                height: height
            )
        }
        let count = width.multipliedReportingOverflow(by: height)
        guard !count.overflow else {
            throw R09ResidualContractError.sampleCountOverflow(
                plane: id,
                width: width,
                height: height
            )
        }
        guard count.partialValue <= R09UnsignedPlaneQ16.maximumSampleCount else {
            throw R09ResidualContractError.sampleCountAboveMaximum(
                plane: id,
                actual: count.partialValue,
                maximum: R09UnsignedPlaneQ16.maximumSampleCount
            )
        }
        return count.partialValue
    }

    static func samples(
        _ samples: [Int64],
        role: String,
        plane: R09ResidualPlaneID,
        range: ClosedRange<Int64>
    ) throws {
        if let invalid = samples.enumerated().first(where: { !range.contains($0.element) }) {
            throw R09ResidualContractError.sampleOutOfRange(
                role: role,
                plane: plane,
                index: invalid.offset,
                value: invalid.element
            )
        }
    }

    static func q15(_ value: Int64, role: String) throws {
        guard (0...R09MaskPlaneQ15.maximumSample).contains(value) else {
            throw R09ResidualContractError.invalidLimit(role: role, value: value)
        }
    }

    static func limit(_ value: Int64, role: String) throws {
        guard (0...R09PlaneResidualLimitQ16.hardMaximumMagnitude).contains(value) else {
            throw R09ResidualContractError.invalidLimit(role: role, value: value)
        }
    }

    static func executionBinding(
        mode: R09ResidualExecutionMode,
        nativeExecution: R09NativeExecutionDisposition
    ) throws {
        guard (mode == .deterministicFixtureSimulation && nativeExecution == .notObserved)
                || (mode == .nativeCoreAI && nativeExecution == .observed) else {
            throw R09ResidualContractError.invalidExecutionBinding
        }
    }

    static func requireIdentity(
        _ expected: R09ResidualPlaneID,
        actual: R09ResidualPlaneID,
        role: String
    ) throws {
        guard expected == actual else {
            throw R09ResidualContractError.planeIdentityMismatch(
                role: role,
                expected: expected,
                actual: actual
            )
        }
    }

    static func indexed<Element>(
        _ elements: [Element],
        role: String,
        id: KeyPath<Element, R09ResidualPlaneID>
    ) throws -> [R09ResidualPlaneID: Element] {
        guard elements.count == R09ResidualPlaneID.allCases.count else {
            throw R09ResidualContractError.planeCountMismatch(
                role: role,
                expected: R09ResidualPlaneID.allCases.count,
                actual: elements.count
            )
        }
        var indexed: [R09ResidualPlaneID: Element] = [:]
        for element in elements {
            let planeID = element[keyPath: id]
            guard indexed.updateValue(element, forKey: planeID) == nil else {
                throw R09ResidualContractError.duplicatePlaneID(role: role, plane: planeID)
            }
        }
        return indexed
    }

    static func require<Element>(
        _ id: R09ResidualPlaneID,
        from indexed: [R09ResidualPlaneID: Element],
        role: String
    ) throws -> Element {
        guard let element = indexed[id] else {
            throw R09ResidualContractError.missingPlaneID(role: role, plane: id)
        }
        return element
    }

    static func geometry(
        role: String,
        plane: R09ResidualPlaneID,
        expected: R09UnsignedPlaneQ16,
        actualWidth: Int,
        actualHeight: Int
    ) throws {
        guard actualWidth == expected.width, actualHeight == expected.height else {
            throw R09ResidualContractError.planeGeometryMismatch(
                role: role,
                plane: plane,
                expectedWidth: expected.width,
                expectedHeight: expected.height,
                actualWidth: actualWidth,
                actualHeight: actualHeight
            )
        }
    }
}
