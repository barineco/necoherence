// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

package necoherence.composition;

import necoherence.semantic.ExactJson.JsonValue;
import static necoherence.composition.SemanticComposition.*;
import static necoherence.semantic.SemanticValues.*;

import java.math.BigInteger;
import java.util.ArrayList;
import java.util.List;
import java.util.Objects;
import java.util.Optional;
import java.util.Set;

import necoherence.semantic.SemanticGeneration;
import necoherence.semantic.SemanticGeneration.GenerationFailure;
import necoherence.semantic.WireJson;
import necoherence.semantic.WireFailure.Syntax;
import necoherence.semantic.WireFailure.UnknownField;
import necoherence.semantic.WireFailure.UnknownTag;
import necoherence.semantic.WireFailure.WireException;
import necoherence.semantic.SemanticValues.ArrayValue;
import necoherence.semantic.SemanticValues.BooleanValue;
import necoherence.semantic.SemanticValues.Member;
import necoherence.semantic.SemanticValues.Null;
import necoherence.semantic.SemanticValues.NullSlot;
import necoherence.semantic.SemanticValues.ObjectValue;
import necoherence.semantic.SemanticValues.Present;
import necoherence.semantic.SemanticValues.Slot;
import necoherence.semantic.SemanticValues.StringValue;
import necoherence.semantic.SemanticValues.WireValue;
import necoherence.semantic.TypeSignatures;
import necoherence.typed.TypedMapping;

/**
 * Strict signature-composition wire decoding and exact wire re-encoding.
 */
public final class SignatureCompositionWire {
    private SignatureCompositionWire() {}

        /** Lean {@code decodeExact}: the failure of the decoder is reported as a decode rejection. */
    static WireValue exactWire(WireValue value) {
        try { return exact(value, "$"); }
        catch (WireException failure) { throw new CompositionPlanWire.DecodeRejection(failure.failure()); }
    }
                /**
     * The declaration-level cause retained separately from semantic outcome contracts.
     * @param function corresponding Lean field
     * @param outcome corresponding Lean field
     * @param cause corresponding Lean field
     */
    public record CauseBinding(FunctionRef function, OutcomeId outcome, WireValue cause) {
        public CauseBinding {
            function = Objects.requireNonNull(function); outcome = Objects.requireNonNull(outcome);
            cause = Objects.requireNonNull(cause);
        }
    }

            /**
     * An exact input wire value and its typed semantic projection.
     */
    public static final class ProblemWire {
        private final WireValue exactJson;
        private final CompositionInput input;
        private final List<CauseBinding> causes;
        private ProblemWire(WireValue exactJson, CompositionInput input, List<CauseBinding> causes) {
            this.exactJson = Objects.requireNonNull(exactJson); this.input = Objects.requireNonNull(input);
            this.causes = List.copyOf(causes);
        }
        ProblemWire withInput(CompositionInput replacement) { return new ProblemWire(exactJson, replacement, causes); }
        /** @return the accepted exact wire value */
        public WireValue exactJson() { return exactJson; }
        /** @return the decoded composition input */
        public CompositionInput input() { return input; }
        /** @return declaration causes retained for operation checking */
        public List<CauseBinding> causes() { return causes; }
    }

        /**
     * Decodes a problem and rejects every unknown field, missing field, or unknown tag.
     * @param library checked signature library
     * @param json composition problem wire value
     * @return the exact wire value and typed input
     * @throws WireException when the wire value is invalid
     */
    public static ProblemWire decodeProblem(WireValue library, WireValue json) throws WireException {
        Objects.requireNonNull(library); Objects.requireNonNull(json);
        keys(json, "$", "identity", "revision", "basis", "signatures", "initial_inputs",
                "initial_resources", "goal", "invocation_domain", "allowed_effects", "explicit_order",
                "selection_policy", "bounds");
        WireValue supplied;
        try { supplied = TypeSignatures.decodeBasis(field(json, "basis", "$", WireValue.class), "$.basis"); }
        catch (GenerationFailure failure) {
            if (failure.wireFailure() != null) throw new WireException(failure.wireFailure());
            throw syntax(failure.path(), failure.condition());
        }
        if (!sameWire(supplied, TypeSignatures.computeBasis(library, arr(List.of()), NIL)))
            throw syntax("$.basis", "composition signature basis mismatch");
        List<FunctionSignature> signatures = new ArrayList<>();
        List<CauseBinding> causes = new ArrayList<>();
        List<WireValue> signatureRows = array(field(json, "signatures", "$", WireValue.class), "$.signatures");
        for (int index = 0; index < signatureRows.size(); index++)
            signatures.add(functionSignature(signatureRows.get(index), "$.signatures[" + index + "]", causes));
        WireValue graph = internalGraph(library);
        CompositionInput input = new CompositionInput(
                text(field(json, "identity", "$", WireValue.class), "$.identity"),
                text(field(json, "revision", "$", WireValue.class), "$.revision"),
                SemanticBasis.of(graph), signatures,
                mapArray(field(json, "initial_inputs", "$", WireValue.class), "$.initial_inputs", SignatureCompositionWire::initialInput),
                mapArray(field(json, "initial_resources", "$", WireValue.class), "$.initial_resources", SignatureCompositionWire::resourceLot),
                goal(field(json, "goal", "$", WireValue.class), "$.goal"),
                invocationDomain(field(json, "invocation_domain", "$", WireValue.class), "$.invocation_domain"),
                mapArray(field(json, "allowed_effects", "$", WireValue.class), "$.allowed_effects", SignatureCompositionWire::effect),
                mapArray(field(json, "explicit_order", "$", WireValue.class), "$.explicit_order", SignatureCompositionWire::siteOrder),
                optional(field(json, "selection_policy", "$", WireValue.class), "$.selection_policy", SignatureCompositionWire::selectionPolicy),
                bounds(field(json, "bounds", "$", WireValue.class), "$.bounds"));
        return new ProblemWire(json, input, causes);
    }

        public static SemanticExecution.AdmittedComposition admitDerivation(
            necoherence.semantic.AdmissionAuthority authority, WireValue library, WireValue problem, PreparedCompositionInput prepared, WireValue json) throws WireException {
        try {
            Objects.requireNonNull(authority);
            return new SemanticExecution.AdmittedComposition(prepared, decodePlan(library, problem, prepared, json));
        } catch (CompositionPlanWire.DecodeRejection rejection) {
            throw new WireException(rejection.failure());
        }
    }

        private static CompositionPlan decodePlan(WireValue library, WireValue problem,
            PreparedCompositionInput prepared, WireValue json) throws WireException {
        WireDecode.keys(json, "plan", "witness", "selection");
        WireValue plan = WireDecode.prop(json, "plan");
        WireDecode.keys(plan, "input_identity", "input_revision", "root");
        WireValue witness = WireDecode.prop(json, "witness");
        WireDecode.keys(witness, "input_snapshot", "initial_membership", "resource_traces");
        if (!sameWire(WireDecode.prop(witness, "input_snapshot"), problem))
            throw WireDecode.syntax("$", "input snapshot mismatch");
        CompositionPlanWire.Expected expected = CompositionPlanWire.expectedBasis(library, prepared, problem);
        PlanTree root = CompositionPlanWire.decodePlanRoot(plan, expected);
        WireValue selection = WireDecode.prop(json, "selection");
        String tag = WireDecode.tagOf(selection);
        if (tag.equals("AnyFeasible")) WireDecode.keys(selection, "tag");
        else if (!tag.equals("Unique")) throw WireDecode.unknownTag("$.tag", tag);
        return new CompositionPlan(WireDecode.textAt(plan, "input_identity"),
                WireDecode.textAt(plan, "input_revision"), root);
    }

        /**
     * Checks the signature library and prepares a decoded composition problem.
     * @param library signature library
     * @param graphDigest semantic graph digest
     * @param problem decoded problem
     * @return the preparation result
     */
    public static PreparationResult prepare(WireValue library, String graphDigest, ProblemWire problem) {
        Objects.requireNonNull(library); Objects.requireNonNull(graphDigest); Objects.requireNonNull(problem);
        TypeSignatures.CheckedLibrary checked;
        try { checked = TypeSignatures.checkLibrary(library); }
        catch (GenerationFailure failure) {
            return new PreparationFailed(new InvalidLibrary(TypeSignatures.libraryCheckFailure(library, failure)));
        }
        return prepare(checked, graphDigest, problem);
    }

    /**
     * Prepares a decoded composition problem over a library that has already been checked.
     * @param checked checked signature library
     * @param graphDigest semantic graph digest
     * @param problem decoded problem
     * @return the preparation result
     */
    public static PreparationResult prepare(TypeSignatures.CheckedLibrary checked, String graphDigest, ProblemWire problem) {
        Objects.requireNonNull(checked); Objects.requireNonNull(graphDigest); Objects.requireNonNull(problem);
        WireValue library = checked.value();
        for (FunctionSignature function : problem.input().signatures()) {
            Optional<WireValue> contract = signatureContract(problem.causes(), function);
            if (contract.isEmpty()) return new PreparationFailed(new InvalidSignature(function.reference(), "missing outcome cause"));
            if (!a(f(contract.get(), "outcomes")).stream().allMatch(outcome -> TypeSignatures.outcomeValid(outcome, a(f(library, "sources")))))
                return new PreparationFailed(new InvalidSignature(function.reference(), "outcome cause or external failure value"));
        }
        OperationChecker operationChecker = (function, definition) -> checkOperation(library, graphDigest,
                problem.causes(), function, definition);
        WireValue graph = internalGraph(library);
        necoherence.semantic.SemanticValues.Context context = new necoherence.semantic.SemanticValues.Context(graph);
        return prepareDirectComposition(context, problem.input(), operationChecker,
                (function, definition) -> {
                    List<TypeRef> references = new ArrayList<>();
                    function.inputs().forEach(port -> references.add(port.contract().typeRef()));
                    function.resourceInputs().forEach(resource -> references.add(resource.tokenType()));
                    function.outcomes().forEach(outcome -> {
                        outcome.valuePorts().forEach(port -> references.add(port.contract().typeRef()));
                        outcome.producedResources().forEach(resource -> references.add(resource.tokenType()));
                    });
                    return references.stream().flatMap(reference -> context.meaningObligations(
                            necoherence.semantic.SemanticGraphWire.typeRefWire(reference)).stream()).toList();
                });
    }

        private static Optional<CompositionInputFailure> checkOperation(WireValue library, String graphDigest,
            List<CauseBinding> causes, FunctionSignature function, DefinitionRef definition) {
        WireValue declaration = a(f(library, "definitions")).stream()
                .filter(candidate -> textUnchecked(f(candidate, "id")).equals(definition.name())).findFirst().orElse(null);
        if (declaration == null) return Optional.of(new InvalidSignature(function.reference(), "unresolved operation identity"));
        if (!tagUnchecked(f(declaration, "shape")).equals("Operation"))
            return Optional.of(new InvalidSignature(function.reference(), "definition is not an operation"));
        if (!function.reference().identity().equals(textUnchecked(f(declaration, "wire_identity")))
                || !function.reference().revision().equals(textUnchecked(f(library, "revision")))
                || !function.reference().contentDigest().equals(graphDigest))
            return Optional.of(new InvalidSignature(function.reference(), "operation identity basis"));
        Optional<WireValue> extended = signatureContract(causes, function);
        if (extended.isEmpty()) return Optional.of(new InvalidSignature(function.reference(), "missing outcome cause"));
        WireValue base = closedPayload(f(declaration, "shape"), "$.shape");
        CompositionEffect expected = tagUnchecked(f(base, "effect")).equals("HttpRequestResponse")
                ? CompositionEffect.HTTP_REQUEST_RESPONSE : CompositionEffect.DATA_ONLY;
        if (function.effect() != expected) return Optional.of(new InvalidSignature(function.reference(), "operation effect"));
        if (!TypeSignatures.operationExtensionValid(library, base, extended.get()))
            return Optional.of(new InvalidSignature(function.reference(), "base outcome preservation or external supplement"));
        return Optional.empty();
    }

        private static Optional<WireValue> signatureContract(List<CauseBinding> causes, FunctionSignature function) {
        List<WireValue> outcomes = new ArrayList<>();
        for (OutcomeContract outcome : function.outcomes()) {
            Optional<CauseBinding> binding = causes.stream().filter(candidate -> candidate.function().equals(function.reference())
                    && candidate.outcome().equals(outcome.id())).findFirst();
            if (binding.isEmpty()) return Optional.empty();
            outcomes.add(obj("id", str(outcome.id().value()),
                    "form", variant(outcome.form() == OutcomeForm.SUCCESS ? "Success" : "DeclaredFailure"),
                    "cause", binding.get().cause(),
                    "value_ports", arr(outcome.valuePorts().stream().map(port -> obj("id", str(port.id().value()), "contract", contractWire(port.contract()))).toList()),
                    "produced_resources", arr(outcome.producedResources().stream().map(SignatureCompositionWire::productionWire).toList())));
        }
        return Optional.of(obj("effect", variant(function.effect() == CompositionEffect.HTTP_REQUEST_RESPONSE ? "HttpRequestResponse" : "DataOnly"),
                "inputs", arr(function.inputs().stream().map(port -> obj("id", str(port.id().value()), "contract", contractWire(port.contract()))).toList()),
                "outcomes", arr(outcomes)));
    }

        private static FunctionSignature functionSignature(WireValue value, String path, List<CauseBinding> causes) throws WireException {
        keys(value, path, "reference", "form", "effect", "inputs", "outcomes", "resource_inputs", "assumption_ref", "handles_failure");
        FunctionRef reference = functionRef(field(value, "reference", path, WireValue.class), path + ".reference");
        FunctionForm form = functionForm(field(value, "form", path, WireValue.class), path + ".form");
        CompositionEffect effect = effect(field(value, "effect", path, WireValue.class), path + ".effect");
        List<InputPort> inputs = mapArray(field(value, "inputs", path, WireValue.class), path + ".inputs", SignatureCompositionWire::inputPort);
        List<OutcomeContract> outcomes = mapArray(field(value, "outcomes", path, WireValue.class), path + ".outcomes",
                (row, outcomePath) -> {
                    OutcomeContract outcome = outcome(row, outcomePath);
                    causes.add(new CauseBinding(reference, outcome.id(), field(row, "cause", outcomePath, WireValue.class)));
                    return outcome;
                });
        return new FunctionSignature(reference, form, effect, inputs, outcomes,
                mapArray(field(value, "resource_inputs", path, WireValue.class), path + ".resource_inputs", SignatureCompositionWire::requirement),
                text(field(value, "assumption_ref", path, WireValue.class), path + ".assumption_ref"),
                optional(field(value, "handles_failure", path, WireValue.class), path + ".handles_failure", SignatureCompositionWire::failureOrigin));
    }

        private static FunctionRef functionRef(WireValue value, String path) throws WireException {
        keys(value, path, "identity", "revision", "content_digest");
        return new FunctionRef(text(field(value, "identity", path, WireValue.class), path + ".identity"),
                text(field(value, "revision", path, WireValue.class), path + ".revision"),
                text(field(value, "content_digest", path, WireValue.class), path + ".content_digest"));
    }

        private static SlotContract contract(WireValue value, String path) throws WireException {
        keys(value, path, "type_id", "required", "nullable");
        return new SlotContract(typeRef(text(field(value, "type_id", path, WireValue.class), path + ".type_id")),
                bool(field(value, "required", path, WireValue.class), path + ".required"),
                bool(field(value, "nullable", path, WireValue.class), path + ".nullable"));
    }

        private static List<PathStep> path(WireValue value, String path) throws WireException {
        return mapArray(value, path, (step, stepPath) -> switch (tagAt(step, stepPath)) {
            case "Field" -> { keys(step, stepPath, "tag", "value"); yield new Field(text(payloadAt(step, stepPath), stepPath + ".value")); }
            case "Index" -> { keys(step, stepPath, "tag", "value"); yield new Index(natural(payloadAt(step, stepPath), stepPath + ".value")); }
            case "Variant" -> { keys(step, stepPath, "tag", "value"); yield new Variant(text(payloadAt(step, stepPath), stepPath + ".value")); }
            default -> throw unknownTag(stepPath + ".tag", tagAt(step, stepPath));
        });
    }

        private static SourceConstraint sourceConstraint(WireValue value, String path) throws WireException {
        return switch (tagAt(value, path)) {
            case "AnyCompatible" -> { keys(value, path, "tag"); yield new AnyCompatible(); }
            case "InitialOnly" -> {
                WireValue row = closedFields(value, path); keys(row, path + ".fields", "input", "path");
                yield new InitialOnly(new InputId(text(field(row, "input", path, WireValue.class), path + ".fields.input")),
                        path(field(row, "path", path, WireValue.class), path + ".fields.path"));
            }
            case "ProducedBy" -> {
                WireValue row = closedFields(value, path); keys(row, path + ".fields", "site", "outcome", "port", "path");
                yield new ProducedBy(new SiteId(text(field(row, "site", path, WireValue.class), path + ".fields.site")),
                        new OutcomeId(text(field(row, "outcome", path, WireValue.class), path + ".fields.outcome")),
                        new PortId(text(field(row, "port", path, WireValue.class), path + ".fields.port")),
                        path(field(row, "path", path, WireValue.class), path + ".fields.path"));
            }
            default -> throw unknownTag(path + ".tag", tagAt(value, path));
        };
    }

        private static ResourceLotRef lotRef(WireValue value, String path) throws WireException {
        return switch (tagAt(value, path)) {
            case "Initial" -> { keys(value, path, "tag", "value"); yield new InitialLot(new LotId(text(payloadAt(value, path), path + ".value"))); }
            case "Produced" -> {
                WireValue row = closedFields(value, path); keys(row, path + ".fields", "site", "outcome", "production");
                yield new ProducedLot(new SiteId(text(field(row, "site", path, WireValue.class), path + ".fields.site")),
                        new OutcomeId(text(field(row, "outcome", path, WireValue.class), path + ".fields.outcome")),
                        new ProductionId(text(field(row, "production", path, WireValue.class), path + ".fields.production")));
            }
            default -> throw unknownTag(path + ".tag", tagAt(value, path));
        };
    }

        private static ResourceProducer resourceProducer(WireValue value, String path) throws WireException {
        return switch (tagAt(value, path)) {
            case "Initial" -> {
                WireValue row = closedFields(value, path); keys(row, path + ".fields", "identity", "revision");
                yield new InitialResourceProducer(text(field(row, "identity", path, WireValue.class), path + ".fields.identity"),
                        text(field(row, "revision", path, WireValue.class), path + ".fields.revision"));
            }
            case "InvocationOutcome" -> {
                WireValue row = closedFields(value, path); keys(row, path + ".fields", "site", "outcome");
                yield new InvocationOutcomeResourceProducer(new SiteId(text(field(row, "site", path, WireValue.class), path + ".fields.site")),
                        new OutcomeId(text(field(row, "outcome", path, WireValue.class), path + ".fields.outcome")));
            }
            default -> throw unknownTag(path + ".tag", tagAt(value, path));
        };
    }

        private static ResourceIdentityConstraint identityConstraint(WireValue value, String path) throws WireException {
        return switch (tagAt(value, path)) {
            case "Any" -> { keys(value, path, "tag"); yield new AnyResourceIdentity(); }
            case "Exactly" -> { keys(value, path, "tag", "value"); yield new ExactlyResourceIdentity(resourceProducer(payloadAt(value, path), path + ".value")); }
            default -> throw unknownTag(path + ".tag", tagAt(value, path));
        };
    }

        private static ResourceLot resourceLot(WireValue value, String path) throws WireException {
        keys(value, path, "id", "token_type", "producer", "revision", "quantity", "provenance");
        return new ResourceLot(new LotId(text(field(value, "id", path, WireValue.class), path + ".id")),
                typeRef(text(field(value, "token_type", path, WireValue.class), path + ".token_type")),
                resourceProducer(field(value, "producer", path, WireValue.class), path + ".producer"),
                natural(field(value, "revision", path, WireValue.class), path + ".revision"),
                natural(field(value, "quantity", path, WireValue.class), path + ".quantity"),
                text(field(value, "provenance", path, WireValue.class), path + ".provenance"));
    }

        private static ResourceRequirement requirement(WireValue value, String path) throws WireException {
        keys(value, path, "id", "token_type", "mode", "multiplicity", "required_revision", "identity");
        RequirementId id = new RequirementId(text(field(value, "id", path, WireValue.class), path + ".id"));
        TypeRef tokenType = typeRef(text(field(value, "token_type", path, WireValue.class), path + ".token_type"));
        WireValue modeValue = field(value, "mode", path, WireValue.class);
        TypedMapping.BindingMode mode = switch (tagAt(modeValue, path + ".mode")) {
            case "Read" -> { keys(modeValue, path + ".mode", "tag"); yield TypedMapping.BindingMode.READ; }
            case "Consume" -> { keys(modeValue, path + ".mode", "tag"); yield TypedMapping.BindingMode.CONSUME; }
            default -> throw unknownTag(path + ".mode.tag", tagAt(modeValue, path + ".mode"));
        };
        return new ResourceRequirement(id, tokenType, mode,
                natural(field(value, "multiplicity", path, WireValue.class), path + ".multiplicity"),
                natural(field(value, "required_revision", path, WireValue.class), path + ".required_revision"),
                identityConstraint(field(value, "identity", path, WireValue.class), path + ".identity"));
    }

        private static ResourceProduction production(WireValue value, String path) throws WireException {
        keys(value, path, "id", "token_type", "revision", "quantity", "provenance");
        return new ResourceProduction(new ProductionId(text(field(value, "id", path, WireValue.class), path + ".id")),
                typeRef(text(field(value, "token_type", path, WireValue.class), path + ".token_type")),
                natural(field(value, "revision", path, WireValue.class), path + ".revision"),
                natural(field(value, "quantity", path, WireValue.class), path + ".quantity"),
                text(field(value, "provenance", path, WireValue.class), path + ".provenance"));
    }

        private static InitialInput initialInput(WireValue value, String path) throws WireException {
        keys(value, path, "id", "contract", "source", "resource");
        InputId id = new InputId(text(field(value, "id", path, WireValue.class), path + ".id"));
        SlotContract contract = contract(field(value, "contract", path, WireValue.class), path + ".contract");
        WireValue source = field(value, "source", path, WireValue.class);
        InitialSource decoded = switch (tagAt(source, path + ".source")) {
            case "Argument" -> { keys(source, path + ".source", "tag"); yield new Argument(); }
            case "SuppliedValue" -> { keys(source, path + ".source", "tag", "value"); yield new SuppliedValue(slot(payloadAt(source, path + ".source"), path + ".source.value")); }
            default -> throw unknownTag(path + ".source.tag", tagAt(source, path + ".source"));
        };
        return new InitialInput(id, contract, decoded,
                optional(field(value, "resource", path, WireValue.class), path + ".resource", (v, p) -> new LotId(text(v, p))));
    }

        private static InputPort inputPort(WireValue value, String path) throws WireException {
        keys(value, path, "id", "contract", "source_constraint", "resource_requirement");
        return new InputPort(new PortId(text(field(value, "id", path, WireValue.class), path + ".id")),
                contract(field(value, "contract", path, WireValue.class), path + ".contract"),
                sourceConstraint(field(value, "source_constraint", path, WireValue.class), path + ".source_constraint"),
                optional(field(value, "resource_requirement", path, WireValue.class), path + ".resource_requirement", (v, p) -> new RequirementId(text(v, p))));
    }

        private static OutputPort outputPort(WireValue value, String path) throws WireException {
        keys(value, path, "id", "contract", "resource_production");
        return new OutputPort(new PortId(text(field(value, "id", path, WireValue.class), path + ".id")),
                contract(field(value, "contract", path, WireValue.class), path + ".contract"),
                optional(field(value, "resource_production", path, WireValue.class), path + ".resource_production", (v, p) -> new ProductionId(text(v, p))));
    }

        private static OutcomeContract outcome(WireValue value, String path) throws WireException {
        keys(value, path, "id", "form", "cause", "value_ports", "produced_resources");
        validateCauseShape(field(value, "cause", path, WireValue.class), path + ".cause");
        OutcomeId id = new OutcomeId(text(field(value, "id", path, WireValue.class), path + ".id"));
        WireValue form = field(value, "form", path, WireValue.class);
        OutcomeForm decoded = switch (tagAt(form, path + ".form")) {
            case "Success" -> { keys(form, path + ".form", "tag"); yield OutcomeForm.SUCCESS; }
            case "DeclaredFailure" -> { keys(form, path + ".form", "tag"); yield OutcomeForm.DECLARED_FAILURE; }
            default -> throw unknownTag(path + ".form.tag", tagAt(form, path + ".form"));
        };
        return new OutcomeContract(id, decoded,
                mapArray(field(value, "value_ports", path, WireValue.class), path + ".value_ports", SignatureCompositionWire::outputPort),
                mapArray(field(value, "produced_resources", path, WireValue.class), path + ".produced_resources", SignatureCompositionWire::production));
    }

        private static FunctionForm functionForm(WireValue value, String path) throws WireException {
        return switch (tagAt(value, path)) {
            case "Pure" -> { keys(value, path, "tag"); yield new Pure(); }
            case "DeclaredTransform" -> { keys(value, path, "tag"); yield new DeclaredTransform(); }
            case "Operation" -> {
                keys(value, path, "tag", "value");
                yield new Operation(new DefinitionRef(typeRef("").source(), text(payloadAt(value, path), path + ".value")));
            }
            default -> throw unknownTag(path + ".tag", tagAt(value, path));
        };
    }

        private static CompositionEffect effect(WireValue value, String path) throws WireException {
        String tag = tagAt(value, path);
        CompositionEffect effect = switch (tag) {
            case "PureFunction" -> CompositionEffect.PURE_FUNCTION;
            case "HttpRequestResponse" -> CompositionEffect.HTTP_REQUEST_RESPONSE;
            case "DataOnly" -> CompositionEffect.DATA_ONLY;
            default -> throw unknownTag(path + ".tag", tag);
        };
        keys(value, path, "tag");
        return effect;
    }

        private static GuardArm guardArm(WireValue value, String path) throws WireException {
        String tag = tagAt(value, path);
        if (tag.equals("Variant")) { keys(value, path, "tag", "value"); return new VariantArm(text(payloadAt(value, path), path + ".value")); }
        GuardArm arm = switch (tag) {
            case "Present" -> new PresentArm(); case "Absent" -> new AbsentArm(); case "Null" -> new NullArm();
            case "UnknownVariant" -> new UnknownVariantArm(); case "Accepted" -> new AcceptedArm(); case "Rejected" -> new RejectedArm();
            default -> throw unknownTag(path + ".tag", tag);
        };
        keys(value, path, "tag");
        return arm;
    }

        private static FailureOrigin failureOrigin(WireValue value, String path) throws WireException {
        return switch (tagAt(value, path)) {
            case "Function" -> {
                WireValue row = closedFields(value, path);
                keys(row, path + ".fields", "function", "outcome");
                yield new FunctionFailureOrigin(functionRef(field(row, "function", path, WireValue.class), path + ".fields.function"),
                        new OutcomeId(text(field(row, "outcome", path, WireValue.class), path + ".fields.outcome")));
            }
            case "Guard" -> {
                WireValue row = closedFields(value, path);
                keys(row, path + ".fields", "guard", "arm");
                yield new GuardFailureOrigin(new GuardId(text(field(row, "guard", path, WireValue.class), path + ".fields.guard")),
                        guardArm(field(row, "arm", path, WireValue.class), path + ".fields.arm"));
            }
            default -> throw unknownTag(path + ".tag", tagAt(value, path));
        };
    }

        private static InvocationDomain invocationDomain(WireValue value, String path) throws WireException {
        keys(value, path, "identity", "revision", "sites", "permitted_projections", "permitted_constructions", "permitted_transforms", "guards");
        return new InvocationDomain(text(field(value, "identity", path, WireValue.class), path + ".identity"),
                text(field(value, "revision", path, WireValue.class), path + ".revision"),
                mapArray(field(value, "sites", path, WireValue.class), path + ".sites", (row, p) -> {
                    keys(row, p, "id", "function"); return new InvocationSite(new SiteId(text(field(row, "id", p, WireValue.class), p + ".id")), functionRef(field(row, "function", p, WireValue.class), p + ".function")); }),
                mapArray(field(value, "permitted_projections", path, WireValue.class), path + ".permitted_projections", (row, p) -> {
                    keys(row, p, "source_type", "path"); return new PermittedProjection(typeRef(text(field(row, "source_type", p, WireValue.class), p + ".source_type")), path(field(row, "path", p, WireValue.class), p + ".path")); }),
                mapArray(field(value, "permitted_constructions", path, WireValue.class), path + ".permitted_constructions", SignatureCompositionWire::construction),
                mapArray(field(value, "permitted_transforms", path, WireValue.class), path + ".permitted_transforms", SignatureCompositionWire::functionRef),
                mapArray(field(value, "guards", path, WireValue.class), path + ".guards", SignatureCompositionWire::guard));
    }

        private static ConstructionRule construction(WireValue value, String path) throws WireException {
        keys(value, path, "identity", "type_id", "nested_fields", "field_constraints");
        return new ConstructionRule(text(field(value, "identity", path, WireValue.class), path + ".identity"),
                typeRef(text(field(value, "type_id", path, WireValue.class), path + ".type_id")),
                mapArray(field(value, "nested_fields", path, WireValue.class), path + ".nested_fields", (pair, p) -> {
                    List<WireValue> values = array(pair, p); if (values.size() != 2) throw syntax(p, "pair size");
                    return new NamedConstruction(text(values.get(0), p + "[0]"), text(values.get(1), p + "[1]")); }),
                mapArray(field(value, "field_constraints", path, WireValue.class), path + ".field_constraints", (row, p) -> {
                    keys(row, p, "field", "source", "presence");
                    String field = text(field(row, "field", p, WireValue.class), p + ".field");
                    SourceConstraint source = sourceConstraint(field(row, "source", p, WireValue.class), p + ".source");
                    WireValue presence = field(row, "presence", p, WireValue.class);
                    FieldPresence decoded = switch (tagAt(presence, p + ".presence")) {
                        case "Required" -> FieldPresence.REQUIRED;
                        case "Optional" -> FieldPresence.OPTIONAL;
                        default -> throw unknownTag(p + ".presence.tag", tagAt(presence, p + ".presence"));
                    };
                    keys(presence, p + ".presence", "tag");
                    return new FieldConstraint(field, source, decoded); }));
    }

        private static DeclaredGuard guard(WireValue value, String path) throws WireException {
        keys(value, path, "id", "source_type", "path", "kind");
        GuardId id = new GuardId(text(field(value, "id", path, WireValue.class), path + ".id"));
        TypeRef sourceType = typeRef(text(field(value, "source_type", path, WireValue.class), path + ".source_type"));
        List<PathStep> steps = path(field(value, "path", path, WireValue.class), path + ".path");
        WireValue kind = field(value, "kind", path, WireValue.class);
        GuardKind decoded = switch (tagAt(kind, path + ".kind")) {
            case "Presence" -> { keys(kind, path + ".kind", "tag"); yield new PresenceGuard(); }
            case "Variants" -> { keys(kind, path + ".kind", "tag"); yield new VariantsGuard(); }
            case "Validate" -> { keys(kind, path + ".kind", "tag", "value"); yield new ValidateGuard(contract(payloadAt(kind, path + ".kind"), path + ".kind.value")); }
            default -> throw unknownTag(path + ".kind.tag", tagAt(kind, path + ".kind"));
        };
        return new DeclaredGuard(id, sourceType, steps, decoded);
    }

        private static GoalSpec goal(WireValue value, String path) throws WireException {
        keys(value, path, "outputs", "failures", "final_resources");
        return new GoalSpec(mapArray(field(value, "outputs", path, WireValue.class), path + ".outputs", (row, p) -> {
            keys(row, p, "id", "contract", "source_constraint"); return new GoalPort(new GoalPortId(text(field(row, "id", p, WireValue.class), p + ".id")),
                    contract(field(row, "contract", p, WireValue.class), p + ".contract"), sourceConstraint(field(row, "source_constraint", p, WireValue.class), p + ".source_constraint")); }),
                mapArray(field(value, "failures", path, WireValue.class), path + ".failures", (row, p) -> {
                    keys(row, p, "id", "origin", "contract", "final_resources"); return new FailureEmbedding(new FailureEmbeddingId(text(field(row, "id", p, WireValue.class), p + ".id")),
                            failureOrigin(field(row, "origin", p, WireValue.class), p + ".origin"), contract(field(row, "contract", p, WireValue.class), p + ".contract"),
                            mapArray(field(row, "final_resources", p, WireValue.class), p + ".final_resources", SignatureCompositionWire::resourceGoal)); }),
                mapArray(field(value, "final_resources", path, WireValue.class), path + ".final_resources", SignatureCompositionWire::resourceGoal));
    }

        private static ResourceGoal resourceGoal(WireValue value, String path) throws WireException {
        keys(value, path, "lot", "multiplicity", "revision"); return new ResourceGoal(lotRef(field(value, "lot", path, WireValue.class), path + ".lot"),
                natural(field(value, "multiplicity", path, WireValue.class), path + ".multiplicity"), natural(field(value, "revision", path, WireValue.class), path + ".revision"));
    }

        private static SelectionPolicy selectionPolicy(WireValue value, String path) throws WireException {
        SelectionPolicy policy = switch (tagAt(value, path)) {
            case "RequireUnique" -> SelectionPolicy.REQUIRE_UNIQUE;
            case "AnyFeasible" -> SelectionPolicy.ANY_FEASIBLE;
            default -> throw unknownTag(path + ".tag", tagAt(value, path));
        };
        keys(value, path, "tag");
        return policy;
    }

        private static SearchBounds bounds(WireValue value, String path) throws WireException {
        keys(value, path, "max_expanded_states", "max_binding_candidates", "max_type_obligations", "max_branch_nodes", "resource_bounds", "max_sample_length");
        BigInteger expandedStates = natural(field(value, "max_expanded_states", path, WireValue.class), path + ".max_expanded_states");
        BigInteger bindingCandidates = natural(field(value, "max_binding_candidates", path, WireValue.class), path + ".max_binding_candidates");
        BigInteger typeObligations = natural(field(value, "max_type_obligations", path, WireValue.class), path + ".max_type_obligations");
        BigInteger branchNodes = natural(field(value, "max_branch_nodes", path, WireValue.class), path + ".max_branch_nodes");
        Optional<ResourceBounds> resourceBounds = optional(field(value, "resource_bounds", path, WireValue.class), path + ".resource_bounds", (row, p) -> {
            keys(row, p, "max_bindings", "max_search_steps", "max_tokens"); return new ResourceBounds(natural(field(row, "max_bindings", p, WireValue.class), p + ".max_bindings"),
                    natural(field(row, "max_search_steps", p, WireValue.class), p + ".max_search_steps"), natural(field(row, "max_tokens", p, WireValue.class), p + ".max_tokens")); });
        return new SearchBounds(expandedStates, bindingCandidates, typeObligations, branchNodes,
                natural(field(value, "max_sample_length", path, WireValue.class), path + ".max_sample_length"), resourceBounds);
    }

        private static SiteOrder siteOrder(WireValue value, String path) throws WireException {
        List<WireValue> values = array(value, path); if (values.size() != 2) throw syntax(path, "pair size");
        return new SiteOrder(new SiteId(text(values.get(0), path + "[0]")), new SiteId(text(values.get(1), path + "[1]")));
    }

        private static Slot<JsonValue> slot(WireValue value, String path) throws WireException {
        return switch (tagAt(value, path)) {
            case "Absent" -> { keys(value, path, "tag"); yield new necoherence.semantic.SemanticValues.Absent<>(); }
            case "Null" -> { keys(value, path, "tag"); yield new NullSlot<>(); }
            case "Present" -> { keys(value, path, "tag", "value"); yield new Present<>(WireJson.fromWire(exact(payloadAt(value, path), path + ".value"))); }
            default -> throw unknownTag(path + ".tag", tagAt(value, path));
        };
    }

        private static void validateCauseShape(WireValue value, String path) throws WireException {
        String kind = tagAt(value, path); if (!Set.of("ValueContract", "ExternalCondition").contains(kind)) throw unknownTag(path + ".tag", kind);
        WireValue row = closedFields(value, path);
        String member = kind.equals("ValueContract") ? "origin" : "specification";
        keys(row, path + ".fields", member);
        String originPath = path + ".fields." + member;
        WireValue origin = field(row, member, path + ".fields", WireValue.class);
        keys(origin, originPath, "source", "locator");
        WireValue source = field(origin, "source", originPath, WireValue.class);
        String sourcePath = originPath + ".source";
        keys(source, sourcePath, "repository", "revision", "path", "content_digest");
        for (String key : List.of("repository", "revision", "path", "content_digest"))
            text(field(source, key, sourcePath, WireValue.class), sourcePath + "." + key);
        for (WireValue locator : array(field(origin, "locator", originPath, WireValue.class), originPath + ".locator"))
            text(locator, originPath + ".locator");
    }

        private static WireValue contractWire(SlotContract contract) { return obj("type_id", str(contract.typeRef().definitionName()), "required", new BooleanValue(contract.required()), "nullable", new BooleanValue(contract.nullable())); }

        private static WireValue productionWire(ResourceProduction production) { return obj("id", str(production.id().value()), "token_type", str(production.tokenType().definitionName()), "revision", str(production.revision().toString()), "quantity", str(production.quantity().toString()), "provenance", str(production.provenance())); }

        private static WireValue internalGraph(WireValue library) {
        List<WireValue> nodes = new ArrayList<>();
        for (WireValue node : a(f(library, "nodes"))) nodes.add(obj("reference", TypeSignatures.typeReference(s(f(node, "id"))), "shape", TypeSignatures.internalShape(f(node, "shape")), "description", NIL, "attributes", arr(List.of()), "extensions", arr(List.of())));
        return obj("profile", f(library, "profile"), "nodes", arr(nodes), "source_refs", arr(List.of()));
    }

        static WireValue exact(WireValue value, String path) throws WireException {
        String kind = tagAt(value, path);
        return switch (kind) {
            case "Null" -> { keys(value, path, "tag"); yield NIL; }
            case "Bool" -> { keys(value, path, "tag", "value"); yield new BooleanValue(bool(payloadAt(value, path), path + ".value")); }
            case "Integer" -> { keys(value, path, "tag", "value"); yield num(integerText(payloadAt(value, path), path + ".value")); }
            case "Decimal" -> {
                keys(value, path, "tag", "text");
                String spelling = text(field(value, "text", path, WireValue.class), path + ".text");
                if (!spelling.equals(spelling.trim())) throw syntax(path + ".text", "decimal whitespace");
                if (!isExactDecimal(spelling)) throw syntax(path + ".text", "invalid exact decimal");
                yield new necoherence.semantic.SemanticValues.DecimalValue(spelling);
            }
            case "String" -> { keys(value, path, "tag", "value"); yield str(text(payloadAt(value, path), path + ".value")); }
            case "Array" -> { keys(value, path, "tag", "items"); yield arr(mapArray(field(value, "items", path, WireValue.class), path + ".items", SignatureCompositionWire::exact)); }
            case "Object" -> {
                keys(value, path, "tag", "members"); List<Member> members = new ArrayList<>();
                List<WireValue> rows = array(field(value, "members", path, WireValue.class), path + ".members");
                for (int index = 0; index < rows.size(); index++) {
                    String rowPath = path + ".members[" + index + "]"; WireValue row = rows.get(index); keys(row, rowPath, "key", "value");
                    members.add(new Member(text(field(row, "key", rowPath, WireValue.class), rowPath + ".key"), exact(field(row, "value", rowPath, WireValue.class), rowPath + ".value")));
                }
                yield new ObjectValue(members);
            }
            default -> throw unknownTag(path + ".tag", kind);
        };
    }

        @FunctionalInterface private interface Decoder<T> { T decode(WireValue value, String path) throws WireException; }

        private static <T> List<T> mapArray(WireValue value, String path, Decoder<T> decoder) throws WireException {
        List<WireValue> values = array(value, path); List<T> result = new ArrayList<>();
        for (int i = 0; i < values.size(); i++) result.add(decoder.decode(values.get(i), path + "[" + i + "]")); return List.copyOf(result);
    }

        private static <T> Optional<T> optional(WireValue value, String path, Decoder<T> decoder) throws WireException { return nil(value) ? Optional.empty() : Optional.of(decoder.decode(value, path)); }

        private static List<WireValue> array(WireValue value, String path) throws WireException { if (!(value instanceof ArrayValue array)) throw syntax(path, "array expected"); return array.items(); }

        private static String text(WireValue value, String path) throws WireException { if (!(value instanceof StringValue text)) throw syntax(path, "string expected"); return text.value(); }

        private static boolean bool(WireValue value, String path) throws WireException { if (!(value instanceof BooleanValue bool)) throw syntax(path, "boolean expected"); return bool.value(); }

        private static BigInteger natural(WireValue value, String path) throws WireException {
        BigInteger number = integerText(value, path); if (number.signum() < 0) throw syntax(path, "natural expected"); return number;
    }

        private static final java.util.regex.Pattern INTEGER_TEXT = java.util.regex.Pattern.compile("0|-?[1-9][0-9]*");
        private static BigInteger integerText(WireValue value, String path) throws WireException {
        String text = text(value, path); if (!INTEGER_TEXT.matcher(text).matches()) throw syntax(path, "integer expected");
        try { return new BigInteger(text); } catch (NumberFormatException failure) { throw syntax(path, "integer expected"); }
    }

        private static String tagAt(WireValue value, String path) throws WireException { WireValue tag = field(value, "tag", path, WireValue.class); return text(tag, path + ".tag"); }

        private static WireValue payloadAt(WireValue value, String path) throws WireException { return field(value, "value", path, WireValue.class); }

        private static ObjectValue object(WireValue value) { return (ObjectValue) value; }

        private static String textUnchecked(WireValue value) { return ((StringValue) value).value(); }

        private static String tagUnchecked(WireValue value) { return textUnchecked(f(value, "tag")); }

        private static boolean sameWire(WireValue left, WireValue right) {
        if (left instanceof ObjectValue leftObject && right instanceof ObjectValue rightObject) {
            if (leftObject.members().size() != rightObject.members().size()) return false;
            for (Member member : leftObject.members()) {
                WireValue value = rightObject.get(member.key());
                if (value == null || !sameWire(member.value(), value)) return false;
            }
            return true;
        }
        if (left instanceof ArrayValue leftArray && right instanceof ArrayValue rightArray) {
            if (leftArray.items().size() != rightArray.items().size()) return false;
            for (int index = 0; index < leftArray.items().size(); index++)
                if (!sameWire(leftArray.items().get(index), rightArray.items().get(index))) return false;
            return true;
        }
        return left.equals(right);
    }

        @SuppressWarnings("unchecked") private static <T> T field(WireValue value, String key, String path, Class<T> type) throws WireException {
        if (!(value instanceof ObjectValue object)) throw syntax(path, "object expected"); WireValue found = object.get(key);
        if (found == null) throw syntax(path + "." + key, "missing field"); return (T) found;
    }

        private static WireException syntax(String path, String condition) { return new WireException(new Syntax(path, condition == null ? "syntax" : condition)); }

        private static WireException unknownTag(String path, String tag) { return new WireException(new UnknownTag(path, tag)); }
}
