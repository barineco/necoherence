// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

package necoherence.transition;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertInstanceOf;
import java.math.BigInteger;
import java.util.List;
import necoherence.core.Nat;
import necoherence.core.PositiveNat;
import necoherence.core.Validation;
import necoherence.transition.StepTransition.*;
import org.junit.jupiter.api.Test;

final class StepTransitionTest {
    private static Nat nat(long value) { return ((Validation.Valid<Nat>) Nat.of(BigInteger.valueOf(value))).value(); }
    private static PositiveNat positive(long value) { return ((Validation.Valid<PositiveNat>) PositiveNat.of(BigInteger.valueOf(value))).value(); }
    @Test void settlesImmediatelyWhenAdvanceConsumesOnTheFirstCall() {
        Result<Integer,String> result = StepTransition.step(0, "input", (s,i) -> new Consumed<>(1,List.of("a")), new PositiveLimit(positive(5)), new Capacity(nat(5)));
        Settled<Integer,String> settled = assertInstanceOf(Settled.class,result);
        assertEquals(nat(1), settled.applications());
    }
    @Test void failsWhenAccumulatedOutputsExceedCapacity() {
        Result<Integer,String> result = StepTransition.step(0,"input",(s,i)->new Consumed<>(1,List.of("a","b","c")),new PositiveLimit(positive(5)),new Capacity(nat(2)));
        CapacityExceeded exceeded = assertInstanceOf(CapacityExceeded.class, assertInstanceOf(Failed.class,result).failure());
        assertEquals(nat(2), exceeded.capacity()); assertEquals(nat(3), exceeded.attempted());
    }
    @Test void invalidBoundsAreClosed() {
        assertInstanceOf(Validation.Invalid.class, Nat.of(BigInteger.valueOf(-1)));
        assertInstanceOf(Validation.Invalid.class, PositiveNat.of(BigInteger.ZERO));
        assertInstanceOf(Validation.Invalid.class, PositiveNat.of(BigInteger.valueOf(-1)));
    }
}
