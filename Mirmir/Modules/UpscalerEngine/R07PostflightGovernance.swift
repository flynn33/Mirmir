import Foundation

enum R07PostflightGovernanceError: Error, Equatable, Sendable {
    case invalidIdentity(field: String)
    case decisionNotCompleted
    case targetDecisionOrdinalOverflow(UInt64)
}

struct R07CompletedR06Decision: Equatable, Sendable {
    let shotID: String
    let decisionOrdinal: UInt64
    let record: R06ASHDecisionRecord

    init(
        shotID: String,
        decisionOrdinal: UInt64,
        record: R06ASHDecisionRecord,
        decisionCompleted: Bool
    ) throws {
        guard decisionCompleted else {
            throw R07PostflightGovernanceError.decisionNotCompleted
        }
        self.shotID = try Self.requireIdentity(shotID, field: "completed_decision.shot_id")
        self.decisionOrdinal = decisionOrdinal
        self.record = record
    }

    private static func requireIdentity(
        _ value: String,
        field: String
    ) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, value == trimmed else {
            throw R07PostflightGovernanceError.invalidIdentity(field: field)
        }
        return value
    }
}

struct R07PostflightReport: Equatable, Sendable {
    let reportID: String
    let shotID: String
    let decisionOrdinal: UInt64
    let findings: R06ASHPostflightFindings

    init(
        reportID: String,
        shotID: String,
        decisionOrdinal: UInt64,
        findings: R06ASHPostflightFindings
    ) throws {
        self.reportID = try Self.requireIdentity(reportID, field: "report_id")
        self.shotID = try Self.requireIdentity(shotID, field: "report.shot_id")
        self.decisionOrdinal = decisionOrdinal
        self.findings = findings
    }

    private static func requireIdentity(
        _ value: String,
        field: String
    ) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, value == trimmed else {
            throw R07PostflightGovernanceError.invalidIdentity(field: field)
        }
        return value
    }
}

struct R07PostflightFeedback: Equatable, Sendable {
    let reportID: String
    let shotID: String
    let sourceDecisionOrdinal: UInt64
    let targetDecisionOrdinal: UInt64
    let findings: R06ASHPostflightFindings

    var artifactRiskQ16: R06ASHQ16 { findings.riskQ16 }
    var findingIDs: [String] { findings.findings.map(\.id) }
}

enum R07PostflightRejection: String, CaseIterable, Hashable, Sendable {
    case duplicate
    case crossShot = "cross_shot"
    case stale
    case future

    static let precedence: [R07PostflightRejection] = [
        .duplicate,
        .crossShot,
        .stale,
        .future
    ]
}

struct R07PostflightInvalidity: Hashable, Sendable {
    let duplicate: Bool
    let crossShot: Bool
    let stale: Bool
    let future: Bool
}

enum R07PostflightDisposition: String, Hashable, Sendable {
    case acceptedScheduledForNPlus1 = "accepted_scheduled_for_n_plus_1"
    case duplicateRejectedDiscarded = "duplicate_rejected_discarded"
    case rejectedDiscarded = "rejected_discarded"
}

struct R07PostflightApplicationResult: Equatable, Sendable {
    let accepted: Bool
    let disposition: R07PostflightDisposition
    let selectedRejection: R07PostflightRejection?
    let feedback: R07PostflightFeedback?
    let rewritesDecisionN: Bool
}

enum R07PostflightGovernanceOutcome: Equatable, Sendable {
    case blocked(R07ProductGateResult)
    case evaluated(R07PostflightApplicationResult)
}

enum R07PostflightBoundaryReason: String, CaseIterable, Hashable, Sendable {
    case sceneCut = "scene_cut"
    case discontinuity
    case callerRequested = "caller_requested"
    case cancellation
    case endOfStream = "end_of_stream"
}

struct R07PostflightBoundaryResult: Hashable, Sendable {
    let reason: R07PostflightBoundaryReason
    let discardedPendingFeedbackCount: Int
    let clearedAcceptedReportIdentityCount: Int
}

struct R07PostflightGovernance: Equatable, Sendable {
    private(set) var acceptedReportIDs: [String] = []
    private(set) var pendingFeedback: [R07PostflightFeedback] = []

    var pendingFeedbackCount: Int { pendingFeedback.count }

    func pendingFeedbackCount(reportID: String) -> Int {
        pendingFeedback.lazy.filter { $0.reportID == reportID }.count
    }

    func feedback(
        forShotID shotID: String,
        decisionOrdinal: UInt64
    ) -> [R07PostflightFeedback] {
        pendingFeedback.filter {
            $0.shotID == shotID && $0.targetDecisionOrdinal == decisionOrdinal
        }
    }

    mutating func consumeFeedback(
        forShotID shotID: String,
        decisionOrdinal: UInt64
    ) throws -> R06ASHPostflightFindings? {
        let validatedShotID = try Self.requireIdentity(
            shotID,
            field: "consume_feedback.shot_id"
        )
        let matchingFeedback = pendingFeedback.filter {
            $0.shotID == validatedShotID
                && $0.targetDecisionOrdinal == decisionOrdinal
        }
        guard !matchingFeedback.isEmpty else { return nil }

        var maximumRiskQ16 = R06ASHQ16.zero
        var mergedFindings: [R06ASHPostflightFinding] = []
        var mergedFindingIDs: Set<String> = []
        for feedback in matchingFeedback {
            maximumRiskQ16 = max(maximumRiskQ16, feedback.artifactRiskQ16)
            for finding in feedback.findings.findings
            where mergedFindingIDs.insert(finding.id).inserted {
                mergedFindings.append(finding)
            }
        }
        let merged = try R06ASHPostflightFindings(
            riskQ16: maximumRiskQ16,
            findings: mergedFindings
        )

        pendingFeedback.removeAll {
            $0.shotID == validatedShotID
                && $0.targetDecisionOrdinal == decisionOrdinal
        }
        return merged
    }

    mutating func apply(
        scope: AppleUpscaleAdmissionScope,
        report: R07PostflightReport,
        to completedDecision: R07CompletedR06Decision
    ) throws -> R07PostflightGovernanceOutcome {
        guard scope != .product else {
            return .blocked(.blocked)
        }

        let invalidity = R07PostflightInvalidity(
            duplicate: acceptedReportIDs.contains(report.reportID),
            crossShot: report.shotID != completedDecision.shotID,
            stale: report.decisionOrdinal < completedDecision.decisionOrdinal,
            future: report.decisionOrdinal > completedDecision.decisionOrdinal
        )
        if let rejection = Self.selectRejection(invalidity) {
            return .evaluated(Self.rejected(rejection, invalidity: invalidity))
        }

        let target = report.decisionOrdinal.addingReportingOverflow(1)
        guard !target.overflow else {
            throw R07PostflightGovernanceError.targetDecisionOrdinalOverflow(
                report.decisionOrdinal
            )
        }
        let feedback = R07PostflightFeedback(
            reportID: report.reportID,
            shotID: report.shotID,
            sourceDecisionOrdinal: report.decisionOrdinal,
            targetDecisionOrdinal: target.partialValue,
            findings: report.findings
        )
        acceptedReportIDs.append(report.reportID)
        pendingFeedback.append(feedback)
        return .evaluated(
            R07PostflightApplicationResult(
                accepted: true,
                disposition: .acceptedScheduledForNPlus1,
                selectedRejection: nil,
                feedback: feedback,
                rewritesDecisionN: false
            )
        )
    }

    mutating func applyBoundary(
        _ reason: R07PostflightBoundaryReason
    ) -> R07PostflightBoundaryResult {
        let result = R07PostflightBoundaryResult(
            reason: reason,
            discardedPendingFeedbackCount: pendingFeedback.count,
            clearedAcceptedReportIdentityCount: acceptedReportIDs.count
        )
        pendingFeedback.removeAll(keepingCapacity: false)
        acceptedReportIDs.removeAll(keepingCapacity: false)
        return result
    }

    static func selectRejection(
        _ invalidity: R07PostflightInvalidity
    ) -> R07PostflightRejection? {
        if invalidity.duplicate { return .duplicate }
        if invalidity.crossShot { return .crossShot }
        if invalidity.stale { return .stale }
        if invalidity.future { return .future }
        return nil
    }

    static func rejectionDisposition(
        _ invalidity: R07PostflightInvalidity
    ) -> R07PostflightDisposition? {
        guard let rejection = selectRejection(invalidity) else { return nil }
        let duplicateOnly = rejection == .duplicate
            && !invalidity.crossShot
            && !invalidity.stale
            && !invalidity.future
        return duplicateOnly ? .duplicateRejectedDiscarded : .rejectedDiscarded
    }

    private static func rejected(
        _ rejection: R07PostflightRejection,
        invalidity: R07PostflightInvalidity
    ) -> R07PostflightApplicationResult {
        guard let disposition = rejectionDisposition(invalidity) else {
            preconditionFailure("Rejected postflight invalidity must select a disposition")
        }
        return R07PostflightApplicationResult(
            accepted: false,
            disposition: disposition,
            selectedRejection: rejection,
            feedback: nil,
            rewritesDecisionN: false
        )
    }

    private static func requireIdentity(
        _ value: String,
        field: String
    ) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, value == trimmed else {
            throw R07PostflightGovernanceError.invalidIdentity(field: field)
        }
        return value
    }
}
