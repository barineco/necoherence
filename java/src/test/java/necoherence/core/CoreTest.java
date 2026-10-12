// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

package necoherence.core;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertInstanceOf;
import static org.junit.jupiter.api.Assertions.assertNotEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

import java.math.BigInteger;
import java.util.List;
import java.util.Random;
import java.util.Set;
import java.util.TreeSet;
import org.junit.jupiter.api.Test;

/** Tests translating python/tests/test_core.py. */
final class CoreTest {

    private static ResourceId rid(int name) {
        return new ResourceId("test", Integer.toString(name));
    }

    private static Revision rev(long value) {
        return ((Validation.Valid<Revision>) Revision.of(BigInteger.valueOf(value))).value();
    }

    @Test
    void invalidRevisionIsClosedAndArbitraryPrecisionIsExact() {
        assertInstanceOf(Validation.Invalid.class, Revision.of(BigInteger.valueOf(-1)));
        BigInteger huge = BigInteger.TEN.pow(100);
        Revision revision = ((Validation.Valid<Revision>) Revision.of(huge)).value();
        assertEquals(huge.toString(), revision.value().toString());
    }

    private static World world(int... resourceThenRevisionPairs) {
        List<World.Entry> entries = new java.util.ArrayList<>();
        for (int i = 0; i < resourceThenRevisionPairs.length; i += 2) {
            entries.add(new World.Entry(rid(resourceThenRevisionPairs[i]),
                    rev(resourceThenRevisionPairs[i + 1])));
        }
        return new World(entries);
    }

    private static Command<String> command(int resource, long revision, String intent) {
        return new Command<>(intent, new Basis(rid(resource), rev(revision)));
    }

    @Test
    void outcomeClosure() {
        World w = world(0, 1, 1, 2);
        List<Outcome<Core.AppliedValue<String>, UnknownResource, StaleBasis, Never>> cases = List.of(
                Core.apply(w, command(0, 1, "ok")),
                Core.apply(w, command(99, 0, "missing")),
                Core.apply(w, command(0, 0, "stale")));

        for (var outcome : cases) {
            switch (outcome) {
                case Outcome.Applied<Core.AppliedValue<String>, UnknownResource, StaleBasis, Never> a -> { }
                case Outcome.Rejected<Core.AppliedValue<String>, UnknownResource, StaleBasis, Never> r -> { }
                case Outcome.Conflicted<Core.AppliedValue<String>, UnknownResource, StaleBasis, Never> c -> { }
                case Outcome.BoundaryFailed<Core.AppliedValue<String>, UnknownResource, StaleBasis, Never> b -> { }
            }
        }

        assertInstanceOf(Outcome.Applied.class, cases.get(0));
        assertInstanceOf(Outcome.Rejected.class, cases.get(1));
        assertInstanceOf(Outcome.Conflicted.class, cases.get(2));
    }

    @Test
    void resourceIdIsDeterminedByKindAndNameTogether() {
        assertEquals(new ResourceId("file", "/a"), new ResourceId("file", "/a"));
        assertNotEquals(new ResourceId("file", "/a"), new ResourceId("file", "/b"));
        assertNotEquals(new ResourceId("file", "/a"), new ResourceId("other", "/a"));
    }

    @Test
    void worldLookupIsClosedNoOptionForAbsence() {
        World w = world(0, 3);
        assertEquals(new Lookup.Found(rev(3)), Core.lookup(w, rid(0)));
        assertEquals(new Lookup.Unknown(new UnknownResource(rid(99))), Core.lookup(w, rid(99)));
    }

    @Test
    void basisRetention() {
        Observation<Integer> observation = new Observation<>(42, new Basis(rid(0), rev(5)), Nat.zero());
        Command<String> command = Core.commandOf(observation, "intent");
        assertEquals(observation.basis(), command.basis());
    }

    @Test
    void staleConflict() {
        World w = world(0, 5);
        Command<String> command = command(0, 4, "x");
        var outcome = Core.apply(w, command);
        assertEquals(
                new Outcome.Conflicted<Core.AppliedValue<String>, UnknownResource, StaleBasis, Never>(
                        new StaleBasis(rev(4), rev(5))),
                outcome);
    }

    @Test
    void applyDisjointComm() {
        World w = world(0, 1, 1, 2, 2, 3);
        Command<String> c1 = command(0, 1, "a");
        Command<String> c2 = command(1, 2, "b");

        var o1 = Core.apply(w, c1);
        assertInstanceOf(Outcome.Applied.class, o1);
        World w1 = ((Outcome.Applied<Core.AppliedValue<String>, UnknownResource, StaleBasis, Never>) o1)
                .value().world();
        var o12 = Core.apply(w1, c2);
        assertInstanceOf(Outcome.Applied.class, o12);
        World w12 = ((Outcome.Applied<Core.AppliedValue<String>, UnknownResource, StaleBasis, Never>) o12)
                .value().world();

        var o2 = Core.apply(w, c2);
        assertInstanceOf(Outcome.Applied.class, o2);
        World w2 = ((Outcome.Applied<Core.AppliedValue<String>, UnknownResource, StaleBasis, Never>) o2)
                .value().world();
        var o21 = Core.apply(w2, c1);
        assertInstanceOf(Outcome.Applied.class, o21);
        World w21 = ((Outcome.Applied<Core.AppliedValue<String>, UnknownResource, StaleBasis, Never>) o21)
                .value().world();

        for (ResourceId resource : List.of(rid(0), rid(1), rid(2), rid(99))) {
            assertEquals(Core.lookup(w12, resource), Core.lookup(w21, resource));
        }
    }

    @Test
    void counterexampleDiscardedBasis() {
        ResourceId res = rid(0);
        World w = new World(List.of(new World.Entry(res, rev(5))));
        Observation<Integer> observation = new Observation<>(42, new Basis(res, rev(5)), Nat.zero());
        Command<Integer> command = new Command<>(observation.payload(), new Basis(res, rev(4)));
        var outcome = Core.apply(w, command);
        assertInstanceOf(Outcome.Conflicted.class, outcome);
    }

    @Test
    void recordsAreImmutableByConstruction() {
        // records have no setters at all: this is a compile-time property,
        // demonstrated here by the absence of any mutator to call. World's
        // entries list is defensively copied in its canonical constructor
        // (see World.java), so a caller-held mutable list cannot reach in.
        java.util.ArrayList<World.Entry> mutable = new java.util.ArrayList<>();
        mutable.add(new World.Entry(rid(0), rev(1)));
        World w = new World(mutable);
        mutable.add(new World.Entry(rid(1), rev(1)));
        assertEquals(1, w.entries().size());
        org.junit.jupiter.api.Assertions.assertThrows(
                UnsupportedOperationException.class, () -> w.entries().add(new World.Entry(rid(2), rev(1))));
    }

    /**
     * Property-based check matching
     * {@code test_apply_disjoint_comm_property} in python/tests/test_core.py,
     * run as a fixed-seed randomized loop.
     */
    @Test
    void applyDisjointCommProperty() {
        Random random = new Random(20260806);
        for (int trial = 0; trial < 200; trial++) {
            int resourceCount = 2 + random.nextInt(7);
            Set<Integer> names = new TreeSet<>();
            while (names.size() < resourceCount) {
                names.add(random.nextInt(21));
            }
            List<Integer> nameList = List.copyOf(names);
            List<World.Entry> entries = new java.util.ArrayList<>();
            for (int name : nameList) {
                entries.add(new World.Entry(rid(name), rev(random.nextInt(51))));
            }
            World w = new World(entries);

            int i1 = random.nextInt(entries.size());
            int i2;
            do {
                i2 = random.nextInt(entries.size());
            } while (i2 == i1);

            World.Entry e1 = entries.get(i1);
            World.Entry e2 = entries.get(i2);
            Command<String> c1 = new Command<>("a", new Basis(e1.resource(), e1.revision()));
            Command<String> c2 = new Command<>("b", new Basis(e2.resource(), e2.revision()));

            var o1 = Core.apply(w, c1);
            var o2 = Core.apply(w, c2);
            assertInstanceOf(Outcome.Applied.class, o1);
            assertInstanceOf(Outcome.Applied.class, o2);
            World w1 = ((Outcome.Applied<Core.AppliedValue<String>, UnknownResource, StaleBasis, Never>) o1)
                    .value().world();
            World w2 = ((Outcome.Applied<Core.AppliedValue<String>, UnknownResource, StaleBasis, Never>) o2)
                    .value().world();

            var o12 = Core.apply(w1, c2);
            var o21 = Core.apply(w2, c1);
            assertInstanceOf(Outcome.Applied.class, o12);
            assertInstanceOf(Outcome.Applied.class, o21);
            World w12 = ((Outcome.Applied<Core.AppliedValue<String>, UnknownResource, StaleBasis, Never>) o12)
                    .value().world();
            World w21 = ((Outcome.Applied<Core.AppliedValue<String>, UnknownResource, StaleBasis, Never>) o21)
                    .value().world();

            Set<ResourceId> observed = new java.util.LinkedHashSet<>();
            for (int name : nameList) {
                observed.add(rid(name));
            }
            observed.add(rid(-1));
            for (ResourceId resource : observed) {
                assertEquals(Core.lookup(w12, resource), Core.lookup(w21, resource));
            }
        }
    }
}
