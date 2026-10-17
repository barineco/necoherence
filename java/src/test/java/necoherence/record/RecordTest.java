// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

package necoherence.record;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;

import java.math.BigInteger;
import java.util.List;
import java.util.Random;
import necoherence.core.Basis;
import necoherence.core.Command;
import necoherence.core.Core;
import necoherence.core.Outcome;
import necoherence.core.ResourceId;
import necoherence.core.Revision;
import necoherence.core.World;
import org.junit.jupiter.api.Test;


final class RecordTest {

    private static ResourceId rid(int name) {
        return new ResourceId("core", Integer.toString(name));
    }

    private static Revision rev(long value) {
        return ((necoherence.core.Validation.Valid<Revision>) Revision.of(BigInteger.valueOf(value))).value();
    }

    private static Basis basis(int resource, long revision) {
        return new Basis(rid(resource), rev(revision));
    }

    private static World world(int[] resources, long[] revisions) {
        List<World.Entry> entries = new java.util.ArrayList<>();
        for (int i = 0; i < resources.length; i++) {
            entries.add(new World.Entry(rid(resources[i]), rev(revisions[i])));
        }
        return new World(entries);
    }

    @Test
    void aRecordHoldsDeclarationInputAndProduct() {
        CallRecord<String, String> held = Record.recordOf("example.greet", "world", "hello world");
        assertEquals("example.greet", held.declaration());
        assertEquals("world", held.input());
        assertEquals("hello world", held.product());
        assertEquals(new RecordBasis.Unsituated(), held.basis());
    }

    @Test
    void anEdgeHoldsWhereALaterCallReadsTheSettledResource() {
        CallRecord<Long, String> earlier = Record.recordOnBasis("pane.apply", 1L, "applied", basis(3, 7));
        CallRecord<Long, String> later = Record.recordOnBasis("pane.apply", 2L, "conflicted", basis(3, 7));
        CallRecord<Long, String> disjoint = Record.recordOnBasis("pane.apply", 3L, "applied", basis(4, 1));

        assertTrue(Record.hasEdge(earlier, later));
        assertFalse(Record.hasEdge(earlier, disjoint));
    }

    @Test
    void aRecordWithoutABasisFormsNoEdge() {
        CallRecord<Long, String> earlier = Record.recordOf("example.greet", 1L, "one");
        CallRecord<Long, String> later = Record.recordOnBasis("pane.apply", 2L, "two", basis(3, 7));

        assertFalse(Record.hasEdge(earlier, later));
        assertFalse(Record.hasEdge(later, earlier));
    }

    @Test
    void aStaleConflictHoldsTheConflictedOutcomeInItsProduct() {
        World before = world(new int[] {0}, new long[] {5});
        Command<Long> command = new Command<>(1L, basis(0, 4));
        var settled = Core.apply(before, command);
        CallRecord<Command<Long>, Outcome<Core.AppliedValue<Long>, necoherence.core.UnknownResource,
                necoherence.core.StaleBasis, necoherence.core.Never>> held =
                Record.recordOnBasis("core.apply", command, settled, command.basis());

        assertEquals("core.apply", held.declaration());
        assertEquals(command, held.input());
        assertTrue(held.basis() instanceof RecordBasis.Situated);
        RecordBasis.Situated situated = (RecordBasis.Situated) held.basis();
        assertEquals(command.basis(), situated.basis());
    }

    @Test
    void anAppliedOutcomeRecordsTheResultingWorld() {
        World before = world(new int[] {0}, new long[] {1});
        Command<Long> command = new Command<>(7L, basis(0, 1));
        var settled = Core.apply(before, command);

        CallRecord<Command<Long>, Object> held = Record.recordOnBasis("core.apply", command, settled, command.basis());
        assertEquals(command, held.input());
        assertEquals(settled, held.product());
    }


    @Test
    void hasEdgeIsSymmetricProperty() {
        Random random = new Random(20260819);
        for (int trial = 0; trial < 200; trial++) {
            boolean aHasBasis = random.nextBoolean();
            boolean bHasBasis = random.nextBoolean();
            int aResource = random.nextInt(4);
            int bResource = random.nextInt(4);
            CallRecord<Integer, Integer> a = aHasBasis
                    ? Record.recordOnBasis("a", 1, 2, basis(aResource, random.nextInt(10)))
                    : Record.recordOf("a", 1, 2);
            CallRecord<Integer, Integer> b = bHasBasis
                    ? Record.recordOnBasis("b", 3, 4, basis(bResource, random.nextInt(10)))
                    : Record.recordOf("b", 3, 4);
            assertEquals(Record.hasEdge(a, b), Record.hasEdge(b, a));
        }
    }


    @Test
    void hasEdgeIsTransitiveOnASharedResourceProperty() {
        Random random = new Random(20260820);
        for (int trial = 0; trial < 200; trial++) {
            int resource = random.nextInt(4);
            CallRecord<Integer, Integer> a = Record.recordOnBasis("a", 1, 2, basis(resource, random.nextInt(10)));
            CallRecord<Integer, Integer> b = Record.recordOnBasis("b", 3, 4, basis(resource, random.nextInt(10)));
            CallRecord<Integer, Integer> c = Record.recordOnBasis("c", 5, 6, basis(resource, random.nextInt(10)));
            assertTrue(Record.hasEdge(a, b));
            assertTrue(Record.hasEdge(b, c));
            assertTrue(Record.hasEdge(a, c));
        }
    }


    @Test
    void noEdgeWitnessesDisjointResourcesProperty() {
        Random random = new Random(20260821);
        for (int trial = 0; trial < 200; trial++) {
            int resourceA = random.nextInt(4);
            int resourceB = random.nextInt(4);
            CallRecord<Integer, Integer> a = Record.recordOnBasis("a", 1, 2, basis(resourceA, random.nextInt(10)));
            CallRecord<Integer, Integer> b = Record.recordOnBasis("b", 3, 4, basis(resourceB, random.nextInt(10)));
            if (!Record.hasEdge(a, b)) {
                assertFalse(rid(resourceA).equals(rid(resourceB)));
            }
        }
    }
}
