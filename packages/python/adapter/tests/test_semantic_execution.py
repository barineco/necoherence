# SPDX-FileCopyrightText: 2026 barineco
# SPDX-License-Identifier: MIT

from __future__ import annotations

import copy
import json
from collections.abc import Mapping
from dataclasses import fields, is_dataclass, replace
from pathlib import Path
from typing import cast

import pytest

from necoherence import network_effect as ne
from necoherence import semantic_composition as sc
from necoherence import semantic_execution as se
from necoherence.request_progression import ExecutionHandle, RequestIdentity
from necoherence.signature_values import CertificateMismatchFailure, UnresolvedValueFailure, ValueContext
from necoherence.signature_composition_wire import decode_problem, prepare_composition_input
from necoherence.type_signatures import _graph, signature_basis
from necoherence.typed_mapping import BindingMode
from composition_fixtures import plan_of, prepared_input, resource_invocation_fixture, signature_type_ref


def _mutable_copy(value: object) -> object:
    if isinstance(value, Mapping):
        return {key: _mutable_copy(item) for key, item in value.items()}
    if isinstance(value, list):
        return [_mutable_copy(item) for item in value]
    if isinstance(value, tuple):
        return tuple(_mutable_copy(item) for item in value)
    if is_dataclass(value) and not isinstance(value, type):
        return replace(value, **{
            field.name: _mutable_copy(getattr(value, field.name)) for field in fields(value)
        })
    return copy.deepcopy(value)


def test_variant_guard_uses_selected_branch_and_preserves_absent_and_null() -> None:
    exchange = json.loads(
        (Path(__file__).parent / "fixtures/variant-guard-incomplete-coverage.json").read_text()
    )
    graph = _graph(exchange["signatures"])
    values = ValueContext(graph)
    problem, causes = decode_problem(exchange["signatures"], exchange["composition"]["problem"])
    prepared = prepare_composition_input(
        exchange["signatures"], signature_basis(exchange["signatures"], [])["graph_sha256"], problem, causes
    )
    assert isinstance(prepared, sc.PreparedCompositionInput)
    guard = prepared.input.invocation_domain.guards[0]

    assert se._inspect_guard(values, guard, sc.ABSENT_VALUE) is sc.UnitGuardArm.ABSENT
    assert se._inspect_guard(values, guard, sc.NULL_VALUE) is sc.UnitGuardArm.NULL
    assert se._inspect_guard(values, guard, sc.PresentValue({"kind": "other"})) == sc.VariantGuardArm("otherwise")
    assert se._inspect_guard(values, guard, sc.PresentValue({})) == se.InvalidPlan("union guard discriminator")


def _admit(prepared: sc.PreparedCompositionInput, plan: sc.CompositionPlan) -> se.AdmittedComposition:
    return se.AdmittedComposition(se._admission_token, prepared, plan)


def test_admitted_composition_construction_requires_the_admission_token() -> None:
    prepared = prepared_input()
    with pytest.raises(TypeError):
        se.AdmittedComposition(object(), prepared, plan_of(prepared))
    with pytest.raises(TypeError):
        se.AdmittedComposition(None, prepared, plan_of(prepared))  # type: ignore[arg-type]
    assert not hasattr(se, "admitted_composition")
    assert "admitted_composition" not in se.__all__


def checked_input() -> tuple[sc.PreparedCompositionInput, se.AdmittedComposition]:
    prepared = prepared_input()
    return prepared, _admit(prepared, plan_of(prepared))


def _prepared_with(prepared: sc.PreparedCompositionInput, input_value: sc.CompositionInput) -> sc.PreparedCompositionInput:
    result = sc.prepare_direct_composition(
        prepared.graph, input_value, prepared.operation_checker, prepared.operation_meaning
    )
    assert isinstance(result, sc.PreparedCompositionInput)
    return result


def _checked_tree(prepared: sc.PreparedCompositionInput, tree: sc.PlanTree) -> se.AdmittedComposition:
    return _admit(prepared, sc.CompositionPlan(prepared.input.identity, prepared.input.revision, tree))


def _return_tree(prepared: sc.PreparedCompositionInput, rank: int = 1) -> sc.ReturnPlanTree:
    root = plan_of(prepared).root
    assert isinstance(root, sc.ReturnPlanTree)
    return replace(root, rank=rank)


def _prepared_operation(
    prepared: sc.PreparedCompositionInput,
    signature: sc.FunctionSignature,
    *,
    failures: tuple[sc.FailureEmbedding, ...] = (),
) -> sc.PreparedCompositionInput:
    site = sc.InvocationSite(sc.SiteId(signature.reference.identity), signature.reference)
    input_value = replace(
        prepared.input,
        signatures=(signature,),
        allowed_effects=(signature.effect,),
        goal=replace(prepared.input.goal, failures=failures),
        invocation_domain=replace(prepared.input.invocation_domain, sites=(site,)),
    )
    return _prepared_with(prepared, input_value)


def _attempt_input() -> ne.AttemptInput:
    attempt = ne.AttemptIdentity(RequestIdentity("semantic", "http", 1), 0)
    return ne.AttemptInput(
        attempt,
        ne.HttpWireInstruction("GET", "http://127.0.0.1/test", (), b""),
        None,
        ne.HostConfiguration(8, 8),
    )


def _http_checked() -> tuple[se.AdmittedComposition, sc.FunctionRef, sc.OutcomeId]:
    prepared, _ = checked_input()
    function = sc.FunctionRef("http", "1", "0" * 64)
    outcome = sc.OutcomeId("success")
    signature = sc.FunctionSignature(
        function,
        sc.OperationFunctionForm(sc.DefinitionRef({}, "http")),
        sc.CompositionEffect.HTTP_REQUEST_RESPONSE,
        (),
        (sc.OutcomeContract(outcome, sc.OutcomeForm.SUCCESS, (), ()),),
        (),
        "provider",
    )
    prepared = _prepared_operation(prepared, signature)
    invocation = sc.InvocationPlan(sc.SiteId("http"), function, (), ())
    tree = sc.InvokePlanTree(0, invocation, ((outcome, _return_tree(prepared)),), ())
    return _checked_tree(prepared, tree), function, outcome


def test_checked_pure_composition_completes_synchronously() -> None:
    _, checked = checked_input()
    result = se.start(checked, (), (), ne.empty_network_state())
    assert result == se.Completed(
        se.Success(((sc.GoalPortId("goal"), sc.PresentValue(False)),)), ne.empty_network_state()
    )


def test_pure_provider_outcome_advances_to_the_verified_return() -> None:
    prepared, _ = checked_input()
    function = sc.FunctionRef("pure", "1", "0" * 64)
    outcome = sc.OutcomeId("success")
    signature = sc.FunctionSignature(
        function, sc.PURE_FUNCTION_FORM, sc.CompositionEffect.PURE_FUNCTION, (),
        (sc.OutcomeContract(outcome, sc.OutcomeForm.SUCCESS, (), ()),), (), "provider",
    )
    prepared = _prepared_operation(prepared, signature)
    tree = sc.InvokePlanTree(
        0, sc.InvocationPlan(sc.SiteId("pure"), function, (), ()),
        ((outcome, _return_tree(prepared)),), (),
    )
    provider = se.Provider(function, se.PureProvider(lambda _: se.CallResult(outcome, ())))
    result = se.start(_checked_tree(prepared, tree), (provider,), (), ne.empty_network_state())
    assert isinstance(result, se.Completed)
    assert result.result == se.Success(((sc.GoalPortId("goal"), sc.PresentValue(False)),))


def test_pure_provider_output_type_mismatch_is_a_value_failure() -> None:
    prepared, _ = checked_input()
    function = sc.FunctionRef("pure", "1", "0" * 64)
    outcome_id = sc.OutcomeId("success")
    port = sc.OutputPort(sc.PortId("value"), prepared.input.goal.outputs[0].contract, None)
    signature = sc.FunctionSignature(
        function, sc.PURE_FUNCTION_FORM, sc.CompositionEffect.PURE_FUNCTION, (),
        (sc.OutcomeContract(outcome_id, sc.OutcomeForm.SUCCESS, (port,), ()),), (), "provider",
    )
    prepared = _prepared_operation(prepared, signature)
    tree = sc.InvokePlanTree(
        0, sc.InvocationPlan(sc.SiteId("pure"), function, (), ()),
        ((outcome_id, _return_tree(prepared)),), (),
    )
    provider = se.Provider(
        function,
        se.PureProvider(lambda _: se.CallResult(outcome_id, ((port.id, sc.PresentValue("wrong")),))),
    )
    result = se.start(_checked_tree(prepared, tree), (provider,), (), ne.empty_network_state())
    assert isinstance(result, se.RunFailure)
    assert isinstance(result.cause, se.ValueFailure)


def test_initial_state_reports_missing_and_duplicate_arguments() -> None:
    prepared, _ = checked_input()
    initial = prepared.input.initial_inputs[0]
    prepared = _prepared_with(
        prepared, replace(prepared.input, initial_inputs=(replace(initial, source=sc.ARGUMENT_SOURCE),))
    )
    assert se._initial_state(prepared, ()) == se.MissingArgument(initial.id)
    assert se._initial_state(
        prepared,
        ((initial.id, sc.PresentValue(False)), (initial.id, sc.PresentValue(False))),
    ) == se.ArgumentCoverage("unique declared argument identifiers required")


def test_projection_and_output_validation_fail_with_lean_conditions() -> None:
    prepared, _ = checked_input()
    assert se._project("kind", sc.PresentValue([]), (sc.IndexStep(0),)) == se.InvalidPlan(
        "array projection outside value"
    )
    invalid = se._validate(prepared.values, prepared.input.goal.outputs[0].contract, sc.PresentValue("wrong"))
    assert isinstance(invalid, se.ValueFailure)
    graph = _mutable_copy(prepared.graph)
    assert isinstance(graph, dict)
    nodes = graph["nodes"]
    assert isinstance(nodes, list)
    nodes.append({
        "id": "opaque",
        "reference": {
            "source": {"repository": "test", "revision": "1", "path": "", "content_digest": "", "document_id": "", "declared_revision": None},
            "definition_name": "opaque", "pointer": [],
        },
        "shape": {"tag": "Opaque", "value": {"name": "opaque"}},
    })
    contract = sc.SlotContract(signature_type_ref("opaque"), True, False)
    values = ValueContext(graph)
    assert isinstance(sc.accepts_slot(values, contract, sc.PresentValue(False)), sc.ValueUnresolved)
    unresolved = se._validate(values, contract, sc.PresentValue(False))
    assert isinstance(unresolved, se.ValueFailure)
    assert isinstance(unresolved.failure, UnresolvedValueFailure)
    guard = sc.DeclaredGuard(sc.GuardId("validate"), contract.type_ref, (), sc.ValidateGuardKind(contract))
    inspected = se._inspect_guard(values, guard, sc.PresentValue(False))
    assert isinstance(inspected, se.ValueFailure)
    assert isinstance(inspected.failure, UnresolvedValueFailure)


def test_checked_composition_owns_immutable_prepared_values() -> None:
    original = prepared_input()
    graph = _mutable_copy(original.graph)
    input_value = _mutable_copy(original.input)
    assert isinstance(graph, dict)
    assert isinstance(input_value, sc.CompositionInput)
    prepared = sc.prepare_direct_composition(
        graph, input_value, original.operation_checker, original.operation_meaning
    )
    assert isinstance(prepared, sc.PreparedCompositionInput)
    checked = _admit(prepared, plan_of(prepared))
    before = se.start(checked, (), (), ne.empty_network_state())
    assert isinstance(before, se.Completed)

    nodes = graph["nodes"]
    assert isinstance(nodes, list)
    node = nodes[0]
    assert isinstance(node, dict)
    shape = node["shape"]
    assert isinstance(shape, dict)
    shape["tag"] = "String"
    source = input_value.goal.outputs[0].contract.type_ref.source
    assert isinstance(source, dict)
    source["repository"] = "forged"

    assert se.start(checked, (), (), ne.empty_network_state()) == before
    immutable_graph = cast(dict[str, object], prepared.graph)
    with pytest.raises(TypeError):
        immutable_graph["nodes"] = ()
    immutable_nodes = cast(list[object], prepared.graph["nodes"])
    with pytest.raises(TypeError):
        immutable_nodes.append({})


def test_presence_guard_selects_all_three_arms() -> None:
    prepared, _ = checked_input()
    source_type = prepared.input.initial_inputs[0].contract.type_ref
    guard = sc.DeclaredGuard(sc.GuardId("presence"), source_type, (), sc.UnitGuardKind.PRESENCE)
    assert se._inspect_guard(prepared.values, guard, sc.ABSENT_VALUE) is sc.UnitGuardArm.ABSENT
    assert se._inspect_guard(prepared.values, guard, sc.NULL_VALUE) is sc.UnitGuardArm.NULL
    assert se._inspect_guard(prepared.values, guard, sc.PresentValue(False)) is sc.UnitGuardArm.PRESENT


def test_guard_plan_advances_through_the_selected_arm() -> None:
    prepared, _ = checked_input()
    initial = prepared.input.initial_inputs[0]
    guard = sc.DeclaredGuard(sc.GuardId("presence"), initial.contract.type_ref, (), sc.UnitGuardKind.PRESENCE)
    prepared = _prepared_with(
        prepared,
        replace(prepared.input, invocation_domain=replace(prepared.input.invocation_domain, guards=(guard,))),
    )
    tree = sc.GuardPlanTree(
        0, guard.id, sc.ValueRef(sc.InitialProducer(initial.id), ()),
        ((sc.UnitGuardArm.PRESENT, _return_tree(prepared)),),
    )
    result = se.start(_checked_tree(prepared, tree), (), (), ne.empty_network_state())
    assert isinstance(result, se.Completed)


def test_declared_provider_outcome_advances_to_failure_return() -> None:
    prepared, _ = checked_input()
    initial = prepared.input.initial_inputs[0]
    function = sc.FunctionRef("pure", "1", "0" * 64)
    outcome = sc.OutcomeId("declared")
    success = sc.OutcomeId("success")
    embedding = sc.FailureEmbedding(
        sc.FailureEmbeddingId("failure"), sc.FunctionFailureOrigin(function, outcome), initial.contract, ()
    )
    signature = sc.FunctionSignature(
        function, sc.PURE_FUNCTION_FORM, sc.CompositionEffect.PURE_FUNCTION, (),
        (sc.OutcomeContract(
            outcome, sc.OutcomeForm.DECLARED_FAILURE,
            (sc.OutputPort(sc.PortId("failure"), initial.contract, None),), (),
        ), sc.OutcomeContract(success, sc.OutcomeForm.SUCCESS, (), ())), (), "provider",
    )
    prepared = _prepared_operation(prepared, signature, failures=(embedding,))
    invocation = sc.InvocationPlan(sc.SiteId("pure"), function, (), ())
    terminal = sc.FailureReturnPlan(embedding.id, sc.SourceBindingExpr(
        sc.ValueRef(sc.InitialProducer(initial.id), ()), sc.project_slot(initial.contract, (), (), prepared.values),
        sc.SuppliedValueCompatibility(sc.PresentValue(False)),
    ))
    tree = sc.InvokePlanTree(
        0, invocation,
        ((outcome, sc.ReturnPlanTree(1, terminal)), (success, _return_tree(prepared))), (),
    )
    provider = se.Provider(
        function,
        se.PureProvider(lambda _: se.CallResult(outcome, ((sc.PortId("failure"), sc.PresentValue(False)),))),
    )
    result = se.start(_checked_tree(prepared, tree), (provider,), (), ne.empty_network_state())
    assert isinstance(result, se.Completed)
    assert result.result == se.DeclaredFailure(embedding.id, sc.PresentValue(False))


def test_provider_coverage_and_effect_match_lean_validation() -> None:
    prepared, _ = checked_input()
    reference = sc.FunctionRef("function", "1", "0" * 64)
    signature = sc.FunctionSignature(
        reference, sc.PURE_FUNCTION_FORM, sc.CompositionEffect.PURE_FUNCTION, (),
        (sc.OutcomeContract(sc.OutcomeId("success"), sc.OutcomeForm.SUCCESS, (), ()),),
        (), "provider"
    )
    prepared = _prepared_operation(prepared, signature)
    assert se._validate_providers(prepared, ()) == se.ProviderCoverage("exact provider coverage required")
    provider = se.Provider(
        reference,
        se.PreparedHttpProvider(se.PreparedNetworkOwner(lambda _: se.InvalidPlan("unused"), lambda _: se.InvalidPlan("unused"))),
    )
    assert se._validate_providers(prepared, (provider,)) == se.ProviderEffect(reference)


def _http_provider(outcome: sc.OutcomeId) -> se.ProviderImplementation:
    return se.PreparedHttpProvider(
        se.PreparedNetworkOwner(
            lambda _: se.ReadyCall(_attempt_input()), lambda _: se.CallResult(outcome, ())
        )
    )


def test_http_start_returns_send_then_start_observation_returns_observe() -> None:
    checked, function, outcome = _http_checked()
    sent = se.start(checked, (se.Provider(function, _http_provider(outcome)),), (), ne.empty_network_state())
    assert isinstance(sent, se.Pending) and isinstance(sent.instruction, se.Send)
    handle = ExecutionHandle("handle")
    started = se.resume(sent.execution, se.StartObservation(ne.Started(_attempt_input().attempt, handle)))
    assert isinstance(started, se.Pending)
    assert started.instruction == se.Observe(ne.StartedAttempt(sent.instruction.command.prepared, handle))


def test_http_response_resumes_the_remaining_verified_plan() -> None:
    checked, function, outcome = _http_checked()
    sent = se.start(checked, (se.Provider(function, _http_provider(outcome)),), (), ne.empty_network_state())
    assert isinstance(sent, se.Pending)
    handle = ExecutionHandle("handle")
    started = se.resume(sent.execution, se.StartObservation(ne.Started(_attempt_input().attempt, handle)))
    assert isinstance(started, se.Pending)
    response = ne.ResponseObservation(
        _attempt_input().attempt, handle, 0, ne.RawHttpResponse(200, (), b""),
        ne.HeaderProvenance.LIBRARY_NORMALIZED, ne.Unknown(ne.UnknownEffectReason.NO_RESPONSE),
    )
    completed = se.resume(started.execution, se.HostObservation(ne.DeliveredObservation(0, response)))
    assert isinstance(completed, se.Completed)
    assert completed.result == se.Success(((sc.GoalPortId("goal"), sc.PresentValue(False)),))


def test_duplicate_and_late_observations_preserve_pending_instruction() -> None:
    checked, function, outcome = _http_checked()
    sent = se.start(checked, (se.Provider(function, _http_provider(outcome)),), (), ne.empty_network_state())
    assert isinstance(sent, se.Pending)
    handle = ExecutionHandle("handle")
    started = se.resume(sent.execution, se.StartObservation(ne.Started(_attempt_input().attempt, handle)))
    assert isinstance(started, se.Pending)
    response = ne.ResponseObservation(
        _attempt_input().attempt, handle, 1, ne.RawHttpResponse(200, (), b""),
        ne.HeaderProvenance.LIBRARY_NORMALIZED, ne.Unknown(ne.UnknownEffectReason.NO_RESPONSE),
    )
    rejected = se.resume(started.execution, se.HostObservation(ne.DeliveredObservation(1, response)))
    assert isinstance(rejected, se.RunFailure)
    assert isinstance(rejected.cause, se.NetworkFailure)


def test_resume_without_pending_and_wrong_observation_kind_fail() -> None:
    prepared, _ = checked_input()
    with pytest.raises(TypeError, match="execution requires start or resume"):
        se.Execution(object(), prepared, (), se.RuntimeState((), ()), _return_tree(prepared), ne.empty_network_state(), None)
    checked, function, outcome = _http_checked()
    sent = se.start(checked, (se.Provider(function, _http_provider(outcome)),), (), ne.empty_network_state())
    assert isinstance(sent, se.Pending)
    wrong = se.resume(
        sent.execution,
        se.HostObservation(ne.PendingObservation(_attempt_input().attempt, ExecutionHandle("wrong-kind"))),
    )
    assert wrong == se.RunFailure(se.InvalidPlan("network observation kind mismatch"), sent.execution.network)


def test_precompleted_provider_returns_no_network_instruction() -> None:
    checked, function, outcome = _http_checked()
    provider = se.Provider(
        function,
        se.PreparedHttpProvider(
            se.PreparedNetworkOwner(
                lambda _: se.CompletedCall(se.CallResult(outcome, ())), lambda _: se.InvalidPlan("unused")
            )
        ),
    )
    result = se.start(checked, (provider,), (), ne.empty_network_state())
    assert isinstance(result, se.Completed)


def test_variant_projection_on_a_non_object_is_a_shape_mismatch() -> None:
    assert se._project("kind", sc.PresentValue([]), (sc.VariantStep("kind"),)) == se.InvalidPlan(
        "projection shape mismatch"
    )
    assert se._project("kind", sc.PresentValue({"kind": "other"}), (sc.VariantStep("kind"),)) == se.InvalidPlan(
        "variant projection mismatch"
    )


def test_consume_reduces_every_entry_of_the_bound_lot() -> None:
    prepared, invocation = resource_invocation_fixture("lot", 0, 0, "requirement")
    signature = prepared.input.signatures[0]
    consuming = replace(
        signature,
        resource_inputs=(replace(signature.resource_inputs[0], mode=BindingMode.CONSUME),),
    )
    initial = se._initial_state(prepared, ())
    assert isinstance(initial, se.RuntimeState)
    state = replace(initial, resources=(*initial.resources, *initial.resources))
    bound = se._bind_resources(consuming, invocation, state)
    assert isinstance(bound, se.RuntimeState)
    assert [lot.quantity for _, lot in bound.resources] == [0, 0]


def test_guard_certificate_mismatch_is_a_failure_not_a_rejection(monkeypatch: pytest.MonkeyPatch) -> None:
    prepared, _ = checked_input()
    contract = prepared.input.initial_inputs[0].contract
    guard = sc.DeclaredGuard(sc.GuardId("validate"), contract.type_ref, (), sc.ValidateGuardKind(contract))
    mismatch = se.ValueFailure(CertificateMismatchFailure("contract or value"))
    monkeypatch.setattr(se, "_validate", lambda _graph, _contract, _value: mismatch)
    assert se._inspect_guard(prepared.values, guard, sc.PresentValue(False)) == mismatch
