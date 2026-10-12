// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

package necoherence.iteration;

import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Objects;
import java.util.Set;
import necoherence.call.Call;
import necoherence.call.Call.CallResult;
import necoherence.call.Call.Request;
import necoherence.call.Immediate;
import necoherence.call.ProjectionFailed;
import necoherence.core.Nat;

/** Iterative call forms with all measures and counters represented as Nat. */
public final class Iteration {
    private Iteration() {}
    public record StageProjectionFailed(Nat position, ProjectionFailed failure) {}
    public sealed interface FoldOutcome<S> permits FoldTrace, FoldStopped {}
    public record FoldTrace<S>(List<S> states) implements FoldOutcome<S> { public FoldTrace { states = List.copyOf(states); } }
    public record FoldStopped<S>(List<S> states, StageProjectionFailed stopped) implements FoldOutcome<S> { public FoldStopped { states = List.copyOf(states); } }
    public static <S> FoldOutcome<S> runFold(Immediate<S,S> step, S seed, Nat count, List<String> stepFields) {
        List<S> states = new ArrayList<>(); states.add(seed); S state = seed; Nat position = Nat.zero();
        while (position.compareTo(count) < 0) {
            CallResult<S> result = Call.io(step, new Request<>(state, stepFields));
            if (result instanceof CallResult.Failed<S> failed) return new FoldStopped<>(states, new StageProjectionFailed(position, failed.failure()));
            state = ((CallResult.Ok<S>) result).value(); states.add(state); position = position.successor();
        }
        return new FoldTrace<>(states);
    }
    public sealed interface StepOutcome<S> permits Continue, Settled {}
    public record Continue<S>(S state, Nat measure) implements StepOutcome<S> { public Continue { Objects.requireNonNull(state); Objects.requireNonNull(measure); } }
    public record Settled<S>(S state) implements StepOutcome<S> { public Settled { Objects.requireNonNull(state); } }
    public sealed interface RecurseOutcome<S> permits RecurseSettled, RecurseDidNotDecrease, RecurseProjectionFailed {}
    public record RecurseSettled<S>(S value, Nat steps) implements RecurseOutcome<S> {}
    public record RecurseDidNotDecrease<S>(Nat position, S state, Nat measure, Nat previousMeasure) implements RecurseOutcome<S> {}
    public record RecurseProjectionFailed<S>(S lastState, StageProjectionFailed stopped) implements RecurseOutcome<S> {}
    public static <S> RecurseOutcome<S> runRecurse(Immediate<S,StepOutcome<S>> step, S seed, List<String> stepFields) {
        S state = seed; Nat previous = null; Nat position = Nat.zero();
        while (true) {
            CallResult<StepOutcome<S>> result = Call.io(step, new Request<>(state, stepFields));
            if (result instanceof CallResult.Failed<StepOutcome<S>> failed) return new RecurseProjectionFailed<>(state, new StageProjectionFailed(position, failed.failure()));
            StepOutcome<S> outcome = ((CallResult.Ok<StepOutcome<S>>) result).value();
            if (outcome instanceof Settled<S> settled) return new RecurseSettled<>(settled.state(), position);
            Continue<S> cont = (Continue<S>) outcome;
            if (previous != null && cont.measure().compareTo(previous) >= 0) return new RecurseDidNotDecrease<>(position, cont.state(), cont.measure(), previous);
            previous = cont.measure(); state = cont.state(); position = position.successor();
        }
    }
    public record ClosureState<T>(Set<T> elements) { public ClosureState { elements = Set.copyOf(elements); } }
    public sealed interface ClosureOutcome<T> permits ClosureFixpoint, ClosureViolation, ClosureProjectionFailed {}
    public record ClosureFixpoint<T>(Set<T> elements, Nat steps) implements ClosureOutcome<T> { public ClosureFixpoint { elements = Set.copyOf(elements); } }
    public record ClosureViolation<T>(Nat position, Set<T> current, Set<T> produced) implements ClosureOutcome<T> { public ClosureViolation { current = Set.copyOf(current); produced = Set.copyOf(produced); } }
    public record ClosureProjectionFailed<T>(Set<T> last, StageProjectionFailed stopped) implements ClosureOutcome<T> { public ClosureProjectionFailed { last = Set.copyOf(last); } }
    public static <T> ClosureOutcome<T> runClosure(Immediate<ClosureState<T>,Set<T>> step, Set<T> carrier, Set<T> seed, List<String> stepFields) {
        Set<T> current = Set.copyOf(seed), carrierCopy = Set.copyOf(carrier); Nat position = Nat.zero();
        while (true) {
            CallResult<Set<T>> result = Call.io(step, new Request<>(new ClosureState<>(current), stepFields));
            if (result instanceof CallResult.Failed<Set<T>> failed) return new ClosureProjectionFailed<>(current, new StageProjectionFailed(position, failed.failure()));
            Set<T> produced = Set.copyOf(((CallResult.Ok<Set<T>>) result).value());
            if (produced.equals(current)) return new ClosureFixpoint<>(current, position);
            if (!produced.containsAll(current) || !carrierCopy.containsAll(produced)) return new ClosureViolation<>(position, current, produced);
            current = produced; position = position.successor();
        }
    }
    @SafeVarargs public static <T> Set<T> setOf(T... elements) { LinkedHashSet<T> set = new LinkedHashSet<>(); Collections.addAll(set,elements); return Set.copyOf(set); }
}
