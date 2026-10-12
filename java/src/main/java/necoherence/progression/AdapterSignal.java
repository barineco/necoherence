// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

package necoherence.progression;

/** Signal observed from the adapter. The {@code Result} of {@code Completed} retains the complete value unchanged. */
public sealed interface AdapterSignal<Result>
        permits AdapterSignal.Started, AdapterSignal.Completed, AdapterSignal.CancelledAtAdapter {

    record Started<Result>(RequestIdentity identity, ExecutionHandle handle) implements AdapterSignal<Result> {
    }

    record Completed<Result>(RequestIdentity identity, ExecutionHandle handle, Result value)
            implements AdapterSignal<Result> {
    }

    record CancelledAtAdapter<Result>(RequestIdentity identity, ExecutionHandle handle)
            implements AdapterSignal<Result> {
    }
}
