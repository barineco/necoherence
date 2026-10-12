// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

package necoherence.admission;

import necoherence.progression.RequestIdentity;

/** Whether one identity's provenance was erased, or is retained and why. */
public sealed interface ProvenanceErasureWitness
        permits ProvenanceErasureWitness.Erased, ProvenanceErasureWitness.Retained {

    record Erased(RequestIdentity identity) implements ProvenanceErasureWitness {
    }

    record Retained(RequestIdentity identity, String reason) implements ProvenanceErasureWitness {
    }
}
