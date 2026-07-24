import CryptoKit
import Foundation

public final class HarnessStateMachine: Sendable {
    public init() {}
    public func transition(from current: HarnessState, to next: HarnessState, hasApprovedPlan: Bool = false) throws -> HarnessState {
        HarnessTrace.log("state.transition.request current=\(current) next=\(next) hasApprovedPlan=\(hasApprovedPlan)")
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
            HarnessTrace.log("state.transition.allowed current=\(current) next=\(next)")
            return next
        case (.awaitingApproval, .executing) where hasApprovedPlan:
            HarnessTrace.log("state.transition.allowed current=\(current) next=\(next)")
            return next
        default:
            HarnessTrace.log("state.transition.rejected current=\(current) next=\(next)")
            throw AppFailure.invalidStateTransition("\(current) -> \(next)")
        }
    }
}
