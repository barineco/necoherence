// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

package necoherence.progression;

import java.util.List;

/**
 * Evidence-backed permission for starting a request. {@code Ordered} allows an
 * {@code OrderedEffect} request to start in policy order; {@code Permitted} does not.
 */
public sealed interface MeaningPermission
        permits MeaningPermission.Permitted, MeaningPermission.Ordered, MeaningPermission.Denied {

    RequestIdentity identity();

    record Permitted(RequestIdentity identity, List<EvidenceVersion> evidence) implements MeaningPermission {
        public Permitted {
            evidence = List.copyOf(evidence);
        }
    }

    record Ordered(RequestIdentity identity, List<EvidenceVersion> evidence) implements MeaningPermission {
        public Ordered {
            evidence = List.copyOf(evidence);
        }
    }

    record Denied(RequestIdentity identity, PermissionDenial reason) implements MeaningPermission {
    }
}
