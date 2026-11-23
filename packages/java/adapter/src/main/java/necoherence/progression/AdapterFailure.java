// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

package necoherence.progression;

/** Failure observed from the adapter. */
public sealed interface AdapterFailure
        permits AdapterFailure.StartAdapterFailure, AdapterFailure.CompletionAdapterFailure,
        AdapterFailure.CancellationAdapterFailure {

    record StartAdapterFailure(RequestIdentity identity, String detail) implements AdapterFailure {
    }

    record CompletionAdapterFailure(RequestIdentity identity, ExecutionHandle handle, String detail)
            implements AdapterFailure {
    }

    record CancellationAdapterFailure(RequestIdentity identity, ExecutionHandle handle, String detail)
            implements AdapterFailure {
    }
}
