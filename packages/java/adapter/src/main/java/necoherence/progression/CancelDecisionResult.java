// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

package necoherence.progression;

/** Closed result of {@link Progression#decideCancel}. */
public sealed interface CancelDecisionResult
        permits CancelDecisionResult.Cancelled, CancelDecisionResult.CancelCommand, CancelDecisionResult.Rejected {

    record Cancelled(RequestProgressionSnapshot snapshot, RequestIdentity identity) implements CancelDecisionResult {}
    record CancelCommand(RequestProgressionSnapshot snapshot, Running running, AdapterCommand command)
            implements CancelDecisionResult {}
    record Rejected(RequestProgressionSnapshot snapshot, CancelFailure failure) implements CancelDecisionResult {}
}
