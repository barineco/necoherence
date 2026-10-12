// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

package necoherence.iteration;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertInstanceOf;
import static org.junit.jupiter.api.Assertions.assertTrue;

import java.math.BigInteger;
import java.util.List;
import java.util.Map;
import java.util.Random;
import java.util.Set;
import necoherence.call.Call;
import necoherence.core.Nat;
import necoherence.call.Immediate;
import necoherence.iteration.Iteration.ClosureFixpoint;
import necoherence.iteration.Iteration.ClosureOutcome;
import necoherence.iteration.Iteration.ClosureProjectionFailed;
import necoherence.iteration.Iteration.ClosureState;
import necoherence.iteration.Iteration.ClosureViolation;
import necoherence.iteration.Iteration.Continue;
import necoherence.iteration.Iteration.FoldOutcome;
import necoherence.iteration.Iteration.FoldStopped;
import necoherence.iteration.Iteration.FoldTrace;
import necoherence.iteration.Iteration.RecurseDidNotDecrease;
import necoherence.iteration.Iteration.RecurseOutcome;
import necoherence.iteration.Iteration.RecurseProjectionFailed;
import necoherence.iteration.Iteration.RecurseSettled;
import necoherence.iteration.Iteration.Settled;
import necoherence.iteration.Iteration.StepOutcome;
import org.junit.jupiter.api.Test;

public class IterationTest {

    private static Nat n(long v) {
        return Nat.fromLong(v);
    }

    @Test
    void foldRunsCountRounds() {
        Immediate<BigInteger, BigInteger> increment =
                Call.immediateOf("test.increment", List.of("value"), x -> x.add(BigInteger.ONE));
        FoldOutcome<BigInteger> outcome = Iteration.runFold(increment, BigInteger.ZERO, n(3), List.of("value"));
        FoldTrace<BigInteger> trace = assertInstanceOf(FoldTrace.class, outcome);
        assertEquals(List.of(BigInteger.ZERO, BigInteger.ONE, BigInteger.TWO, BigInteger.valueOf(3)), trace.states());
    }

    @Test
    void foldRunsZeroRoundsForZeroCount() {
        Immediate<BigInteger, BigInteger> increment =
                Call.immediateOf("test.increment", List.of("value"), x -> x.add(BigInteger.ONE));
        FoldOutcome<BigInteger> outcome = Iteration.runFold(increment, BigInteger.valueOf(7), Nat.zero(), List.of("value"));
        FoldTrace<BigInteger> trace = assertInstanceOf(FoldTrace.class, outcome);
        assertEquals(List.of(BigInteger.valueOf(7)), trace.states());
    }

    @Test
    void foldStopsAtTheFirstRoundWhoseProjectionFails() {
        Immediate<BigInteger, BigInteger> increment =
                Call.immediateOf("test.increment", List.of("value"), x -> x.add(BigInteger.ONE));
        FoldOutcome<BigInteger> outcome = Iteration.runFold(increment, BigInteger.ZERO, n(3), List.of());
        FoldStopped<BigInteger> stopped = assertInstanceOf(FoldStopped.class, outcome);
        assertEquals(List.of(BigInteger.ZERO), stopped.states());
        assertEquals(Nat.zero(), stopped.stopped().position());
        assertEquals("test.increment", stopped.stopped().failure().declaration());
        assertEquals(List.of("value"), stopped.stopped().failure().fields());
    }

    /** fold's round count never exceeds the requested count, over a finite domain of counts. */
    @Test
    void foldTraceLengthBoundedByCountProperty() {
        Immediate<BigInteger, BigInteger> increment =
                Call.immediateOf("test.increment", List.of("value"), x -> x.add(BigInteger.ONE));
        for (long count = 0; count <= 12; count++) {
            FoldOutcome<BigInteger> outcome =
                    Iteration.runFold(increment, BigInteger.ZERO, n(count), List.of("value"));
            FoldTrace<BigInteger> trace = assertInstanceOf(FoldTrace.class, outcome);
            assertEquals(count + 1, trace.states().size());
        }
    }

    @Test
    void recurseSettlesWhenMeasureDecreases() {
        Immediate<long[], StepOutcome<long[]>> gcd =
                Call.immediateOf(
                        "test.gcd",
                        List.of("state"),
                        state -> {
                            long a = state[0];
                            long b = state[1];
                            if (b == 0) {
                                return new Settled<>(state);
                            }
                            return new Continue<>(new long[] {b, a % b}, n(b));
                        });
        RecurseOutcome<long[]> outcome = Iteration.runRecurse(gcd, new long[] {48, 18}, List.of("state"));
        RecurseSettled<long[]> settled = assertInstanceOf(RecurseSettled.class, outcome);
        assertEquals(6L, settled.value()[0]);
        assertEquals(0L, settled.value()[1]);
        assertEquals(n(3), settled.steps());
    }

    @Test
    void recurseReturnsDidNotDecrease() {
        Immediate<BigInteger, StepOutcome<BigInteger>> stuck =
                Call.immediateOf(
                        "test.stuck", List.of("state"), state -> new Continue<>(state.add(BigInteger.ONE), n(5)));
        RecurseOutcome<BigInteger> outcome = Iteration.runRecurse(stuck, BigInteger.ZERO, List.of("state"));
        RecurseDidNotDecrease<BigInteger> failed = assertInstanceOf(RecurseDidNotDecrease.class, outcome);
        assertEquals(n(1), failed.position());
        assertEquals(n(5), failed.measure());
        assertEquals(n(5), failed.previousMeasure());
    }

    @Test
    void recurseReturnsProjectionFailedWhenStepFieldsAreMissing() {
        Immediate<BigInteger, StepOutcome<BigInteger>> gcd =
                Call.immediateOf("test.gcd", List.of("state"), state -> new Settled<>(state));
        RecurseOutcome<BigInteger> outcome = Iteration.runRecurse(gcd, BigInteger.ZERO, List.of());
        RecurseProjectionFailed<BigInteger> failed = assertInstanceOf(RecurseProjectionFailed.class, outcome);
        assertEquals(BigInteger.ZERO, failed.lastState());
        assertEquals(Nat.zero(), failed.stopped().position());
        assertEquals("test.gcd", failed.stopped().failure().declaration());
        assertEquals(List.of("state"), failed.stopped().failure().fields());
    }

    /** A strictly-decreasing measure over a random finite starting bound always settles within
     * that many rounds, and never reports didNotDecrease. */
    @Test
    void recurseStrictlyDecreasingMeasureAlwaysSettlesProperty() {
        Random random = new Random(20260819);
        for (int trial = 0; trial < 200; trial++) {
            long start = 1 + random.nextInt(30);
            Immediate<Long, StepOutcome<Long>> counter =
                    Call.immediateOf(
                            "test.counter",
                            List.of("state"),
                            state -> state <= 0 ? new Settled<>(state) : new Continue<>(state - 1, n(state - 1)));
            RecurseOutcome<Long> outcome = Iteration.runRecurse(counter, start, List.of("state"));
            RecurseSettled<Long> settled = assertInstanceOf(RecurseSettled.class, outcome);
            assertEquals(0L, settled.value());
            assertEquals(n(start), settled.steps());
        }
    }

    @Test
    void closureReachesFixpoint() {
        Map<Long, Set<Long>> edges = Map.of(1L, Set.of(2L), 2L, Set.of(3L), 3L, Set.of());
        Immediate<ClosureState<Long>, Set<Long>> reach =
                Call.immediateOf(
                        "test.reach",
                        List.of("elements"),
                        state -> {
                            Set<Long> grown = new java.util.LinkedHashSet<>(state.elements());
                            for (Long node : state.elements()) {
                                grown.addAll(edges.getOrDefault(node, Set.of()));
                            }
                            return Set.copyOf(grown);
                        });
        ClosureOutcome<Long> outcome =
                Iteration.runClosure(reach, Set.of(1L, 2L, 3L), Set.of(1L), List.of("elements"));
        ClosureFixpoint<Long> fix = assertInstanceOf(ClosureFixpoint.class, outcome);
        assertEquals(Set.of(1L, 2L, 3L), fix.elements());
        assertEquals(n(2), fix.steps());
    }

    @Test
    void closureReportsViolationWhenNotExtensive() {
        Immediate<ClosureState<Long>, Set<Long>> shrinks =
                Call.immediateOf("test.shrinks", List.of("elements"), state -> Set.of());
        ClosureOutcome<Long> outcome =
                Iteration.runClosure(shrinks, Set.of(1L, 2L), Set.of(1L), List.of("elements"));
        ClosureViolation<Long> violation = assertInstanceOf(ClosureViolation.class, outcome);
        assertEquals(Nat.zero(), violation.position());
        assertEquals(Set.of(1L), violation.current());
        assertTrue(violation.produced().isEmpty());
    }

    @Test
    void closureReportsProjectionFailedWhenStepFieldsAreMissing() {
        Immediate<ClosureState<Long>, Set<Long>> reach =
                Call.immediateOf("test.reach", List.of("elements"), state -> state.elements());
        ClosureOutcome<Long> outcome = Iteration.runClosure(reach, Set.of(1L), Set.of(1L), List.of());
        ClosureProjectionFailed<Long> failed = assertInstanceOf(ClosureProjectionFailed.class, outcome);
        assertEquals(Set.of(1L), failed.last());
        assertEquals(Nat.zero(), failed.stopped().position());
        assertEquals("test.reach", failed.stopped().failure().declaration());
        assertEquals(List.of("elements"), failed.stopped().failure().fields());
    }

    /** closure over a random finite reachability graph never exceeds the carrier's own size in
     * steps, and its fixpoint is always a subset of the carrier. */
    @Test
    void closureBoundedByCarrierSizeProperty() {
        Random random = new Random(20260820);
        for (int trial = 0; trial < 100; trial++) {
            int size = 2 + random.nextInt(8);
            Set<Long> carrier = new java.util.LinkedHashSet<>();
            for (long i = 0; i < size; i++) {
                carrier.add(i);
            }
            Map<Long, Set<Long>> edges = new java.util.LinkedHashMap<>();
            for (long i = 0; i < size - 1; i++) {
                if (random.nextBoolean()) {
                    edges.put(i, Set.of(i + 1));
                }
            }
            Immediate<ClosureState<Long>, Set<Long>> reach =
                    Call.immediateOf(
                            "test.reach",
                            List.of("elements"),
                            state -> {
                                Set<Long> grown = new java.util.LinkedHashSet<>(state.elements());
                                for (Long node : state.elements()) {
                                    grown.addAll(edges.getOrDefault(node, Set.of()));
                                }
                                return Set.copyOf(grown);
                            });
            ClosureOutcome<Long> outcome = Iteration.runClosure(reach, carrier, Set.of(0L), List.of("elements"));
            ClosureFixpoint<Long> fix = assertInstanceOf(ClosureFixpoint.class, outcome);
            assertTrue(carrier.containsAll(fix.elements()));
            assertTrue(fix.steps().compareTo(n(size)) <= 0);
        }
    }
}
