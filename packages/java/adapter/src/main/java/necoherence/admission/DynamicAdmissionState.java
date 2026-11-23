// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

package necoherence.admission;

import java.util.HashSet;
import java.util.Set;
import necoherence.progression.RequestIdentity;
import necoherence.progression.RequestProgressionSnapshot;
import necoherence.progression.ResourceBudget;

/**
 * Dynamic admission state: the progression snapshot, its configured safety limit, and provenance.
 *
 * <p>{@link #of} is the only way to build a state. A state also holds the identities of the provenance's
 * future uses and outstanding signals as sets, so that membership is decided without reading the lists;
 * operations that replace the progression keep the provenance and its sets as they are.
 */
public final class DynamicAdmissionState {
    private final RequestProgressionSnapshot progression;
    private final ResourceBudget configuredSafetyLimit;
    private final AdmissionProvenance provenance;
    private final Set<RequestIdentity> futureUseIdentities;
    private final Set<RequestIdentity> signalIdentities;

    private DynamicAdmissionState(RequestProgressionSnapshot progression, ResourceBudget configuredSafetyLimit,
            AdmissionProvenance provenance, Set<RequestIdentity> futureUseIdentities,
            Set<RequestIdentity> signalIdentities) {
        this.progression = progression;
        this.configuredSafetyLimit = configuredSafetyLimit;
        this.provenance = provenance;
        this.futureUseIdentities = futureUseIdentities;
        this.signalIdentities = signalIdentities;
    }

    public static DynamicAdmissionState of(
            RequestProgressionSnapshot progression, ResourceBudget configuredSafetyLimit,
            AdmissionProvenance provenance) {
        Set<RequestIdentity> futureUses = new HashSet<>(provenance.futureUses());
        Set<RequestIdentity> signals = new HashSet<>();
        for (AdmissionSignal signal : provenance.outstandingSignals()) {
            signals.add(signal.identity());
        }
        return new DynamicAdmissionState(progression, configuredSafetyLimit, provenance, futureUses, signals);
    }

    public RequestProgressionSnapshot progression() {
        return progression;
    }

    public ResourceBudget configuredSafetyLimit() {
        return configuredSafetyLimit;
    }

    public AdmissionProvenance provenance() {
        return provenance;
    }

    public DynamicAdmissionState withProgression(RequestProgressionSnapshot newProgression) {
        return new DynamicAdmissionState(
                newProgression, configuredSafetyLimit, provenance, futureUseIdentities, signalIdentities);
    }

    boolean retainsFutureUse(RequestIdentity identity) {
        return futureUseIdentities.contains(identity);
    }

    boolean hasOutstandingSignal(RequestIdentity identity) {
        return signalIdentities.contains(identity);
    }

    @Override
    public boolean equals(Object other) {
        return other instanceof DynamicAdmissionState state
                && progression.equals(state.progression)
                && configuredSafetyLimit.equals(state.configuredSafetyLimit)
                && provenance.equals(state.provenance);
    }

    @Override
    public int hashCode() {
        return java.util.Objects.hash(progression, configuredSafetyLimit, provenance);
    }

    @Override
    public String toString() {
        return "DynamicAdmissionState[progression=" + progression + ", configuredSafetyLimit="
                + configuredSafetyLimit + ", provenance=" + provenance + "]";
    }
}
