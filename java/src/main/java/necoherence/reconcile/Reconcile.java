// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

package necoherence.reconcile;

import java.util.ArrayList;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Optional;
import java.util.Set;
import necoherence.core.Basis;
import necoherence.core.Nat;
import necoherence.core.ResourceId;
import necoherence.core.Revision;
import necoherence.core.World;

/** Reconcile recorded bases against their world. */
public final class Reconcile {
    private Reconcile() {}
    private static List<ResourceId> resourcesOf(List<Optional<Basis>> bases) {
        Set<ResourceId> seen = new LinkedHashSet<>();
        for (Optional<Basis> mb : bases) mb.ifPresent(b -> seen.add(b.resource()));
        return List.copyOf(seen);
    }
    private static Optional<Revision> maxRevision(List<Optional<Basis>> bases, ResourceId resource) {
        Optional<Revision> acc = Optional.empty();
        for (Optional<Basis> mb : bases) if (mb.isPresent() && mb.get().resource().equals(resource)) {
            Revision candidate = mb.get().revision();
            if (acc.isEmpty() || acc.get().compareTo(candidate) < 0) acc = Optional.of(candidate);
        }
        return acc;
    }
    private static Optional<Divergence> divergenceAt(World world, ResourceId resource, Revision recorded) {
        for (World.Entry entry : world.entries()) if (entry.resource().equals(resource)) {
            if (entry.revision().compareTo(recorded.successor()) > 0)
                return Optional.of(new Divergence.WorldAhead(resource, recorded, entry.revision()));
            if (entry.revision().compareTo(recorded) < 0)
                return Optional.of(new Divergence.WorldBehind(resource, recorded, entry.revision()));
            return Optional.empty();
        }
        return Optional.of(new Divergence.UnknownToWorld(resource, recorded));
    }
    public static Reconciliation reconcile(List<Optional<Basis>> bases, World world, Nat dropped) {
        List<Divergence> divergences = new ArrayList<>();
        for (ResourceId resource : resourcesOf(bases)) maxRevision(bases, resource).flatMap(r -> divergenceAt(world, resource, r)).ifPresent(divergences::add);
        return new Reconciliation(divergences, Nat.fromLong(bases.stream().filter(Optional::isEmpty).count()), dropped);
    }
    public static boolean coherent(Reconciliation r) { return r.divergences().isEmpty() && r.unbased().isZero() && r.dropped().isZero(); }
}
