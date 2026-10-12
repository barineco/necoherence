// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

package necoherence.progression;

/** Start or cancellation command passed to the adapter. */
public sealed interface AdapterCommand permits AdapterCommand.StartCommand, AdapterCommand.CancelCommand {

    record StartCommand(RequestIdentity identity, RequestFootprint footprint) implements AdapterCommand {
    }

    record CancelCommand(RequestIdentity identity, ExecutionHandle handle) implements AdapterCommand {
    }
}
