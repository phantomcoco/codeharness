import CryptoKit
import Foundation

public final class PlanGateStateMachine: Sendable {
    public init() {}
    public func transition(from current: PlanGateState, to next: PlanGateState, hasApprovedPlan: Bool = false) throws -> PlanGateState {
        PlanGateTrace.log("state.transition.request current=\(current) next=\(next) hasApprovedPlan=\(hasApprovedPlan)")
        switch (current, next) {
        case (.idle, .planning),
             (.planning, .awaitingApproval),
             (.planning, .failed),
             (.planning, .cancelled),
             (.awaitingApproval, .idle),
             (.awaitingApproval, .failed),
             (.awaitingApproval, .cancelled),
             (.executing, .completed),
             (.executing, .failed),
             (.executing, .cancelled),
             (.completed, .planning),
             (.completed, .idle),
             (.failed, .planning),
             (.failed, .idle),
             (.cancelled, .planning),
             (.cancelled, .idle):
            PlanGateTrace.log("state.transition.allowed current=\(current) next=\(next)")
            return next
        case (.awaitingApproval, .executing) where hasApprovedPlan:
            PlanGateTrace.log("state.transition.allowed current=\(current) next=\(next)")
            return next
        default:
            PlanGateTrace.log("state.transition.rejected current=\(current) next=\(next)")
            throw AppFailure.invalidStateTransition("\(current) -> \(next)")
        }
    }
}
