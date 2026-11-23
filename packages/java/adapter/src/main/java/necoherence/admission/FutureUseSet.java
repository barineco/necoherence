// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

package necoherence.admission;

import java.util.List;
import necoherence.progression.RequestIdentity;

/** Identities whose data a caller still intends to use again, read from {@link AdmissionProvenance}. */
public record FutureUseSet(List<RequestIdentity> identities) {

    public FutureUseSet {
        identities = List.copyOf(identities);
    }
}
