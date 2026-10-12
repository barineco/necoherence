// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

package necoherence.progression;

/** Closed result of applying an adapter start observation. */
public sealed interface StartObservationResult
        permits StartObservationResult.Publishing, StartObservationResult.Failed {

    record Publishing(RequestProgressionSnapshot snapshot, Running running) implements StartObservationResult {}
    record Failed(RequestProgressionSnapshot snapshot, StartObservationFailure failure) implements StartObservationResult {}
}
