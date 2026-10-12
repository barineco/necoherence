// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

package necoherence.reconcile;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertInstanceOf;
import static org.junit.jupiter.api.Assertions.assertTrue;

import java.math.BigInteger;
import java.util.HashSet;
import java.util.List;
import java.util.Optional;
import java.util.Set;
import necoherence.core.Basis;
import necoherence.core.Nat;
import necoherence.core.ResourceId;
import necoherence.core.Revision;
import necoherence.core.World;
import org.junit.jupiter.api.Test;

/** Tests translating lean/Necoherence/Reconcile.lean. */
final class ReconcileTest {

    private static ResourceId rid(String name) {
        return new ResourceId("core", name);
    }

    private static Nat nat(long value) {
        return Nat.fromLong(value);
    }

    private static Revision rev(long value) {
        return ((necoherence.core.Validation.Valid<Revision>) Revision.of(BigInteger.valueOf(value))).value();
    }

    private static Basis basis(String resource, long revision) {
        return new Basis(rid(resource), rev(revision));
    }

    private static World world(Object... resourceThenRevisionPairs) {
        List<World.Entry> entries = new java.util.ArrayList<>();
        for (int i = 0; i < resourceThenRevisionPairs.length; i += 2) {
            entries.add(new World.Entry(rid((String) resourceThenRevisionPairs[i]), rev((long) resourceThenRevisionPairs[i + 1])));
        }
        return new World(entries);
    }

    @Test
    void worldAheadByMoreThanOneStepDiverges() {
        List<Optional<Basis>> bases = List.of(Optional.of(basis("a", 1)));
        World world = world("a", 3L);
        Reconciliation r = Reconcile.reconcile(bases, world, Nat.zero());
        assertEquals(1, r.divergences().size());
        Divergence.WorldAhead ahead = assertInstanceOf(Divergence.WorldAhead.class, r.divergences().get(0));
        assertEquals(rev(1), ahead.recorded());
        assertEquals(rev(3), ahead.actual());
    }

    @Test
    void worldAheadByExactlyOneStepIsNotADivergence() {
        List<Optional<Basis>> bases = List.of(Optional.of(basis("a", 1)));
        World world = world("a", 2L);
        Reconciliation r = Reconcile.reconcile(bases, world, Nat.zero());
        assertTrue(r.divergences().isEmpty());
    }

    @Test
    void worldBehindDiverges() {
        List<Optional<Basis>> bases = List.of(Optional.of(basis("a", 5)));
        World world = world("a", 3L);
        Reconciliation r = Reconcile.reconcile(bases, world, Nat.zero());
        assertEquals(1, r.divergences().size());
        Divergence.WorldBehind behind = assertInstanceOf(Divergence.WorldBehind.class, r.divergences().get(0));
        assertEquals(rev(5), behind.recorded());
        assertEquals(rev(3), behind.actual());
    }

    @Test
    void unknownToWorldDivergesWhenTheResourceIsAbsent() {
        List<Optional<Basis>> bases = List.of(Optional.of(basis("a", 1)));
        World world = new World(List.of());
        Reconciliation r = Reconcile.reconcile(bases, world, Nat.zero());
        assertEquals(1, r.divergences().size());
        assertInstanceOf(Divergence.UnknownToWorld.class, r.divergences().get(0));
    }

    @Test
    void unbasedCountsEntriesWithNoBasis() {
        List<Optional<Basis>> bases = List.of(Optional.of(basis("a", 1)), Optional.empty(), Optional.empty());
        World world = world("a", 1L);
        Reconciliation r = Reconcile.reconcile(bases, world, Nat.zero());
        assertEquals(nat(2), r.unbased());
    }

    @Test
    void coherentIsTrueOnlyWhenEveryComponentIsEmpty() {
        Reconciliation coherent = new Reconciliation(List.of(), Nat.zero(), Nat.zero());
        assertTrue(Reconcile.coherent(coherent));

        Reconciliation withUnbased = new Reconciliation(List.of(), Nat.one(), Nat.zero());
        assertFalse(Reconcile.coherent(withUnbased));

        Reconciliation withDropped = new Reconciliation(List.of(), Nat.zero(), Nat.one());
        assertFalse(Reconcile.coherent(withDropped));
    }

    /** Reconciliation's divergence set does not depend on the order of the recorded input. */
    @Test
    void reconcileDivergencesAreOrderIndependentProperty() {
        List<Optional<Basis>> bases1 = List.of(
                Optional.of(basis("a", 1)), Optional.of(basis("b", 5)), Optional.empty(), Optional.of(basis("c", 2)));
        List<Optional<Basis>> bases2 = List.of(
                Optional.of(basis("c", 2)), Optional.empty(), Optional.of(basis("a", 1)), Optional.of(basis("b", 5)));
        World world = world("a", 1L, "b", 3L, "c", 2L);
        Reconciliation r1 = Reconcile.reconcile(bases1, world, Nat.zero());
        Reconciliation r2 = Reconcile.reconcile(bases2, world, Nat.zero());

        Set<Divergence> set1 = new HashSet<>(r1.divergences());
        Set<Divergence> set2 = new HashSet<>(r2.divergences());
        assertEquals(set1, set2);
        assertEquals(r1.unbased(), r2.unbased());
    }

    /** The recorded maximum for a resource is the highest revision named by any basis on it. */
    @Test
    void reconcileUsesTheHighestRecordedRevisionPerResource() {
        List<Optional<Basis>> bases = List.of(
                Optional.of(basis("a", 1)), Optional.of(basis("a", 4)), Optional.of(basis("a", 2)));
        World world = world("a", 4L);
        Reconciliation r = Reconcile.reconcile(bases, world, Nat.zero());
        assertTrue(r.divergences().isEmpty());
    }
}
