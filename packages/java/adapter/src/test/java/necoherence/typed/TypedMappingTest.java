// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

package necoherence.typed;

import static necoherence.composition.SemanticComposition.ForgedAcyclicity;
import static necoherence.composition.SemanticComposition.ForgedClosure;
import static necoherence.composition.SemanticComposition.ResourceReplayMismatch;
import static necoherence.typed.TypedMapping.*;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertInstanceOf;

import java.math.BigInteger;
import java.util.ArrayList;
import java.util.List;
import java.util.Optional;
import org.junit.jupiter.api.Test;

final class TypedMappingTest {
    private static BigInteger nat(long value) { return BigInteger.valueOf(value); }

    private static TypedPlace readyPlace() { return new TypedPlace("P-READY", "T-JOB", nat(1)); }
    private static TypedPlace donePlace() { return new TypedPlace("P-DONE", "T-JOB", nat(1)); }
    private static TypedTransition runTransition() {
        return new TypedTransition("T-RUN", List.of("P-READY"), List.of("P-DONE"), List.of(), nat(1));
    }
    private static InputBinding runBinding() {
        return binding("T-RUN", "job", "P-READY", "T-JOB", "job-1", BindingMode.CONSUME,
                nat(1), nat(1));
    }
    private static InputBinding binding(String transitionId, String name, String place,
            String tokenType, String identity, BindingMode mode, BigInteger multiplicity,
            BigInteger requiredRevision) {
        return new InputBinding(transitionId, name, place, tokenType, identity, "test",
                multiplicity, mode, requiredRevision);
    }
    private static ColoredToken inputToken(String identity, long revision) {
        return new ColoredToken(identity, nat(0), nat(revision), TokenKind.INPUT);
    }
    private static Marking readyMarking() {
        return new Marking(List.of(
                new PlaceTokens("P-READY", List.of(inputToken("job-1", 1))),
                new PlaceTokens("P-DONE", List.of())));
    }
    private static DomainBound bound() {
        return new DomainBound("unit:typed-mapping-solver", nat(0), nat(1), nat(10), nat(10));
    }
    private static DeclarationGraph graph() {
        return new DeclarationGraph(List.of("P-READY", "P-DONE"), List.of("T-RUN"),
                List.of(new Edge("P-READY", "P-DONE")), nat(1));
    }
    private static SolverInput input() {
        return input(List.of(readyPlace(), donePlace()), List.of(runTransition()),
                List.of(runBinding()), new PlaceHasAtLeast("P-DONE", nat(1)), graph(), readyMarking());
    }
    private static SolverInput input(List<TypedPlace> places, List<TypedTransition> transitions,
            List<InputBinding> bindings, GoalPredicate goal, DeclarationGraph graph, Marking marking) {
        return new SolverInput(places, transitions, bindings, goal, graph, marking, bound());
    }
    private static SolverInput withGoal(GoalPredicate goal) {
        SolverInput base = input();
        return input(base.places(), base.transitions(), base.bindings(), goal, base.graph(), base.marking());
    }
    private static Marking doneMarking() {
        return stepAt(input(), readyMarking(), "T-RUN").orElseThrow();
    }

    @Test void deriveEnabledReportsRunEnabled() {
        EnabledResult result = deriveEnabled(input());
        assertEquals(new DerivedEnabledSet(new EnabledSet(List.of(
                new EnabledTransition("T-RUN", List.of(runBinding()))))), result);
    }

    @Test void consumeRemovesOnlySelectedOccurrences() {
        Marking marking = new Marking(List.of(new PlaceTokens("P-DUP",
                List.of(inputToken("job-d", 1), inputToken("job-d", 1)))));
        InputBinding binding = binding("T-D", "bd", "P-DUP", "T-JOB", "job-d",
                BindingMode.CONSUME, nat(1), nat(1));
        Marking after = applyConsumption(marking, List.of(binding));
        assertEquals(List.of(inputToken("job-d", 1)), tokensAt(after, "P-DUP"));
    }

    @Test void goalEvaluationAndPathReplayUseTheTypedMarking() {
        Marking done = doneMarking();
        GoalPredicate exact = new PlaceHasToken("P-DONE", "T-RUN", nat(0), nat(1));
        assertEquals(true, evalGoal(done, new GoalAnd(
                new PlaceHasAtLeast("P-DONE", nat(1)), exact)));
        assertEquals(Optional.of(done), pathReplay(input(), readyMarking(), List.of("T-RUN")));
        assertEquals(Optional.empty(), pathReplay(input(), readyMarking(), List.of("T-MISSING")));
    }

    @Test void everyInvalidReasonIsReturnedExplicitly() {
        SolverInput base = input();

        InputBinding unknownPlace = binding("T-RUN", "extra", "P-GHOST", "T-JOB", "job-1",
                BindingMode.READ, nat(1), nat(1));
        assertEquals(Optional.of(new UnknownPlace("P-GHOST")), validate(input(base.places(),
                base.transitions(), List.of(runBinding(), unknownPlace), base.goal(), base.graph(), base.marking())));

        TypedTransition unknownInput = new TypedTransition("T-RUN", List.of("P-GHOST"),
                List.of("P-DONE"), List.of(), nat(1));
        assertEquals(Optional.of(new UnknownInputPlace("T-RUN", "P-GHOST")), validate(input(
                base.places(), List.of(unknownInput), base.bindings(), base.goal(), base.graph(), base.marking())));

        InputBinding unknownTransition = binding("T-GHOST", "extra", "P-READY", "T-JOB", "job-1",
                BindingMode.READ, nat(1), nat(1));
        assertEquals(Optional.of(new UnknownTransition("T-GHOST")), validate(input(base.places(),
                base.transitions(), List.of(runBinding(), unknownTransition), base.goal(), base.graph(), base.marking())));

        assertEquals(Optional.of(new DuplicateTransitionIdentity("T-RUN")), validate(input(base.places(),
                List.of(runTransition(), runTransition()), base.bindings(), base.goal(), base.graph(), base.marking())));

        assertEquals(Optional.of(new MissingInputBinding("T-RUN", "P-READY")), validate(input(
                base.places(), base.transitions(), List.of(), base.goal(), base.graph(), base.marking())));

        InputBinding wrongType = binding("T-RUN", "job", "P-READY", "T-WRONG", "job-1",
                BindingMode.CONSUME, nat(1), nat(1));
        assertEquals(Optional.of(new TypeMismatch("P-READY", "T-WRONG", "T-JOB")), validate(input(
                base.places(), base.transitions(), List.of(wrongType), base.goal(), base.graph(), base.marking())));

        InputBinding zero = binding("T-RUN", "job", "P-READY", "T-JOB", "job-1",
                BindingMode.CONSUME, nat(0), nat(1));
        assertEquals(Optional.of(new MultiplicityMismatch("T-RUN", "job", nat(1), nat(0))),
                validate(input(base.places(), base.transitions(), List.of(zero), base.goal(), base.graph(), base.marking())));

        Marking wrongRevision = new Marking(List.of(
                new PlaceTokens("P-READY", List.of(inputToken("job-1", 2))),
                new PlaceTokens("P-DONE", List.of())));
        assertEquals(Optional.of(new RevisionMismatch("T-RUN", "job", nat(1), nat(2))),
                validate(input(base.places(), base.transitions(), base.bindings(), base.goal(), base.graph(), wrongRevision)));

        InputBinding duplicateName = binding("T-RUN", "job", "P-READY", "T-JOB", "other",
                BindingMode.READ, nat(1), nat(1));
        assertEquals(Optional.of(new IdentityMismatch("T-RUN", "job")), validate(input(base.places(),
                base.transitions(), List.of(runBinding(), duplicateName), base.goal(), base.graph(), base.marking())));

        InputBinding wrongDependency = binding("T-RUN", "extra", "P-DONE", "T-JOB", "job-1",
                BindingMode.READ, nat(1), nat(1));
        assertEquals(Optional.of(new DependencyMismatch("T-RUN", "P-DONE")), validate(input(
                base.places(), base.transitions(), List.of(runBinding(), wrongDependency), base.goal(),
                base.graph(), base.marking())));
    }

    static EnabledResult deriveEnabled(SolverInput input) {
        Optional<InvalidReason> invalid = validate(input);
        if (invalid.isPresent()) return new InvalidEnabled(invalid.get());
        List<EnabledTransition> enabled = new ArrayList<>();
        for (TypedTransition transition : input.transitions()) {
            List<InputBinding> bindings = bindingsFor(input, transition.identity());
            if (transitionEnabledAt(bindings, input.marking())) {
                enabled.add(new EnabledTransition(transition.identity(), bindings));
            }
        }
        return new DerivedEnabledSet(new EnabledSet(enabled));
    }
}
