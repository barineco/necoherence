// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

package necoherence.progression;

import java.util.Optional;

/** Current value of a request retained by the snapshot. */
public record RequestEntry(
        RequestIdentity identity,
        RequestFootprint footprint,
        ResourceDemand demand,
        RequestPhase phase,
        MeaningPermission meaningPermission,
        Optional<CostSelection> costSelection,
        Optional<ExecutionHandle> executionHandle) {

    public RequestEntry withPhase(RequestPhase newPhase) {
        return new RequestEntry(identity, footprint, demand, newPhase, meaningPermission, costSelection, executionHandle);
    }

    public RequestEntry withCostSelection(CostSelection selection) {
        return new RequestEntry(
                identity, footprint, demand, phase, meaningPermission, Optional.of(selection), executionHandle);
    }
}
