# SPDX-FileCopyrightText: 2026 barineco
# SPDX-License-Identifier: MIT

"""Test-side encoder that turns a decoded composition problem back into its wire document."""

from __future__ import annotations

import copy
from collections.abc import Mapping, Sequence
from typing import cast

from necoherence.composition_wire_base import (
    encode_function_ref,
    encode_guard_arm,
    encode_path_step,
    encode_resource_lot_ref,
    encode_slot_contract,
    encode_slot_value,
    wire_fields,
    wire_tuple,
    wire_unit,
)
from necoherence.semantic_composition import (
    AnyCompatible,
    AnyResourceIdentity,
    ArgumentSource,
    CompositionEffect,
    CompositionInput,
    ConstructionRule,
    DeclaredGuard,
    DeclaredTransformForm,
    ExactResourceIdentity,
    FailureEmbedding,
    FieldConstraint,
    FieldPresence,
    FunctionFailureOrigin,
    FunctionSignature,
    GoalPort,
    GoalSpec,
    GuardFailureOrigin,
    InitialInput,
    InitialOnly,
    InitialResourceProducer,
    InputPort,
    InvocationDomain,
    InvocationResourceProducer,
    InvocationSite,
    OperationFunctionForm,
    OutcomeContract,
    OutcomeForm,
    OutputPort,
    PermittedProjection,
    PureFunctionForm,
    ResourceBounds,
    ResourceGoal,
    ResourceLot,
    ResourceRequirement,
    SearchBounds,
    SelectionPolicy,
    SourceConstraint,
    UnitGuardKind,
    ValidateGuardKind,
)
from necoherence.signature_composition_wire import (
    CauseBinding,
    Json,
    _encode_outcome_cause,
    _encode_resource_production,
)
from necoherence.signature_values import WireFailure
from necoherence.type_signatures import signature_basis
from necoherence.typed_mapping import BindingMode


def encode_problem(
    library: Mapping[str, object], input_value: CompositionInput, causes: Sequence[CauseBinding]
) -> dict[str, Json]:
    encoded_signatures: list[Json] = []
    for function in input_value.signatures:
        encoded = _encode_function_signature(function)
        outcomes = cast(list[Json], encoded["outcomes"])
        for index, outcome in enumerate(function.outcomes):
            cause = next(
                (binding.cause for binding in causes if binding.function == function.reference and binding.outcome == outcome.id),
                None,
            )
            if cause is None:
                raise WireFailure("Syntax", "$.signatures.outcomes.cause", "missing outcome cause")
            outcome_row = cast(dict[str, Json], outcomes[index])
            outcome_row["cause"] = _encode_outcome_cause(cause)
        encoded_signatures.append(encoded)
    return {
        "identity": input_value.identity,
        "revision": input_value.revision,
        "basis": cast(Json, copy.deepcopy(signature_basis(library, []))),
        "signatures": encoded_signatures,
        "initial_inputs": [_encode_initial_input(value) for value in input_value.initial_inputs],
        "initial_resources": [_encode_resource_lot(value) for value in input_value.initial_resources],
        "goal": _encode_goal_spec(input_value.goal),
        "invocation_domain": _encode_invocation_domain(input_value.invocation_domain),
        "allowed_effects": [wire_unit(_effect_tag(value)) for value in input_value.allowed_effects],
        "explicit_order": [[before.value, after.value] for before, after in input_value.explicit_order],
        "selection_policy": None if input_value.selection_policy is None else wire_unit(_selection_tag(input_value.selection_policy)),
        "bounds": _encode_search_bounds(input_value.bounds),
    }


def _encode_source_constraint(value: SourceConstraint) -> dict[str, Json]:
    if isinstance(value, AnyCompatible):
        return wire_unit("AnyCompatible")
    if isinstance(value, InitialOnly):
        return wire_fields("InitialOnly", {"input": value.id.value, "path": [encode_path_step(item) for item in value.path]})
    return wire_fields("ProducedBy", {"site": value.site.value, "outcome": value.outcome.value, "port": value.port.value, "path": [encode_path_step(item) for item in value.path]})


def _encode_resource_producer(value: InitialResourceProducer | InvocationResourceProducer) -> dict[str, Json]:
    if isinstance(value, InitialResourceProducer):
        return wire_fields("Initial", {"identity": value.identity, "revision": value.revision})
    return wire_fields("InvocationOutcome", {"site": value.site.value, "outcome": value.outcome.value})


def _encode_resource_identity(value: AnyResourceIdentity | ExactResourceIdentity) -> dict[str, Json]:
    return wire_unit("Any") if isinstance(value, AnyResourceIdentity) else wire_tuple("Exactly", _encode_resource_producer(value.producer))


def _encode_resource_lot(value: ResourceLot) -> dict[str, Json]:
    return {"id": value.id.value, "token_type": value.token_type.definition_name, "producer": _encode_resource_producer(value.producer), "revision": str(value.revision), "quantity": str(value.quantity), "provenance": value.provenance}


def _encode_resource_requirement(value: ResourceRequirement) -> dict[str, Json]:
    return {"id": value.id.value, "token_type": value.token_type.definition_name, "mode": wire_unit("Read" if value.mode is BindingMode.READ else "Consume"), "multiplicity": str(value.multiplicity), "required_revision": str(value.required_revision), "identity": _encode_resource_identity(value.identity)}


def _encode_initial_input(value: InitialInput) -> dict[str, Json]:
    source = wire_unit("Argument") if isinstance(value.source, ArgumentSource) else wire_tuple("SuppliedValue", encode_slot_value(value.source.value))
    return {"id": value.id.value, "contract": encode_slot_contract(value.contract), "source": source, "resource": None if value.resource is None else value.resource.value}


def _encode_input_port(value: InputPort) -> dict[str, Json]:
    return {"id": value.id.value, "contract": encode_slot_contract(value.contract), "source_constraint": _encode_source_constraint(value.source_constraint), "resource_requirement": None if value.resource_requirement is None else value.resource_requirement.value}


def _encode_output_port(value: OutputPort) -> dict[str, Json]:
    return {"id": value.id.value, "contract": encode_slot_contract(value.contract), "resource_production": None if value.resource_production is None else value.resource_production.value}


def _encode_outcome(value: OutcomeContract) -> dict[str, Json]:
    return {"id": value.id.value, "form": wire_unit("Success" if value.form is OutcomeForm.SUCCESS else "DeclaredFailure"), "value_ports": [_encode_output_port(item) for item in value.value_ports], "produced_resources": [_encode_resource_production(item) for item in value.produced_resources]}


def _encode_function_form(value: PureFunctionForm | DeclaredTransformForm | OperationFunctionForm) -> dict[str, Json]:
    if isinstance(value, PureFunctionForm):
        return wire_unit("Pure")
    if isinstance(value, DeclaredTransformForm):
        return wire_unit("DeclaredTransform")
    return wire_tuple("Operation", value.definition.name)


def _effect_tag(value: CompositionEffect) -> str:
    return {CompositionEffect.PURE_FUNCTION: "PureFunction", CompositionEffect.HTTP_REQUEST_RESPONSE: "HttpRequestResponse", CompositionEffect.DATA_ONLY: "DataOnly"}[value]


def _encode_failure_origin(value: FunctionFailureOrigin | GuardFailureOrigin) -> dict[str, Json]:
    if isinstance(value, FunctionFailureOrigin):
        return wire_fields("Function", {"function": encode_function_ref(value.function), "outcome": value.outcome.value})
    return wire_fields("Guard", {"guard": value.guard.value, "arm": encode_guard_arm(value.arm)})


def _encode_function_signature(value: FunctionSignature) -> dict[str, Json]:
    return {"reference": encode_function_ref(value.reference), "form": _encode_function_form(value.form), "effect": wire_unit(_effect_tag(value.effect)), "inputs": [_encode_input_port(item) for item in value.inputs], "outcomes": [_encode_outcome(item) for item in value.outcomes], "resource_inputs": [_encode_resource_requirement(item) for item in value.resource_inputs], "assumption_ref": value.assumption_ref, "handles_failure": None if value.handles_failure is None else _encode_failure_origin(value.handles_failure)}


def _encode_invocation_site(value: InvocationSite) -> dict[str, Json]:
    return {"id": value.id.value, "function": encode_function_ref(value.function)}


def _encode_projection(value: PermittedProjection) -> dict[str, Json]:
    return {"source_type": value.source_type.definition_name, "path": [encode_path_step(item) for item in value.path]}


def _encode_guard_kind(value: UnitGuardKind | ValidateGuardKind) -> dict[str, Json]:
    if value is UnitGuardKind.PRESENCE:
        return wire_unit("Presence")
    if value is UnitGuardKind.VARIANTS:
        return wire_unit("Variants")
    return wire_tuple("Validate", encode_slot_contract(value.contract))


def _encode_guard(value: DeclaredGuard) -> dict[str, Json]:
    return {"id": value.id.value, "source_type": value.source_type.definition_name, "path": [encode_path_step(item) for item in value.path], "kind": _encode_guard_kind(value.kind)}


def _encode_field_constraint(value: FieldConstraint) -> dict[str, Json]:
    return {"field": value.field, "source": _encode_source_constraint(value.source), "presence": wire_unit("Required" if value.presence is FieldPresence.REQUIRED else "Optional")}


def _encode_construction(value: ConstructionRule) -> dict[str, Json]:
    return {"identity": value.identity, "type_id": value.type_ref.definition_name, "nested_fields": [[name, nested] for name, nested in value.nested_fields], "field_constraints": [_encode_field_constraint(item) for item in value.field_constraints]}


def _encode_invocation_domain(value: InvocationDomain) -> dict[str, Json]:
    return {"identity": value.identity, "revision": value.revision, "sites": [_encode_invocation_site(item) for item in value.sites], "permitted_projections": [_encode_projection(item) for item in value.permitted_projections], "permitted_constructions": [_encode_construction(item) for item in value.permitted_constructions], "permitted_transforms": [encode_function_ref(item) for item in value.permitted_transforms], "guards": [_encode_guard(item) for item in value.guards]}


def _encode_resource_goal(value: ResourceGoal) -> dict[str, Json]:
    return {"lot": encode_resource_lot_ref(value.lot), "multiplicity": str(value.multiplicity), "revision": str(value.revision)}


def _encode_goal_port(value: GoalPort) -> dict[str, Json]:
    return {"id": value.id.value, "contract": encode_slot_contract(value.contract), "source_constraint": _encode_source_constraint(value.source_constraint)}


def _encode_failure_embedding(value: FailureEmbedding) -> dict[str, Json]:
    return {"id": value.id.value, "origin": _encode_failure_origin(value.origin), "contract": encode_slot_contract(value.contract), "final_resources": [_encode_resource_goal(item) for item in value.final_resources]}


def _encode_goal_spec(value: GoalSpec) -> dict[str, Json]:
    return {"outputs": [_encode_goal_port(item) for item in value.outputs], "failures": [_encode_failure_embedding(item) for item in value.failures], "final_resources": [_encode_resource_goal(item) for item in value.final_resources]}


def _selection_tag(value: SelectionPolicy) -> str:
    return "RequireUnique" if value is SelectionPolicy.REQUIRE_UNIQUE else "AnyFeasible"


def _encode_resource_bounds(value: ResourceBounds) -> dict[str, Json]:
    return {"max_bindings": str(value.max_bindings), "max_search_steps": str(value.max_search_steps), "max_tokens": str(value.max_tokens)}


def _encode_search_bounds(value: SearchBounds) -> dict[str, Json]:
    return {"max_expanded_states": str(value.max_expanded_states), "max_binding_candidates": str(value.max_binding_candidates), "max_type_obligations": str(value.max_type_obligations), "max_branch_nodes": str(value.max_branch_nodes), "resource_bounds": None if value.resource_bounds is None else _encode_resource_bounds(value.resource_bounds), "max_sample_length": str(value.max_sample_length)}
