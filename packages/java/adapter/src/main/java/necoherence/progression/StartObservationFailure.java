// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

package necoherence.progression;

/** Closed failures while applying a start observation to a preparing entry. */
public sealed interface StartObservationFailure
        permits StartObservationFailure.UnknownRequest, StartObservationFailure.RequestNotStarting,
        StartObservationFailure.StartIdentityMismatch, StartObservationFailure.StartSignalMismatch,
        StartObservationFailure.StartAdapterFailureObserved {

    record UnknownRequest(RequestIdentity identity) implements StartObservationFailure {}
    record RequestNotStarting(RequestIdentity identity) implements StartObservationFailure {}
    record StartIdentityMismatch(RequestIdentity identity, RequestIdentity other) implements StartObservationFailure {}
    record StartSignalMismatch(RequestIdentity identity) implements StartObservationFailure {}
    record StartAdapterFailureObserved(RequestIdentity identity, String detail) implements StartObservationFailure {}
}
