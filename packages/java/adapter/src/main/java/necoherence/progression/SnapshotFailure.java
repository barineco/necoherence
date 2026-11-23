// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

package necoherence.progression;

/** Reason why {@link RequestProgressionSnapshot#of} rejects its input. */
public sealed interface SnapshotFailure permits SnapshotFailure.DuplicateIdentity {

    /** Two entries carry the same identity. */
    record DuplicateIdentity(RequestIdentity identity) implements SnapshotFailure {
    }
}
