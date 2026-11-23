// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

package necoherence.composition;

import static necoherence.composition.SemanticComposition.*;
import static necoherence.composition.SignatureCompositionWire.*;
import static necoherence.composition.SemanticExecution.*;
import static necoherence.semantic.SemanticLibraryFixture.library;
import static necoherence.semantic.SemanticLibraryFixture.slot;
import static necoherence.semantic.SemanticValues.*;
import static org.junit.jupiter.api.Assertions.*;

import java.math.BigInteger;
import java.io.ByteArrayInputStream;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.Base64;
import java.util.List;
import java.util.Optional;
import java.util.zip.GZIPInputStream;
import necoherence.core.Nat;
import necoherence.network.NetworkEffect;
import necoherence.progression.ExecutionHandle;
import necoherence.progression.RequestIdentity;
import necoherence.semantic.SemanticGeneration;
import necoherence.semantic.ExactJson.JsonValue;
import necoherence.semantic.SemanticValues.WireValue;
import necoherence.semantic.WireJson;
import necoherence.semantic.TypeSignatures;
import org.junit.jupiter.api.Test;

final class SemanticExecutionTest {
    private static final String DIGEST = "0".repeat(64);
    private static final String HTTP_EXCHANGE_GZIP_BASE64 = """
            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
            """;

    @Test void variantGuardUsesSelectedBranchAndPreservesAbsentAndNull() throws Exception {
        String exchange = Files.readString(Path.of("src/test/resources/variant-guard-incomplete-coverage.json"));
        WireValue wire = SemanticGeneration.readJson(exchange);
        WireValue signatures = f(wire, "signatures");
        var problem = SignatureCompositionWire.decodeProblem(signatures, f(f(wire, "composition"), "problem"));
        var preparation = SignatureCompositionWire.prepare(signatures, s(f(f(wire, "basis"), "graph_sha256")), problem);
        PreparedCompositionInput prepared = assertInstanceOf(Prepared.class, preparation).value();
        DeclaredGuard guard = prepared.input().invocationDomain().guards().getFirst();

        assertEquals(new ProviderSuccess<>(new AbsentArm()), inspectGuard(prepared, guard, new Absent<>()));
        assertEquals(new ProviderSuccess<>(new NullArm()), inspectGuard(prepared, guard, new NullSlot<>()));
        assertEquals(new ProviderSuccess<>(new VariantArm("otherwise")), inspectGuard(prepared, guard,
                wirePresent(obj("kind", str("other")))));
        assertEquals(new ProviderRejected<>(new InvalidPlan("union guard discriminator")),
                inspectGuard(prepared, guard, wirePresent(obj())));
    }

    @Test void checkedPureCompositionCompletesSynchronously() throws Exception {
        Fixture fixture = fixture(false, List.of(), List.of());

        RunResult result = SemanticExecution.start(fixture.checked(), List.of(), List.of(), emptyNetwork());

        Completed completed = assertInstanceOf(Completed.class,
                assertInstanceOf(Progressed.class, result, result.toString()).progress());
        Success success = assertInstanceOf(Success.class, completed.result());
        assertEquals(List.of(new GoalValue(new GoalPortId("result"), wirePresent(num(BigInteger.ONE)))),
                success.outputs());
        assertEquals(emptyNetwork(), completed.network());
    }

    @Test void httpProviderReturnsSendObserveAndCompleted() throws Exception {
        AdmittedComposition checked = httpChecked();
        FunctionRef function = checked.prepared().input().signatures().getFirst().reference();
        OutcomeId outcome = new OutcomeId("success");
        PreparedNetworkOwner owner = new PreparedNetworkOwner(arguments -> new ProviderSuccess<>(new Ready(attemptInput())),
                response -> new ProviderSuccess<>(new CallResult(outcome, List.of(
                        new PortValue(new PortId("output"), wirePresent(new BooleanValue(true)))))));
        RunResult run = SemanticExecution.start(checked,
                List.of(new Provider(function, new PreparedHttpProvider(owner))), booleanArguments(), emptyNetwork());
        Pending sent = assertInstanceOf(Pending.class,
                assertInstanceOf(Progressed.class, run).progress());
        Send send = assertInstanceOf(Send.class, sent.instruction());
        ExecutionHandle handle = new ExecutionHandle("handle");
        Pending observing = assertInstanceOf(Pending.class, assertInstanceOf(Progressed.class,
                SemanticExecution.resume(sent.execution(), new Start(
                        new NetworkEffect.StartObservation.Started(attemptInput().attempt(), handle)))).progress());
        assertEquals(new Observe(new NetworkEffect.StartedAttempt(send.command().prepared(), handle)),
                observing.instruction());
        RunResult resumed = SemanticExecution.resume(observing.execution(),
                new Host(new NetworkEffect.HostObservation.Delivered(Nat.zero(), response(handle))));
        Completed completed = assertInstanceOf(Completed.class,
                assertInstanceOf(Progressed.class, resumed).progress());
        assertInstanceOf(Success.class, completed.result());
        assertEquals(0, Execution.class.getConstructors().length);
    }

    @Test void preparedHttpCompletionProducesNoNetworkInstruction() throws Exception {
        AdmittedComposition checked = httpChecked();
        FunctionRef function = checked.prepared().input().signatures().getFirst().reference();
        PreparedNetworkOwner owner = new PreparedNetworkOwner(arguments -> new ProviderSuccess<>(
                new CompletedCall(new CallResult(new OutcomeId("success"), List.of(
                        new PortValue(new PortId("output"), wirePresent(new BooleanValue(true))))))),
                response -> new ProviderRejected<>(new InvalidPlan("unused")));
        Completed completed = assertInstanceOf(Completed.class,
                assertInstanceOf(Progressed.class, SemanticExecution.start(
                        checked, List.of(new Provider(function, new PreparedHttpProvider(owner))),
                        booleanArguments(), emptyNetwork())).progress());
        assertInstanceOf(Success.class, completed.result());
        assertEquals(emptyNetwork(), completed.network());
    }

    @Test void startUsesThePlanOwnedByTheCheckedComposition() throws Exception {
        Fixture fixture = fixture(false, List.of(), List.of());
        Completed completed = assertInstanceOf(Completed.class,
                assertInstanceOf(Progressed.class, SemanticExecution.start(
                        fixture.checked(), List.of(), List.of(), emptyNetwork())).progress());
        assertInstanceOf(Success.class, completed.result());
    }

    @Test void startReportsProviderCoverageEffectAndMissingArgumentFromVerifiedInputs() throws Exception {
        WireValue pureSignature = signatureWire("provider", "PureFunction");
        Fixture pure = fixture(false, List.of(pureSignature), List.of());

        RunRejected missing = assertInstanceOf(RunRejected.class,
                SemanticExecution.start(pure.checked(), List.of(), List.of(), emptyNetwork()));
        assertEquals(new ProviderCoverage("exact provider coverage required"), missing.failure().cause());
        FunctionRef reference = new FunctionRef("provider", "1", DIGEST);
        Provider different = new Provider(new FunctionRef("different", "1", DIGEST),
                new PureProvider(arguments -> new ProviderRejected<>(new InvalidPlan("unused"))));
        RunRejected missingReference = assertInstanceOf(RunRejected.class,
                SemanticExecution.start(pure.checked(), List.of(different), List.of(), emptyNetwork()));
        assertEquals(new MissingProvider(reference), missingReference.failure().cause());
        Provider wrong = new Provider(reference, new PreparedHttpProvider(new PreparedNetworkOwner(
                arguments -> new ProviderRejected<>(new InvalidPlan("unused")),
                response -> new ProviderRejected<>(new InvalidPlan("unused")))));
        RunRejected effect = assertInstanceOf(RunRejected.class,
                SemanticExecution.start(pure.checked(), List.of(wrong), List.of(), emptyNetwork()));
        assertEquals(new ProviderEffect(reference), effect.failure().cause());
        InitialInput initial = pure.prepared().input().initialInputs().getFirst();
        PreparedCompositionInput argumentPrepared = assertInstanceOf(Prepared.class,
                prepare(library(), graphDigest(), decodeProblem(library(), problem(true, List.of(pureSignature), List.of())))).value();
        assertEquals(new ProviderRejected<RuntimeState>(new MissingArgument(initial.id())),
                SemanticExecution.initialState(argumentPrepared, List.of()));
    }

    @Test void valueAndArgumentFailuresUseLeanConstructors() throws Exception {
        Fixture fixture = fixture(false, List.of(), List.of());
        PreparedCompositionInput prepared = fixture.prepared();
        SlotContract contract = prepared.input().goal().outputs().getFirst().contract();
        Value rejected = assertInstanceOf(Value.class, SemanticExecution.validate(prepared, contract,
                wirePresent(str("wrong"))).orElseThrow());
        assertInstanceOf(necoherence.semantic.SemanticValidation.ValueRejected.class, rejected.failure());
        TypeRef missing = new TypeRef(contract.typeRef().source(), "missing", List.of());
        SlotContract unresolved = new SlotContract(missing, true, false);
        Value unresolvedFailure = assertInstanceOf(Value.class, SemanticExecution.validate(prepared, unresolved,
                wirePresent(str("value"))).orElseThrow());
        assertInstanceOf(necoherence.semantic.SemanticValidation.ValidationUnresolved.class, unresolvedFailure.failure());
        DeclaredGuard guard = new DeclaredGuard(new GuardId("guard"), contract.typeRef(), List.of(),
                new ValidateGuard(unresolved));
        ProviderRejected<?> guardFailure = assertInstanceOf(ProviderRejected.class,
                SemanticExecution.inspectGuard(prepared, guard, wirePresent(str("value"))));
        Value guardValue = assertInstanceOf(Value.class, guardFailure.failure());
        assertInstanceOf(necoherence.semantic.SemanticValidation.ValidationUnresolved.class, guardValue.failure());
        ProviderResult<RuntimeState> duplicate = SemanticExecution.initialState(prepared,
                List.of(new ArgumentValue(new InputId("argument"), wirePresent(num(BigInteger.ONE)))));
        assertEquals(new ProviderRejected<RuntimeState>(new ArgumentCoverage(
                "unique declared argument identifiers required")), duplicate);
    }

    @Test void resumeRejectsMismatchedObservationAndExecutionCannotBeForged() throws Exception {
        AdmittedComposition checked = httpChecked();
        FunctionRef function = checked.prepared().input().signatures().getFirst().reference();
        PreparedNetworkOwner owner = new PreparedNetworkOwner(arguments -> new ProviderSuccess<>(new Ready(attemptInput())),
                response -> new ProviderRejected<>(new InvalidPlan("unused")));
        Pending pending = assertInstanceOf(Pending.class, assertInstanceOf(Progressed.class,
                SemanticExecution.start(checked, List.of(new Provider(function, new PreparedHttpProvider(owner))),
                        booleanArguments(), emptyNetwork())).progress());
        RunRejected mismatch = assertInstanceOf(RunRejected.class, SemanticExecution.resume(pending.execution(),
                new Host(new NetworkEffect.HostObservation.Delivered(Nat.zero(),
                        response(new ExecutionHandle("handle"))))));
        assertEquals(new InvalidPlan("network observation kind mismatch"), mismatch.failure().cause());
        assertEquals(0, Execution.class.getConstructors().length);
    }

    @Test void startOwnsThePendingExecutionPassedToResume() throws Exception {
        AdmittedComposition checked = httpChecked();
        FunctionRef function = checked.prepared().input().signatures().getFirst().reference();
        PreparedNetworkOwner owner = new PreparedNetworkOwner(arguments -> new ProviderSuccess<>(new Ready(attemptInput())),
                response -> new ProviderRejected<>(new InvalidPlan("unused")));
        Pending sent = assertInstanceOf(Pending.class, assertInstanceOf(Progressed.class,
                SemanticExecution.start(checked, List.of(new Provider(function, new PreparedHttpProvider(owner))),
                        booleanArguments(), emptyNetwork())).progress());
        Pending observing = assertInstanceOf(Pending.class, assertInstanceOf(Progressed.class,
                SemanticExecution.resume(sent.execution(), new Start(
                        new NetworkEffect.StartObservation.Started(attemptInput().attempt(),
                                new ExecutionHandle("handle"))))).progress());
        assertInstanceOf(Observe.class, observing.instruction());
    }

    @Test void projectionUsesLeanFailureConditions() {
        ProviderResult<Slot<JsonValue>> outside = SemanticExecution.project("kind",
                wirePresent(arr(List.of())), List.of(new Index(BigInteger.ZERO)));
        assertEquals(new ProviderRejected<Slot<JsonValue>>(
                new InvalidPlan("array projection outside value")), outside);
    }

    private record Fixture(WireValue problem, PreparedCompositionInput prepared,
            AdmittedComposition checked) {}

    private static AdmittedComposition httpChecked() throws Exception {
        byte[] compressed = Base64.getMimeDecoder().decode(HTTP_EXCHANGE_GZIP_BASE64);
        String exchange;
        try (var input = new GZIPInputStream(new ByteArrayInputStream(compressed))) {
            exchange = new String(input.readAllBytes(), StandardCharsets.UTF_8);
        }
        WireValue wire = SemanticGeneration.readJson(exchange);
        return TypeSignatures.admitGeneration(
                SemanticGeneration.GenerationBasis.ofInput(wire), exchange).composition();
    }

    private static List<ArgumentValue> booleanArguments() {
        return List.of(new ArgumentValue(new InputId("argument"), wirePresent(new BooleanValue(true))));
    }

    private static Fixture fixture(boolean argument, List<WireValue> signatures,
            List<WireValue> sites) throws Exception {
        WireValue problem = problem(argument, signatures, sites);
        ProblemWire decoded = decodeProblem(library(), problem);
        PreparationResult preparation = prepare(library(), graphDigest(), decoded);
        PreparedCompositionInput prepared = assertInstanceOf(Prepared.class,
                preparation, preparation.toString()).value();
        WireValue producer = variant("Initial", str("argument"));
        WireValue supplied = variant("Present", SemanticGeneration.toExact(num(BigInteger.ONE)));
        WireValue projection = obj("profile", f(f(library(), "profile"), "reference"),
                "source_refs", f(f(library(), "profile"), "source_refs"), "source", slot("number"),
                "path", arr(List.of()), "assumptions", arr(List.of()), "destination", slot("number"));
        WireValue binding = fields("Source", obj("value", obj("producer", producer, "path", arr(List.of())),
                "projection", projection, "compatibility", fields("SuppliedValue", obj("value", supplied))));
        WireValue terminal = variant("Success", arr(List.of(arr(List.of(str("result"), binding)))));
        WireValue trace = obj("steps", arr(List.of()), "terminal", terminal);
        String valuePlace = tuple("initial-value", "argument"), control = tuple("control", "0");
        String tokenType = typeIdentity(TypeSignatures.typeReference("number"));
        WireValue valueToken = token(valuePlace), controlToken = token("control-root");
        WireValue marking = obj("places", arr(List.of(arr(List.of(str(valuePlace), arr(List.of(valueToken)))),
                arr(List.of(str(control), arr(List.of(controlToken)))))));
        WireValue places = arr(List.of(obj("identity", str(valuePlace), "token_type", str(tokenType), "revision", str("0")),
                obj("identity", str(control), "token_type", str("control"), "revision", str("0"))));
        WireValue goal = variant("And", arr(List.of(
                fields("PlaceHasToken", obj("place", str(control), "target", str("control-root"), "index", str("0"), "revision", str("0"))),
                fields("PlaceHasToken", obj("place", str(valuePlace), "target", str(valuePlace), "index", str("0"), "revision", str("0"))))));
        WireValue lowering = obj("places", places, "transitions", arr(List.of()), "bindings", arr(List.of()),
                "goal", goal, "graph", obj("places", arr(List.of(str(valuePlace), str(control))),
                        "transitions", arr(List.of()), "edges", arr(List.of()), "revision", str("0")),
                "marking", marking, "bound", obj("target_identity", str("composition"), "index", str("0"),
                        "revision", str("0"), "max_bindings", str("0"), "max_search_steps", str("1")));
        WireValue correspondence = obj("lots", arr(List.of()), "values", arr(List.of(obj("producer", producer,
                        "place", str(valuePlace), "token_target", str(valuePlace), "revision", str("0")))),
                "normalized_bindings", arr(List.of()), "execution_order", arr(List.of()));
        WireValue certificate = obj("trace", trace, "lowering", lowering, "correspondence", correspondence,
                "reachability", obj("path", arr(List.of()), "final_marking", marking),
                "acyclicity", obj("explored_markings", arr(List.of(marking)), "steps", str("1"), "frontier", arr(List.of())),
                "value_sources", arr(List.of(arr(List.of(producer, supplied)))));
        WireValue root = obj("rank", str("0"), "node", variant("Return", terminal));
        WireValue witness = obj("input_snapshot", problem, "initial_membership",
                arr(List.of(arr(List.of(str("argument"), supplied)))), "resource_traces", arr(List.of(certificate)));
        WireValue derivation = obj("plan", obj("input_identity", str("composition"), "input_revision", str("1"), "root", root),
                "witness", witness, "selection", variant("AnyFeasible"));
        return new Fixture(problem, prepared, necoherence.semantic.AdmissionTestAccess.admit(library(), problem, prepared, derivation));
    }

    private static WireValue problem(boolean argument, List<WireValue> signatures, List<WireValue> sites) {
        WireValue basis = TypeSignatures.computeBasis(library(), arr(List.of()), NIL);
        WireValue source = argument ? variant("Argument")
                : variant("SuppliedValue", variant("Present", SemanticGeneration.toExact(num(BigInteger.ONE))));
        WireValue initial = obj("id", str("argument"), "contract", slot("number"),
                "source", source, "resource", NIL);
        WireValue constraint = fields("InitialOnly", obj("input", str("argument"), "path", arr(List.of())));
        WireValue goal = obj("outputs", arr(List.of(obj("id", str("result"), "contract", slot("number"),
                        "source_constraint", constraint))), "failures", arr(List.of()), "final_resources", arr(List.of()));
        WireValue domain = obj("identity", str("domain"), "revision", str("1"), "sites", arr(sites),
                "permitted_projections", arr(List.of()), "permitted_constructions", arr(List.of()),
                "permitted_transforms", arr(List.of()), "guards", arr(List.of()));
        WireValue bounds = obj("max_expanded_states", str("10000"), "max_binding_candidates", str("100000"),
                "max_type_obligations", str("10000"), "max_branch_nodes", str("100000"),
                "resource_bounds", NIL, "max_sample_length", str("32"));
        return obj("identity", str("composition"), "revision", str("1"), "basis", basis,
                "signatures", arr(signatures), "initial_inputs", arr(List.of(initial)),
                "initial_resources", arr(List.of()), "goal", goal, "invocation_domain", domain,
                "allowed_effects", arr(signatures.stream().map(row -> f(row, "effect")).toList()),
                "explicit_order", arr(List.of()),
                "selection_policy", variant("AnyFeasible"), "bounds", bounds);
    }

    private static WireValue signatureWire(String identity, String effect) {
        WireValue reference = obj("identity", str(identity), "revision", str("1"), "content_digest", str(DIGEST));
        WireValue source = a(f(library(), "sources")).getFirst();
        WireValue outcome = obj("id", str("unused"), "form", variant("Success"),
                "cause", fields("ValueContract", obj("origin", obj("source", source,
                        "locator", arr(List.of(str("rules")))))),
                "value_ports", arr(List.of()), "produced_resources", arr(List.of()));
        return obj("reference", reference, "form", effect.equals("PureFunction") ? variant("Pure") : variant("Operation", str("http")),
                "effect", variant(effect), "inputs", arr(List.of()), "outcomes", arr(List.of(outcome)),
                "resource_inputs", arr(List.of()), "assumption_ref", str("provider"), "handles_failure", NIL);
    }

    private static NetworkEffect.AttemptInput attemptInput() {
        NetworkEffect.AttemptIdentity identity = new NetworkEffect.AttemptIdentity(
                new RequestIdentity("semantic", "http", Nat.one()), Nat.zero());
        return new NetworkEffect.AttemptInput(identity,
                new NetworkEffect.HttpWireInstruction("GET", "http://127.0.0.1/test", List.of(), necoherence.network.ByteString.empty()),
                Optional.empty(), new NetworkEffect.HostConfiguration(Nat.fromLong(8), Nat.fromLong(8),
                        Optional.empty(), Optional.empty()));
    }

    private static NetworkEffect.AdapterObservation response(ExecutionHandle handle) {
        return new NetworkEffect.AdapterObservation.ResponseObservation(attemptInput().attempt(), handle,
                new NetworkEffect.SourceSequence.None(), new NetworkEffect.RawHttpResponse(200, List.of(), necoherence.network.ByteString.empty()),
                NetworkEffect.HeaderProvenance.LibraryNormalized,
                new NetworkEffect.EffectStatus.Unknown(NetworkEffect.UnknownEffectReason.NoResponse));
    }

    private static NetworkEffect.NetworkState emptyNetwork() {
        return NetworkEffect.NetworkState.empty();
    }

    private static WireValue token(String target) {
        return obj("target", str(target), "index", str("0"), "revision", str("0"), "kind", variant("Input"));
    }

    private static String tuple(String... values) {
        StringBuilder result = new StringBuilder();
        for (String value : values) result.append(value.getBytes(StandardCharsets.UTF_8).length).append(':').append(value);
        return result.toString();
    }

    private static String typeIdentity(WireValue reference) {
        WireValue source = f(reference, "source"), declared = f(source, "declared_revision");
        List<String> path = new ArrayList<>();
        for (WireValue entry : a(f(reference, "pointer"))) path.add(s(entry));
        return tuple("type", s(f(source, "repository")), s(f(source, "revision")), s(f(source, "path")),
                s(f(source, "content_digest")), s(f(source, "document_id")), nil(declared) ? "none" : "some",
                nil(declared) ? "" : s(declared), s(f(reference, "definition_name")),
                tuple(path.toArray(String[]::new)));
    }

    private static String graphDigest() {
        return s(f(TypeSignatures.computeBasis(library(), arr(List.of()), NIL), "graph_sha256"));
    }
    private static Present<JsonValue> wirePresent(WireValue value) { return new Present<>(WireJson.fromWire(value)); }
}
