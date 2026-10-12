// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

package necoherence.progression;

/** Closed failures emitted before a start command is derived. */
public sealed interface StartDecisionFailure
        permits StartDecisionFailure.UnknownRequest, StartDecisionFailure.RequestNotPending,
        StartDecisionFailure.PolicyOrderBlocked, StartDecisionFailure.PermissionDenied,
        StartDecisionFailure.PermissionIdentityMismatch, StartDecisionFailure.PermissionNotOrdered,
        StartDecisionFailure.CostSelectionIdentityMismatch, StartDecisionFailure.InFlightLimitExceeded,
        StartDecisionFailure.ConcurrentLimitExceeded {

    record UnknownRequest(RequestIdentity identity) implements StartDecisionFailure {}
    record RequestNotPending(RequestIdentity identity) implements StartDecisionFailure {}
    record PolicyOrderBlocked(RequestIdentity identity) implements StartDecisionFailure {}
    record PermissionDenied(RequestIdentity identity, PermissionDenial reason) implements StartDecisionFailure {}
    record PermissionIdentityMismatch(RequestIdentity identity, RequestIdentity other) implements StartDecisionFailure {}
    record PermissionNotOrdered(RequestIdentity identity) implements StartDecisionFailure {}
    record CostSelectionIdentityMismatch(RequestIdentity identity, RequestIdentity other) implements StartDecisionFailure {}
    record InFlightLimitExceeded(ResourceDemand demand, ResourceBudget budget) implements StartDecisionFailure {}
    record ConcurrentLimitExceeded(ResourceDemand demand, ResourceBudget budget) implements StartDecisionFailure {}
}
