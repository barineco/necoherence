// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

package necoherence.admission;

import necoherence.progression.RequestProgressionSnapshot;
import necoherence.progression.ResourceBudget;

/** Dynamic admission state: the progression snapshot, its configured safety limit, and provenance. */
public record DynamicAdmissionState(
        RequestProgressionSnapshot progression, ResourceBudget configuredSafetyLimit, AdmissionProvenance provenance) {

    public DynamicAdmissionState withProgression(RequestProgressionSnapshot newProgression) {
        return new DynamicAdmissionState(newProgression, configuredSafetyLimit, provenance);
    }
}
