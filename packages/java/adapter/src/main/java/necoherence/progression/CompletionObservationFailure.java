// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

package necoherence.progression;

/** Closed failures while applying a completion or cancellation observation. */
public sealed interface CompletionObservationFailure
        permits CompletionObservationFailure.UnknownCompletion, CompletionObservationFailure.CompletionNotRunning,
        CompletionObservationFailure.HandleMismatch, CompletionObservationFailure.CompletionIdentityMismatch,
        CompletionObservationFailure.CompletionSignalMismatch,
        CompletionObservationFailure.CompletionAdapterFailureObserved,
        CompletionObservationFailure.CancellationAdapterFailureObserved {

    record UnknownCompletion(RequestIdentity identity) implements CompletionObservationFailure {}
    record CompletionNotRunning(RequestIdentity identity) implements CompletionObservationFailure {}
    record HandleMismatch(RequestIdentity identity) implements CompletionObservationFailure {}
    record CompletionIdentityMismatch(RequestIdentity identity, RequestIdentity other) implements CompletionObservationFailure {}
    record CompletionSignalMismatch(RequestIdentity identity) implements CompletionObservationFailure {}
    record CompletionAdapterFailureObserved(RequestIdentity identity, String detail) implements CompletionObservationFailure {}
    record CancellationAdapterFailureObserved(RequestIdentity identity, String detail) implements CompletionObservationFailure {}
}
