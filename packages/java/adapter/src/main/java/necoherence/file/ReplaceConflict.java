// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

package necoherence.file;

import necoherence.core.StaleBasis;

/** Closed conflict: the world revision is stale, or the file's digest was mutated externally. */
public sealed interface ReplaceConflict permits ReplaceConflict.StaleBasisConflict, ReplaceConflict.ExternalMutationConflict {

    record StaleBasisConflict(StaleBasis staleBasis) implements ReplaceConflict {
    }

    record ExternalMutationConflict(ExternalMutation mutation) implements ReplaceConflict {
    }
}
