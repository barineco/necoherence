// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

package necoherence.composition;

import necoherence.semantic.ExactJson.JsonValue;
import static necoherence.network.NetworkEffect.*;
import static necoherence.semantic.SemanticValues.*;

import java.math.BigInteger;
import java.util.ArrayList;
import java.util.HashSet;
import java.util.List;
import java.util.Objects;
import java.util.Optional;
import java.util.Set;
import neco.quotient.application.Applied;
import neco.quotient.application.Application;
import neco.quotient.application.Construction;
import neco.quotient.application.Entry;
import neco.quotient.application.KeyedBlocks;
import necoherence.core.Nat;
import necoherence.network.NetworkEffect;
import necoherence.semantic.SemanticValues.Context;
import necoherence.semantic.ExactJson;
import necoherence.semantic.ExactJson.JsonArr;
import necoherence.semantic.ExactJson.JsonMember;
import necoherence.semantic.ExactJson.JsonNull;
import necoherence.semantic.ExactJson.JsonObj;
import necoherence.semantic.ExactJson.JsonStr;
import necoherence.semantic.SemanticTypes;
import necoherence.semantic.SemanticValidation;
import necoherence.composition.SemanticComposition.TypeRef;
import necoherence.semantic.SemanticValues.Slot;
import necoherence.semantic.SemanticValidation.ValidationFailure;
import necoherence.semantic.SemanticValidation.ValueRejected;
import necoherence.typed.TypedMapping;

/** Pure execution of a checked semantic composition. */
public final class SemanticExecution {
    private SemanticExecution() {}

    /** A composition whose certificate and derivation were admitted by the runtime check. */
    public static final class AdmittedComposition {
        private final SemanticComposition.PreparedCompositionInput prepared;
        private final SemanticComposition.CompositionPlan plan;
        private final PreparedTree root;

        AdmittedComposition(SemanticComposition.PreparedCompositionInput prepared,
                SemanticComposition.CompositionPlan plan) {
            this.prepared = Objects.requireNonNull(prepared);
            this.plan = Objects.requireNonNull(plan);
            this.root = prepareTree(this.plan.root());
        }

        public SemanticComposition.PreparedCompositionInput prepared() { return prepared; }
        public SemanticComposition.CompositionPlan plan() { return plan; }
    }

    /** A composition execution failure. */
    public sealed interface ExecutionFailure permits Value, MissingArgument, ArgumentCoverage,
            MissingValue, MissingProvider, ProviderCoverage, ProviderEffect, ProviderFailure,
            InvalidOutcome, Resource, InvalidPlan, Network, NetworkTerminal {}
    /** Value validation failed. */
    public record Value(ValidationFailure failure) implements ExecutionFailure {}
    /** A declared argument was not supplied. */
    public record MissingArgument(SemanticComposition.InputId id) implements ExecutionFailure {}
    /** Argument identifiers did not exactly cover declared arguments. */
    public record ArgumentCoverage(String condition) implements ExecutionFailure {}
    /** A value reference had no producer value. */
    public record MissingValue(SemanticComposition.ValueRef reference) implements ExecutionFailure {}
    /** A function had no provider. */
    public record MissingProvider(SemanticComposition.FunctionRef function) implements ExecutionFailure {}
    /** Provider identities did not exactly cover the signatures. */
    public record ProviderCoverage(String condition) implements ExecutionFailure {}
    /** A provider implementation had the wrong effect. */
    public record ProviderEffect(SemanticComposition.FunctionRef function) implements ExecutionFailure {}
    /** A provider rejected its call. */
    public record ProviderFailure(SemanticComposition.SiteId site, String message) implements ExecutionFailure {}
    /** A provider returned an undeclared outcome. */
    public record InvalidOutcome(SemanticComposition.SiteId site,
            SemanticComposition.OutcomeId outcome) implements ExecutionFailure {}
    /** A resource requirement failed. */
    public record Resource(SemanticComposition.ResourceLotRef lot, String condition) implements ExecutionFailure {}
    /** A checked composition tree could not be interpreted. */
    public record InvalidPlan(String condition) implements ExecutionFailure {}
    /** The network-effect core rejected a transition. */
    public record Network(NetworkEffect.NetworkFailure failure) implements ExecutionFailure {}
    /** The network-effect core reached a non-response terminal. */
    public record NetworkTerminal(NetworkEffect.NetworkTerminal terminal) implements ExecutionFailure {}

    /** A provider result with an explicit execution failure. */
    public sealed interface ProviderResult<T> permits ProviderSuccess, ProviderRejected {}
    /** A successful provider result. */
    public record ProviderSuccess<T>(T value) implements ProviderResult<T> {}
    /** A rejected provider result. */
    public record ProviderRejected<T>(ExecutionFailure failure) implements ProviderResult<T> {}

    /** One port value passed to or returned by a provider. */
    public record PortValue(SemanticComposition.PortId port, Slot<JsonValue> value) {
        public PortValue { Objects.requireNonNull(port); Objects.requireNonNull(value); }
    }
    /** One argument supplied by the caller. */
    public record ArgumentValue(SemanticComposition.InputId input, Slot<JsonValue> value) {
        public ArgumentValue { Objects.requireNonNull(input); Objects.requireNonNull(value); }
    }
    /** One successful goal value. */
    public record GoalValue(SemanticComposition.GoalPortId port, Slot<JsonValue> value) {
        public GoalValue { Objects.requireNonNull(port); Objects.requireNonNull(value); }
    }
    /** The declared outcome and values returned by a provider. */
    public record CallResult(SemanticComposition.OutcomeId outcome, List<PortValue> outputs) {
        public CallResult { Objects.requireNonNull(outcome); outputs = copy(outputs); }
    }

    @FunctionalInterface private interface NetworkEncoder {
        ProviderResult<AttemptInput> encode(List<PortValue> arguments);
    }
    /** Decodes a raw HTTP response as a provider outcome. */
    @FunctionalInterface public interface NetworkDecoder {
        /** Decodes a response without performing I/O. */
        ProviderResult<CallResult> decode(RawHttpResponse response);
    }
    private record NetworkOwner(NetworkEncoder encode, NetworkDecoder decode) {
        private NetworkOwner { Objects.requireNonNull(encode); Objects.requireNonNull(decode); }
    }
    /** The result of preparing an HTTP call. */
    public sealed interface PreparedCall permits Ready, CompletedCall {}
    /** A prepared network attempt. */
    public record Ready(AttemptInput input) implements PreparedCall {}
    /** A provider outcome completed during preparation. */
    public record CompletedCall(CallResult result) implements PreparedCall {}
    /** Prepares an HTTP call without performing I/O. */
    @FunctionalInterface public interface NetworkPreparer {
        /** Prepares or completes one provider call. */
        ProviderResult<PreparedCall> prepare(List<PortValue> arguments);
    }
    /** Owns pure preparation and response decoding for an HTTP provider. */
    public record PreparedNetworkOwner(NetworkPreparer prepare, NetworkDecoder decode) {
        public PreparedNetworkOwner { Objects.requireNonNull(prepare); Objects.requireNonNull(decode); }
    }
    /** Calls a pure provider. */
    @FunctionalInterface public interface PureCallback {
        /** Evaluates one provider call synchronously. */
        ProviderResult<CallResult> call(List<PortValue> arguments);
    }
    /** A provider implementation classified by its declared effect. */
    public sealed interface ProviderImplementation permits PureProvider, PreparedHttpProvider {}
    /** A synchronous pure provider. */
    public record PureProvider(PureCallback callback) implements ProviderImplementation {}
    /** A network provider with pure preparation. */
    public record PreparedHttpProvider(PreparedNetworkOwner owner) implements ProviderImplementation {}
    /** A provider associated with one function reference. */
    public record Provider(SemanticComposition.FunctionRef reference, ProviderImplementation implementation) {
        public Provider { Objects.requireNonNull(reference); Objects.requireNonNull(implementation); }
    }

    /** The terminal value of an execution. */
    public sealed interface ExecutionResult permits Success, DeclaredFailure {}
    /** Successful goal outputs. */
    public record Success(List<GoalValue> outputs) implements ExecutionResult {
        public Success { outputs = copy(outputs); }
    }
    /** A declared failure embedding and its value. */
    public record DeclaredFailure(SemanticComposition.FailureEmbeddingId embedding,
            Slot<JsonValue> value) implements ExecutionResult {}
    /** A runtime producer value. */
    public record RuntimeValue(SemanticComposition.ProducerRef producer, Slot<JsonValue> value) {}
    /** A runtime resource lot. */
    public record RuntimeResource(SemanticComposition.ResourceLotRef reference,
            SemanticComposition.ResourceLot lot) {}
    /** Values and resources accumulated while following the composition tree. */
    public record RuntimeState(List<RuntimeValue> values, List<RuntimeResource> resources) {
        public RuntimeState { values = copy(values); resources = copy(resources); }
    }
    /** An execution failure paired with the latest network state. */
    public record RunFailure(ExecutionFailure cause, NetworkEffect.NetworkState network) {}
    /** The network action requested from the caller. */
    public sealed interface NetworkInstruction permits Send, Observe {}
    /** Requests delivery of a send command. */
    public record Send(SendCommand command) implements NetworkInstruction {}
    /** Requests observation of a started attempt. */
    public record Observe(StartedAttempt started) implements NetworkInstruction {}
    /** An observation supplied by the caller. */
    public sealed interface ExecutionObservation permits Start, Host {}
    /** A start observation. */
    public record Start(StartObservation observation) implements ExecutionObservation {}
    /** A host observation. */
    public record Host(HostObservation observation) implements ExecutionObservation {}

    private sealed interface PreparedTree permits PreparedInvoke, PreparedGuard, PreparedReturn {
        SemanticComposition.PlanTree source();
    }
    private record PreparedInvoke(SemanticComposition.InvokeTree source,
            Optional<KeyedBlocks<SemanticComposition.OutcomeId, PreparedTree>> arms) implements PreparedTree {
        private PreparedInvoke { Objects.requireNonNull(source); Objects.requireNonNull(arms); }
    }
    private record PreparedGuard(SemanticComposition.GuardTree source,
            Optional<KeyedBlocks<SemanticComposition.GuardArm, PreparedTree>> arms) implements PreparedTree {
        private PreparedGuard { Objects.requireNonNull(source); Objects.requireNonNull(arms); }
    }
    private record PreparedReturn(SemanticComposition.ReturnTree source) implements PreparedTree {
        private PreparedReturn { Objects.requireNonNull(source); }
    }

    private static PreparedTree prepareTree(SemanticComposition.PlanTree tree) {
        if (tree instanceof SemanticComposition.InvokeTree invoked) {
            Construction<SemanticComposition.OutcomeId, PreparedTree> table = Application.keyedBlocksOf(
                    invoked.arms().stream().map(candidate -> new Entry<>(candidate.outcome(), prepareTree(candidate.child()))).toList());
            return new PreparedInvoke(invoked, table instanceof Construction.Built<SemanticComposition.OutcomeId, PreparedTree> built
                    ? Optional.of(built.blocks()) : Optional.empty());
        }
        if (tree instanceof SemanticComposition.GuardTree guarded) {
            Construction<SemanticComposition.GuardArm, PreparedTree> table = Application.keyedBlocksOf(
                    guarded.arms().stream().map(candidate -> new Entry<>(candidate.arm(), prepareTree(candidate.child()))).toList());
            return new PreparedGuard(guarded, table instanceof Construction.Built<SemanticComposition.GuardArm, PreparedTree> built
                    ? Optional.of(built.blocks()) : Optional.empty());
        }
        return new PreparedReturn((SemanticComposition.ReturnTree) tree);
    }

    /** The suspended network state of an execution. */
    private sealed interface PendingNetwork permits PendingStart, PendingResponse {}
    /** A call waiting for its start observation. */
    private record PendingStart(SemanticComposition.InvocationPlan invocation,
            Optional<KeyedBlocks<SemanticComposition.OutcomeId, PreparedTree>> arms, NetworkOwner owner,
            PreparedAttempt prepared) implements PendingNetwork {
        private PendingStart { Objects.requireNonNull(arms); }
    }
    /** A call waiting for its host response. */
    private record PendingResponse(SemanticComposition.InvocationPlan invocation,
            Optional<KeyedBlocks<SemanticComposition.OutcomeId, PreparedTree>> arms, NetworkOwner owner,
            StartedAttempt started) implements PendingNetwork {
        private PendingResponse { Objects.requireNonNull(arms); }
    }
    /** A resumable composition execution. */
    public static final class Execution {
        private final SemanticComposition.PreparedCompositionInput prepared;
        private final List<Provider> providers;
        private final RuntimeState state;
        private final PreparedTree node;
        private final NetworkEffect.NetworkState network;
        private final Optional<PendingNetwork> pending;

        private Execution(SemanticComposition.PreparedCompositionInput prepared,
                List<Provider> providers, RuntimeState state, PreparedTree node,
                NetworkEffect.NetworkState network, Optional<PendingNetwork> pending) {
            this.prepared = Objects.requireNonNull(prepared);
            this.providers = copy(providers);
            this.state = Objects.requireNonNull(state);
            this.node = Objects.requireNonNull(node);
            this.network = Objects.requireNonNull(network);
            this.pending = Objects.requireNonNull(pending);
        }

        public SemanticComposition.PreparedCompositionInput prepared() { return prepared; }
        public List<Provider> providers() { return providers; }
        public RuntimeState state() { return state; }
        public SemanticComposition.PlanTree tree() { return node.source(); }
        private PreparedTree node() { return node; }
        public NetworkEffect.NetworkState network() { return network; }
        private Optional<PendingNetwork> pending() { return pending; }
    }
    /** A completed or suspended execution. */
    public sealed interface Progress permits Completed, Pending {}
    /** A completed execution and its final network state. */
    public record Completed(ExecutionResult result, NetworkEffect.NetworkState network) implements Progress {}
    /** A suspended execution and the next caller-owned network action. */
    public record Pending(Execution execution, NetworkInstruction instruction) implements Progress {}
    /** The explicit result of starting or resuming execution. */
    public sealed interface RunResult permits Progressed, RunRejected {}
    /** A successful execution transition. */
    public record Progressed(Progress progress) implements RunResult {}
    /** A rejected execution transition. */
    public record RunRejected(RunFailure failure) implements RunResult {}

    /** Projects a runtime slot through one checked value path. */
    public static ProviderResult<Slot<JsonValue>> project(String tagKey, Slot<JsonValue> source,
            List<SemanticComposition.PathStep> path) {
        Slot<JsonValue> value = source;
        for (SemanticComposition.PathStep step : path) {
            if (!(value instanceof Present<JsonValue> present))
                return new ProviderRejected<>(new InvalidPlan("projection shape mismatch"));
            JsonValue raw = present.value();
            if (step instanceof SemanticComposition.Field field && raw instanceof JsonObj object) {
                JsonValue member = SemanticValidation.memberValue(field.wireName(), object.members()).orElse(null);
                if (member == null) value = new Absent<>();
                else if (member instanceof JsonNull) value = new NullSlot<>();
                else value = new Present<>(member);
            } else if (step instanceof SemanticComposition.Index index && raw instanceof JsonArr array) {
                if (index.index().compareTo(BigInteger.valueOf(array.items().size())) >= 0)
                    return new ProviderRejected<>(new InvalidPlan("array projection outside value"));
                JsonValue item = array.items().get(index.index().intValueExact());
                if (item instanceof JsonNull) value = new NullSlot<>();
                else value = new Present<>(item);
            } else if (step instanceof SemanticComposition.Variant variant && raw instanceof JsonObj object) {
                if (!new JsonStr(variant.wireTag()).equals(SemanticValidation.memberValue(tagKey, object.members()).orElse(null)))
                    return new ProviderRejected<>(new InvalidPlan("variant projection mismatch"));
            } else {
                return new ProviderRejected<>(new InvalidPlan("projection shape mismatch"));
            }
        }
        return new ProviderSuccess<>(value);
    }

    /** Looks up and projects one producer value. */
    static ProviderResult<Slot<JsonValue>> lookup(SemanticComposition.PreparedCompositionInput prepared,
            RuntimeState state, SemanticComposition.ValueRef reference) {
        RuntimeValue found = state.values().stream()
                .filter(value -> value.producer().equals(reference.producer())).findFirst().orElse(null);
        if (found == null) return new ProviderRejected<>(new MissingValue(reference));
        return project(prepared.valueContext().tagKey(), found.value(), reference.path());
    }

    /** Evaluates a checked binding against runtime values. */
    static ProviderResult<Slot<JsonValue>> evaluateBinding(
            SemanticComposition.PreparedCompositionInput prepared, RuntimeState state,
            SemanticComposition.BindingExpr binding) {
        if (binding instanceof SemanticComposition.SourceBinding source)
            return lookup(prepared, state, source.value());
        SemanticComposition.ProductBinding product = (SemanticComposition.ProductBinding) binding;
        List<JsonMember> members = new ArrayList<>();
        for (SemanticComposition.NamedBinding field : product.fields()) {
            ProviderResult<Slot<JsonValue>> evaluated = evaluateBinding(prepared, state, field.binding());
            if (evaluated instanceof ProviderRejected<Slot<JsonValue>> rejected) return rejected;
            Slot<JsonValue> value = ((ProviderSuccess<Slot<JsonValue>>) evaluated).value();
            if (value instanceof Present<JsonValue> present) members.add(new JsonMember(field.name(), present.value()));
            else if (value instanceof NullSlot<JsonValue>) members.add(new JsonMember(field.name(), ExactJson.NIL));
        }
        return new ProviderSuccess<>(new Present<JsonValue>(new JsonObj(members)));
    }

    /** Validates a slot using the prepared composition's semantic graph. */
    static Optional<ExecutionFailure> validate(SemanticComposition.PreparedCompositionInput prepared,
            SemanticComposition.SlotContract contract, Slot<JsonValue> value) {
        ValidationFailure failure = prepared.valueContext().slotFailure(contract, value);
        return failure == null ? Optional.empty() : Optional.of(new Value(failure));
    }

    /** Builds the initial runtime state from declared and caller-supplied inputs. */
    static ProviderResult<RuntimeState> initialState(SemanticComposition.PreparedCompositionInput prepared,
            List<ArgumentValue> arguments) {
        for (ArgumentValue argument : arguments) {
            long count = arguments.stream().filter(candidate -> candidate.input().equals(argument.input())).count();
            boolean declared = prepared.input().initialInputs().stream().anyMatch(initial ->
                    initial.id().equals(argument.input()) && initial.source() instanceof SemanticComposition.Argument);
            if (count != 1 || !declared)
                return new ProviderRejected<>(new ArgumentCoverage("unique declared argument identifiers required"));
        }
        List<RuntimeValue> values = new ArrayList<>();
        for (SemanticComposition.InitialInput initial : prepared.input().initialInputs()) {
            Slot<JsonValue> value;
            if (initial.source() instanceof SemanticComposition.SuppliedValue supplied) value = supplied.value();
            else {
                ArgumentValue argument = arguments.stream().filter(item -> item.input().equals(initial.id()))
                        .findFirst().orElse(null);
                if (argument == null) return new ProviderRejected<>(new MissingArgument(initial.id()));
                value = argument.value();
            }
            Optional<ExecutionFailure> invalid = validate(prepared, initial.contract(), value);
            if (invalid.isPresent()) return new ProviderRejected<>(invalid.get());
            values.add(new RuntimeValue(new SemanticComposition.InitialProducer(initial.id()), value));
        }
        List<RuntimeResource> resources = prepared.input().initialResources().stream().map(lot ->
                new RuntimeResource(new SemanticComposition.InitialLot(lot.id()), lot)).toList();
        return new ProviderSuccess<>(new RuntimeState(values, resources));
    }

    /** Applies one invocation's resource bindings. */
    public static ProviderResult<RuntimeState> bindResources(SemanticComposition.FunctionSignature signature,
            SemanticComposition.InvocationPlan invocation, RuntimeState state) {
        List<RuntimeResource> resources = new ArrayList<>(state.resources());
        for (SemanticComposition.ResourceBinding binding : invocation.resources()) {
            SemanticComposition.ResourceRequirement requirement = signature.resourceInputs().stream()
                    .filter(item -> item.id().equals(binding.requirement())).findFirst().orElse(null);
            if (requirement == null) return new ProviderRejected<>(new InvalidPlan("resource requirement mismatch"));
            RuntimeResource resource = resources.stream().filter(item -> item.reference().equals(binding.lot()))
                    .findFirst().orElse(null);
            if (resource == null) return new ProviderRejected<>(new Resource(binding.lot(), "missing lot"));
            if (!resource.lot().revision().equals(requirement.requiredRevision()))
                return new ProviderRejected<>(new Resource(binding.lot(), "revision mismatch"));
            if (resource.lot().quantity().compareTo(requirement.multiplicity()) < 0)
                return new ProviderRejected<>(new Resource(binding.lot(), "insufficient quantity"));
            if (requirement.mode() == TypedMapping.BindingMode.CONSUME) {
                resources.replaceAll(item -> item.reference().equals(binding.lot()) ? new RuntimeResource(item.reference(),
                        new SemanticComposition.ResourceLot(item.lot().id(), item.lot().tokenType(), item.lot().producer(),
                                item.lot().revision(), item.lot().quantity().subtract(requirement.multiplicity()),
                                item.lot().provenance())) : item);
            }
        }
        return new ProviderSuccess<>(new RuntimeState(state.values(), resources));
    }

    /** Inspects one declared guard. */
    static ProviderResult<SemanticComposition.GuardArm> inspectGuard(
            SemanticComposition.PreparedCompositionInput prepared, SemanticComposition.DeclaredGuard guard,
            Slot<JsonValue> value) {
        if (guard.kind() instanceof SemanticComposition.PresenceGuard) {
            if (value instanceof Absent<JsonValue>) return new ProviderSuccess<>(new SemanticComposition.AbsentArm());
            if (value instanceof NullSlot<JsonValue>) return new ProviderSuccess<>(new SemanticComposition.NullArm());
            return new ProviderSuccess<>(new SemanticComposition.PresentArm());
        }
        if (guard.kind() instanceof SemanticComposition.ValidateGuard checked) {
            Optional<ExecutionFailure> failure = validate(prepared, checked.contract(), value);
            if (failure.isEmpty()) return new ProviderSuccess<>(new SemanticComposition.AcceptedArm());
            if (failure.get() instanceof Value rejected
                    && rejected.failure() instanceof ValueRejected)
                return new ProviderSuccess<>(new SemanticComposition.RejectedArm());
            return new ProviderRejected<>(failure.get());
        }
        if (value instanceof Absent<JsonValue>)
            return new ProviderSuccess<>(new SemanticComposition.AbsentArm());
        if (value instanceof NullSlot<JsonValue>)
            return new ProviderSuccess<>(new SemanticComposition.NullArm());
        if (!(value instanceof Present<JsonValue> present) || !(present.value() instanceof JsonObj object))
            return new ProviderRejected<>(new InvalidPlan("union guard shape"));
        Context context = prepared.valueContext();
        if (!(SemanticValidation.memberValue(context.tagKey(), object.members()).orElse(null) instanceof JsonStr))
            return new ProviderRejected<>(new InvalidPlan("union guard discriminator"));
        Optional<TypeRef> projected = projectedReference(prepared, guard.sourceType(), guard.path());
        if (projected.isEmpty()) return new ProviderRejected<>(new InvalidPlan("union guard projection"));
        TypeRef reference = projected.get();
        if (!(resolvedShape(context.typed(), reference).orElse(null) instanceof SemanticTypes.TaggedUnionShape union))
            return new ProviderRejected<>(new InvalidPlan("union guard declaration"));
        int selected = context.selectBranch(reference, present.value());
        if (selected < 0)
            return new ProviderRejected<>(new InvalidPlan("union branch selection"));
        return new ProviderSuccess<>(new SemanticComposition.VariantArm(union.spec().branches().get(selected).wireTag()));
    }

    private static Optional<TypeRef> projectedReference(SemanticComposition.PreparedCompositionInput prepared,
            TypeRef source, List<SemanticComposition.PathStep> path) {
        SemanticTypes.SemanticGraph graph = prepared.valueContext().typed();
        TypeRef reference = source;
        for (SemanticComposition.PathStep step : path) {
            Optional<SemanticTypes.TypeShape> shape = resolvedShape(graph, reference);
            if (shape.isEmpty()) return Optional.empty();
            Optional<TypeRef> next = Optional.empty();
            if (step instanceof SemanticComposition.Field field && shape.get() instanceof SemanticTypes.ProductShape product) {
                next = product.spec().fields().stream().filter(candidate -> candidate.wireName().equals(field.wireName()))
                        .findFirst().map(candidate -> candidate.slot().typeRef());
            } else if (step instanceof SemanticComposition.Index && shape.get() instanceof SemanticTypes.ArrayShape array) {
                next = Optional.of(array.spec().item().typeRef());
            } else if (step instanceof SemanticComposition.Variant variant && shape.get() instanceof SemanticTypes.TaggedUnionShape union) {
                next = union.spec().branches().stream().filter(candidate -> candidate.wireTag().equals(variant.wireTag()))
                        .findFirst().map(candidate -> candidate.target());
            }
            if (next.isEmpty()) return Optional.empty();
            reference = next.get();
        }
        return Optional.of(reference);
    }

    /** Resolves alias references to the declared shape, or returns empty when the reference is unresolved or cyclic. */
    private static Optional<SemanticTypes.TypeShape> resolvedShape(SemanticTypes.SemanticGraph graph, TypeRef reference) {
        Set<TypeRef> seen = new HashSet<>();
        TypeRef current = reference;
        while (seen.add(current)) {
            Optional<SemanticTypes.TypeNode> node = graph.findType(current);
            if (node.isEmpty()) return Optional.empty();
            if (node.get().shape() instanceof SemanticTypes.AliasShape alias) current = alias.target();
            else return Optional.of(node.get().shape());
        }
        return Optional.empty();
    }

    /** Starts execution of one verified composition. */
    public static RunResult start(AdmittedComposition admitted, List<Provider> providers,
            List<ArgumentValue> arguments, NetworkEffect.NetworkState network) {
        Objects.requireNonNull(admitted); Objects.requireNonNull(providers);
        Objects.requireNonNull(arguments); Objects.requireNonNull(network);
        ReadStateStep read = readNetworkState(network);
        if (read instanceof ReadStateStep.Rejected rejected)
            return rejected(rejected.state(), new Network(rejected.failure()));
        network = ((ReadStateStep.Read) read).state();
        SemanticComposition.PreparedCompositionInput prepared = admitted.prepared();
        Optional<ExecutionFailure> providerFailure = validateProviders(prepared, providers);
        if (providerFailure.isPresent()) return rejected(network, providerFailure.get());
        ProviderResult<RuntimeState> initialized = initialState(prepared, arguments);
        if (initialized instanceof ProviderRejected<RuntimeState> failure)
            return rejected(network, failure.failure());
        return advance(new Execution(prepared, providers,
                ((ProviderSuccess<RuntimeState>) initialized).value(), admitted.root,
                network, Optional.empty()));
    }

    /** Resumes a suspended execution from a caller-supplied observation. */
    public static RunResult resume(Execution execution, ExecutionObservation observation) {
        Objects.requireNonNull(execution); Objects.requireNonNull(observation);
        if (execution.pending().isEmpty())
            return rejected(execution.network(), new InvalidPlan("only pending executions may resume"));
        PendingNetwork pending = execution.pending().get();
        if (pending instanceof PendingStart start && observation instanceof Start supplied) {
            NetworkStep step = observeStart(execution.network(), start.prepared(), supplied.observation());
            if (step instanceof NetworkStep.Started started) {
                PendingResponse response = new PendingResponse(start.invocation(), start.arms(), start.owner(), started.started());
                Execution next = execution(execution, execution.state(), execution.node(), started.state(), Optional.of(response));
                return progressed(new Pending(next, new Observe(started.started())));
            }
            if (step instanceof NetworkStep.Terminal terminal)
                return rejected(terminal.state(), new NetworkTerminal(terminal.settled().terminal()));
            if (step instanceof NetworkStep.Rejected rejected)
                return rejected(rejected.state(), new Network(rejected.failure()));
            return rejected(execution.network(), new InvalidPlan("network start result"));
        }
        if (pending instanceof PendingResponse response && observation instanceof Host supplied) {
            NetworkStep step = NetworkEffect.observe(execution.network(), supplied.observation());
            if (step instanceof NetworkStep.Pending nextStarted) {
                PendingResponse nextPending = new PendingResponse(response.invocation(), response.arms(),
                        response.owner(), nextStarted.started());
                return progressed(new Pending(execution(execution, execution.state(), execution.node(),
                        nextStarted.state(), Optional.of(nextPending)), new Observe(nextStarted.started())));
            }
            if (step instanceof NetworkStep.Terminal terminal) {
                if (!(terminal.settled().terminal().outcome() instanceof NetworkOutcome.Response raw))
                    return rejected(terminal.state(), new NetworkTerminal(terminal.settled().terminal()));
                ProviderResult<CallResult> decoded = response.owner().decode().decode(raw.response());
                if (decoded instanceof ProviderRejected<CallResult> failure)
                    return rejected(terminal.state(), failure.failure());
                Execution resumed = execution(execution, execution.state(), execution.node(),
                        terminal.state(), Optional.empty());
                ProviderResult<Execution> accepted = acceptOutcome(resumed, response.invocation(),
                        response.arms(), ((ProviderSuccess<CallResult>) decoded).value());
                if (accepted instanceof ProviderRejected<Execution> failure)
                    return rejected(terminal.state(), failure.failure());
                return advance(((ProviderSuccess<Execution>) accepted).value());
            }
            if (step instanceof NetworkStep.Duplicate duplicate)
                return repeatedObservation(execution, response, duplicate.state());
            if (step instanceof NetworkStep.Late late)
                return repeatedObservation(execution, response, late.state());
            if (step instanceof NetworkStep.Rejected rejected)
                return rejected(rejected.state(), new Network(rejected.failure()));
            return rejected(execution.network(), new InvalidPlan("completion delivered a start result"));
        }
        return rejected(execution.network(), new InvalidPlan("network observation kind mismatch"));
    }

    /** Advances a runtime state until completion or a caller-owned network action. */
    private static RunResult advance(Execution execution) {
        PreparedTree tree = execution.node();
        if (tree instanceof PreparedReturn returned)
            return complete(execution, returned.source().terminal());
        if (tree instanceof PreparedGuard prepared) {
            SemanticComposition.GuardTree guarded = prepared.source();
            SemanticComposition.DeclaredGuard guard = execution.prepared().input().invocationDomain().guards().stream()
                    .filter(candidate -> candidate.id().equals(guarded.guard())).findFirst().orElse(null);
            if (guard == null) return rejected(execution.network(), new InvalidPlan("guard identity mismatch"));
            ProviderResult<Slot<JsonValue>> found = lookup(execution.prepared(), execution.state(), guarded.inspected());
            if (found instanceof ProviderRejected<Slot<JsonValue>> failure)
                return rejected(execution.network(), failure.failure());
            ProviderResult<SemanticComposition.GuardArm> inspected = inspectGuard(execution.prepared(), guard,
                    ((ProviderSuccess<Slot<JsonValue>>) found).value());
            if (inspected instanceof ProviderRejected<SemanticComposition.GuardArm> failure)
                return rejected(execution.network(), failure.failure());
            SemanticComposition.GuardArm arm = ((ProviderSuccess<SemanticComposition.GuardArm>) inspected).value();
            if (prepared.arms().isEmpty())
                return rejected(execution.network(), new InvalidPlan("duplicate guard branch"));
            Applied<SemanticComposition.GuardArm, PreparedTree> applied = Application.apply(prepared.arms().get(), arm);
            if (!(applied instanceof Applied.Value<SemanticComposition.GuardArm, PreparedTree> next))
                return rejected(execution.network(), new InvalidPlan("guard branch mismatch"));
            return advance(execution(execution, execution.state(), next.value(), execution.network(), Optional.empty()));
        }
        PreparedInvoke selected = (PreparedInvoke) tree;
        SemanticComposition.InvokeTree invoked = selected.source();
        SemanticComposition.InvocationPlan invocation = invoked.invocation();
        SemanticComposition.FunctionSignature signature = execution.prepared().input().signatures().stream()
                .filter(candidate -> candidate.reference().equals(invocation.function())).findFirst().orElse(null);
        if (signature == null) return rejected(execution.network(), new InvalidPlan("function identity mismatch"));
        ProviderResult<RuntimeState> bound = bindResources(signature, invocation, execution.state());
        if (bound instanceof ProviderRejected<RuntimeState> failure)
            return rejected(execution.network(), failure.failure());
        RuntimeState state = ((ProviderSuccess<RuntimeState>) bound).value();
        List<PortValue> arguments = new ArrayList<>();
        for (SemanticComposition.PortBinding binding : invocation.bindings()) {
            SemanticComposition.InputPort port = signature.inputs().stream()
                    .filter(candidate -> candidate.id().equals(binding.port())).findFirst().orElse(null);
            if (port == null) return rejected(execution.network(), new InvalidPlan("input port mismatch"));
            ProviderResult<Slot<JsonValue>> evaluated = evaluateBinding(execution.prepared(), state, binding.binding());
            if (evaluated instanceof ProviderRejected<Slot<JsonValue>> failure)
                return rejected(execution.network(), failure.failure());
            Slot<JsonValue> value = ((ProviderSuccess<Slot<JsonValue>>) evaluated).value();
            Optional<ExecutionFailure> invalid = validate(execution.prepared(), port.contract(), value);
            if (invalid.isPresent()) return rejected(execution.network(), invalid.get());
            arguments.add(new PortValue(binding.port(), value));
        }
        Execution boundExecution = execution(execution, state, tree, execution.network(), Optional.empty());
        Provider provider = execution.providers().stream()
                .filter(candidate -> candidate.reference().equals(invocation.function())).findFirst().orElse(null);
        if (provider == null) return rejected(execution.network(), new MissingProvider(invocation.function()));
        if (provider.implementation() instanceof PureProvider pure) {
            ProviderResult<CallResult> called = pure.callback().call(arguments);
            if (called instanceof ProviderRejected<CallResult> failure)
                return rejected(execution.network(), failure.failure());
            ProviderResult<Execution> accepted = acceptOutcome(boundExecution, invocation, selected.arms(),
                    ((ProviderSuccess<CallResult>) called).value());
            if (accepted instanceof ProviderRejected<Execution> failure)
                return rejected(execution.network(), failure.failure());
            return advance(((ProviderSuccess<Execution>) accepted).value());
        }
        PreparedNetworkOwner owner = ((PreparedHttpProvider) provider.implementation()).owner();
        ProviderResult<PreparedCall> prepared = owner.prepare().prepare(arguments);
        if (prepared instanceof ProviderRejected<PreparedCall> failure)
            return rejected(execution.network(), failure.failure());
        PreparedCall call = ((ProviderSuccess<PreparedCall>) prepared).value();
        if (call instanceof Ready ready)
            return startHttp(boundExecution, invocation, selected.arms(), arguments,
                    new NetworkOwner(ignored -> new ProviderSuccess<>(ready.input()), owner.decode()));
        ProviderResult<Execution> accepted = acceptOutcome(boundExecution, invocation, selected.arms(),
                ((CompletedCall) call).result());
        if (accepted instanceof ProviderRejected<Execution> failure)
            return rejected(execution.network(), failure.failure());
        return advance(((ProviderSuccess<Execution>) accepted).value());
    }

    private static RunResult startHttp(Execution execution, SemanticComposition.InvocationPlan invocation,
            Optional<KeyedBlocks<SemanticComposition.OutcomeId, PreparedTree>> arms, List<PortValue> arguments, NetworkOwner owner) {
        ProviderResult<AttemptInput> encoded = owner.encode().encode(arguments);
        if (encoded instanceof ProviderRejected<AttemptInput> failure)
            return rejected(execution.network(), failure.failure());
        PrepareStep prepared = NetworkEffect.prepare(execution.network(), ((ProviderSuccess<AttemptInput>) encoded).value());
        if (prepared instanceof PrepareStep.Rejected failure)
            return rejected(failure.state(), new Network(failure.failure()));
        PrepareStep.Prepared ready = (PrepareStep.Prepared) prepared;
        CommandStep<SendCommand> command = sendCommand(ready.state(), ready.prepared());
        if (command instanceof CommandStep.Rejected<SendCommand> failure)
            return rejected(failure.state(), new Network(failure.failure()));
        CommandStep.CommandReady<SendCommand> send = (CommandStep.CommandReady<SendCommand>) command;
        PendingStart pending = new PendingStart(invocation, arms, owner, ready.prepared());
        Execution next = execution(execution, execution.state(), execution.node(), send.state(), Optional.of(pending));
        return progressed(new Pending(next, new Send(send.command())));
    }

    private static ProviderResult<Execution> acceptOutcome(Execution execution,
            SemanticComposition.InvocationPlan invocation, Optional<KeyedBlocks<SemanticComposition.OutcomeId, PreparedTree>> arms,
            CallResult result) {
        SemanticComposition.FunctionSignature signature = execution.prepared().input().signatures().stream()
                .filter(candidate -> candidate.reference().equals(invocation.function())).findFirst().orElse(null);
        if (signature == null) return new ProviderRejected<>(new InvalidPlan("function identity mismatch"));
        SemanticComposition.OutcomeContract outcome = signature.outcomes().stream()
                .filter(candidate -> candidate.id().equals(result.outcome())).findFirst().orElse(null);
        if (outcome == null) return new ProviderRejected<>(new InvalidOutcome(invocation.site(), result.outcome()));
        if (result.outputs().size() != outcome.valuePorts().size())
            return new ProviderRejected<>(new InvalidPlan("output port coverage"));
        List<RuntimeValue> produced = new ArrayList<>();
        for (SemanticComposition.OutputPort port : outcome.valuePorts()) {
            PortValue output = result.outputs().stream().filter(item -> item.port().equals(port.id()))
                    .findFirst().orElse(null);
            if (output == null) return new ProviderRejected<>(new InvalidPlan("missing output port"));
            Optional<ExecutionFailure> invalid = validate(execution.prepared(), port.contract(), output.value());
            if (invalid.isPresent()) return new ProviderRejected<>(invalid.get());
            produced.add(new RuntimeValue(new SemanticComposition.InvocationOutcomeProducer(
                    invocation.site(), outcome.id(), port.id()), output.value()));
        }
        List<RuntimeResource> resources = new ArrayList<>(execution.state().resources());
        for (SemanticComposition.ResourceProduction production : outcome.producedResources()) {
            resources.add(new RuntimeResource(new SemanticComposition.ProducedLot(invocation.site(), outcome.id(), production.id()),
                    new SemanticComposition.ResourceLot(new SemanticComposition.LotId(production.id().value()),
                            production.tokenType(), new SemanticComposition.InvocationOutcomeResourceProducer(
                                    invocation.site(), outcome.id()), production.revision(), production.quantity(),
                            production.provenance())));
        }
        if (arms.isEmpty())
            return new ProviderRejected<>(new InvalidPlan("duplicate outcome branch"));
        Applied<SemanticComposition.OutcomeId, PreparedTree> applied = Application.apply(arms.get(), outcome.id());
        if (!(applied instanceof Applied.Value<SemanticComposition.OutcomeId, PreparedTree> arm))
            return new ProviderRejected<>(new InvalidPlan("outcome branch mismatch"));
        List<RuntimeValue> values = new ArrayList<>(execution.state().values()); values.addAll(produced);
        return new ProviderSuccess<>(execution(execution, new RuntimeState(values, resources), arm.value(),
                execution.network(), Optional.empty()));
    }

    private static RunResult complete(Execution execution, SemanticComposition.ReturnPlan terminal) {
        if (terminal instanceof SemanticComposition.SuccessReturn success) {
            List<GoalValue> outputs = new ArrayList<>();
            for (SemanticComposition.GoalBinding binding : success.outputs()) {
                SemanticComposition.GoalPort port = execution.prepared().input().goal().outputs().stream()
                        .filter(candidate -> candidate.id().equals(binding.port())).findFirst().orElse(null);
                if (port == null) return rejected(execution.network(), new InvalidPlan("goal port mismatch"));
                ProviderResult<Slot<JsonValue>> evaluated = evaluateBinding(execution.prepared(), execution.state(), binding.binding());
                if (evaluated instanceof ProviderRejected<Slot<JsonValue>> failure)
                    return rejected(execution.network(), failure.failure());
                Slot<JsonValue> value = ((ProviderSuccess<Slot<JsonValue>>) evaluated).value();
                Optional<ExecutionFailure> invalid = validate(execution.prepared(), port.contract(), value);
                if (invalid.isPresent()) return rejected(execution.network(), invalid.get());
                outputs.add(new GoalValue(binding.port(), value));
            }
            Optional<ExecutionFailure> resource = finalResources(execution,
                    execution.prepared().input().goal().finalResources());
            return resource.<RunResult>map(failure -> rejected(execution.network(), failure))
                    .orElseGet(() -> progressed(new Completed(new Success(outputs), execution.network())));
        }
        SemanticComposition.FailureReturn failure = (SemanticComposition.FailureReturn) terminal;
        SemanticComposition.FailureEmbedding embedding = execution.prepared().input().goal().failures().stream()
                .filter(candidate -> candidate.id().equals(failure.embedding())).findFirst().orElse(null);
        if (embedding == null) return rejected(execution.network(), new InvalidPlan("failure embedding mismatch"));
        ProviderResult<Slot<JsonValue>> evaluated = evaluateBinding(execution.prepared(), execution.state(), failure.value());
        if (evaluated instanceof ProviderRejected<Slot<JsonValue>> rejected)
            return rejected(execution.network(), rejected.failure());
        Slot<JsonValue> value = ((ProviderSuccess<Slot<JsonValue>>) evaluated).value();
        Optional<ExecutionFailure> invalid = validate(execution.prepared(), embedding.contract(), value);
        if (invalid.isPresent()) return rejected(execution.network(), invalid.get());
        return progressed(new Completed(new DeclaredFailure(failure.embedding(), value), execution.network()));
    }

    private static Optional<ExecutionFailure> finalResources(Execution execution,
            List<SemanticComposition.ResourceGoal> goals) {
        for (SemanticComposition.ResourceGoal goal : goals) {
            RuntimeResource resource = execution.state().resources().stream()
                    .filter(item -> item.reference().equals(goal.lot())).findFirst().orElse(null);
            if (resource == null) return Optional.of(new Resource(goal.lot(), "missing final lot"));
            if (resource.lot().quantity().compareTo(goal.multiplicity()) < 0
                    || !resource.lot().revision().equals(goal.revision()))
                return Optional.of(new Resource(goal.lot(), "final resource mismatch"));
        }
        return Optional.empty();
    }

    private static Optional<ExecutionFailure> validateProviders(
            SemanticComposition.PreparedCompositionInput prepared, List<Provider> providers) {
        if (providers.size() != prepared.input().signatures().size())
            return Optional.of(new ProviderCoverage("exact provider coverage required"));
        for (Provider provider : providers) if (providers.stream()
                .filter(candidate -> candidate.reference().equals(provider.reference())).count() != 1)
            return Optional.of(new ProviderCoverage("unique provider references required"));
        for (SemanticComposition.FunctionSignature signature : prepared.input().signatures()) {
            Provider provider = providers.stream().filter(candidate ->
                    candidate.reference().equals(signature.reference())).findFirst().orElse(null);
            if (provider == null) return Optional.of(new MissingProvider(signature.reference()));
            boolean pure = provider.implementation() instanceof PureProvider;
            boolean matches = pure
                    ? signature.effect() == SemanticComposition.CompositionEffect.PURE_FUNCTION
                        || signature.effect() == SemanticComposition.CompositionEffect.DATA_ONLY
                    : signature.effect() == SemanticComposition.CompositionEffect.HTTP_REQUEST_RESPONSE;
            if (!matches) return Optional.of(new ProviderEffect(signature.reference()));
        }
        return Optional.empty();
    }

    private static RunResult repeatedObservation(Execution execution, PendingResponse pending,
            NetworkEffect.NetworkState network) {
        return progressed(new Pending(execution(execution, execution.state(), execution.node(), network,
                Optional.of(pending)), new Observe(pending.started())));
    }

    private static Execution execution(Execution source, RuntimeState state, PreparedTree tree,
            NetworkEffect.NetworkState network, Optional<PendingNetwork> pending) {
        return new Execution(source.prepared(), source.providers(), state, tree, network, pending);
    }
    private static RunResult progressed(Progress progress) { return new Progressed(progress); }
    private static RunResult rejected(NetworkEffect.NetworkState network, ExecutionFailure failure) {
        return new RunRejected(new RunFailure(failure, network));
    }

    private static <T> List<T> copy(List<T> values) {
        List<T> result = List.copyOf(Objects.requireNonNull(values)); result.forEach(Objects::requireNonNull); return result;
    }
}
