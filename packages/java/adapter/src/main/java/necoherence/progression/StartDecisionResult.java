// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

package necoherence.progression;

/** Closed command-decision result for {@link Progression#decideStart}. */
public sealed interface StartDecisionResult
        permits StartDecisionResult.Execute, StartDecisionResult.Deferred, StartDecisionResult.Rejected {

    record Execute(RequestProgressionSnapshot snapshot, Starting starting, AdapterCommand command)
            implements StartDecisionResult {}
    record Deferred(RequestProgressionSnapshot snapshot, Accepted accepted) implements StartDecisionResult {}
    record Rejected(RequestProgressionSnapshot snapshot, StartDecisionFailure failure) implements StartDecisionResult {}
}
