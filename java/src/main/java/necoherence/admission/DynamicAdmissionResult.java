// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

package necoherence.admission;

import java.util.Optional;
import necoherence.progression.ResourceBudget;

/** Result of one successful dynamic admission evaluation; all six declared fields are always present. */
public record DynamicAdmissionResult(
        ResourceBudget effectiveBudget,
        AdmissionDecision admissionDecision,
        FutureUseSet futureUseSet,
        OutstandingSignalSet outstandingSignalSet,
        Optional<ProvenanceErasureWitness> provenanceErasureWitness,
        CoalescingWitness coalescingWitness) {
}
