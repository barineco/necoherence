// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

package necoherence.transition;

import java.util.ArrayList;
import java.util.List;
import java.util.function.BiFunction;
import necoherence.core.Nat;
import necoherence.core.PositiveNat;

/** Closed bounded single-owner transition evaluated in one call. */
public final class StepTransition {
    private StepTransition() {}
    /** A positive bound on how many times one input may be reprocessed. */
    public record PositiveLimit(PositiveNat value) {}
    /** A nonnegative bound on how many outputs one transition may accumulate. */
    public record Capacity(Nat value) {}
    public sealed interface Consumption<S, O> permits Consumed, Reprocess { S state(); List<O> outputs(); }
    public record Consumed<S, O>(S state, List<O> outputs) implements Consumption<S, O> { public Consumed { outputs = List.copyOf(outputs); } }
    public record Reprocess<S, O>(S state, List<O> outputs) implements Consumption<S, O> { public Reprocess { outputs = List.copyOf(outputs); } }
    public sealed interface Failure permits ReprocessLimitExhausted, CapacityExceeded {}
    public record ReprocessLimitExhausted(Nat applications) implements Failure {}
    public record CapacityExceeded(Nat capacity, Nat attempted) implements Failure {}
    public sealed interface Result<S, O> permits Settled, Failed { S state(); List<O> outputs(); }
    public record Settled<S, O>(S state, List<O> outputs, Nat applications) implements Result<S, O> { public Settled { outputs = List.copyOf(outputs); } }
    public record Failed<S, O>(S state, List<O> outputs, Failure failure) implements Result<S, O> { public Failed { outputs = List.copyOf(outputs); } }

    public static <S, I, O> Result<S, O> step(
            S initial, I input, BiFunction<S, I, Consumption<S, O>> advance, PositiveLimit limit, Capacity capacity) {
        S state = initial;
        List<O> accumulated = new ArrayList<>();
        Nat applications = Nat.zero();
        Nat fuel = limit.value().asNat();
        while (!fuel.isZero()) {
            Consumption<S, O> decision = advance.apply(state, input);
            state = decision.state();
            accumulated.addAll(decision.outputs());
            applications = applications.plus(Nat.one());
            Nat attempted = nat(accumulated.size());
            if (attempted.compareTo(capacity.value()) > 0)
                return new Failed<>(state, List.copyOf(accumulated), new CapacityExceeded(capacity.value(), attempted));
            if (decision instanceof Consumed<S, O>) return new Settled<>(state, List.copyOf(accumulated), applications);
            fuel = fuel.minusWhenOrdered(Nat.one());
        }
        return new Failed<>(state, List.copyOf(accumulated), new ReprocessLimitExhausted(applications));
    }

    private static Nat nat(long value) { return Nat.fromLong(value); }
}
