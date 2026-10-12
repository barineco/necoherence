// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

package necoherence.progression;

/** Closed result of applying a completion or cancellation observation. */
public sealed interface CompletionObservationResult<Result>
        permits CompletionObservationResult.Applied, CompletionObservationResult.Superseded,
        CompletionObservationResult.Cancelled, CompletionObservationResult.Failed {

    record Applied<Result>(RequestProgressionSnapshot snapshot, RequestIdentity identity, Result value)
            implements CompletionObservationResult<Result> {}
    record Superseded<Result>(RequestProgressionSnapshot snapshot, RequestIdentity identity)
            implements CompletionObservationResult<Result> {}
    record Cancelled<Result>(RequestProgressionSnapshot snapshot, RequestIdentity identity)
            implements CompletionObservationResult<Result> {}
    record Failed<Result>(RequestProgressionSnapshot snapshot, CompletionObservationFailure failure)
            implements CompletionObservationResult<Result> {}
}
