# SPDX-FileCopyrightText: 2026 barineco
# SPDX-License-Identifier: MIT

"""Execution of verified semantic compositions."""

from __future__ import annotations

from collections.abc import Callable, Mapping, Sequence
from dataclasses import dataclass, field, replace
from typing import Generic, TypeAlias, TypeVar, cast

from neco_quotient_application import DuplicateKey, KeyedBlocks, Value, apply, keyed_blocks_of

from . import network_effect as ne
from . import semantic_composition as sc
from .signature_values import (
    CertificateMismatchFailure,
    UnresolvedValueFailure,
    ValueContext,
    ValueFailure as SignatureValueFailure,
    select_union_branch,
)
from .typed_mapping import BindingMode


class ExecutionFailure:
    pass


@dataclass(frozen=True, slots=True)
class ValueFailure(ExecutionFailure):
    failure: SignatureValueFailure | UnresolvedValueFailure | CertificateMismatchFailure


@dataclass(frozen=True, slots=True)
class MissingArgument(ExecutionFailure):
    id: sc.InputId


@dataclass(frozen=True, slots=True)
class ArgumentCoverage(ExecutionFailure):
    condition: str


@dataclass(frozen=True, slots=True)
class MissingValue(ExecutionFailure):
    ref: sc.ValueRef


@dataclass(frozen=True, slots=True)
class MissingProvider(ExecutionFailure):
    function: sc.FunctionRef


@dataclass(frozen=True, slots=True)
class ProviderCoverage(ExecutionFailure):
    condition: str


@dataclass(frozen=True, slots=True)
class ProviderEffect(ExecutionFailure):
    function: sc.FunctionRef


@dataclass(frozen=True, slots=True)
class ProviderFailure(ExecutionFailure):
    site: sc.SiteId
    message: str


@dataclass(frozen=True, slots=True)
class InvalidOutcome(ExecutionFailure):
    site: sc.SiteId
    outcome: sc.OutcomeId


@dataclass(frozen=True, slots=True)
class ResourceFailure(ExecutionFailure):
    lot: sc.ResourceLotRef
    condition: str


@dataclass(frozen=True, slots=True)
class InvalidPlan(ExecutionFailure):
    condition: str


@dataclass(frozen=True, slots=True)
class NetworkFailure(ExecutionFailure):
    failure: object


@dataclass(frozen=True, slots=True)
class NetworkTerminalFailure(ExecutionFailure):
    terminal: ne.NetworkTerminal


@dataclass(frozen=True, slots=True)
class CallResult:
    outcome: sc.OutcomeId
    outputs: tuple[tuple[sc.PortId, sc.SlotValue], ...]


ProviderCallback: TypeAlias = Callable[[tuple[tuple[sc.PortId, sc.SlotValue], ...]], CallResult | ExecutionFailure]
EncodeCallback: TypeAlias = Callable[[tuple[tuple[sc.PortId, sc.SlotValue], ...]], ne.AttemptInput | ExecutionFailure]
DecodeCallback: TypeAlias = Callable[[ne.RawHttpResponse], CallResult | ExecutionFailure]


@dataclass(frozen=True, slots=True)
class NetworkOwner:
    encode: EncodeCallback
    decode: DecodeCallback


NetworkInput = TypeVar("NetworkInput")
NetworkOutput = TypeVar("NetworkOutput")


@dataclass(frozen=True, slots=True)
class NetworkTransport(Generic[NetworkInput, NetworkOutput]):
    encode: Callable[[NetworkInput], ne.AttemptInput | ExecutionFailure]
    decode: Callable[[ne.RawHttpResponse], NetworkOutput | ExecutionFailure]


class PreparedCall:
    pass


@dataclass(frozen=True, slots=True)
class ReadyCall(PreparedCall):
    input: ne.AttemptInput


@dataclass(frozen=True, slots=True)
class CompletedCall(PreparedCall, Generic[NetworkOutput]):
    result: NetworkOutput


@dataclass(frozen=True, slots=True)
class NetworkBinding(Generic[NetworkInput, NetworkOutput]):
    transport: NetworkTransport[NetworkInput, NetworkOutput]
    prepare: Callable[[NetworkInput], ReadyCall | CompletedCall[NetworkOutput] | ExecutionFailure]
    outcome_id: Callable[[NetworkOutput], str]


@dataclass(frozen=True, slots=True)
class PreparedNetworkOwner:
    prepare: Callable[
        [tuple[tuple[sc.PortId, sc.SlotValue], ...]],
        ReadyCall | CompletedCall[CallResult] | ExecutionFailure,
    ]
    decode: DecodeCallback


@dataclass(frozen=True, slots=True)
class PureProvider:
    callback: ProviderCallback


@dataclass(frozen=True, slots=True)
class PreparedHttpProvider:
    owner: PreparedNetworkOwner


ProviderImplementation: TypeAlias = PureProvider | PreparedHttpProvider


@dataclass(frozen=True, slots=True)
class Provider:
    reference: sc.FunctionRef
    implementation: ProviderImplementation


class ExecutionResult:
    pass


@dataclass(frozen=True, slots=True)
class Success(ExecutionResult):
    outputs: tuple[tuple[sc.GoalPortId, sc.SlotValue], ...]


@dataclass(frozen=True, slots=True)
class DeclaredFailure(ExecutionResult):
    embedding: sc.FailureEmbeddingId
    value: sc.SlotValue


@dataclass(frozen=True, slots=True)
class RuntimeState:
    values: tuple[tuple[sc.ProducerRef, sc.SlotValue], ...]
    resources: tuple[tuple[sc.ResourceLotRef, sc.ResourceLot], ...]


@dataclass(frozen=True, slots=True)
class RunFailure:
    cause: ExecutionFailure
    network: ne.NetworkState


class NetworkInstruction:
    pass


@dataclass(frozen=True, slots=True)
class Send(NetworkInstruction):
    command: ne.SendCommand


@dataclass(frozen=True, slots=True)
class Observe(NetworkInstruction):
    started: ne.StartedAttempt


class ExecutionObservation:
    pass


@dataclass(frozen=True, slots=True)
class StartObservation(ExecutionObservation):
    observation: ne.StartObservation


@dataclass(frozen=True, slots=True)
class HostObservation(ExecutionObservation):
    observation: ne.HostObservation


@dataclass(frozen=True, slots=True)
class _PreparedInvoke:
    invocation: sc.InvocationPlan
    arms: _OutcomeTable


@dataclass(frozen=True, slots=True)
class _PreparedGuard:
    guard: sc.GuardId
    inspected: sc.ValueRef
    arms: _GuardTable


_PreparedTree: TypeAlias = _PreparedInvoke | _PreparedGuard | sc.ReturnPlanTree
_OutcomeTable: TypeAlias = KeyedBlocks[sc.OutcomeId, _PreparedTree] | DuplicateKey[sc.OutcomeId]
_GuardTable: TypeAlias = KeyedBlocks[sc.GuardArm, _PreparedTree] | DuplicateKey[sc.GuardArm]


def _prepare_tree(tree: sc.PlanTree) -> _PreparedTree:
    if isinstance(tree, sc.ReturnPlanTree):
        return tree
    if isinstance(tree, sc.InvokePlanTree):
        return _PreparedInvoke(tree.invocation, keyed_blocks_of(tuple((key, _prepare_tree(child)) for key, child in tree.arms)))
    return _PreparedGuard(tree.guard, tree.inspected, keyed_blocks_of(tuple((key, _prepare_tree(child)) for key, child in tree.arms)))


class PendingNetwork:
    pass


@dataclass(frozen=True, slots=True)
class PendingStart(PendingNetwork):
    invocation: sc.InvocationPlan
    arms: _OutcomeTable
    owner: NetworkOwner
    prepared: ne.PreparedAttempt


@dataclass(frozen=True, slots=True)
class PendingResponse(PendingNetwork):
    invocation: sc.InvocationPlan
    arms: _OutcomeTable
    owner: NetworkOwner
    started: ne.StartedAttempt


_execution_token = object()
_admission_token = object()


@dataclass(frozen=True, slots=True, init=False)
class AdmittedComposition:
    prepared: sc.PreparedCompositionInput
    plan: sc.CompositionPlan
    _root: _PreparedTree = field(repr=False, compare=False)

    def __init__(self, token: object, prepared: sc.PreparedCompositionInput, plan: sc.CompositionPlan) -> None:
        if token is not _admission_token:
            raise TypeError("admitted composition requires runtime admission")
        object.__setattr__(self, "prepared", prepared)
        object.__setattr__(self, "plan", plan)
        object.__setattr__(self, "_root", _prepare_tree(plan.root))


@dataclass(frozen=True, slots=True, init=False)
class Execution:
    prepared: sc.PreparedCompositionInput
    providers: tuple[Provider, ...]
    state: RuntimeState
    tree: _PreparedTree
    network: ne.NetworkState
    pending: PendingNetwork | None

    def __init__(self, token: object, prepared: sc.PreparedCompositionInput,
                 providers: tuple[Provider, ...], state: RuntimeState, tree: _PreparedTree,
                 network: ne.NetworkState, pending: PendingNetwork | None) -> None:
        if token is not _execution_token:
            raise TypeError("execution requires start or resume")
        object.__setattr__(self, "prepared", prepared)
        object.__setattr__(self, "providers", providers)
        object.__setattr__(self, "state", state)
        object.__setattr__(self, "tree", tree)
        object.__setattr__(self, "network", network)
        object.__setattr__(self, "pending", pending)


def _replace_execution(execution: Execution, *, state: RuntimeState | None = None,
                       tree: _PreparedTree | None = None, network: ne.NetworkState | None = None,
                       pending: PendingNetwork | None | object = ...) -> Execution:
    return Execution(
        _execution_token,
        execution.prepared,
        execution.providers,
        execution.state if state is None else state,
        execution.tree if tree is None else tree,
        execution.network if network is None else network,
        execution.pending if pending is ... else cast(PendingNetwork | None, pending),
    )


class Progress:
    pass


@dataclass(frozen=True, slots=True)
class Completed(Progress):
    result: ExecutionResult
    network: ne.NetworkState


@dataclass(frozen=True, slots=True)
class Pending(Progress):
    execution: Execution
    instruction: NetworkInstruction


def _members(value: object) -> Mapping[str, object] | None:
    return value if isinstance(value, Mapping) and all(isinstance(key, str) for key in value) else None


def _project(tag_key: str, value: sc.SlotValue, path: sc.ValuePath) -> sc.SlotValue | ExecutionFailure:
    current = value
    for step in path:
        if not isinstance(current, sc.PresentValue):
            return InvalidPlan("projection shape mismatch")
        if isinstance(step, sc.FieldStep):
            members = _members(current.value)
            if members is None:
                return InvalidPlan("projection shape mismatch")
            if step.value not in members:
                current = sc.ABSENT_VALUE
            elif members[step.value] is None:
                current = sc.NULL_VALUE
            else:
                current = sc.PresentValue(members[step.value])
        elif isinstance(step, sc.IndexStep):
            if not isinstance(current.value, Sequence) or isinstance(current.value, (str, bytes, bytearray)):
                return InvalidPlan("projection shape mismatch")
            if step.value >= len(current.value):
                return InvalidPlan("array projection outside value")
            item = current.value[step.value]
            current = sc.NULL_VALUE if item is None else sc.PresentValue(item)
        elif isinstance(step, sc.VariantStep):
            members = _members(current.value)
            if members is None:
                return InvalidPlan("projection shape mismatch")
            if members.get(tag_key) != step.value:
                return InvalidPlan("variant projection mismatch")
        else:
            return InvalidPlan("projection shape mismatch")
    return current


def _lookup(graph: sc.SemanticGraph, state: RuntimeState, ref: sc.ValueRef) -> sc.SlotValue | ExecutionFailure:
    value = next((value for producer, value in state.values if producer == ref.producer), None)
    if value is None:
        return MissingValue(ref)
    profile = graph.get("profile")
    tag_key = ""
    if isinstance(profile, Mapping):
        tag = profile.get("tag")
        if isinstance(tag, Mapping) and isinstance(tag.get("key"), str):
            tag_key = tag["key"]
    return _project(tag_key, value, ref.path)


def _evaluate_binding(graph: sc.SemanticGraph, state: RuntimeState, binding: sc.BindingExpr) -> sc.SlotValue | ExecutionFailure:
    if isinstance(binding, sc.SourceBindingExpr):
        return _lookup(graph, state, binding.value)
    members: dict[str, object] = {}
    for name, child in binding.fields:
        value = _evaluate_binding(graph, state, child)
        if isinstance(value, ExecutionFailure):
            return value
        if isinstance(value, sc.PresentValue):
            members[name] = value.value
        elif isinstance(value, sc.NullValue):
            members[name] = None
    return sc.PresentValue(members)


def _validate(values: ValueContext, contract: sc.SlotContract, value: sc.SlotValue) -> ExecutionFailure | None:
    decision = sc.accepts_slot(values, contract, value)
    if isinstance(decision, sc.ValueRejected):
        return ValueFailure(decision.failure)
    if isinstance(decision, sc.ValueUnresolved):
        return ValueFailure(UnresolvedValueFailure(decision.obligations))
    return None


def _initial_state(
    prepared: sc.PreparedCompositionInput,
    arguments: tuple[tuple[sc.InputId, sc.SlotValue], ...],
) -> RuntimeState | ExecutionFailure:
    for identity, _ in arguments:
        if sum(candidate == identity for candidate, _ in arguments) != 1 or not any(
            item.id == identity and isinstance(item.source, sc.ArgumentSource)
            for item in prepared.input.initial_inputs
        ):
            return ArgumentCoverage("unique declared argument identifiers required")
    values: list[tuple[sc.ProducerRef, sc.SlotValue]] = []
    for item in prepared.input.initial_inputs:
        if isinstance(item.source, sc.SuppliedValueSource):
            value = item.source.value
        else:
            found = next((value for identity, value in arguments if identity == item.id), None)
            if found is None:
                return MissingArgument(item.id)
            value = found
        failure = _validate(prepared.values, item.contract, value)
        if failure is not None:
            return failure
        values.append((sc.InitialProducer(item.id), value))
    resources = tuple((sc.InitialLotRef(item.id), item) for item in prepared.input.initial_resources)
    return RuntimeState(tuple(values), resources)


def _bind_resources(signature: sc.FunctionSignature, invocation: sc.InvocationPlan, state: RuntimeState) -> RuntimeState | ExecutionFailure:
    resources = state.resources
    for binding in invocation.resources:
        requirement = next((item for item in signature.resource_inputs if item.id == binding.requirement), None)
        if requirement is None:
            return InvalidPlan("resource requirement mismatch")
        lot = next((lot for ref, lot in resources if ref == binding.lot), None)
        if lot is None:
            return ResourceFailure(binding.lot, "missing lot")
        if lot.revision != requirement.required_revision:
            return ResourceFailure(binding.lot, "revision mismatch")
        if lot.quantity < requirement.multiplicity:
            return ResourceFailure(binding.lot, "insufficient quantity")
        if requirement.mode is BindingMode.CONSUME:
            resources = tuple(
                (ref, replace(existing, quantity=existing.quantity - requirement.multiplicity))
                if ref == binding.lot else (ref, existing)
                for ref, existing in resources
            )
    return replace(state, resources=resources)


def _inspect_guard(values: ValueContext, guard: sc.DeclaredGuard, value: sc.SlotValue) -> sc.GuardArm | ExecutionFailure:
    graph = values.graph
    if guard.kind is sc.UnitGuardKind.PRESENCE:
        if isinstance(value, sc.AbsentValue):
            return sc.UnitGuardArm.ABSENT
        if isinstance(value, sc.NullValue):
            return sc.UnitGuardArm.NULL
        return sc.UnitGuardArm.PRESENT
    if isinstance(guard.kind, sc.ValidateGuardKind):
        failure = _validate(values, guard.kind.contract, value)
        if failure is None:
            return sc.UnitGuardArm.ACCEPTED
        if isinstance(failure, ValueFailure) and isinstance(failure.failure, SignatureValueFailure):
            return sc.UnitGuardArm.REJECTED
        return failure
    if isinstance(value, sc.AbsentValue):
        return sc.UnitGuardArm.ABSENT
    if isinstance(value, sc.NullValue):
        return sc.UnitGuardArm.NULL
    if not isinstance(value, sc.PresentValue):
        return InvalidPlan("union guard shape")
    members = _members(value.value)
    if members is None:
        return InvalidPlan("union guard shape")
    profile = graph.get("profile")
    tag = profile.get("tag") if isinstance(profile, Mapping) else None
    key = tag.get("key", "") if isinstance(tag, Mapping) else ""
    wire_tag = members.get(key)
    if not isinstance(wire_tag, str):
        return InvalidPlan("union guard discriminator")
    projection = sc.project_slot(sc.SlotContract(guard.source_type, True, False), guard.path, (), values)
    if isinstance(projection, sc.ProjectionFailure):
        return InvalidPlan("union guard projection")
    shape = sc._resolved_shape(graph, projection.destination.type_ref)
    if shape is None or sc._tag(shape) != "TaggedUnion":
        return InvalidPlan("union guard declaration")
    branches = sc._shape_payload(shape).get("branches", ())
    if not isinstance(branches, Sequence):
        return InvalidPlan("union guard declaration")
    branch = select_union_branch(graph["profile"], branches, value.value)
    if not isinstance(branch, Mapping) or not isinstance(branch.get("wire_tag"), str):
        return InvalidPlan("union branch selection")
    return sc.VariantGuardArm(branch["wire_tag"])


def _provider_matches(effect: sc.CompositionEffect, implementation: ProviderImplementation) -> bool:
    if isinstance(implementation, PureProvider):
        return effect in (sc.CompositionEffect.PURE_FUNCTION, sc.CompositionEffect.DATA_ONLY)
    return isinstance(implementation, PreparedHttpProvider) and effect is sc.CompositionEffect.HTTP_REQUEST_RESPONSE


def _validate_providers(prepared: sc.PreparedCompositionInput, providers: tuple[Provider, ...]) -> ExecutionFailure | None:
    if len(providers) != len(prepared.input.signatures):
        return ProviderCoverage("exact provider coverage required")
    if any(sum(candidate.reference == provider.reference for candidate in providers) != 1 for provider in providers):
        return ProviderCoverage("unique provider references required")
    for signature in prepared.input.signatures:
        provider = next((item for item in providers if item.reference == signature.reference), None)
        if provider is None:
            return MissingProvider(signature.reference)
        if not _provider_matches(signature.effect, provider.implementation):
            return ProviderEffect(signature.reference)
    return None


def _invocation_call(execution: Execution, invocation: sc.InvocationPlan) -> tuple[sc.FunctionSignature, RuntimeState, tuple[tuple[sc.PortId, sc.SlotValue], ...]] | ExecutionFailure:
    signature = next((item for item in execution.prepared.input.signatures if item.reference == invocation.function), None)
    if signature is None:
        return InvalidPlan("function identity mismatch")
    state = _bind_resources(signature, invocation, execution.state)
    if isinstance(state, ExecutionFailure):
        return state
    arguments: list[tuple[sc.PortId, sc.SlotValue]] = []
    for identity, binding in invocation.bindings:
        port = next((item for item in signature.inputs if item.id == identity), None)
        if port is None:
            return InvalidPlan("input port mismatch")
        value = _evaluate_binding(execution.prepared.graph, state, binding)
        if isinstance(value, ExecutionFailure):
            return value
        failure = _validate(execution.prepared.values, port.contract, value)
        if failure is not None:
            return failure
        arguments.append((identity, value))
    return signature, state, tuple(arguments)


def _accept_outcome(execution: Execution, signature: sc.FunctionSignature, invocation: sc.InvocationPlan, arms: _OutcomeTable, result: CallResult) -> Execution | ExecutionFailure:
    outcome = next((item for item in signature.outcomes if item.id == result.outcome), None)
    if outcome is None:
        return InvalidOutcome(invocation.site, result.outcome)
    if len(result.outputs) != len(outcome.value_ports):
        return InvalidPlan("output port coverage")
    values: list[tuple[sc.ProducerRef, sc.SlotValue]] = []
    for port in outcome.value_ports:
        found = next((value for identity, value in result.outputs if identity == port.id), None)
        if found is None:
            return InvalidPlan("missing output port")
        failure = _validate(execution.prepared.values, port.contract, found)
        if failure is not None:
            return failure
        values.append((sc.InvocationOutcomeProducer(invocation.site, outcome.id, port.id), found))
    resources = tuple(
        (
            sc.ProducedLotRef(invocation.site, outcome.id, production.id),
            sc.ResourceLot(
                sc.LotId(production.id.value), production.token_type,
                sc.InvocationResourceProducer(invocation.site, outcome.id),
                production.revision, production.quantity, production.provenance,
            ),
        )
        for production in outcome.produced_resources
    )
    if isinstance(arms, DuplicateKey):
        return InvalidPlan("duplicate outcome branch")
    applied = apply(arms, outcome.id)
    if not isinstance(applied, Value):
        return InvalidPlan("outcome branch mismatch")
    tree = applied.value
    return _replace_execution(
        execution,
        state=RuntimeState(execution.state.values + tuple(values), execution.state.resources + resources),
        tree=tree,
        pending=None,
    )


def _start_http(execution: Execution, invocation: sc.InvocationPlan, arms: _OutcomeTable, arguments: tuple[tuple[sc.PortId, sc.SlotValue], ...], owner: NetworkOwner) -> Progress | RunFailure:
    encoded = owner.encode(arguments)
    if isinstance(encoded, ExecutionFailure):
        return RunFailure(encoded, execution.network)
    prepared = ne.prepare(execution.network, encoded)
    if isinstance(prepared, ne.NetworkRejected):
        return RunFailure(NetworkFailure(prepared.failure), prepared.state)
    issued = ne.send_command(prepared.state, prepared.prepared)
    if isinstance(issued, ne.NetworkRejected):
        return RunFailure(NetworkFailure(issued.failure), issued.state)
    pending = PendingStart(invocation, arms, owner, prepared.prepared)
    next_execution = _replace_execution(execution, network=issued.state, pending=pending)
    return Pending(next_execution, Send(issued.command))


def _advance(execution: Execution) -> Progress | RunFailure:
    while True:
        tree = execution.tree
        if isinstance(tree, sc.ReturnPlanTree):
            terminal = tree.terminal
            if isinstance(terminal, sc.SuccessReturnPlan):
                outputs: list[tuple[sc.GoalPortId, sc.SlotValue]] = []
                for identity, binding in terminal.outputs:
                    port = next((item for item in execution.prepared.input.goal.outputs if item.id == identity), None)
                    if port is None:
                        return RunFailure(InvalidPlan("goal port mismatch"), execution.network)
                    value = _evaluate_binding(execution.prepared.graph, execution.state, binding)
                    if isinstance(value, ExecutionFailure):
                        return RunFailure(value, execution.network)
                    failure = _validate(execution.prepared.values, port.contract, value)
                    if failure is not None:
                        return RunFailure(failure, execution.network)
                    outputs.append((identity, value))
                for resource in execution.prepared.input.goal.final_resources:
                    lot = next((lot for ref, lot in execution.state.resources if ref == resource.lot), None)
                    if lot is None:
                        return RunFailure(ResourceFailure(resource.lot, "missing final lot"), execution.network)
                    if lot.quantity < resource.multiplicity or lot.revision != resource.revision:
                        return RunFailure(ResourceFailure(resource.lot, "final resource mismatch"), execution.network)
                return Completed(Success(tuple(outputs)), execution.network)
            failure_embedding = next((item for item in execution.prepared.input.goal.failures if item.id == terminal.embedding), None)
            if failure_embedding is None:
                return RunFailure(InvalidPlan("failure embedding mismatch"), execution.network)
            value = _evaluate_binding(execution.prepared.graph, execution.state, terminal.value)
            if isinstance(value, ExecutionFailure):
                return RunFailure(value, execution.network)
            failure = _validate(execution.prepared.values, failure_embedding.contract, value)
            if failure is not None:
                return RunFailure(failure, execution.network)
            return Completed(DeclaredFailure(terminal.embedding, value), execution.network)
        if isinstance(tree, _PreparedGuard):
            guard = next((item for item in execution.prepared.input.invocation_domain.guards if item.id == tree.guard), None)
            if guard is None:
                return RunFailure(InvalidPlan("guard identity mismatch"), execution.network)
            value = _lookup(execution.prepared.graph, execution.state, tree.inspected)
            if isinstance(value, ExecutionFailure):
                return RunFailure(value, execution.network)
            arm = _inspect_guard(execution.prepared.values, guard, value)
            if isinstance(arm, ExecutionFailure):
                return RunFailure(arm, execution.network)
            if isinstance(tree.arms, DuplicateKey):
                return RunFailure(InvalidPlan("duplicate guard branch"), execution.network)
            applied = apply(tree.arms, arm)
            if not isinstance(applied, Value):
                return RunFailure(InvalidPlan("guard branch mismatch"), execution.network)
            execution = _replace_execution(execution, tree=applied.value)
            continue
        call = _invocation_call(execution, tree.invocation)
        if isinstance(call, ExecutionFailure):
            return RunFailure(call, execution.network)
        signature, state, arguments = call
        execution = _replace_execution(execution, state=state)
        provider = next((item for item in execution.providers if item.reference == tree.invocation.function), None)
        if provider is None:
            return RunFailure(MissingProvider(tree.invocation.function), execution.network)
        implementation = provider.implementation
        if isinstance(implementation, PureProvider):
            result = implementation.callback(arguments)
            if isinstance(result, ExecutionFailure):
                return RunFailure(result, execution.network)
            accepted = _accept_outcome(execution, signature, tree.invocation, tree.arms, result)
            if isinstance(accepted, ExecutionFailure):
                return RunFailure(accepted, execution.network)
            execution = accepted
            continue
        prepared_call = implementation.owner.prepare(arguments)
        if isinstance(prepared_call, ExecutionFailure):
            return RunFailure(prepared_call, execution.network)
        if isinstance(prepared_call, ReadyCall):
            owner = NetworkOwner(lambda _arguments: prepared_call.input, implementation.owner.decode)
            return _start_http(execution, tree.invocation, tree.arms, arguments, owner)
        accepted = _accept_outcome(execution, signature, tree.invocation, tree.arms, prepared_call.result)
        if isinstance(accepted, ExecutionFailure):
            return RunFailure(accepted, execution.network)
        execution = accepted


def start(
    admitted: AdmittedComposition,
    providers: tuple[Provider, ...],
    arguments: tuple[tuple[sc.InputId, sc.SlotValue], ...],
    network: ne.NetworkState,
) -> Progress | RunFailure:
    prepared = admitted.prepared
    read = ne.read_network_state(network)
    failure = _validate_providers(prepared, providers)
    if failure is not None:
        return RunFailure(failure, read.state)
    state = _initial_state(prepared, arguments)
    if isinstance(state, ExecutionFailure):
        return RunFailure(state, read.state)
    execution = Execution(_execution_token, prepared, providers, state, admitted._root, read.state, None)
    return _advance(execution)


def resume(execution: Execution, observation: ExecutionObservation) -> Progress | RunFailure:
    pending = execution.pending
    if pending is None:
        return RunFailure(InvalidPlan("only pending executions may resume"), execution.network)
    if isinstance(pending, PendingStart) and isinstance(observation, StartObservation):
        started_result = ne.observe_start(execution.network, pending.prepared, observation.observation)
        if isinstance(started_result, ne.NetworkStarted):
            next_pending = PendingResponse(pending.invocation, pending.arms, pending.owner, started_result.started)
            next_execution = _replace_execution(execution, network=started_result.state, pending=next_pending)
            return Pending(next_execution, Observe(started_result.started))
        if isinstance(started_result, ne.NetworkTerminalResult):
            return RunFailure(NetworkTerminalFailure(started_result.settled.terminal), started_result.state)
        return RunFailure(NetworkFailure(started_result.failure), started_result.state)
    if isinstance(pending, PendingResponse) and isinstance(observation, HostObservation):
        host_result = ne.observe(execution.network, observation.observation)
        if isinstance(host_result, ne.NetworkPending):
            next_pending = PendingResponse(pending.invocation, pending.arms, pending.owner, host_result.started)
            return Pending(_replace_execution(execution, network=host_result.state, pending=next_pending), Observe(host_result.started))
        if isinstance(host_result, ne.NetworkTerminalResult):
            terminal = host_result.settled.terminal
            if not isinstance(terminal.outcome, ne.Response):
                return RunFailure(NetworkTerminalFailure(terminal), host_result.state)
            decoded = pending.owner.decode(terminal.outcome.response)
            if isinstance(decoded, ExecutionFailure):
                return RunFailure(decoded, host_result.state)
            next_execution = _replace_execution(execution, network=host_result.state, pending=None)
            signature = next((item for item in execution.prepared.input.signatures if item.reference == pending.invocation.function), None)
            if signature is None:
                return RunFailure(InvalidPlan("function identity mismatch"), host_result.state)
            accepted = _accept_outcome(next_execution, signature, pending.invocation, pending.arms, decoded)
            if isinstance(accepted, ExecutionFailure):
                return RunFailure(accepted, host_result.state)
            return _advance(accepted)
        if isinstance(host_result, (ne.Duplicate, ne.NetworkLate)):
            return Pending(_replace_execution(execution, network=host_result.state), Observe(pending.started))
        if isinstance(host_result, ne.NetworkRejected):
            return RunFailure(NetworkFailure(host_result.failure), host_result.state)
    return RunFailure(InvalidPlan("network observation kind mismatch"), execution.network)


__all__ = [
    "ExecutionFailure", "ValueFailure", "MissingArgument", "ArgumentCoverage", "MissingValue", "MissingProvider",
    "ProviderCoverage", "ProviderEffect", "ProviderFailure", "InvalidOutcome", "ResourceFailure", "InvalidPlan",
    "NetworkFailure", "NetworkTerminalFailure", "CallResult", "NetworkOwner", "NetworkInput", "NetworkOutput",
    "NetworkTransport", "PreparedCall", "ReadyCall", "CompletedCall", "NetworkBinding", "PreparedNetworkOwner",
    "PureProvider", "PreparedHttpProvider", "Provider", "ExecutionResult", "Success", "DeclaredFailure",
    "RuntimeState", "RunFailure", "NetworkInstruction", "Send", "Observe", "ExecutionObservation",
    "StartObservation", "HostObservation", "PendingNetwork", "PendingStart", "PendingResponse", "Execution",
    "Progress", "Completed", "Pending", "AdmittedComposition", "start", "resume",
    "ProviderCallback", "EncodeCallback", "DecodeCallback",
]
