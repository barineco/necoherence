// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

package necoherence.comparison;

import static necoherence.composition.SemanticExecution.*;
import static necoherence.semantic.SemanticValues.*;

import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.List;
import necoherence.composition.SemanticExecution.AdmittedComposition;
import necoherence.composition.SemanticComposition.*;
import necoherence.composition.SemanticExecution;
import necoherence.core.Nat;
import necoherence.network.NetworkEffect;
import necoherence.progression.ExecutionHandle;
import necoherence.progression.RequestIdentity;
import necoherence.semantic.ExactJson.JsonValue;
import necoherence.semantic.SemanticGeneration;
import necoherence.semantic.SemanticGeneration.CheckedGeneration;
import necoherence.semantic.SemanticGeneration.GenerationBasis;
import necoherence.semantic.SemanticValues;
import necoherence.semantic.WireJson;
import necoherence.semantic.SemanticValues.Slot;
import necoherence.semantic.SemanticValues.WireValue;
import necoherence.semantic.TypeSignatures;

public final class ExecutionCheck {
    private ExecutionCheck() {}

    /** Reads a comparison input natural as a JSON integer, as the Lean runner reads it with getNat?. */
    private static java.math.BigInteger jsonNat(WireValue value) {
        if (value instanceof IntegerValue number && number.value().signum() >= 0) return number.value();
        throw new IllegalArgumentException("natural integer required");
    }

    private static Slot<JsonValue> slot(WireValue value) {
        return switch (s(f(value, "tag"))) {
            case "absent" -> new Absent<>();
            case "null" -> new NullSlot<>();
            case "present" -> new Present<>(WireJson.fromWire(f(value, "value")));
            default -> throw new IllegalArgumentException("unknown slot");
        };
    }

    private static WireValue slotJson(Slot<JsonValue> value) {
        if (value instanceof Absent<JsonValue>) return obj("tag", str("absent"));
        if (value instanceof NullSlot<JsonValue>) return obj("tag", str("null"));
        WireValue present = WireJson.toWire(((Present<JsonValue>) value).value());
        return obj("tag", str("present"), "value", present);
    }

    private static NetworkEffect.AttemptInput attemptInput(WireValue description) {
        NetworkEffect.AttemptIdentity identity = new NetworkEffect.AttemptIdentity(
                new RequestIdentity("semantic", description instanceof SemanticValues.ObjectValue object && object.get("provenance") != null ? s(object.get("provenance")) : "comparison", Nat.one()),
                description instanceof SemanticValues.ObjectValue object && object.get("ordinal") != null ? Nat.fromLong(jsonNat(object.get("ordinal")).longValueExact()) : Nat.zero());
        return new NetworkEffect.AttemptInput(identity,
                new NetworkEffect.HttpWireInstruction(s(f(description, "method")), s(f(description, "target")), headers(f(description, "headers")), bytes(f(description, "body"))),
                java.util.Optional.empty(), new NetworkEffect.HostConfiguration(Nat.fromLong(1024), Nat.fromLong(1024), java.util.Optional.empty(), java.util.Optional.empty()));
    }

    private static necoherence.network.ByteString bytes(WireValue value) {
        return necoherence.network.ByteString.ofUnsigned(a(value).stream().mapToInt(item -> jsonNat(item).intValueExact()).toArray());
    }

    private static List<NetworkEffect.RawHeaderField> headers(WireValue value) {
        return a(value).stream().map(item -> new NetworkEffect.RawHeaderField(s(f(item, "name")), bytes(f(item, "value")))).toList();
    }

    private static List<Provider> providers(WireValue testCase, List<FunctionRef> references) {
        List<Provider> result = new ArrayList<>();
        for (WireValue description : a(f(testCase, "providers"))) {
            int signature = description instanceof SemanticValues.ObjectValue object && object.get("signature") != null ? jsonNat(object.get("signature")).intValueExact() : 0;
            FunctionRef providerReference = s(f(description, "reference")).equals("declared")
                    ? references.get(signature) : new FunctionRef("other", "1", "0".repeat(64));
            ProviderImplementation implementation;
            if (s(f(description, "effect")).equals("pure")) {
                CallResult returned = callResult(description);
                implementation = new PureProvider(arguments -> new ProviderSuccess<>(returned));
            } else {
                WireValue prepared = a(f(description, "prepare")).getFirst();
                implementation = new PreparedHttpProvider(new PreparedNetworkOwner(
                        arguments -> new ProviderSuccess<>(s(f(prepared, "tag")).equals("completed")
                                ? new CompletedCall(callResult(prepared)) : new Ready(attemptInput(f(prepared, "request")))),
                        response -> {
                            WireValue decoded = a(f(description, "decode")).stream()
                                    .filter(value -> jsonNat(f(value, "status")).intValueExact() == response.status()).findFirst().orElseThrow();
                            if (decoded instanceof SemanticValues.ObjectValue object && object.get("failure") != null)
                                return new ProviderRejected<>(new ProviderFailure(new SiteId("operation"), s(f(f(decoded, "failure"), "message"))));
                            return new ProviderSuccess<>(callResult(decoded));
                        }));
            }
            result.add(new Provider(providerReference, implementation));
        }
        return result;
    }

    private static CallResult callResult(WireValue description) {
        List<PortValue> outputs = new ArrayList<>();
        for (WireValue value : a(f(description, "outputs")))
            outputs.add(new PortValue(new PortId(s(f(value, "id"))), slot(f(value, "value"))));
        return new CallResult(new OutcomeId(s(f(description, "outcome"))), outputs);
    }

    private static WireValue functionJson(FunctionRef value) {
        return obj("identity", str(value.identity()), "revision", str(value.revision()), "contentDigest", str(value.contentDigest()));
    }

    private static WireValue nested(String constructor, WireValue... arguments) {
        return obj("constructor", str(constructor), "arguments", arr(List.of(arguments)));
    }

    private static WireValue typeJson(WireValue reference) {
        WireValue source = f(reference, "source");
        return obj("source", obj("repository", f(source, "repository"), "revision", f(source, "revision"),
                "path", f(source, "path"), "contentDigest", f(source, "content_digest"),
                "documentId", f(source, "document_id"), "declaredRevision", f(source, "declared_revision")),
                "definition", f(reference, "definition_name"), "pointer", f(reference, "pointer"));
    }

    private static WireValue pathJson(List<PathStep> path) {
        return arr(path.stream().map(step -> {
            if (step instanceof Field value) return obj("field", str(value.wireName()));
            if (step instanceof Index value) return obj("index", num(value.index()));
            return obj("variant", str(((Variant) step).wireTag()));
        }).toList());
    }

    private static WireValue producerJson(ProducerRef producer) {
        if (producer instanceof InitialProducer value)
            return nested("initial", str(value.id().value()));
        InvocationOutcomeProducer value = (InvocationOutcomeProducer) producer;
        return nested("invocationOutcome", str(value.site().value()),
                str(value.outcome().value()), str(value.port().value()));
    }

    private static WireValue valueRefJson(ValueRef reference) {
        return obj("producer", producerJson(reference.producer()), "path", pathJson(reference.path()));
    }

    private static WireValue lotJson(ResourceLotRef lot) {
        if (lot instanceof InitialLot value) return nested("initial", str(value.id().value()));
        ProducedLot value = (ProducedLot) lot;
        return nested("produced", str(value.site().value()), str(value.outcome().value()),
                str(value.production().value()));
    }

    private static WireValue validationFailureJson(necoherence.semantic.SemanticValidation.ValidationFailure failure) {
        return ValueFailureJson.render(failure);
    }

    private static WireValue failureJson(ExecutionFailure value) {
        if (value instanceof MissingArgument failure) return obj("tag", str("MissingArgument"), "input", str(failure.id().value()));
        if (value instanceof ArgumentCoverage failure) return obj("tag", str("ArgumentCoverage"), "condition", str(failure.condition()));
        if (value instanceof ProviderCoverage failure) return obj("tag", str("ProviderCoverage"), "condition", str(failure.condition()));
        if (value instanceof InvalidPlan failure) return obj("tag", str("InvalidPlan"), "condition", str(failure.condition()));
        if (value instanceof MissingProvider failure) return obj("tag", str("MissingProvider"), "function", functionJson(failure.function()));
        if (value instanceof ProviderEffect failure) return obj("tag", str("ProviderEffect"), "function", functionJson(failure.function()));
        if (value instanceof ProviderFailure failure) return obj("tag", str("ProviderFailure"), "site", str(failure.site().value()), "message", str(failure.message()));
        if (value instanceof InvalidOutcome failure) return obj("tag", str("InvalidOutcome"), "site", str(failure.site().value()), "outcome", str(failure.outcome().value()));
        if (value instanceof Resource failure) return obj("tag", str("Resource"), "lot", lotJson(failure.lot()), "condition", str(failure.condition()));
        if (value instanceof NetworkTerminal failure) {
            var terminal = failure.terminal();
            var failed = terminal.outcome() instanceof NetworkEffect.NetworkOutcome.Failed item ? item : null;
            var unknown = terminal.effect() instanceof NetworkEffect.EffectStatus.Unknown item ? item : null;
            return obj("tag", str("NetworkTerminal"), "outcome", str(terminal.outcome().getClass().getSimpleName()),
                    "stage", failed == null ? NIL : str(failed.failure().stage().name()),
                    "cause", failed == null ? NIL : str(failed.failure().cause().getClass().getSimpleName()),
                    "effect", str(terminal.effect().getClass().getSimpleName()),
                    "reason", unknown == null ? NIL : str(unknown.reason().name()));
        }
        if (value instanceof Network failure) return obj("tag", str("Network"), "detail", NetworkFailureJson.render(failure.failure()));
        if (value instanceof Value failure) return obj("tag", str("Value"), "detail", validationFailureJson(failure.failure()));
        MissingValue failure = (MissingValue) value;
        return obj("tag", str("MissingValue"), "detail", valueRefJson(failure.reference()));
    }

    private static NetworkEffect.AttemptInput requestFor(WireValue testCase, int index) {
        List<WireValue> ready = new ArrayList<>();
        for (WireValue provider : a(f(testCase, "providers")))
            if (!s(f(provider, "effect")).equals("pure")) for (WireValue prepared : a(f(provider, "prepare")))
                if (s(f(prepared, "tag")).equals("ready")) ready.add(prepared);
        return attemptInput(f(ready.get(index), "request"));
    }

    private static WireValue run(WireValue testCase) throws Exception {
        String exchange = s(f(testCase, "exchange"));
        WireValue envelope = SemanticGeneration.readJson(exchange);
        CheckedGeneration generation = TypeSignatures.admitGeneration(
                GenerationBasis.ofInput(envelope), exchange);
        AdmittedComposition checked = generation.composition();
        List<FunctionRef> references = checked.prepared().input().signatures().stream().map(FunctionSignature::reference).toList();
        if (references.isEmpty()) references = List.of(new FunctionRef("unused", "0", "0".repeat(64)));
        List<ArgumentValue> arguments = new ArrayList<>();
        for (WireValue value : a(f(testCase, "arguments"))) {
            arguments.add(new ArgumentValue(new InputId(s(f(value, "id"))), slot(f(value, "value"))));
        }
        RunResult current = SemanticExecution.start(checked, providers(testCase, references), arguments,
                NetworkEffect.NetworkState.empty());
        List<WireValue> progress = new ArrayList<>();
        int observationIndex = 0;
        while (current instanceof Progressed progressed && progressed.progress() instanceof Pending pending) {
            progress.add(obj("tag", str("pending"), "instruction", str(pending.instruction() instanceof Send ? "send" : "observe")));
            WireValue observation = a(f(testCase, "observations")).get(observationIndex++);
            int requestIndex = observation instanceof SemanticValues.ObjectValue object && object.get("request") != null ? jsonNat(object.get("request")).intValueExact() : 0;
            NetworkEffect.AttemptInput request = requestFor(testCase, requestIndex);
            ExecutionHandle handle = new ExecutionHandle(observation instanceof SemanticValues.ObjectValue object && object.get("handle") != null ? s(object.get("handle")) : "handle");
            ExecutionObservation supplied;
            if (s(f(observation, "tag")).equals("start") && s(f(observation, "kind")).equals("started")) {
                supplied = new Start(new NetworkEffect.StartObservation.Started(request.attempt(), handle));
            } else if (s(f(observation, "tag")).equals("start")) {
                NetworkEffect.NetworkHostFailure failure = new NetworkEffect.NetworkHostFailure(request.attempt(), NetworkEffect.HostStage.Start,
                        request.configuration(), new NetworkEffect.HostFailure.ExecutionStartFailed());
                supplied = new Start(new NetworkEffect.StartObservation.StartFailed(failure,
                        new NetworkEffect.EffectStatus.Unknown(NetworkEffect.UnknownEffectReason.NoResponse)));
            } else {
                NetworkEffect.AdapterObservation response = new NetworkEffect.AdapterObservation.ResponseObservation(
                        request.attempt(), handle, new NetworkEffect.SourceSequence.None(),
                        new NetworkEffect.RawHttpResponse(jsonNat(f(observation, "status")).intValueExact(), headers(f(observation, "headers")), bytes(f(observation, "body"))),
                        NetworkEffect.HeaderProvenance.LibraryNormalized,
                        new NetworkEffect.EffectStatus.Unknown(NetworkEffect.UnknownEffectReason.NoResponse));
                Nat delivery = observation instanceof SemanticValues.ObjectValue object && object.get("delivery") != null ? Nat.fromLong(jsonNat(object.get("delivery")).longValueExact()) : Nat.zero();
                supplied = new Host(new NetworkEffect.HostObservation.Delivered(delivery, response));
            }
            current = SemanticExecution.resume(pending.execution(), supplied);
        }
        String identity = s(f(testCase, "case"));
        if (current instanceof RunRejected rejected) {
            return obj("case", str(identity), "progress", arr(progress), "failure", failureJson(rejected.failure().cause()));
        }
        Completed completed = (Completed) ((Progressed) current).progress();
        progress.add(obj("tag", str("completed")));
        WireValue terminal;
        if (completed.result() instanceof Success success) {
            List<WireValue> outputs = success.outputs().stream().map(value -> arr(List.of(str(value.port().value()), slotJson(value.value())))).toList();
            terminal = obj("tag", str("success"), "outcome", arr(outputs));
        } else {
            DeclaredFailure failure = (DeclaredFailure) completed.result();
            terminal = obj("tag", str("failure"), "embedding", str(failure.embedding().value()), "value", slotJson(failure.value()));
        }
        return obj("case", str(identity), "progress", arr(progress), "result", terminal);
    }

    public static void main(String[] args) throws Exception {
        WireValue document = SemanticGeneration.readJson(Files.readString(Path.of(args[0]), StandardCharsets.UTF_8));
        List<WireValue> rows = new ArrayList<>();
        for (WireValue testCase : a(f(document, "cases"))) {
            try { rows.add(run(testCase)); }
            catch (Exception failure) {
                rows.add(obj(
                        "case", str(s(f(testCase, "case"))),
                        "progress", arr(List.of()),
                        "driverFailure", str(failure.getClass().getSimpleName() + ": " + failure.getMessage())));
            }
        }
        System.out.println(encodeWire(arr(rows)));
    }
}
