// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

package necoherence.admission;

import necoherence.core.Nat;
import necoherence.progression.PermissionDenial;
import necoherence.progression.RequestIdentity;
import necoherence.progression.StartDecisionFailure;
import necoherence.progression.SubmitFailure;

/** Closed failure of a dynamic admission evaluation or provenance elision. */
public sealed interface DynamicAdmissionFailure
        permits DynamicAdmissionFailure.CapacityObservationUnavailable,
        DynamicAdmissionFailure.ResourceCoordinateMismatch, DynamicAdmissionFailure.ConfiguredSafetyLimitExceeded,
        DynamicAdmissionFailure.MeaningDenied, DynamicAdmissionFailure.PermissionIdentityMismatch,
        DynamicAdmissionFailure.AdapterBindingUnavailable, DynamicAdmissionFailure.BindingSelectionMismatch,
        DynamicAdmissionFailure.ProgressionSubmitFailure, DynamicAdmissionFailure.ProgressionStartFailure,
        DynamicAdmissionFailure.ProvenanceRetentionRequired, DynamicAdmissionFailure.UnknownRequest,
        DynamicAdmissionFailure.RequestNotTerminal {

    record CapacityObservationUnavailable(Nat age, Nat maxAge) implements DynamicAdmissionFailure {}
    record ResourceCoordinateMismatch(String configuredResource, String observedResource) implements DynamicAdmissionFailure {}
    record ConfiguredSafetyLimitExceeded(String resource, Nat occupied, Nat allowed) implements DynamicAdmissionFailure {}
    record MeaningDenied(RequestIdentity identity, PermissionDenial reason) implements DynamicAdmissionFailure {}
    record PermissionIdentityMismatch(RequestIdentity requestIdentity, RequestIdentity permissionIdentity)
            implements DynamicAdmissionFailure {}
    record AdapterBindingUnavailable(RequestIdentity identity) implements DynamicAdmissionFailure {}
    record BindingSelectionMismatch(RequestIdentity identity) implements DynamicAdmissionFailure {}
    record ProgressionSubmitFailure(SubmitFailure failure) implements DynamicAdmissionFailure {}
    record ProgressionStartFailure(StartDecisionFailure failure) implements DynamicAdmissionFailure {}
    record ProvenanceRetentionRequired(RequestIdentity identity) implements DynamicAdmissionFailure {}
    record UnknownRequest(RequestIdentity identity) implements DynamicAdmissionFailure {}
    record RequestNotTerminal(RequestIdentity identity) implements DynamicAdmissionFailure {}
}
