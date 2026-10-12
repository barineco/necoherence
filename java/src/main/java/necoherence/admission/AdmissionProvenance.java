// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

package necoherence.admission;

import java.util.List;
import necoherence.progression.RequestIdentity;

/**
 * Explicit provenance carried alongside a {@link DynamicAdmissionState}: identities a caller still
 * intends to reuse, and adapter signals not yet folded into their own terminal entry. Neither is
 * inferred from the progression snapshot.
 */
public record AdmissionProvenance(List<RequestIdentity> futureUses, List<AdmissionSignal> outstandingSignals) {

    public AdmissionProvenance {
        futureUses = List.copyOf(futureUses);
        outstandingSignals = List.copyOf(outstandingSignals);
    }
}
