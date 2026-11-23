// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

package necoherence.reconcile;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import necoherence.core.Basis;
import necoherence.core.Core;
import necoherence.core.Lookup;
import necoherence.core.Nat;
import necoherence.core.ResourceId;
import necoherence.core.Revision;
import necoherence.core.World;

/** Reconcile recorded bases against their world. */
public final class Reconcile {
    private Reconcile() {}
    private static Optional<Divergence> divergenceAt(World world, ResourceId resource, Revision recorded) {
        if (!(Core.lookup(world, resource) instanceof Lookup.Found found)) {
            return Optional.of(new Divergence.UnknownToWorld(resource, recorded));
        }
        Revision actual = found.revision();
        if (actual.compareTo(recorded.successor()) > 0) return Optional.of(new Divergence.WorldAhead(resource, recorded, actual));
        if (actual.compareTo(recorded) < 0) return Optional.of(new Divergence.WorldBehind(resource, recorded, actual));
        return Optional.empty();
    }
    public static Reconciliation reconcile(List<Optional<Basis>> bases, World world, Nat dropped) {
        Map<ResourceId, Revision> latest = new LinkedHashMap<>();
        long unbased = 0;
        for (Optional<Basis> basis : bases) {
            if (basis.isEmpty()) {
                unbased++;
            } else {
                latest.merge(basis.get().resource(), basis.get().revision(), (a, b) -> a.compareTo(b) >= 0 ? a : b);
            }
        }
        List<Divergence> divergences = new ArrayList<>();
        for (Map.Entry<ResourceId, Revision> recorded : latest.entrySet()) {
            divergenceAt(world, recorded.getKey(), recorded.getValue()).ifPresent(divergences::add);
        }
        return new Reconciliation(divergences, Nat.fromLong(unbased), dropped);
    }
    public static boolean coherent(Reconciliation r) { return r.divergences().isEmpty() && r.unbased().isZero() && r.dropped().isZero(); }
}
