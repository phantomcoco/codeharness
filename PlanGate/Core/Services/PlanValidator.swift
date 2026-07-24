import CryptoKit
import Foundation

public struct PlanValidator: Sendable {
    public static let maxActions = 3
    private let security: WorkspaceSecurityValidator
    public init(security: WorkspaceSecurityValidator = WorkspaceSecurityValidator()) {
        self.security = security
    }

    public func validate(plan: ProposedPlan, workspace: Workspace) throws {
        PlanGateTrace.log("plan.validate.start planID=\(plan.id) actions=\(plan.actions.count)")
        guard plan.actions.count <= Self.maxActions else { throw AppFailure.unsupportedAction("too many actions") }
        let writes = plan.actions.filter { $0.kind == .writeFile }
        let verifies = plan.actions.filter { $0.kind == .verify }
        guard writes.count <= 2 else { throw AppFailure.tooManyWriteActions }
        guard verifies.count <= 1 else { throw AppFailure.tooManyVerificationActions }
        for write in writes {
            guard let path = write.relativePath else { throw AppFailure.invalidPath("missing relativePath") }
            _ = try security.resolve(relativePath: path, in: workspace)
        }
        if let verify = verifies.first {
            guard verify.commandID == CommandPolicy.swiftTest.id else {
                throw AppFailure.commandNotAllowlisted(verify.commandID ?? "")
            }
        }
        if writes.first != nil, verifies.first != nil {
            guard plan.actions.first?.kind == .writeFile, plan.actions.last?.kind == .verify else {
                throw AppFailure.unsupportedAction("write must precede verify")
            }
        }
        PlanGateTrace.log("plan.validate.done planID=\(plan.id) writes=\(writes.count) verifies=\(verifies.count)")
    }
}
