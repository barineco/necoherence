# SPDX-FileCopyrightText: 2026 barineco
# SPDX-License-Identifier: MIT

"""Closed JSON wire for semantic composition inputs."""

from __future__ import annotations

import copy
from collections.abc import Callable, Mapping, Sequence
from dataclasses import dataclass
from typing import TypeAlias, cast

from . import semantic_composition as composition
from .semantic_execution import AdmittedComposition, _admission_token

from .semantic_composition import (
    ANY_COMPATIBLE, _type_ref_native, ANY_RESOURCE_IDENTITY, ARGUMENT_SOURCE,
    DECLARED_TRANSFORM_FORM, NULL_VALUE, PURE_FUNCTION_FORM, ABSENT_VALUE, AnyCompatible,
    AnyResourceIdentity, ArgumentSource, CompositionEffect, CompositionInput,
    CompositionInputFailure, ConstructionRule, DeclaredGuard, DeclaredTransformForm, DefinitionRef,
    ExactResourceIdentity, FailureEmbedding, FailureEmbeddingId, FieldConstraint, FieldPresence,
    FieldStep, FunctionFailureOrigin, FunctionRef, FunctionSignature, GoalPort, GoalPortId,
    GoalSpec, GuardFailureOrigin, GuardId, IndexStep, InitialInput, InitialOnly,
    InitialResourceProducer, InvalidLibrary, InvalidSignature, InputId, InputPort,
    InvocationDomain, InvocationResourceProducer, InvocationSite, LotId, OperationFunctionForm,
    OutcomeContract, OutcomeForm, OutcomeId, OutputPort, PermittedProjection, PortId, PresentValue,
    PreparedCompositionInput, ProducedBy, ProductionId, PureFunctionForm, RequirementId,
    ResourceBounds, ResourceGoal, ResourceLot, ResourceProduction, ResourceRequirement,
    SearchBounds, SelectionPolicy, SemanticBasis, SemanticGraph, SiteId, SlotContract, SlotValue,
    SourceConstraint, SuppliedValueSource, TypeRef, UnitGuardArm, UnitGuardKind, ValidateGuardKind,
    VariantGuardArm, VariantStep, _prepare_direct_composition, _immutable_copy,
)
from .signature_values import ValueContext, WireFailure, exact_decode
from .library_check import library_check_failure
from .type_signatures import (
    SOURCE_REF, DeclarationFailure, checkLibrary, outcomeValid, signature_basis,
)
from .declaration_wire import SHAPE, SIGNATURE_BASIS, exact_json
from .profile_wire import PROFILE_REF
from .wire_schema import listed
from .composition_wire_base import (
    INCLUSION_RULE_VALUES, json_equal, decode_function_ref, decode_producer,
    decode_resource_lot_ref, encode_function_ref, encode_guard_arm, encode_path_step,
    encode_resource_lot_ref, encode_slot_contract, encode_slot_value, wire_array, wire_boolean,
    wire_fields, wire_frame, wire_json, wire_key, wire_list, wire_mapping, wire_natural,
    wire_record, wire_string, wire_sum, wire_tag, wire_tuple, wire_unit,
)
from .typed_mapping import BindingMode

Json: TypeAlias = None | bool | int | str | list["Json"] | dict[str, "Json"]


@dataclass(frozen=True, slots=True)
class SourceIdentity:
    repository: str
    revision: str
    path: str
    content_digest: str


@dataclass(frozen=True, slots=True)
class Origin:
    source: SourceIdentity
    locator: tuple[str, ...]


@dataclass(frozen=True, slots=True)
class ValueContractCause:
    origin: Origin


@dataclass(frozen=True, slots=True)
class ExternalConditionCause:
    specification: Origin


OutcomeCause: TypeAlias = ValueContractCause | ExternalConditionCause


@dataclass(frozen=True, slots=True)
class CauseBinding:
    function: FunctionRef
    outcome: OutcomeId
    cause: OutcomeCause


def signature_contract(
    causes: Sequence[CauseBinding], function: FunctionSignature
) -> dict[str, object] | str:
    outcomes: list[dict[str, object]] = []
    for outcome in function.outcomes:
        binding = next(
            (
                item
                for item in causes
                if item.function == function.reference and item.outcome == outcome.id
            ),
            None,
        )
        if binding is None:
            return "missing outcome cause"
        outcomes.append(
            {
                "id": outcome.id.value,
                "form": wire_unit(
                    "Success"
                    if outcome.form is OutcomeForm.SUCCESS
                    else "DeclaredFailure"
                ),
                "cause": _encode_outcome_cause(binding.cause),
                "value_ports": [
                    {"id": port.id.value, "contract": encode_slot_contract(port.contract)}
                    for port in outcome.value_ports
                ],
                "produced_resources": [
                    _encode_resource_production(production)
                    for production in outcome.produced_resources
                ],
            }
        )
    return {
        "effect": wire_unit(
            "HttpRequestResponse"
            if function.effect is CompositionEffect.HTTP_REQUEST_RESPONSE
            else "DataOnly"
        ),
        "inputs": [
            {"id": port.id.value, "contract": encode_slot_contract(port.contract)}
            for port in function.inputs
        ],
        "outcomes": outcomes,
    }


def check_operation(
    library: Mapping[str, object],
    graph_digest: str,
    causes: Sequence[CauseBinding],
    function: FunctionSignature,
    reference: DefinitionRef,
) -> InvalidSignature | None:
    def invalid(reason: str) -> InvalidSignature:
        return InvalidSignature(function.reference, reason)
    definitions = wire_array(library.get("definitions", ()), "library.definitions")
    definition = next(
        (
            wire_mapping(value, "library definition")
            for value in definitions
            if wire_mapping(value, "library definition").get("id") == reference.name
        ),
        None,
    )
    if definition is None:
        return invalid("unresolved operation identity")
    shape = wire_mapping(definition.get("shape"), "definition.shape")
    tag, base = wire_sum(shape, {"Operation": "value", "Value": "value", "Message": "value", "Symbol": "value"}, "definition.shape")
    if tag != "Operation":
        return invalid("definition is not an operation")
    if (
        function.reference.identity != definition.get("wire_identity")
        or function.reference.revision != library.get("revision")
        or function.reference.content_digest != graph_digest
    ):
        return invalid("operation identity basis")
    extended = signature_contract(causes, function)
    if isinstance(extended, str):
        return invalid(extended)
    base_contract = wire_mapping(base, "definition.shape.value")
    base_effect = wire_mapping(base_contract.get("effect"), "operation.effect").get("tag")
    expected = (
        CompositionEffect.HTTP_REQUEST_RESPONSE
        if base_effect == "HttpRequestResponse"
        else CompositionEffect.DATA_ONLY
    )
    if function.effect is not expected:
        return invalid("operation effect")
    if not _operation_extension_valid(base_contract, extended, library):
        return invalid("base outcome preservation or external supplement")
    return None


def prepare_composition_input(
    library: Mapping[str, object],
    graph_digest: str,
    input_value: CompositionInput,
    causes: Sequence[CauseBinding],
) -> PreparedCompositionInput | CompositionInputFailure:
    try:
        checkLibrary(library)
    except DeclarationFailure as failure:
        return InvalidLibrary(library_check_failure(failure.reference, failure.predicate, failure.location))
    for function in input_value.signatures:
        contract = signature_contract(causes, function)
        if isinstance(contract, str):
            return InvalidSignature(function.reference, contract)
        outcomes = wire_array(contract["outcomes"], "contract.outcomes")
        if not all(outcomeValid(library, outcome) for outcome in outcomes):
            return InvalidSignature(function.reference, "outcome cause or external failure value")
    graph = cast(SemanticGraph, _immutable_copy(_graph(library)))
    values = ValueContext(graph)
    def operation_meaning(function: FunctionSignature, _reference: DefinitionRef) -> Sequence[object]:
        references = [port.contract.type_ref for port in function.inputs]
        references.extend(item.token_type for item in function.resource_inputs)
        for outcome in function.outcomes:
            references.extend(port.contract.type_ref for port in outcome.value_ports)
            references.extend(item.token_type for item in outcome.produced_resources)
        return tuple(values.meaning_obligations([_type_ref_native(reference) for reference in references]))
    return _prepare_direct_composition(
        graph,
        values,
        input_value,
        lambda function, reference: check_operation(
            library, graph_digest, causes, function, reference
        ),
        operation_meaning,
    )


def _operation_extension_valid(
    base: Mapping[str, object],
    extended: Mapping[str, object],
    library: Mapping[str, object],
) -> bool:
    if base.get("effect") != extended.get("effect") or base.get("inputs") != extended.get("inputs"):
        return False
    base_outcomes = wire_array(base.get("outcomes", ()), "base.outcomes")
    extended_outcomes = wire_array(extended.get("outcomes", ()), "extended.outcomes")
    identities = [
        wire_mapping(value, "extended outcome").get("id") for value in extended_outcomes
    ]
    if any(not isinstance(identity, str) or not identity for identity in identities):
        return False
    if len(set(identities)) != len(identities):
        return False
    if not all(outcome in extended_outcomes for outcome in base_outcomes):
        return False
    for outcome in extended_outcomes:
        if outcome in base_outcomes:
            continue
        row = wire_mapping(outcome, "extended outcome")
        cause = wire_mapping(row.get("cause"), "extended outcome.cause")
        if cause.get("tag") != "ExternalCondition" or not outcomeValid(library, row):
            return False
    return True


def decode_problem(library: Mapping[str, object], value: object) -> tuple[CompositionInput, tuple[CauseBinding, ...]]:
    return _decode_problem(library, value, signature_basis(library, []))


def _decode_problem(
    library: Mapping[str, object], value: object, library_basis: Mapping[str, object]
) -> tuple[CompositionInput, tuple[CauseBinding, ...]]:
    row = wire_record(
        value,
        (
            "identity",
            "revision",
            "basis",
            "signatures",
            "initial_inputs",
            "initial_resources",
            "goal",
            "invocation_domain",
            "allowed_effects",
            "explicit_order",
            "selection_policy",
            "bounds",
        ),
        "$",
    )
    SIGNATURE_BASIS(row["basis"], "$.basis")
    if row["basis"] != library_basis:
        raise WireFailure("Syntax", "$.basis", "composition signature basis mismatch")
    signature_rows = wire_array(row["signatures"], "$")
    signatures = tuple(_decode_function_signature(item, "$") for item in signature_rows)
    causes_rows: list[CauseBinding] = []
    for raw_signature in signature_rows:
        reference = decode_function_ref(wire_key(raw_signature, "reference", "$"), "$.reference")
        for raw_outcome in wire_array(wire_frame(raw_signature, "outcomes", "$"), "$"):
            outcome_id = OutcomeId(wire_string(wire_key(raw_outcome, "id", "$"), "$.id"))
            causes_rows.append(CauseBinding(reference, outcome_id, _decode_outcome_cause(wire_key(raw_outcome, "cause", "$"), "$.cause")))
    causes = tuple(causes_rows)
    graph = _graph(library)
    return (
        CompositionInput(
            identity=wire_string(row["identity"], "$.identity"),
            revision=wire_string(row["revision"], "$.revision"),
            basis=SemanticBasis.of(graph),
            signatures=signatures,
            initial_inputs=wire_list(row["initial_inputs"], "$.initial_inputs", _decode_initial_input),
            initial_resources=wire_list(row["initial_resources"], "$.initial_resources", _decode_resource_lot),
            goal=_decode_goal_spec(row["goal"], "$.goal"),
            invocation_domain=_decode_invocation_domain(row["invocation_domain"], "$.invocation_domain"),
            allowed_effects=wire_list(row["allowed_effects"], "$.allowed_effects", _decode_effect),
            explicit_order=wire_list(row["explicit_order"], "$.explicit_order", _decode_site_pair),
            selection_policy=None if row["selection_policy"] is None else _decode_selection_policy(row["selection_policy"], "$.selection_policy"),
            bounds=_decode_search_bounds(row["bounds"], "$.bounds"),
        ),
        causes,
    )


def _graph(library: Mapping[str, object]) -> Mapping[str, object]:
    from .type_signatures import _graph as signature_graph

    return cast(Mapping[str, object], signature_graph(library))


def _decode_type_ref(value: object, path: str) -> TypeRef:
    return TypeRef(
        {
            "repository": "ncoh-type-signatures",
            "revision": "1",
            "path": "",
            "content_digest": "",
            "document_id": "",
            "declared_revision": None,
        },
        wire_string(value, path),
    )


def _decode_definition_ref(value: object, path: str) -> DefinitionRef:
    reference = _decode_type_ref(value, path)
    return DefinitionRef(reference.source, reference.definition_name)


def _decode_slot_contract(value: object, path: str) -> SlotContract:
    row = wire_record(value, ("type_id", "required", "nullable"), path)
    return SlotContract(
        _decode_type_ref(row["type_id"], f"{path}.type_id"),
        wire_boolean(row["required"], f"{path}.required"),
        wire_boolean(row["nullable"], f"{path}.nullable"),
    )


def _decode_path_step(value: object, path: str) -> FieldStep | IndexStep | VariantStep:
    tag, item = wire_sum(value, {"Field": "value", "Index": "value", "Variant": "value"}, path)
    if tag == "Field":
        return FieldStep(wire_string(item, path))
    if tag == "Index":
        return IndexStep(wire_natural(item, path))
    return VariantStep(wire_string(item, path))


def _decode_path(value: object, path: str) -> tuple[FieldStep | IndexStep | VariantStep, ...]:
    return wire_list(value, path, _decode_path_step)


def _decode_slot_value(value: object, path: str) -> SlotValue:
    tag, item = wire_sum(value, {"Absent": None, "Null": None, "Present": "value"}, path)
    if tag == "Absent":
        return ABSENT_VALUE
    if tag == "Null":
        return NULL_VALUE
    exact = wire_json(item, path)
    exact_json(exact, path)
    return PresentValue(exact_decode(exact))


def _decode_source_constraint(value: object, path: str) -> SourceConstraint:
    tag, item = wire_sum(value, {"AnyCompatible": None, "InitialOnly": "fields", "ProducedBy": "fields"}, path)
    if tag == "AnyCompatible":
        return ANY_COMPATIBLE
    if tag == "InitialOnly":
        row = wire_record(item, ("input", "path"), path)
        return InitialOnly(InputId(wire_string(row["input"], f"{path}.input")), _decode_path(row["path"], f"{path}.path"))
    row = wire_record(item, ("site", "outcome", "port", "path"), path)
    return ProducedBy(
        SiteId(wire_string(row["site"], f"{path}.site")),
        OutcomeId(wire_string(row["outcome"], f"{path}.outcome")),
        PortId(wire_string(row["port"], f"{path}.port")),
        _decode_path(row["path"], f"{path}.path"),
    )


def _decode_resource_producer(value: object, path: str) -> InitialResourceProducer | InvocationResourceProducer:
    tag, item = wire_sum(value, {"Initial": "fields", "InvocationOutcome": "fields"}, path)
    if tag == "Initial":
        row = wire_record(item, ("identity", "revision"), path)
        return InitialResourceProducer(wire_string(row["identity"], f"{path}.identity"), wire_string(row["revision"], f"{path}.revision"))
    row = wire_record(item, ("site", "outcome"), path)
    return InvocationResourceProducer(SiteId(wire_string(row["site"], f"{path}.site")), OutcomeId(wire_string(row["outcome"], f"{path}.outcome")))


def _decode_resource_identity(value: object, path: str) -> AnyResourceIdentity | ExactResourceIdentity:
    tag, item = wire_sum(value, {"Any": None, "Exactly": "value"}, path)
    return ANY_RESOURCE_IDENTITY if tag == "Any" else ExactResourceIdentity(_decode_resource_producer(item, path))


def _decode_binding_mode(value: object, path: str) -> BindingMode:
    tag, _ = wire_sum(value, {"Read": None, "Consume": None}, path)
    return BindingMode.READ if tag == "Read" else BindingMode.CONSUME


def _decode_resource_lot(value: object, path: str) -> ResourceLot:
    row = wire_record(value, ("id", "token_type", "producer", "revision", "quantity", "provenance"), path)
    return ResourceLot(LotId(wire_string(row["id"], f"{path}.id")), _decode_type_ref(row["token_type"], f"{path}.token_type"), _decode_resource_producer(row["producer"], f"{path}.producer"), wire_natural(row["revision"], f"{path}.revision"), wire_natural(row["quantity"], f"{path}.quantity"), wire_string(row["provenance"], f"{path}.provenance"))


def _decode_resource_requirement(value: object, path: str) -> ResourceRequirement:
    row = wire_record(value, ("id", "token_type", "mode", "multiplicity", "required_revision", "identity"), path)
    return ResourceRequirement(RequirementId(wire_string(row["id"], f"{path}.id")), _decode_type_ref(row["token_type"], f"{path}.token_type"), _decode_binding_mode(row["mode"], f"{path}.mode"), wire_natural(row["multiplicity"], f"{path}.multiplicity"), wire_natural(row["required_revision"], f"{path}.required_revision"), _decode_resource_identity(row["identity"], f"{path}.identity"))


def _decode_resource_production(value: object, path: str) -> ResourceProduction:
    row = wire_record(value, ("id", "token_type", "revision", "quantity", "provenance"), path)
    return ResourceProduction(ProductionId(wire_string(row["id"], f"{path}.id")), _decode_type_ref(row["token_type"], f"{path}.token_type"), wire_natural(row["revision"], f"{path}.revision"), wire_natural(row["quantity"], f"{path}.quantity"), wire_string(row["provenance"], f"{path}.provenance"))


def _encode_resource_production(value: ResourceProduction) -> dict[str, Json]:
    return {"id": value.id.value, "token_type": value.token_type.definition_name, "revision": str(value.revision), "quantity": str(value.quantity), "provenance": value.provenance}


def _decode_initial_input(value: object, path: str) -> InitialInput:
    row = wire_record(value, ("id", "contract", "source", "resource"), path)
    input_id = InputId(wire_string(row["id"], f"{path}.id"))
    contract = _decode_slot_contract(row["contract"], f"{path}.contract")
    tag, item = wire_sum(row["source"], {"Argument": None, "SuppliedValue": "value"}, f"{path}.source")
    source = ARGUMENT_SOURCE if tag == "Argument" else SuppliedValueSource(_decode_slot_value(item, f"{path}.source"))
    resource = None if row["resource"] is None else LotId(wire_string(row["resource"], f"{path}.resource"))
    return InitialInput(input_id, contract, source, resource)


def _decode_input_port(value: object, path: str) -> InputPort:
    row = wire_record(value, ("id", "contract", "source_constraint", "resource_requirement"), path)
    port_id = PortId(wire_string(row["id"], f"{path}.id"))
    contract = _decode_slot_contract(row["contract"], f"{path}.contract")
    source_constraint = _decode_source_constraint(row["source_constraint"], f"{path}.source_constraint")
    resource = None if row["resource_requirement"] is None else RequirementId(wire_string(row["resource_requirement"], f"{path}.resource_requirement"))
    return InputPort(port_id, contract, source_constraint, resource)


def _decode_output_port(value: object, path: str) -> OutputPort:
    row = wire_record(value, ("id", "contract", "resource_production"), path)
    port_id = PortId(wire_string(row["id"], f"{path}.id"))
    contract = _decode_slot_contract(row["contract"], f"{path}.contract")
    resource = None if row["resource_production"] is None else ProductionId(wire_string(row["resource_production"], f"{path}.resource_production"))
    return OutputPort(port_id, contract, resource)


def _decode_source_identity(value: object, path: str) -> SourceIdentity:
    row = wire_record(value, ("repository", "revision", "path", "content_digest"), path)
    return SourceIdentity(
        wire_string(row["repository"], f"{path}.repository"),
        wire_string(row["revision"], f"{path}.revision"),
        wire_string(row["path"], f"{path}.path"),
        wire_string(row["content_digest"], f"{path}.content_digest"),
    )


def _decode_origin(value: object, path: str) -> Origin:
    row = wire_record(value, ("source", "locator"), path)
    source = _decode_source_identity(row["source"], f"{path}.source")
    return Origin(source, wire_list(row["locator"], f"{path}.locator", wire_string))


def _decode_outcome_cause(value: object, path: str) -> OutcomeCause:
    tag, fields_value = wire_sum(value, {"ValueContract": "fields", "ExternalCondition": "fields"}, path)
    if tag == "ValueContract":
        row = wire_record(fields_value, ("origin",), path)
        return ValueContractCause(_decode_origin(row["origin"], f"{path}.origin"))
    row = wire_record(fields_value, ("specification",), path)
    return ExternalConditionCause(_decode_origin(row["specification"], f"{path}.specification"))


def _encode_source_identity(value: SourceIdentity) -> dict[str, Json]:
    return {"repository": value.repository, "revision": value.revision, "path": value.path, "content_digest": value.content_digest}


def _encode_origin(value: Origin) -> dict[str, Json]:
    return {"source": _encode_source_identity(value.source), "locator": [item for item in value.locator]}


def _encode_outcome_cause(value: OutcomeCause) -> dict[str, Json]:
    if isinstance(value, ValueContractCause):
        return wire_fields("ValueContract", {"origin": _encode_origin(value.origin)})
    return wire_fields("ExternalCondition", {"specification": _encode_origin(value.specification)})


def _decode_outcome(value: object, path: str) -> OutcomeContract:
    row = wire_record(value, ("id", "form", "cause", "value_ports", "produced_resources"), path)
    _decode_outcome_cause(row["cause"], f"{path}.cause")
    outcome_id = OutcomeId(wire_string(row["id"], f"{path}.id"))
    tag, _ = wire_sum(row["form"], {"Success": None, "DeclaredFailure": None}, f"{path}.form")
    value_ports = wire_list(row["value_ports"], f"{path}.value_ports", _decode_output_port)
    produced_resources = wire_list(row["produced_resources"], f"{path}.produced_resources", _decode_resource_production)
    return OutcomeContract(outcome_id, OutcomeForm.SUCCESS if tag == "Success" else OutcomeForm.DECLARED_FAILURE, value_ports, produced_resources)


def _decode_function_form(value: object, path: str) -> PureFunctionForm | DeclaredTransformForm | OperationFunctionForm:
    tag, item = wire_sum(value, {"Pure": None, "DeclaredTransform": None, "Operation": "value"}, path)
    if tag == "Pure":
        return PURE_FUNCTION_FORM
    if tag == "DeclaredTransform":
        return DECLARED_TRANSFORM_FORM
    return OperationFunctionForm(_decode_definition_ref(item, path))


def _decode_effect(value: object, path: str) -> CompositionEffect:
    tag, _ = wire_sum(value, {"PureFunction": None, "HttpRequestResponse": None, "DataOnly": None}, path)
    return {"PureFunction": CompositionEffect.PURE_FUNCTION, "HttpRequestResponse": CompositionEffect.HTTP_REQUEST_RESPONSE, "DataOnly": CompositionEffect.DATA_ONLY}[tag]


def _decode_guard_arm(value: object, path: str) -> UnitGuardArm | VariantGuardArm:
    tag, item = wire_sum(value, {"Present": None, "Absent": None, "Null": None, "UnknownVariant": None, "Accepted": None, "Rejected": None, "Variant": "value"}, path)
    if tag == "Variant":
        return VariantGuardArm(wire_string(item, path))
    return {"Present": UnitGuardArm.PRESENT, "Absent": UnitGuardArm.ABSENT, "Null": UnitGuardArm.NULL, "UnknownVariant": UnitGuardArm.UNKNOWN_VARIANT, "Accepted": UnitGuardArm.ACCEPTED, "Rejected": UnitGuardArm.REJECTED}[tag]


def _decode_failure_origin(value: object, path: str) -> FunctionFailureOrigin | GuardFailureOrigin:
    tag, item = wire_sum(value, {"Function": "fields", "Guard": "fields"}, path)
    if tag == "Function":
        row = wire_record(item, ("function", "outcome"), path)
        return FunctionFailureOrigin(decode_function_ref(row["function"], f"{path}.function"), OutcomeId(wire_string(row["outcome"], f"{path}.outcome")))
    row = wire_record(item, ("guard", "arm"), path)
    return GuardFailureOrigin(GuardId(wire_string(row["guard"], f"{path}.guard")), _decode_guard_arm(row["arm"], f"{path}.arm"))


def _decode_function_signature(value: object, path: str) -> FunctionSignature:
    row = wire_record(value, ("reference", "form", "effect", "inputs", "outcomes", "resource_inputs", "assumption_ref", "handles_failure"), path)
    return FunctionSignature(decode_function_ref(row["reference"], f"{path}.reference"), _decode_function_form(row["form"], f"{path}.form"), _decode_effect(row["effect"], f"{path}.effect"), wire_list(row["inputs"], f"{path}.inputs", _decode_input_port), wire_list(row["outcomes"], f"{path}.outcomes", _decode_outcome), wire_list(row["resource_inputs"], f"{path}.resource_inputs", _decode_resource_requirement), wire_string(row["assumption_ref"], f"{path}.assumption_ref"), None if row["handles_failure"] is None else _decode_failure_origin(row["handles_failure"], f"{path}.handles_failure"))


def _decode_invocation_site(value: object, path: str) -> InvocationSite:
    row = wire_record(value, ("id", "function"), path)
    return InvocationSite(SiteId(wire_string(row["id"], f"{path}.id")), decode_function_ref(row["function"], f"{path}.function"))


def _decode_projection(value: object, path: str) -> PermittedProjection:
    row = wire_record(value, ("source_type", "path"), path)
    return PermittedProjection(_decode_type_ref(row["source_type"], f"{path}.source_type"), _decode_path(row["path"], f"{path}.path"))


def _decode_guard_kind(value: object, path: str) -> UnitGuardKind | ValidateGuardKind:
    tag, item = wire_sum(value, {"Presence": None, "Variants": None, "Validate": "value"}, path)
    if tag == "Presence":
        return UnitGuardKind.PRESENCE
    if tag == "Variants":
        return UnitGuardKind.VARIANTS
    return ValidateGuardKind(_decode_slot_contract(item, path))


def _decode_guard(value: object, path: str) -> DeclaredGuard:
    row = wire_record(value, ("id", "source_type", "path", "kind"), path)
    return DeclaredGuard(GuardId(wire_string(row["id"], f"{path}.id")), _decode_type_ref(row["source_type"], f"{path}.source_type"), _decode_path(row["path"], f"{path}.path"), _decode_guard_kind(row["kind"], f"{path}.kind"))


def _decode_field_constraint(value: object, path: str) -> FieldConstraint:
    row = wire_record(value, ("field", "source", "presence"), path)
    field = wire_string(row["field"], f"{path}.field")
    source = _decode_source_constraint(row["source"], f"{path}.source")
    tag, _ = wire_sum(row["presence"], {"Required": None, "Optional": None}, f"{path}.presence")
    return FieldConstraint(field, source, FieldPresence.REQUIRED if tag == "Required" else FieldPresence.OPTIONAL)


def _decode_string_pair(value: object, path: str) -> tuple[str, str]:
    pair = wire_array(value, path)
    if len(pair) != 2:
        raise WireFailure("Syntax", path, "pair size")
    return wire_string(pair[0], f"{path}"), wire_string(pair[1], f"{path}")


def _decode_construction(value: object, path: str) -> ConstructionRule:
    row = wire_record(value, ("identity", "type_id", "nested_fields", "field_constraints"), path)
    return ConstructionRule(wire_string(row["identity"], f"{path}.identity"), _decode_type_ref(row["type_id"], f"{path}.type_id"), wire_list(row["nested_fields"], f"{path}.nested_fields", _decode_string_pair), wire_list(row["field_constraints"], f"{path}.field_constraints", _decode_field_constraint))


def _decode_invocation_domain(value: object, path: str) -> InvocationDomain:
    row = wire_record(value, ("identity", "revision", "sites", "permitted_projections", "permitted_constructions", "permitted_transforms", "guards"), path)
    return InvocationDomain(wire_string(row["identity"], f"{path}.identity"), wire_string(row["revision"], f"{path}.revision"), wire_list(row["sites"], f"{path}.sites", _decode_invocation_site), wire_list(row["permitted_projections"], f"{path}.permitted_projections", _decode_projection), wire_list(row["permitted_constructions"], f"{path}.permitted_constructions", _decode_construction), wire_list(row["permitted_transforms"], f"{path}.permitted_transforms", decode_function_ref), wire_list(row["guards"], f"{path}.guards", _decode_guard))


def _decode_resource_goal(value: object, path: str) -> ResourceGoal:
    row = wire_record(value, ("lot", "multiplicity", "revision"), path)
    return ResourceGoal(decode_resource_lot_ref(row["lot"], f"{path}.lot"), wire_natural(row["multiplicity"], f"{path}.multiplicity"), wire_natural(row["revision"], f"{path}.revision"))


def _decode_goal_port(value: object, path: str) -> GoalPort:
    row = wire_record(value, ("id", "contract", "source_constraint"), path)
    return GoalPort(GoalPortId(wire_string(row["id"], f"{path}.id")), _decode_slot_contract(row["contract"], f"{path}.contract"), _decode_source_constraint(row["source_constraint"], f"{path}.source_constraint"))


def _decode_failure_embedding(value: object, path: str) -> FailureEmbedding:
    row = wire_record(value, ("id", "origin", "contract", "final_resources"), path)
    return FailureEmbedding(FailureEmbeddingId(wire_string(row["id"], f"{path}.id")), _decode_failure_origin(row["origin"], f"{path}.origin"), _decode_slot_contract(row["contract"], f"{path}.contract"), wire_list(row["final_resources"], f"{path}.final_resources", _decode_resource_goal))


def _decode_goal_spec(value: object, path: str) -> GoalSpec:
    row = wire_record(value, ("outputs", "failures", "final_resources"), path)
    return GoalSpec(wire_list(row["outputs"], f"{path}.outputs", _decode_goal_port), wire_list(row["failures"], f"{path}.failures", _decode_failure_embedding), wire_list(row["final_resources"], f"{path}.final_resources", _decode_resource_goal))


def _decode_selection_policy(value: object, path: str) -> SelectionPolicy:
    tag, _ = wire_sum(value, {"RequireUnique": None, "AnyFeasible": None}, path)
    return SelectionPolicy.REQUIRE_UNIQUE if tag == "RequireUnique" else SelectionPolicy.ANY_FEASIBLE


def _decode_resource_bounds(value: object, path: str) -> ResourceBounds:
    row = wire_record(value, ("max_bindings", "max_search_steps", "max_tokens"), path)
    return ResourceBounds(wire_natural(row["max_bindings"], f"{path}.max_bindings"), wire_natural(row["max_search_steps"], f"{path}.max_search_steps"), wire_natural(row["max_tokens"], f"{path}.max_tokens"))


def _decode_search_bounds(value: object, path: str) -> SearchBounds:
    row = wire_record(value, ("max_expanded_states", "max_binding_candidates", "max_type_obligations", "max_branch_nodes", "resource_bounds", "max_sample_length"), path)
    max_expanded_states = wire_natural(row["max_expanded_states"], f"{path}.max_expanded_states")
    max_binding_candidates = wire_natural(row["max_binding_candidates"], f"{path}.max_binding_candidates")
    max_type_obligations = wire_natural(row["max_type_obligations"], f"{path}.max_type_obligations")
    max_branch_nodes = wire_natural(row["max_branch_nodes"], f"{path}.max_branch_nodes")
    resource_bounds = None if row["resource_bounds"] is None else _decode_resource_bounds(row["resource_bounds"], f"{path}.resource_bounds")
    max_sample_length = wire_natural(row["max_sample_length"], f"{path}.max_sample_length")
    return SearchBounds(max_expanded_states, max_binding_candidates, max_type_obligations, max_branch_nodes, max_sample_length, resource_bounds)


def _decode_site_pair(value: object, path: str) -> tuple[SiteId, SiteId]:
    pair = wire_array(value, path)
    if len(pair) != 2:
        raise WireFailure("Syntax", path, "pair size")
    return SiteId(wire_string(pair[0], f"{path}")), SiteId(wire_string(pair[1], f"{path}"))


@dataclass(frozen=True, slots=True)
class _Context:
    """The declarations that the inclusion certificates of a derivation are decoded against."""

    library: Mapping[str, object]
    graph: Mapping[str, object]
    basis: Mapping[str, object]


def _decode_value_ref(value: object, path: str) -> composition.ValueRef:
    row = wire_record(value, ("producer", "path"), path)
    producer = decode_producer(row["producer"], f"{path}.producer")
    return composition.ValueRef(producer, _decode_path(row["path"], f"{path}.path"))


def _decode_assumption(value: object, path: str) -> composition.ProjectionAssumption:
    tag, item = wire_sum(
        value,
        {"Present": "value", "NonNull": "value", "Variant": "fields", "IndexPresent": "fields"},
        path,
    )
    if tag == "Present":
        return composition.PresentAssumption(_decode_path(item, path))
    if tag == "NonNull":
        return composition.NonNullAssumption(_decode_path(item, path))
    if tag == "Variant":
        row = wire_record(item, ("path", "tag"), path)
        return composition.VariantAssumption(_decode_path(row["path"], f"{path}.path"), wire_string(row["tag"], f"{path}.tag"))
    row = wire_record(item, ("path", "index"), path)
    return composition.IndexPresentAssumption(_decode_path(row["path"], f"{path}.path"), wire_natural(row["index"], f"{path}.index"))


def _decode_projection_certificate(value: object, path: str) -> composition.ProjectionCertificate:
    row = wire_record(value, ("profile", "source_refs", "source", "path", "assumptions", "destination"), path)
    return composition.ProjectionCertificate(
        _validated(PROFILE_REF, row["profile"], f"{path}.profile"),
        tuple(cast(list[object], _validated(listed(SOURCE_REF), row["source_refs"], f"{path}.source_refs"))),
        _decode_slot_contract(row["source"], f"{path}.source"),
        _decode_path(row["path"], f"{path}.path"),
        wire_list(row["assumptions"], f"{path}.assumptions", _decode_assumption),
        _decode_slot_contract(row["destination"], f"{path}.destination"),
    )


def _decode_type_pair(value: object, path: str) -> composition.TypePair:
    row = wire_record(value, ("source", "destination", "source_tag"), path)
    source = _decode_slot_contract(row["source"], f"{path}.source")
    destination = _decode_slot_contract(row["destination"], f"{path}.destination")
    source_tag = None if row["source_tag"] is None else wire_string(row["source_tag"], f"{path}.source_tag")
    return composition.TypePair(source, destination, source_tag)


def _validated(check: Callable[[object, str], None], value: object, path: str) -> object:
    check(value, path)
    return copy.deepcopy(value)


def _decode_inclusion(context: _Context, value: object, path: str) -> composition.InclusionCertificate:
    """Decode the Lean `inclusionDecode`, which checks the key set of the certificate and of each pair row before reading a field."""
    certificate = wire_record(value, ("basis", "source", "destination", "empty_types", "pairs", "root"), path)
    basis = _validated(SIGNATURE_BASIS, certificate["basis"], f"{path}.basis")
    if not json_equal(basis, context.basis):
        raise WireFailure("Syntax", path, "inclusion basis mismatch")
    library_nodes = {
        wire_string(wire_mapping(item, "library node").get("id"), "library node.id"): wire_mapping(item, "library node")
        for item in wire_array(context.library.get("nodes", ()), "library.nodes")
    }
    graph_nodes = {
        wire_string(wire_mapping(item, "graph node").get("id"), "graph node.id"): wire_mapping(item, "graph node")
        for item in wire_array(context.graph.get("nodes", ()), "graph.nodes")
    }
    pairs: list[composition.PairEntry] = []
    for row_value in wire_array(certificate["pairs"], path):
        row = wire_record(row_value, ("pair", "source_shape", "destination_shape", "rule", "children"), path)
        pair = _decode_type_pair(row["pair"], f"{path}.pair")
        source_id = pair.source.type_ref.definition_name
        destination_id = pair.destination.type_ref.definition_name
        source_node = library_nodes.get(source_id)
        destination_node = library_nodes.get(destination_id)
        if source_node is None or destination_node is None:
            raise WireFailure("Syntax", path, "undeclared type")
        source_shape = _validated(SHAPE, row["source_shape"], f"{path}.source_shape")
        destination_shape = _validated(SHAPE, row["destination_shape"], f"{path}.destination_shape")
        if not json_equal(source_shape, source_node.get("shape")) or not json_equal(destination_shape, destination_node.get("shape")):
            raise WireFailure("Syntax", path, "inclusion shape mismatch")
        semantic_source = graph_nodes.get(source_id)
        semantic_destination = graph_nodes.get(destination_id)
        if semantic_source is None or semantic_destination is None:
            raise WireFailure("Syntax", path, "undeclared type")
        rule_tag, _ = wire_sum(row["rule"], dict.fromkeys(INCLUSION_RULE_VALUES), path)
        children = wire_list(row["children"], f"{path}.children", wire_natural)
        pairs.append(composition.PairEntry(
            pair,
            copy.deepcopy(semantic_source.get("shape")),
            copy.deepcopy(semantic_destination.get("shape")),
            composition.InclusionRule(INCLUSION_RULE_VALUES[rule_tag]),
            children,
        ))
    source = _decode_slot_contract(certificate["source"], f"{path}.source")
    destination = _decode_slot_contract(certificate["destination"], f"{path}.destination")
    empty_types = wire_list(certificate["empty_types"], f"{path}.empty_types", _decode_type_ref)
    root = wire_natural(certificate["root"], f"{path}.root")
    return composition.InclusionCertificate(
        SemanticBasis.of(context.graph), source, destination, empty_types, tuple(pairs), root,
    )


def _decode_binding(context: _Context, value: object, path: str) -> composition.BindingExpr:
    tag, item = wire_sum(value, {"Source": "fields", "Product": "fields"}, path)
    if tag == "Source":
        row = wire_record(item, ("value", "projection", "compatibility"), path)
        compatibility_tag, compatibility_item = wire_sum(
            row["compatibility"], {"SuppliedValue": "fields", "Inclusion": "value"}, path,
        )
        compatibility_value: composition.BindingCompatibility
        if compatibility_tag == "SuppliedValue":
            supplied = wire_record(compatibility_item, ("value",), path)
            compatibility_value = composition.SuppliedValueCompatibility(_decode_slot_value(supplied["value"], f"{path}.value"))
        else:
            compatibility_value = composition.InclusionCompatibility(_decode_inclusion(context, compatibility_item, path))
        source_value = _decode_value_ref(row["value"], f"{path}.value")
        projection = _decode_projection_certificate(row["projection"], f"{path}.projection")
        return composition.SourceBindingExpr(source_value, projection, compatibility_value)
    row = wire_record(item, ("construction", "type_id", "fields"), path)
    fields: list[tuple[str, composition.BindingExpr]] = []
    for pair_value in wire_array(row["fields"], path):
        pair = wire_array(pair_value, path)
        if len(pair) != 2:
            raise WireFailure("Syntax", path, "construction field pair size")
        fields.append((wire_string(pair[0], path), _decode_binding(context, pair[1], path)))
    construction = wire_string(row["construction"], f"{path}.construction")
    type_id = _decode_type_ref(row["type_id"], f"{path}.type_id")
    return composition.ProductBindingExpr(construction, type_id, tuple(fields))


def _decode_resource_binding(context: _Context, value: object, path: str) -> composition.ResourceBinding:
    row = wire_record(value, ("requirement", "lot", "inclusion"), path)
    return composition.ResourceBinding(
        RequirementId(wire_string(row["requirement"], f"{path}.requirement")),
        decode_resource_lot_ref(row["lot"], f"{path}.lot"),
        _decode_inclusion(context, row["inclusion"], path),
    )


def _decode_invocation(context: _Context, value: object, path: str) -> composition.InvocationPlan:
    row = wire_record(value, ("site", "function", "bindings", "resources"), path)
    resources = wire_list(row["resources"], path, lambda item, item_path: _decode_resource_binding(context, item, item_path))
    bindings: list[tuple[PortId, composition.BindingExpr]] = []
    for item in wire_array(row["bindings"], path):
        pair = wire_array(item, path)
        if len(pair) != 2:
            raise WireFailure("Syntax", path, "invocation binding pair size")
        bindings.append((PortId(wire_string(pair[0], path)), _decode_binding(context, pair[1], path)))
    return composition.InvocationPlan(
        SiteId(wire_string(row["site"], f"{path}.site")),
        decode_function_ref(row["function"], f"{path}.function"),
        tuple(bindings),
        resources,
    )


def _decode_return(context: _Context, value: object, path: str) -> composition.ReturnPlan:
    tag, item = wire_sum(value, {"Success": "value", "Failure": "fields"}, path)
    if tag == "Failure":
        row = wire_record(item, ("embedding", "value"), path)
        embedding = FailureEmbeddingId(wire_string(row["embedding"], f"{path}.embedding"))
        return composition.FailureReturnPlan(embedding, _decode_binding(context, row["value"], path))
    outputs: list[tuple[GoalPortId, composition.BindingExpr]] = []
    for pair_value in wire_array(item, path):
        pair = wire_array(pair_value, path)
        if len(pair) != 2:
            raise WireFailure("Syntax", path, "output pair size")
        outputs.append((GoalPortId(wire_string(pair[0], path)), _decode_binding(context, pair[1], path)))
    return composition.SuccessReturnPlan(tuple(outputs))


def _decode_tree(context: _Context, value: object, path: str) -> composition.PlanTree:
    row = wire_record(value, ("rank", "node"), path)
    rank = wire_natural(row["rank"], f"{path}.rank")
    tag, item = wire_sum(row["node"], {"Return": "value", "Invoke": "fields", "Guard": "fields"}, path)
    if tag == "Return":
        return composition.ReturnPlanTree(rank, _decode_return(context, item, path))
    if tag == "Invoke":
        details = wire_record(item, ("invocation", "arms", "empty_outcomes"), path)
        arms: list[tuple[OutcomeId, composition.PlanTree]] = []
        for item in wire_array(details["arms"], path):
            pair = wire_array(item, path)
            if len(pair) != 2:
                raise WireFailure("Syntax", path, "invocation arm pair size")
            arms.append((OutcomeId(wire_string(pair[0], path)), _decode_tree(context, pair[1], path)))
        invocation = _decode_invocation(context, details["invocation"], path)
        empty = tuple(
            OutcomeId(wire_string(item, f"{path}.empty_outcomes"))
            for item in wire_array(details["empty_outcomes"], f"{path}.empty_outcomes")
        )
        return composition.InvokePlanTree(rank, invocation, tuple(arms), empty)
    details = wire_record(item, ("guard", "inspected", "arms"), path)
    guard_arms: list[tuple[composition.GuardArm, composition.PlanTree]] = []
    for arm_value in wire_array(details["arms"], path):
        pair = wire_array(arm_value, path)
        if len(pair) != 2:
            raise WireFailure("Syntax", path, "guard arm pair size")
        guard_arms.append((_decode_guard_arm(pair[0], path), _decode_tree(context, pair[1], path)))
    guard = GuardId(wire_string(details["guard"], f"{path}.guard"))
    inspected = _decode_value_ref(details["inspected"], f"{path}.inspected")
    return composition.GuardPlanTree(rank, guard, inspected, tuple(guard_arms))


class CompositionInputRejected(Exception):
    def __init__(self, failure: CompositionInputFailure) -> None:
        super().__init__(failure)
        self.failure = failure


def _admit_composition(
    signatures: Mapping[str, object],
    graph_digest: str,
    composition_value: object,
    library_basis: Mapping[str, object],
) -> AdmittedComposition:
    row = wire_record(composition_value, ("problem", "derivation"), "$.composition")
    problem, causes = _decode_problem(signatures, row["problem"], library_basis)
    prepared = prepare_composition_input(signatures, graph_digest, problem, causes)
    if not isinstance(prepared, PreparedCompositionInput):
        raise CompositionInputRejected(prepared)
    plan = _decode_plan(signatures, row["problem"], prepared, row["derivation"], library_basis)
    return AdmittedComposition(_admission_token, prepared, plan)


def decode_plan(
    library: Mapping[str, object],
    problem_json: object,
    prepared: PreparedCompositionInput,
    value: object,
) -> composition.CompositionPlan:
    return _decode_plan(library, problem_json, prepared, value, signature_basis(library, []))


def _decode_plan(
    library: Mapping[str, object],
    problem_json: object,
    prepared: PreparedCompositionInput,
    value: object,
    library_basis: Mapping[str, object],
) -> composition.CompositionPlan:
    context = _Context(library, prepared.graph, library_basis)
    row = wire_record(value, ("plan", "witness", "selection"), "$")
    plan_row = wire_record(row["plan"], ("input_identity", "input_revision", "root"), "$")
    witness_row = wire_record(row["witness"], ("input_snapshot", "initial_membership", "resource_traces"), "$")
    if not json_equal(witness_row["input_snapshot"], problem_json):
        raise WireFailure("Syntax", "$", "input snapshot mismatch")
    tree = _decode_tree(context, plan_row["root"], "$")
    tag = wire_tag(row["selection"], "$")
    if tag == "AnyFeasible":
        wire_record(row["selection"], ("tag",), "$")
    elif tag != "Unique":
        raise WireFailure("UnknownTag", "$.tag", tag)
    return composition.CompositionPlan(
        wire_string(plan_row["input_identity"], "$.input_identity"),
        wire_string(plan_row["input_revision"], "$.input_revision"),
        tree,
    )


__all__ = [
    "AdmittedComposition",
    "CauseBinding",
    "CompositionInputRejected",
    "check_operation",
    "decode_problem",
    "prepare_composition_input",
    "signature_contract",
]
