// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

package necoherence.admission;

import java.util.Optional;
import neco.quotient.retention.DematerializeWitness;
import necoherence.progression.RequestIdentity;
import necoherence.progression.ResourceBudget;

/** Result of one successful dynamic admission evaluation; all six declared fields are always present. */
public record DynamicAdmissionResult(
        ResourceBudget effectiveBudget,
        AdmissionDecision admissionDecision,
        FutureUseSet futureUseSet,
        OutstandingSignalSet outstandingSignalSet,
        Optional<DematerializeWitness<RequestIdentity, Void, Void, ProvenanceObservation>> provenanceErasureWitness,
        CoalescingWitness coalescingWitness) {
}
