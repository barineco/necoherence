// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

package necoherence.typed;

import java.math.BigInteger;
import java.util.ArrayList;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Objects;
import java.util.Optional;
import java.util.Set;

/** Finite typed places, transitions, markings, goals, and checked witnesses. */
public final class TypedMapping {
    private static final BigInteger ZERO = BigInteger.ZERO;
    private static final BigInteger ONE = BigInteger.ONE;

    private TypedMapping() {}

    public enum TokenKind { INPUT, OUTPUT, FAILURE, EFFECT, OBSERVATION, ACCEPTED }

    public record ColoredToken(String target, BigInteger index, BigInteger revision, TokenKind kind) {
        public ColoredToken {
            target = Objects.requireNonNull(target);
            index = natural(index);
            revision = natural(revision);
            kind = Objects.requireNonNull(kind);
        }
    }

    public record TypedPlace(String identity, String tokenType, BigInteger revision) {
        public TypedPlace {
            identity = Objects.requireNonNull(identity);
            tokenType = Objects.requireNonNull(tokenType);
            revision = natural(revision);
        }
    }

    public record TypedTransition(String identity, List<String> inputPlaces, List<String> outputPlaces,
            List<String> failurePlaces, BigInteger revision) {
        public TypedTransition {
            identity = Objects.requireNonNull(identity);
            inputPlaces = copyStrings(inputPlaces);
            outputPlaces = copyStrings(outputPlaces);
            failurePlaces = copyStrings(failurePlaces);
            revision = natural(revision);
        }
    }

    public enum BindingMode { READ, CONSUME }

    public record InputBinding(String transitionId, String name, String place, String tokenType,
            String identity, String provenance, BigInteger multiplicity, BindingMode mode,
            BigInteger requiredRevision) {
        public InputBinding {
            transitionId = Objects.requireNonNull(transitionId);
            name = Objects.requireNonNull(name);
            place = Objects.requireNonNull(place);
            tokenType = Objects.requireNonNull(tokenType);
            identity = Objects.requireNonNull(identity);
            provenance = Objects.requireNonNull(provenance);
            multiplicity = natural(multiplicity);
            mode = Objects.requireNonNull(mode);
            requiredRevision = natural(requiredRevision);
        }
    }

    public record Edge(String source, String destination) {
        public Edge {
            source = Objects.requireNonNull(source);
            destination = Objects.requireNonNull(destination);
        }
    }

    public record DeclarationGraph(List<String> places, List<String> transitions, List<Edge> edges,
            BigInteger revision) {
        public DeclarationGraph {
            places = copyStrings(places);
            transitions = copyStrings(transitions);
            edges = List.copyOf(edges);
            edges.forEach(Objects::requireNonNull);
            revision = natural(revision);
        }
    }

    public record DomainBound(String targetIdentity, BigInteger index, BigInteger revision,
            BigInteger maxBindings, BigInteger maxSearchSteps) {
        public DomainBound {
            targetIdentity = Objects.requireNonNull(targetIdentity);
            index = natural(index);
            revision = natural(revision);
            maxBindings = natural(maxBindings);
            maxSearchSteps = natural(maxSearchSteps);
        }
    }

    public record PlaceTokens(String place, List<ColoredToken> tokens) {
        public PlaceTokens {
            place = Objects.requireNonNull(place);
            tokens = List.copyOf(tokens);
            tokens.forEach(Objects::requireNonNull);
        }
    }

    public record Marking(List<PlaceTokens> places) {
        public Marking {
            places = List.copyOf(places);
            places.forEach(Objects::requireNonNull);
        }
    }

    public sealed interface GoalPredicate permits PlaceHasAtLeast, PlaceHasToken, GoalAnd, GoalOr, GoalNot {}
    public record PlaceHasAtLeast(String place, BigInteger count) implements GoalPredicate {
        public PlaceHasAtLeast {
            place = Objects.requireNonNull(place);
            count = natural(count);
        }
    }
    public record PlaceHasToken(String place, String target, BigInteger index, BigInteger revision)
            implements GoalPredicate {
        public PlaceHasToken {
            place = Objects.requireNonNull(place);
            target = Objects.requireNonNull(target);
            index = natural(index);
            revision = natural(revision);
        }
    }
    public record GoalAnd(GoalPredicate left, GoalPredicate right) implements GoalPredicate {
        public GoalAnd {
            left = Objects.requireNonNull(left);
            right = Objects.requireNonNull(right);
        }
    }
    public record GoalOr(GoalPredicate left, GoalPredicate right) implements GoalPredicate {
        public GoalOr {
            left = Objects.requireNonNull(left);
            right = Objects.requireNonNull(right);
        }
    }
    public record GoalNot(GoalPredicate value) implements GoalPredicate {
        public GoalNot { value = Objects.requireNonNull(value); }
    }

    public record SolverInput(List<TypedPlace> places, List<TypedTransition> transitions,
            List<InputBinding> bindings, GoalPredicate goal, DeclarationGraph graph,
            Marking marking, DomainBound bound) {
        public SolverInput {
            places = List.copyOf(places);
            transitions = List.copyOf(transitions);
            bindings = List.copyOf(bindings);
            places.forEach(Objects::requireNonNull);
            transitions.forEach(Objects::requireNonNull);
            bindings.forEach(Objects::requireNonNull);
            goal = Objects.requireNonNull(goal);
            graph = Objects.requireNonNull(graph);
            marking = Objects.requireNonNull(marking);
            bound = Objects.requireNonNull(bound);
        }
    }

    public sealed interface InvalidReason permits UnknownPlace, UnknownInputPlace, UnknownTransition,
            DuplicateTransitionIdentity, MissingInputBinding, TypeMismatch, MultiplicityMismatch,
            RevisionMismatch, IdentityMismatch, DependencyMismatch {}
    public record UnknownPlace(String place) implements InvalidReason {}
    public record UnknownInputPlace(String transitionId, String place) implements InvalidReason {}
    public record UnknownTransition(String transitionId) implements InvalidReason {}
    public record DuplicateTransitionIdentity(String identity) implements InvalidReason {}
    public record MissingInputBinding(String transitionId, String place) implements InvalidReason {}
    public record TypeMismatch(String place, String expected, String actual) implements InvalidReason {}
    public record MultiplicityMismatch(String transitionId, String name, BigInteger expected,
            BigInteger actual) implements InvalidReason {}
    public record RevisionMismatch(String transitionId, String name, BigInteger expected,
            BigInteger actual) implements InvalidReason {}
    public record IdentityMismatch(String transitionId, String name) implements InvalidReason {}
    public record DependencyMismatch(String transitionId, String place) implements InvalidReason {}

    public sealed interface UnknownReason permits BindingBoundExhausted, SearchStepBoundExhausted {}
    public record BindingBoundExhausted(BigInteger limit) implements UnknownReason {}
    public record SearchStepBoundExhausted(BigInteger limit) implements UnknownReason {}

    public record EnabledTransition(String transitionId, List<InputBinding> bindings) {
        public EnabledTransition { bindings = List.copyOf(bindings); }
    }
    public record EnabledSet(List<EnabledTransition> enabled) {
        public EnabledSet { enabled = List.copyOf(enabled); }
    }
    public sealed interface EnabledResult permits DerivedEnabledSet, InvalidEnabled {}
    public record DerivedEnabledSet(EnabledSet enabledSet) implements EnabledResult {}
    public record InvalidEnabled(InvalidReason reason) implements EnabledResult {}

    public record ReachabilityWitness(List<String> path, Marking finalMarking) {
        public ReachabilityWitness {
            path = copyStrings(path);
            finalMarking = Objects.requireNonNull(finalMarking);
        }
    }
    public record ClosureWitness(List<Marking> exploredMarkings, BigInteger steps, List<Marking> frontier) {
        public ClosureWitness {
            exploredMarkings = List.copyOf(exploredMarkings);
            steps = natural(steps);
            frontier = List.copyOf(frontier);
        }
    }
    public sealed interface ReachabilityResult permits InvalidReachability, Reachable, UnknownReachability,
            Unreachable {}
    public record InvalidReachability(InvalidReason reason) implements ReachabilityResult {}
    public record Reachable(ReachabilityWitness witness) implements ReachabilityResult {}
    public record UnknownReachability(UnknownReason reason) implements ReachabilityResult {}
    public record Unreachable(ClosureWitness witness) implements ReachabilityResult {}

    public record DeadlockWitness(Marking marking) {}
    public sealed interface DeadlockResult permits Deadlocked, InvalidDeadlock, NotDeadlocked, UnknownDeadlock {}
    public record Deadlocked(DeadlockWitness witness) implements DeadlockResult {}
    public record InvalidDeadlock(InvalidReason reason) implements DeadlockResult {}
    public record NotDeadlocked(EnabledSet enabledSet) implements DeadlockResult {}
    public record UnknownDeadlock(UnknownReason reason) implements DeadlockResult {}

    public record CycleWitness(List<String> prefixPath, List<String> cyclePath, Marking cycleStart,
            Marking cycleEnd, boolean measureDecreasing) {
        public CycleWitness {
            prefixPath = copyStrings(prefixPath);
            cyclePath = copyStrings(cyclePath);
        }
    }
    public record AcyclicWitness(List<Marking> exploredMarkings, BigInteger steps, List<Marking> frontier) {
        public AcyclicWitness {
            exploredMarkings = List.copyOf(exploredMarkings);
            steps = natural(steps);
            frontier = List.copyOf(frontier);
        }
    }
    public sealed interface WellFoundednessResult permits InvalidWellFoundedness, NotWellFounded,
            UnknownWellFoundedness, WellFounded {}
    public record InvalidWellFoundedness(InvalidReason reason) implements WellFoundednessResult {}
    public record NotWellFounded(CycleWitness witness) implements WellFoundednessResult {}
    public record UnknownWellFoundedness(UnknownReason reason) implements WellFoundednessResult {}
    public record WellFounded(AcyclicWitness witness) implements WellFoundednessResult {}

    public sealed interface SolverFailure permits ContractViolation, InternalInvariantViolation {}
    public record ContractViolation(String message) implements SolverFailure {}
    public record InternalInvariantViolation(String message) implements SolverFailure {}

    private static BigInteger natural(BigInteger value) {
        Objects.requireNonNull(value);
        if (value.signum() < 0) throw new IllegalArgumentException("natural number");
        return value;
    }

    private static List<String> copyStrings(List<String> values) {
        List<String> result = List.copyOf(values);
        result.forEach(Objects::requireNonNull);
        return result;
    }

    public static List<ColoredToken> tokensAt(Marking marking, String place) {
        for (PlaceTokens entry : marking.places()) {
            if (entry.place().equals(place)) return entry.tokens();
        }
        return List.of();
    }

    public static boolean evalGoal(Marking marking, GoalPredicate goal) {
        return switch (goal) {
            case PlaceHasAtLeast value -> value.count().compareTo(BigInteger.valueOf(
                    tokensAt(marking, value.place()).size())) <= 0;
            case PlaceHasToken value -> tokensAt(marking, value.place()).stream().anyMatch(token ->
                    token.target().equals(value.target()) && token.index().equals(value.index())
                            && token.revision().equals(value.revision()));
            case GoalAnd value -> evalGoal(marking, value.left()) && evalGoal(marking, value.right());
            case GoalOr value -> evalGoal(marking, value.left()) || evalGoal(marking, value.right());
            case GoalNot value -> !evalGoal(marking, value.value());
        };
    }

    private static boolean placeExists(List<TypedPlace> places, String identity) {
        return places.stream().anyMatch(place -> place.identity().equals(identity));
    }

    private static Optional<String> placeType(List<TypedPlace> places, String identity) {
        return places.stream().filter(place -> place.identity().equals(identity))
                .map(TypedPlace::tokenType).findFirst();
    }

    private static boolean transitionExists(List<TypedTransition> transitions, String identity) {
        return transitions.stream().anyMatch(transition -> transition.identity().equals(identity));
    }

    private static Optional<TypedTransition> findTransition(List<TypedTransition> transitions,
            String identity) {
        return transitions.stream().filter(transition -> transition.identity().equals(identity)).findFirst();
    }

    public static Optional<InvalidReason> validate(SolverInput input) {
        return checkInputPlaceMembership(input)
                .or(() -> checkDuplicateTransitionIdentity(input))
                .or(() -> checkBindingCoverage(input))
                .or(() -> firstSome(input.bindings(), binding -> checkBindingStructure(input, binding)))
                .or(() -> firstSome(input.bindings(), binding -> checkBindingRevision(input, binding)))
                .or(() -> checkGraphPlaces(input))
                .or(() -> checkGraphTransitions(input))
                .or(() -> checkGraphEdges(input))
                .or(() -> checkBranchPlaces(input));
    }

    private static <T> Optional<InvalidReason> firstSome(List<T> items,
            java.util.function.Function<T, Optional<InvalidReason>> check) {
        for (T item : items) {
            Optional<InvalidReason> reason = check.apply(item);
            if (reason.isPresent()) return reason;
        }
        return Optional.empty();
    }

    private static Optional<InvalidReason> checkInputPlaceMembership(SolverInput input) {
        for (TypedTransition transition : input.transitions()) {
            for (String place : transition.inputPlaces()) {
                if (!placeExists(input.places(), place)) return Optional.of(new UnknownInputPlace(transition.identity(), place));
            }
        }
        return Optional.empty();
    }

    private static Optional<String> duplicateTransitionIdentity(List<TypedTransition> transitions) {
        for (int index = 0; index < transitions.size(); index++) {
            String identity = transitions.get(index).identity();
            for (int other = index + 1; other < transitions.size(); other++) {
                if (transitions.get(other).identity().equals(identity)) return Optional.of(identity);
            }
        }
        return Optional.empty();
    }

    private static Optional<InvalidReason> checkDuplicateTransitionIdentity(SolverInput input) {
        Optional<String> identity = duplicateTransitionIdentity(input.transitions());
        if (identity.isEmpty()) return Optional.empty();
        return Optional.of(new DuplicateTransitionIdentity(identity.get()));
    }

    private static Optional<InvalidReason> checkBindingCoverage(SolverInput input) {
        for (TypedTransition transition : input.transitions()) {
            for (String place : transition.inputPlaces()) {
                boolean covered = input.bindings().stream().anyMatch(binding ->
                        binding.transitionId().equals(transition.identity()) && binding.place().equals(place));
                if (!covered) return Optional.of(new MissingInputBinding(transition.identity(), place));
            }
        }
        return Optional.empty();
    }

    private static Optional<InvalidReason> checkBindingStructure(SolverInput input, InputBinding binding) {
        if (!transitionExists(input.transitions(), binding.transitionId())) {
            return Optional.of(new UnknownTransition(binding.transitionId()));
        }
        if (!placeExists(input.places(), binding.place())) return Optional.of(new UnknownPlace(binding.place()));
        TypedTransition transition = findTransition(input.transitions(), binding.transitionId()).orElseThrow();
        if (!transition.inputPlaces().contains(binding.place())) {
            return Optional.of(new DependencyMismatch(binding.transitionId(), binding.place()));
        }
        String actual = placeType(input.places(), binding.place()).orElseThrow();
        if (!actual.equals(binding.tokenType())) return Optional.of(new TypeMismatch(binding.place(), binding.tokenType(), actual));
        if (binding.multiplicity().equals(ZERO)) {
            return Optional.of(new MultiplicityMismatch(binding.transitionId(), binding.name(), ONE, ZERO));
        }
        if (duplicateBindingName(input, binding)) return Optional.of(new IdentityMismatch(binding.transitionId(), binding.name()));
        return Optional.empty();
    }

    private static boolean duplicateBindingName(SolverInput input, InputBinding binding) {
        long names = input.bindings().stream().filter(other ->
                other.transitionId().equals(binding.transitionId()) && other.name().equals(binding.name())).count();
        return names > 1;
    }

    private static Optional<InvalidReason> checkBindingRevision(SolverInput input, InputBinding binding) {
        for (ColoredToken token : tokensAt(input.marking(), binding.place())) {
            if (token.target().equals(binding.identity()) && !token.revision().equals(binding.requiredRevision())) {
                return Optional.of(new RevisionMismatch(binding.transitionId(), binding.name(),
                        binding.requiredRevision(), token.revision()));
            }
        }
        return Optional.empty();
    }

    private static Optional<InvalidReason> checkGraphPlaces(SolverInput input) {
        for (String place : input.graph().places()) {
            if (!placeExists(input.places(), place)) return Optional.of(new UnknownPlace(place));
        }
        return Optional.empty();
    }

    private static Optional<InvalidReason> checkGraphTransitions(SolverInput input) {
        for (String transition : input.graph().transitions()) {
            if (!transitionExists(input.transitions(), transition)) return Optional.of(new UnknownTransition(transition));
        }
        return Optional.empty();
    }

    private static Optional<InvalidReason> checkGraphEdges(SolverInput input) {
        for (Edge edge : input.graph().edges()) {
            if (!isGraphNode(input, edge.source()) || !isGraphNode(input, edge.destination())) {
                return Optional.of(new DependencyMismatch(edge.source(), edge.destination()));
            }
        }
        return Optional.empty();
    }

    private static Optional<InvalidReason> checkBranchPlaces(SolverInput input) {
        for (TypedTransition transition : input.transitions()) {
            for (String place : concat(transition.outputPlaces(), transition.failurePlaces())) {
                if (!placeExists(input.places(), place)) return Optional.of(new DependencyMismatch(transition.identity(), place));
            }
        }
        return Optional.empty();
    }

    private static boolean isGraphNode(SolverInput input, String identity) {
        return input.graph().places().contains(identity) || input.graph().transitions().contains(identity);
    }

    private static <T> List<T> concat(List<T> first, List<T> second) {
        List<T> result = new ArrayList<>(first.size() + second.size());
        result.addAll(first);
        result.addAll(second);
        return result;
    }

    public static List<InputBinding> bindingsFor(SolverInput input, String transitionId) {
        return input.bindings().stream().filter(binding -> binding.transitionId().equals(transitionId)).toList();
    }

    public static boolean bindingSatisfiedAt(Marking marking, InputBinding binding) {
        long matching = tokensAt(marking, binding.place()).stream().filter(token ->
                token.target().equals(binding.identity())
                        && token.revision().equals(binding.requiredRevision())).count();
        return binding.multiplicity().compareTo(BigInteger.valueOf(matching)) <= 0;
    }

    public static boolean transitionEnabledAt(List<InputBinding> bindings, Marking marking) {
        return bindings.stream().allMatch(binding -> bindingSatisfiedAt(marking, binding));
    }

    public static BigInteger candidateBindingCount(SolverInput input) {
        BigInteger count = ZERO;
        for (TypedTransition transition : input.transitions()) {
            count = count.add(BigInteger.valueOf(bindingsFor(input, transition.identity()).size()));
        }
        return count;
    }

    public static boolean bindingBoundExceeded(SolverInput input) {
        return input.bound().maxBindings().compareTo(candidateBindingCount(input)) < 0;
    }

    private static List<ColoredToken> selectMatching(List<ColoredToken> tokens, InputBinding binding) {
        List<ColoredToken> selected = new ArrayList<>();
        for (ColoredToken token : tokens) {
            if (token.target().equals(binding.identity())
                    && token.revision().equals(binding.requiredRevision())) {
                if (BigInteger.valueOf(selected.size()).compareTo(binding.multiplicity()) >= 0) break;
                selected.add(token);
            }
        }
        return selected;
    }

    public static List<ColoredToken> consumedAt(List<InputBinding> bindings, Marking marking, String place) {
        List<ColoredToken> consumed = new ArrayList<>();
        for (InputBinding binding : bindings) {
            if (binding.place().equals(place) && binding.mode() == BindingMode.CONSUME) {
                consumed.addAll(selectMatching(tokensAt(marking, place), binding));
            }
        }
        return List.copyOf(consumed);
    }

    private static List<ColoredToken> eraseFirst(List<ColoredToken> tokens, ColoredToken token) {
        List<ColoredToken> retained = new ArrayList<>(tokens);
        retained.remove(token);
        return List.copyOf(retained);
    }

    public static List<ColoredToken> subtractTokens(List<ColoredToken> tokens, List<ColoredToken> toRemove) {
        List<ColoredToken> retained = tokens;
        for (ColoredToken token : toRemove) retained = eraseFirst(retained, token);
        return List.copyOf(retained);
    }

    public static Marking applyConsumption(Marking marking, List<InputBinding> bindings) {
        return new Marking(marking.places().stream().map(entry -> new PlaceTokens(entry.place(),
                subtractTokens(entry.tokens(), consumedAt(bindings, marking, entry.place())))).toList());
    }

    private static Marking addToken(Marking marking, String place, ColoredToken token) {
        if (marking.places().stream().anyMatch(entry -> entry.place().equals(place))) {
            return new Marking(marking.places().stream().map(entry -> {
                if (!entry.place().equals(place)) return entry;
                List<ColoredToken> tokens = new ArrayList<>(entry.tokens().size() + 1);
                tokens.add(token);
                tokens.addAll(entry.tokens());
                return new PlaceTokens(entry.place(), tokens);
            }).toList());
        }
        List<PlaceTokens> places = new ArrayList<>(marking.places());
        places.add(new PlaceTokens(place, List.of(token)));
        return new Marking(places);
    }

    private static Marking addTokens(Marking marking, List<String> places, ColoredToken token) {
        Marking result = marking;
        for (String place : places) result = addToken(result, place, token);
        return result;
    }

    public static ColoredToken producedToken(TypedTransition transition) {
        return new ColoredToken(transition.identity(), ZERO, transition.revision(), TokenKind.OUTPUT);
    }

    public static Marking applyBranchAt(Marking marking, TypedTransition transition,
            List<InputBinding> bindings) {
        return addTokens(applyConsumption(marking, bindings), transition.outputPlaces(),
                producedToken(transition));
    }

    public static Optional<Marking> stepAt(SolverInput input, Marking marking, String transitionId) {
        Optional<TypedTransition> transition = findTransition(input.transitions(), transitionId);
        if (transition.isEmpty()) return Optional.empty();
        List<InputBinding> bindings = bindingsFor(input, transitionId);
        if (!transitionEnabledAt(bindings, marking)) return Optional.empty();
        return Optional.of(applyBranchAt(marking, transition.get(), bindings));
    }

    public static Optional<Marking> pathReplay(SolverInput input, Marking start, List<String> path) {
        Marking current = start;
        for (String transitionId : path) {
            Optional<Marking> next = stepAt(input, current, transitionId);
            if (next.isEmpty()) return Optional.empty();
            current = next.get();
        }
        return Optional.of(current);
    }

}
