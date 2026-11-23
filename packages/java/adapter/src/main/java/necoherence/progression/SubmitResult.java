// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

package necoherence.progression;

/** Closed result of submit. Success returns an {@link Accepted} token. */
public sealed interface SubmitResult permits SubmitResult.SubmitAccepted, SubmitResult.SubmitRejected {

    record SubmitAccepted(RequestProgressionSnapshot snapshot, Accepted accepted) implements SubmitResult {
    }

    record SubmitRejected(RequestProgressionSnapshot snapshot, SubmitFailure failure) implements SubmitResult {
    }
}
