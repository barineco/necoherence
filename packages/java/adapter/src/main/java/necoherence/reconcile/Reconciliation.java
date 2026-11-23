// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

package necoherence.reconcile;

import java.util.List;
import necoherence.core.Nat;

/** Closed reconciliation product. */
public record Reconciliation(List<Divergence> divergences, Nat unbased, Nat dropped) {
    public Reconciliation { divergences = List.copyOf(divergences); }
}
