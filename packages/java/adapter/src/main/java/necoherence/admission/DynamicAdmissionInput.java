// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

package necoherence.admission;

import java.util.Optional;
import necoherence.core.Nat;
import necoherence.progression.CostSelection;
import necoherence.progression.RequestInput;

/** One admission request; adapter observations are applied outside admission. */
public record DynamicAdmissionInput(DynamicAdmissionState state, RequestInput request,
        EnvironmentSpecification environmentSpecification, CapacityObservation capacityObservation,
        Nat observedAt, Optional<CostSelection> start) {}
