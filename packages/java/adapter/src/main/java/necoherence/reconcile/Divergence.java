// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

package necoherence.reconcile;

import necoherence.core.ResourceId;
import necoherence.core.Revision;

/** One resource where the recorded history and the world disagree. */
public sealed interface Divergence permits Divergence.WorldAhead, Divergence.WorldBehind, Divergence.UnknownToWorld {

    ResourceId resource();

    record WorldAhead(ResourceId resource, Revision recorded, Revision actual) implements Divergence {
    }

    record WorldBehind(ResourceId resource, Revision recorded, Revision actual) implements Divergence {
    }

    record UnknownToWorld(ResourceId resource, Revision recorded) implements Divergence {
    }
}
