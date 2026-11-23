// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

package necoherence.progression;

import necoherence.core.Nat;

/** Cost-based selection between immediate execution and remaining pending. */
public sealed interface CostSelection permits CostSelection.ExecuteNow, CostSelection.RemainPending {
    RequestIdentity identity();
    EvidenceVersion evidence();
    Nat cost();
    record ExecuteNow(RequestIdentity identity, EvidenceVersion evidence, Nat cost) implements CostSelection {}
    record RemainPending(RequestIdentity identity, EvidenceVersion evidence, Nat cost) implements CostSelection {}
}
