// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

package necoherence.progression;

/** Closed result of building a snapshot. */
public sealed interface SnapshotResult permits SnapshotResult.Built, SnapshotResult.Rejected {

    record Built(RequestProgressionSnapshot snapshot) implements SnapshotResult {
    }

    record Rejected(SnapshotFailure failure) implements SnapshotResult {
    }
}
