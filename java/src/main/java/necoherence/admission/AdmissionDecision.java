// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

package necoherence.admission;

import necoherence.progression.Accepted;
import necoherence.progression.RequestIdentity;
import necoherence.progression.StartDecisionResult;

/** Closed admit value: which request-progression connection produced the new state. */
public sealed interface AdmissionDecision
        permits AdmissionDecision.Submitted, AdmissionDecision.Started, AdmissionDecision.Coalesced {

    record Submitted(DynamicAdmissionState state, Accepted accepted) implements AdmissionDecision {}
    record Started(DynamicAdmissionState state, StartDecisionResult result) implements AdmissionDecision {}
    record Coalesced(DynamicAdmissionState state, RequestIdentity identity) implements AdmissionDecision {}
}
