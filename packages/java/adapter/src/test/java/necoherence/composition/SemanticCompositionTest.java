// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

package necoherence.composition;

import static necoherence.composition.SemanticComposition.*;
import static necoherence.composition.SignatureCompositionWire.*;
import static necoherence.semantic.SemanticLibraryFixture.library;
import static necoherence.semantic.SemanticLibraryFixture.slot;
import static necoherence.semantic.SemanticValues.*;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertInstanceOf;
import static org.junit.jupiter.api.Assertions.assertThrows;

import java.math.BigInteger;
import java.util.ArrayList;
import java.util.List;
import java.util.Optional;
import necoherence.semantic.ExactJson;
import necoherence.semantic.SemanticValues.Member;
import necoherence.semantic.SemanticValues.ObjectValue;
import necoherence.semantic.SemanticValues.WireValue;
import necoherence.semantic.TypeSignatures;
import necoherence.semantic.WireFailure.Syntax;
import necoherence.semantic.WireFailure.UnknownField;
import necoherence.semantic.WireFailure.UnknownTag;
import necoherence.semantic.WireFailure.WireException;
import org.junit.jupiter.api.Test;

final class SemanticCompositionTest {
    private static final String DIGEST = "0".repeat(64);

    @Test void problemWireRoundTripPreservesTheAcceptedJsonValue() throws Exception {
        WireValue input = problem();
        ProblemWire decoded = decodeProblem(library(), input);
        assertEquals(input, decoded.exactJson());
    }

    @Test void problemWireRejectsUnknownMissingAndUnknownTagFields() {
        WireException unknown = assertThrows(WireException.class,
                () -> decodeProblem(library(), with(problem(), "extra", NIL)));
        assertInstanceOf(UnknownField.class, unknown.failure());

        WireException missing = assertThrows(WireException.class,
                () -> decodeProblem(library(), without(problem(), "goal")));
        assertEquals(new Syntax("$.goal", "missing field"), missing.failure());

        WireValue invalidEffects = replace(problem(), "allowed_effects", arr(List.of(variant("Unspecified"))));
        WireException tag = assertThrows(WireException.class, () -> decodeProblem(library(), invalidEffects));
        assertEquals(new UnknownTag("$.allowed_effects[0].tag", "Unspecified"), tag.failure());
    }

    @Test void validationReturnsEveryLeanCompositionInputFailureConstructor() throws Exception {
        ProblemWire decoded = decodeProblem(library(), problem());
        CompositionInput valid = decoded.input();

        assertFailure(new BasisMismatch(), withBasis(valid, new SemanticBasis(valid.basis().profile(),
                List.of(new necoherence.semantic.SemanticTypes.SourceRef("external", "1", "other.json", DIGEST, "", Optional.empty())))));

        InitialInput initial = valid.initialInputs().getFirst();
        assertFailure(new DuplicateIdentity("input", "argument"),
                withInitialInputs(valid, List.of(initial, initial)));

        TypeRef missingType = typeRef("missing");
        assertFailure(new UnresolvedType(missingType), withInitialInputs(valid, List.of(
                new InitialInput(initial.id(), new SlotContract(missingType, true, false), initial.source(), initial.resource()))));
        TypeRef foreignSource = new TypeRef(new necoherence.semantic.SemanticTypes.SourceRef("external", "1", "other.json", DIGEST, "", Optional.empty()),
                "number", List.of());
        assertFailure(new UnresolvedType(foreignSource), withInitialInputs(valid, List.of(
                new InitialInput(initial.id(), new SlotContract(foreignSource, true, false), initial.source(), initial.resource()))));

        FunctionRef absentFunction = new FunctionRef("absent", "1", DIGEST);
        InvocationDomain unresolvedSite = new InvocationDomain("domain", "1",
                List.of(new InvocationSite(new SiteId("site"), absentFunction)), List.of(), List.of(), List.of(), List.of());
        assertFailure(new UnresolvedFunction(absentFunction), withInvocationDomain(valid, unresolvedSite));

        FunctionRef invalidRef = new FunctionRef("", "1", DIGEST);
        FunctionSignature invalidFunction = new FunctionSignature(invalidRef, new Pure(),
                CompositionEffect.PURE_FUNCTION, List.of(), List.of(), List.of(), "assumption", Optional.empty());
        assertFailure(new InvalidSignature(invalidRef, "identity, revision, digest, assumptions, or outcomes"),
                withSignatures(valid, List.of(invalidFunction)));

        InitialInput rejected = new InitialInput(initial.id(), initial.contract(),
                new SuppliedValue(new Present<>(ExactJson.num(BigInteger.valueOf(101)))), Optional.empty());
        PreparationFailed invalidValue = assertInstanceOf(PreparationFailed.class,
                prepare(library(), graphDigest(), wire(withInitialInputs(valid, List.of(rejected)))));
        InvalidInitialValue initialFailure = assertInstanceOf(InvalidInitialValue.class, invalidValue.failure());
        assertEquals(initial.id(), initialFailure.id());
        assertEquals(SimpleValueCondition.ABOVE_MAXIMUM, initialFailure.failure().condition());

        assertFailure(new EmptyGoal(),
                withGoal(valid, new GoalSpec(List.of(), List.of(), List.of())));

        ResourceLot invocationLot = new ResourceLot(new LotId("lot"), typeRef("number"),
                new InvocationOutcomeResourceProducer(new SiteId("site"), new OutcomeId("ok")),
                BigInteger.ZERO, BigInteger.ONE, "test");
        assertFailure(new InvalidResourceDeclaration("initial lot has an invocation producer"),
                withInitialResources(valid, List.of(invocationLot)));

        FunctionRef pureRef = new FunctionRef("pure", "1", DIGEST);
        FunctionSignature pure = new FunctionSignature(pureRef, new Pure(), CompositionEffect.PURE_FUNCTION,
                List.of(), List.of(new OutcomeContract(new OutcomeId("ok"), OutcomeForm.SUCCESS, List.of(), List.of())),
                List.of(), "assumption", Optional.empty());
        InvocationSite site = new InvocationSite(new SiteId("site"), pureRef);
        assertFailureWithCause(new SiteEffectNotPermitted(new SiteId("site"), CompositionEffect.PURE_FUNCTION),
                withInvocationDomain(withSignatures(valid, List.of(pure)), domain(List.of(site), List.of(), List.of())), pureRef);

        FunctionRef transformRef = new FunctionRef("transform", "1", DIGEST);
        FunctionSignature transform = new FunctionSignature(transformRef, new DeclaredTransform(), CompositionEffect.PURE_FUNCTION,
                List.of(), List.of(new OutcomeContract(new OutcomeId("ok"), OutcomeForm.SUCCESS, List.of(), List.of())),
                List.of(), "assumption", Optional.empty());
        assertFailureWithCause(new TransformNotPermitted(transformRef),
                withAllowedEffects(withInvocationDomain(withSignatures(valid, List.of(transform)),
                        domain(List.of(new InvocationSite(new SiteId("site"), transformRef)), List.of(), List.of())),
                        List.of(CompositionEffect.PURE_FUNCTION)), transformRef);

        InitialOnly missingSource = new InitialOnly(new InputId("missing"), List.of());
        assertFailure(new GoalSourceConstraintUndefined(new GoalPortId("result"), missingSource),
                withGoal(valid, new GoalSpec(List.of(new GoalPort(new GoalPortId("result"),
                        new SlotContract(typeRef("number"), true, false), missingSource)), List.of(), List.of())));

        FailureOrigin absentOrigin = new FunctionFailureOrigin(new FunctionRef("absent", "1", DIGEST), new OutcomeId("fail"));
        FailureEmbedding embedding = new FailureEmbedding(new FailureEmbeddingId("failure"), absentOrigin,
                new SlotContract(typeRef("number"), true, false), List.of());
        assertFailure(new FailureEmbeddingOriginUndefined(new FailureEmbeddingId("failure"), absentOrigin),
                withGoal(valid, new GoalSpec(valid.goal().outputs(), List.of(embedding), List.of())));

        assertFailure(new ConstructionNotProduct("number-rule", typeRef("number")),
                withInvocationDomain(valid, domain(List.of(), List.of(
                        new ConstructionRule("number-rule", typeRef("number"), List.of(), List.of())), List.of())));

        TypeRef product = typeRef("product");
        assertFailure(new FieldConstraintUnknownField("product-rule", "missing"),
                withInvocationDomain(valid, domain(List.of(), List.of(new ConstructionRule("product-rule", product,
                        List.of(), List.of(new FieldConstraint("missing", new AnyCompatible(), FieldPresence.REQUIRED)))), List.of())));
        assertFailure(new ConstrainedNestedField("product-rule", "n"),
                withInvocationDomain(valid, domain(List.of(), List.of(new ConstructionRule("product-rule", product,
                        List.of(new NamedConstruction("n", "number-rule")),
                        List.of(new FieldConstraint("n", new AnyCompatible(), FieldPresence.REQUIRED)))), List.of())));
        FieldConstraint undefinedField = new FieldConstraint("n", missingSource, FieldPresence.REQUIRED);
        assertFailure(new ConstructionFieldSourceUndefined("product-rule", undefinedField),
                withInvocationDomain(valid, domain(List.of(), List.of(new ConstructionRule("product-rule", product,
                        List.of(), List.of(undefinedField))), List.of())));
        assertFailure(new NestedFieldUndeclared("product-rule", "missing"),
                withInvocationDomain(valid, domain(List.of(), List.of(new ConstructionRule("product-rule", product,
                        List.of(new NamedConstruction("missing", "inner")), List.of())), List.of())));
        assertFailure(new NestedConstructionMismatch("product-rule", "n", "inner", typeRef("number")),
                withInvocationDomain(valid, domain(List.of(), List.of(
                        new ConstructionRule("product-rule", product, List.of(new NamedConstruction("n", "inner")), List.of()),
                        new ConstructionRule("inner", product, List.of(), List.of())), List.of())));

        assertFailure(new ExplicitSiteOrderInvalid(new SiteId("site"), new SiteId("site")),
                withExplicitOrder(valid, List.of(new SiteOrder(new SiteId("site"), new SiteId("site")))));
    }

    @Test void invalidLibraryReturnsTheProfilePredicateAndLocation() throws Exception {
        CompositionInput valid = decodeProblem(library(), problem()).input();
        WireValue profile = f(library(), "profile");
        WireValue broken = replace(library(), "profile", replace(profile, "default_integer_domain", str("missing")));
        PreparationFailed failed = assertInstanceOf(PreparationFailed.class,
                prepare(broken, graphDigest(), wire(valid)));
        InvalidLibrary invalid = assertInstanceOf(InvalidLibrary.class, failed.failure());
        assertEquals(new necoherence.semantic.TypeSignatures.ProfileCheckFailure(
                new necoherence.semantic.SemanticTypes.ProfileRef("generic-values", "2", "b".repeat(64)),
                necoherence.semantic.SemanticValidation.ProfilePredicate.PR05, List.of("default_integer_domain")),
                invalid.failure());
    }

    @Test void preparedCompositionInputHasNoPublicConstructor() {
        assertEquals(0, PreparedCompositionInput.class.getConstructors().length);
    }

    private static void assertFailure(CompositionInputFailure expected, CompositionInput input) {
        PreparationFailed failure = assertInstanceOf(PreparationFailed.class,
                prepare(library(), graphDigest(), wire(input)));
        assertEquals(expected, failure.failure());
    }

    private static void assertFailureWithCause(CompositionInputFailure expected, CompositionInput input, FunctionRef function) {
        PreparationFailed failure = assertInstanceOf(PreparationFailed.class,
                prepare(library(), graphDigest(), wireWithCause(input, function)));
        assertEquals(expected, failure.failure());
    }

    /** A problem whose library signature for the function carries the outcome cause that the preparation binds. */
    private static ProblemWire wireWithCause(CompositionInput input, FunctionRef function) {
        WireValue signature = obj("reference", obj("identity", str(function.identity()), "revision", str(function.revision()),
                        "content_digest", str(function.contentDigest())),
                "form", variant("Pure"), "effect", variant("PureFunction"), "inputs", arr(List.of()),
                "outcomes", arr(List.of(obj("id", str("ok"), "form", variant("Success"),
                        "cause", fields("ValueContract", obj("origin", necoherence.semantic.SemanticLibraryFixture.origin)),
                        "value_ports", arr(List.of()), "produced_resources", arr(List.of())))),
                "resource_inputs", arr(List.of()), "assumption_ref", str("assumption"), "handles_failure", NIL);
        try { return decodeProblem(library(), replace(problem(), "signatures", arr(List.of(signature)))).withInput(input); }
        catch (WireException failure) { throw new IllegalStateException(failure); }
    }

    private static ProblemWire wire(CompositionInput input) {
        try { return decodeProblem(library(), problem()).withInput(input); }
        catch (WireException failure) { throw new IllegalStateException(failure); }
    }

    private static String graphDigest() {
        return s(f(TypeSignatures.computeBasis(library(), arr(List.of()), NIL), "graph_sha256"));
    }

    private static WireValue problem() {
        WireValue basis = TypeSignatures.computeBasis(library(), arr(List.of()), NIL);
        WireValue initial = obj("id", str("argument"), "contract", slot("number"),
                "source", variant("Argument"), "resource", NIL);
        WireValue source = fields("InitialOnly", obj("input", str("argument"), "path", arr(List.of())));
        WireValue goal = obj("outputs", arr(List.of(obj("id", str("result"), "contract", slot("number"),
                        "source_constraint", source))), "failures", arr(List.of()), "final_resources", arr(List.of()));
        WireValue domain = obj("identity", str("domain"), "revision", str("1"), "sites", arr(List.of()),
                "permitted_projections", arr(List.of()), "permitted_constructions", arr(List.of()),
                "permitted_transforms", arr(List.of()), "guards", arr(List.of()));
        WireValue bounds = obj("max_expanded_states", str("10000"),
                "max_binding_candidates", str("100000"),
                "max_type_obligations", str("10000"),
                "max_branch_nodes", str("100000"), "resource_bounds", NIL,
                "max_sample_length", str("32"));
        return obj("identity", str("composition"), "revision", str("1"), "basis", basis,
                "signatures", arr(List.of()), "initial_inputs", arr(List.of(initial)),
                "initial_resources", arr(List.of()), "goal", goal, "invocation_domain", domain,
                "allowed_effects", arr(List.of()), "explicit_order", arr(List.of()),
                "selection_policy", NIL, "bounds", bounds);
    }

    private static CompositionInput withBasis(CompositionInput input, SemanticBasis basis) {
        return new CompositionInput(input.identity(), input.revision(), basis, input.signatures(), input.initialInputs(),
                input.initialResources(), input.goal(), input.invocationDomain(), input.allowedEffects(), input.explicitOrder(), input.selectionPolicy(), input.bounds());
    }
    private static CompositionInput withInitialInputs(CompositionInput input, List<InitialInput> values) {
        return new CompositionInput(input.identity(), input.revision(), input.basis(), input.signatures(), values,
                input.initialResources(), input.goal(), input.invocationDomain(), input.allowedEffects(), input.explicitOrder(), input.selectionPolicy(), input.bounds());
    }
    private static CompositionInput withInitialResources(CompositionInput input, List<ResourceLot> values) {
        return new CompositionInput(input.identity(), input.revision(), input.basis(), input.signatures(), input.initialInputs(),
                values, input.goal(), input.invocationDomain(), input.allowedEffects(), input.explicitOrder(), input.selectionPolicy(), input.bounds());
    }
    private static CompositionInput withInvocationDomain(CompositionInput input, InvocationDomain value) {
        return new CompositionInput(input.identity(), input.revision(), input.basis(), input.signatures(), input.initialInputs(),
                input.initialResources(), input.goal(), value, input.allowedEffects(), input.explicitOrder(), input.selectionPolicy(), input.bounds());
    }
    private static CompositionInput withSignatures(CompositionInput input, List<FunctionSignature> values) {
        return new CompositionInput(input.identity(), input.revision(), input.basis(), values, input.initialInputs(),
                input.initialResources(), input.goal(), input.invocationDomain(), input.allowedEffects(), input.explicitOrder(), input.selectionPolicy(), input.bounds());
    }
    private static CompositionInput withGoal(CompositionInput input, GoalSpec value) {
        return new CompositionInput(input.identity(), input.revision(), input.basis(), input.signatures(), input.initialInputs(),
                input.initialResources(), value, input.invocationDomain(), input.allowedEffects(), input.explicitOrder(), input.selectionPolicy(), input.bounds());
    }
    private static CompositionInput withAllowedEffects(CompositionInput input, List<CompositionEffect> values) {
        return new CompositionInput(input.identity(), input.revision(), input.basis(), input.signatures(), input.initialInputs(),
                input.initialResources(), input.goal(), input.invocationDomain(), values, input.explicitOrder(), input.selectionPolicy(), input.bounds());
    }
    private static CompositionInput withExplicitOrder(CompositionInput input, List<SiteOrder> values) {
        return new CompositionInput(input.identity(), input.revision(), input.basis(), input.signatures(), input.initialInputs(),
                input.initialResources(), input.goal(), input.invocationDomain(), input.allowedEffects(), values, input.selectionPolicy(), input.bounds());
    }
    private static InvocationDomain domain(List<InvocationSite> sites, List<ConstructionRule> constructions, List<FunctionRef> transforms) {
        return new InvocationDomain("domain", "1", sites, List.of(), constructions, transforms, List.of());
    }

    private static WireValue replace(WireValue value, String key, WireValue replacement) {
        return new ObjectValue(((ObjectValue) value).members().stream()
                .map(member -> member.key().equals(key) ? new Member(key, replacement) : member).toList());
    }
    private static WireValue with(WireValue value, String key, WireValue addition) {
        List<Member> members = new ArrayList<>(((ObjectValue) value).members()); members.add(new Member(key, addition));
        return new ObjectValue(members);
    }
    private static WireValue without(WireValue value, String key) {
        return new ObjectValue(((ObjectValue) value).members().stream().filter(member -> !member.key().equals(key)).toList());
    }
}
