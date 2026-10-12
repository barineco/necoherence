// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

package necoherence.progression;

/**
 * Observed adapter result for a command. Java does not execute the adapter and consumes this value as input to a
 * pure function.
 */
public sealed interface AdapterResult<Signal> permits AdapterResult.AppliedSignal, AdapterResult.AdapterFailed {

    record AppliedSignal<Signal>(Signal signal) implements AdapterResult<Signal> {
    }

    record AdapterFailed<Signal>(AdapterFailure failure) implements AdapterResult<Signal> {
    }
}
