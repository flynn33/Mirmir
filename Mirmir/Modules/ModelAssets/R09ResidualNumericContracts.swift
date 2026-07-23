import Foundation

enum R09ResidualPlaneID: String, CaseIterable, Hashable, Sendable {
    case luma
    case chromaCb = "chroma_cb"
    case chromaCr = "chroma_cr"
}

enum R09ResidualMath {
    static func sign(_ value: Int64) -> Int64 {
        if value < 0 { return -1 }
        if value > 0 { return 1 }
        return 0
    }

    static func magnitude(_ value: Int64) -> Int64 {
        value < 0 ? -value : value
    }
}

enum R09ResidualContractError: Error, Equatable, Sendable {
    case invalidIdentity(field: String)
    case invalidSHA256(field: String)
    case invalidDimension(plane: R09ResidualPlaneID, width: Int, height: Int)
    case sampleCountOverflow(plane: R09ResidualPlaneID, width: Int, height: Int)
    case sampleCountAboveMaximum(plane: R09ResidualPlaneID, actual: Int, maximum: Int)
    case sampleCountMismatch(
        role: String,
        plane: R09ResidualPlaneID,
        expected: Int,
        actual: Int
    )
    case sampleOutOfRange(
        role: String,
        plane: R09ResidualPlaneID,
        index: Int,
        value: Int64
    )
    case planeCountMismatch(role: String, expected: Int, actual: Int)
    case duplicatePlaneID(role: String, plane: R09ResidualPlaneID)
    case missingPlaneID(role: String, plane: R09ResidualPlaneID)
    case planeIdentityMismatch(
        role: String,
        expected: R09ResidualPlaneID,
        actual: R09ResidualPlaneID
    )
    case planeGeometryMismatch(
        role: String,
        plane: R09ResidualPlaneID,
        expectedWidth: Int,
        expectedHeight: Int,
        actualWidth: Int,
        actualHeight: Int
    )
    case invalidLimit(role: String, value: Int64)
    case invalidBudget(role: String, value: Int64)
    case invalidScale(numerator: Int, denominator: Int)
    case invalidFrameOrdinal(role: String, value: Int64)
    case invalidStateGeneration(Int64)
    case invalidReferenceBinding
    case invalidExecutionBinding
}

struct R09UnsignedPlaneQ16: Hashable, Sendable {
    static let scale: Int64 = 65_536
    static let maximumDimension = 64
    static let maximumSampleCount = 4_096

    let id: R09ResidualPlaneID
    let width: Int
    let height: Int
    let samplesQ16: [Int64]

    init(
        id: R09ResidualPlaneID,
        width: Int,
        height: Int,
        samplesQ16: [Int64]
    ) throws {
        let count = try R09ResidualValidation.sampleCount(
            id: id,
            width: width,
            height: height
        )
        guard samplesQ16.count == count else {
            throw R09ResidualContractError.sampleCountMismatch(
                role: "unsigned_q16",
                plane: id,
                expected: count,
                actual: samplesQ16.count
            )
        }
        try R09ResidualValidation.samples(
            samplesQ16,
            role: "unsigned_q16",
            plane: id,
            range: 0...Self.scale
        )
        self.id = id
        self.width = width
        self.height = height
        self.samplesQ16 = samplesQ16
    }
}

struct R09PlanarFrameQ16: Hashable, Sendable {
    let luma: R09UnsignedPlaneQ16
    let chromaCb: R09UnsignedPlaneQ16
    let chromaCr: R09UnsignedPlaneQ16

    init(
        luma: R09UnsignedPlaneQ16,
        chromaCb: R09UnsignedPlaneQ16,
        chromaCr: R09UnsignedPlaneQ16
    ) throws {
        try R09ResidualValidation.requireIdentity(.luma, actual: luma.id, role: "frame")
        try R09ResidualValidation.requireIdentity(
            .chromaCb,
            actual: chromaCb.id,
            role: "frame"
        )
        try R09ResidualValidation.requireIdentity(
            .chromaCr,
            actual: chromaCr.id,
            role: "frame"
        )
        self.luma = luma
        self.chromaCb = chromaCb
        self.chromaCr = chromaCr
    }

    init(planes: [R09UnsignedPlaneQ16]) throws {
        let indexed = try R09ResidualValidation.indexed(
            planes,
            role: "frame",
            id: \R09UnsignedPlaneQ16.id
        )
        try self.init(
            luma: R09ResidualValidation.require(.luma, from: indexed, role: "frame"),
            chromaCb: R09ResidualValidation.require(
                .chromaCb,
                from: indexed,
                role: "frame"
            ),
            chromaCr: R09ResidualValidation.require(
                .chromaCr,
                from: indexed,
                role: "frame"
            )
        )
    }

    var orderedPlanes: [R09UnsignedPlaneQ16] {
        [luma, chromaCb, chromaCr]
    }

    subscript(id: R09ResidualPlaneID) -> R09UnsignedPlaneQ16 {
        switch id {
        case .luma: return luma
        case .chromaCb: return chromaCb
        case .chromaCr: return chromaCr
        }
    }
}

struct R09MaskPlaneQ15: Hashable, Sendable {
    static let maximumSample: Int64 = 32_767

    let id: R09ResidualPlaneID
    let width: Int
    let height: Int
    let samplesQ15: [Int64]

    init(
        id: R09ResidualPlaneID,
        width: Int,
        height: Int,
        samplesQ15: [Int64]
    ) throws {
        let count = try R09ResidualValidation.sampleCount(
            id: id,
            width: width,
            height: height
        )
        guard samplesQ15.count == count else {
            throw R09ResidualContractError.sampleCountMismatch(
                role: "mask_q15",
                plane: id,
                expected: count,
                actual: samplesQ15.count
            )
        }
        try R09ResidualValidation.samples(
            samplesQ15,
            role: "mask_q15",
            plane: id,
            range: 0...Self.maximumSample
        )
        self.id = id
        self.width = width
        self.height = height
        self.samplesQ15 = samplesQ15
    }
}

struct R09PlanarMaskQ15: Hashable, Sendable {
    let luma: R09MaskPlaneQ15
    let chromaCb: R09MaskPlaneQ15
    let chromaCr: R09MaskPlaneQ15

    init(planes: [R09MaskPlaneQ15]) throws {
        let indexed = try R09ResidualValidation.indexed(
            planes,
            role: "mask",
            id: \R09MaskPlaneQ15.id
        )
        luma = try R09ResidualValidation.require(.luma, from: indexed, role: "mask")
        chromaCb = try R09ResidualValidation.require(.chromaCb, from: indexed, role: "mask")
        chromaCr = try R09ResidualValidation.require(.chromaCr, from: indexed, role: "mask")
    }

    var orderedPlanes: [R09MaskPlaneQ15] {
        [luma, chromaCb, chromaCr]
    }

    subscript(id: R09ResidualPlaneID) -> R09MaskPlaneQ15 {
        switch id {
        case .luma: return luma
        case .chromaCb: return chromaCb
        case .chromaCr: return chromaCr
        }
    }
}

struct R09PlaneResidualLimitQ16: Hashable, Sendable {
    static let hardMaximumMagnitude: Int64 = 4_096

    let id: R09ResidualPlaneID
    let maximumMagnitudeQ16: Int64

    init(id: R09ResidualPlaneID, maximumMagnitudeQ16: Int64) throws {
        try R09ResidualValidation.limit(
            maximumMagnitudeQ16,
            role: "plane_\(id.rawValue)"
        )
        self.id = id
        self.maximumMagnitudeQ16 = maximumMagnitudeQ16
    }
}

struct R09PerPlaneResidualLimitsQ16: Hashable, Sendable {
    let luma: R09PlaneResidualLimitQ16
    let chromaCb: R09PlaneResidualLimitQ16
    let chromaCr: R09PlaneResidualLimitQ16

    init(limits: [R09PlaneResidualLimitQ16]) throws {
        let indexed = try R09ResidualValidation.indexed(
            limits,
            role: "plane_limit",
            id: \R09PlaneResidualLimitQ16.id
        )
        luma = try R09ResidualValidation.require(
            .luma,
            from: indexed,
            role: "plane_limit"
        )
        chromaCb = try R09ResidualValidation.require(
            .chromaCb,
            from: indexed,
            role: "plane_limit"
        )
        chromaCr = try R09ResidualValidation.require(
            .chromaCr,
            from: indexed,
            role: "plane_limit"
        )
    }

    subscript(id: R09ResidualPlaneID) -> R09PlaneResidualLimitQ16 {
        switch id {
        case .luma: return luma
        case .chromaCb: return chromaCb
        case .chromaCr: return chromaCr
        }
    }
}

enum R09ResidualContentClass: String, CaseIterable, Hashable, Sendable {
    case naturalVideo = "natural_video"
    case animation
    case uiCapture = "ui_capture"
    case mixed
}

struct R09ContentResidualLimitQ16: Hashable, Sendable {
    let contentClass: R09ResidualContentClass
    let maximumMagnitudeQ16: Int64

    init(
        contentClass: R09ResidualContentClass,
        maximumMagnitudeQ16: Int64
    ) throws {
        try R09ResidualValidation.limit(maximumMagnitudeQ16, role: "content")
        self.contentClass = contentClass
        self.maximumMagnitudeQ16 = maximumMagnitudeQ16
    }
}

struct R09EdgeLimitPlaneQ16: Hashable, Sendable {
    let id: R09ResidualPlaneID
    let width: Int
    let height: Int
    let maximumMagnitudesQ16: [Int64]

    init(
        id: R09ResidualPlaneID,
        width: Int,
        height: Int,
        maximumMagnitudesQ16: [Int64]
    ) throws {
        let count = try R09ResidualValidation.sampleCount(
            id: id,
            width: width,
            height: height
        )
        guard maximumMagnitudesQ16.count == count else {
            throw R09ResidualContractError.sampleCountMismatch(
                role: "edge_limit_q16",
                plane: id,
                expected: count,
                actual: maximumMagnitudesQ16.count
            )
        }
        for value in maximumMagnitudesQ16 {
            try R09ResidualValidation.limit(value, role: "edge_\(id.rawValue)")
        }
        self.id = id
        self.width = width
        self.height = height
        self.maximumMagnitudesQ16 = maximumMagnitudesQ16
    }
}

struct R09PlanarEdgeLimitsQ16: Hashable, Sendable {
    let luma: R09EdgeLimitPlaneQ16
    let chromaCb: R09EdgeLimitPlaneQ16
    let chromaCr: R09EdgeLimitPlaneQ16

    init(planes: [R09EdgeLimitPlaneQ16]) throws {
        let indexed = try R09ResidualValidation.indexed(
            planes,
            role: "edge_limit",
            id: \R09EdgeLimitPlaneQ16.id
        )
        luma = try R09ResidualValidation.require(.luma, from: indexed, role: "edge_limit")
        chromaCb = try R09ResidualValidation.require(
            .chromaCb,
            from: indexed,
            role: "edge_limit"
        )
        chromaCr = try R09ResidualValidation.require(
            .chromaCr,
            from: indexed,
            role: "edge_limit"
        )
    }

    subscript(id: R09ResidualPlaneID) -> R09EdgeLimitPlaneQ16 {
        switch id {
        case .luma: return luma
        case .chromaCb: return chromaCb
        case .chromaCr: return chromaCr
        }
    }
}

struct R09ConsistencyLimitsQ16: Hashable, Sendable {
    let sourceMaximumMagnitudeQ16: Int64
    let temporalMaximumMagnitudeQ16: Int64

    init(
        sourceMaximumMagnitudeQ16: Int64,
        temporalMaximumMagnitudeQ16: Int64
    ) throws {
        try R09ResidualValidation.limit(sourceMaximumMagnitudeQ16, role: "source_consistency")
        try R09ResidualValidation.limit(
            temporalMaximumMagnitudeQ16,
            role: "temporal_consistency"
        )
        self.sourceMaximumMagnitudeQ16 = sourceMaximumMagnitudeQ16
        self.temporalMaximumMagnitudeQ16 = temporalMaximumMagnitudeQ16
    }
}

struct R09ResidualLimits: Hashable, Sendable {
    let perPlane: R09PerPlaneResidualLimitsQ16
    let content: R09ContentResidualLimitQ16
    let edge: R09PlanarEdgeLimitsQ16
    let consistency: R09ConsistencyLimitsQ16
}

struct R09SignedResidualPlaneQ16: Hashable, Sendable {
    let id: R09ResidualPlaneID
    let width: Int
    let height: Int
    let samplesQ16: [Int64]

    init(
        id: R09ResidualPlaneID,
        width: Int,
        height: Int,
        samplesQ16: [Int64]
    ) throws {
        let count = try R09ResidualValidation.sampleCount(
            id: id,
            width: width,
            height: height
        )
        guard samplesQ16.count == count else {
            throw R09ResidualContractError.sampleCountMismatch(
                role: "signed_residual_q16",
                plane: id,
                expected: count,
                actual: samplesQ16.count
            )
        }
        let maximum = R09PlaneResidualLimitQ16.hardMaximumMagnitude
        try R09ResidualValidation.samples(
            samplesQ16,
            role: "signed_residual_q16",
            plane: id,
            range: -maximum...maximum
        )
        self.id = id
        self.width = width
        self.height = height
        self.samplesQ16 = samplesQ16
    }
}

struct R09PlanarResidualQ16: Hashable, Sendable {
    let luma: R09SignedResidualPlaneQ16
    let chromaCb: R09SignedResidualPlaneQ16
    let chromaCr: R09SignedResidualPlaneQ16

    init(planes: [R09SignedResidualPlaneQ16]) throws {
        let indexed = try R09ResidualValidation.indexed(
            planes,
            role: "residual",
            id: \R09SignedResidualPlaneQ16.id
        )
        luma = try R09ResidualValidation.require(.luma, from: indexed, role: "residual")
        chromaCb = try R09ResidualValidation.require(
            .chromaCb,
            from: indexed,
            role: "residual"
        )
        chromaCr = try R09ResidualValidation.require(
            .chromaCr,
            from: indexed,
            role: "residual"
        )
    }

    var orderedPlanes: [R09SignedResidualPlaneQ16] {
        [luma, chromaCb, chromaCr]
    }

    subscript(id: R09ResidualPlaneID) -> R09SignedResidualPlaneQ16 {
        switch id {
        case .luma: return luma
        case .chromaCb: return chromaCb
        case .chromaCr: return chromaCr
        }
    }
}
