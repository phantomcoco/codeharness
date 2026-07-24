import CryptoKit
import Foundation

public struct ApprovalBindingService: Sendable {
    public init() {}

    public func fingerprint(plan: ProposedPlan) throws -> String {
        PlanGateTrace.log("approval.fingerprint.start planID=\(plan.id) actions=\(plan.actions.count)")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let fingerprint = SHA256Digest.hash(data: try encoder.encode(plan))
        PlanGateTrace.log("approval.fingerprint.done planID=\(plan.id) prefix=\(fingerprint.prefix(12))")
        return fingerprint
    }

    public func approve(plan: ProposedPlan, at date: Date) throws -> ApprovalRecord {
        PlanGateTrace.log("approval.approve.start planID=\(plan.id)")
        return ApprovalRecord(planID: plan.id, fingerprint: try fingerprint(plan: plan), approvedAt: date)
    }

    public func validate(record: ApprovalRecord?, plan: ProposedPlan?) throws {
        PlanGateTrace.log("approval.validate.start recordPresent=\(record != nil) planPresent=\(plan != nil)")
        guard let record, let plan else { throw AppFailure.planNotApproved }
        guard record.planID == plan.id else { throw AppFailure.approvalMismatch }
        guard try record.fingerprint == fingerprint(plan: plan) else { throw AppFailure.approvalMismatch }
        PlanGateTrace.log("approval.validate.done planID=\(plan.id)")
    }
}
