# SPDX-FileCopyrightText: 2026 barineco
# SPDX-License-Identifier: MIT

from __future__ import annotations

import copy
from typing import Any

import pytest

from necoherence.library_check import ProfileFailure, ProfilePredicate
from necoherence.semantic_composition import (
    ANY_COMPATIBLE,
    ARGUMENT_SOURCE,
    BASIS_MISMATCH,
    CompositionInput,
    DuplicateIdentity,
    GoalPort,
    GoalPortId,
    GoalSpec,
    InitialInput,
    InputId,
    InvalidInitialValue,
    EmptyGoal,
    ExplicitSiteOrderInvalid,
    InvalidLibrary,
    InvalidResourceDeclaration,
    InvalidSignature,
    InvocationDomain,
    InvocationSite,
    LotId,
    PresentValue,
    PreparedCompositionInput,
    RuleMismatch,
    SearchBounds,
    SemanticBasis,
    SiteId,
    SlotContract,
    SuppliedValueSource,
    UnresolvedFunction,
    UnresolvedType,
    FunctionRef,
    FunctionSignature,
    PURE_FUNCTION_FORM,
    CompositionEffect,
    prepare_direct_composition,
    validate_composition_input,
)
from necoherence.signature_composition_wire import _Context, _decode_inclusion, decode_problem, prepare_composition_input
from necoherence.signature_values import ValueContext, WireFailure
from necoherence.type_signatures import DeclarationFailure, _graph, signature_basis
from composition_fixtures import signature_type_ref
from composition_problem_encoding import encode_problem


def library() -> dict[str, object]:
    return {
        "schema": "ncoh-type-signatures@1",
        "identity": "composition-test",
        "revision": "1",
        "profile": {
            "reference": {"identity": "test", "revision": "1", "content_digest": "0" * 64},
            "source_refs": [],
        },
        "sources": [],
        "provenance": [],
        "groups": [],
        "annotations": [],
        "nodes": [
            {
                "id": "truth",
                "shape": {"tag": "Boolean", "value": {"const_value": None, "default_value": None}},
            }
        ],
        "definitions": [],
    }


def problem_wire() -> dict[str, object]:
    declarations = library()
    return {
        "identity": "composition",
        "revision": "1",
        "basis": signature_basis(declarations, []),
        "signatures": [],
        "initial_inputs": [
            {
                "id": "input",
                "contract": {"type_id": "truth", "required": True, "nullable": False},
                "source": {"tag": "Argument"},
                "resource": None,
            }
        ],
        "initial_resources": [],
        "goal": {
            "outputs": [
                {
                    "id": "goal",
                    "contract": {"type_id": "truth", "required": True, "nullable": False},
                    "source_constraint": {"tag": "AnyCompatible"},
                }
            ],
            "failures": [],
            "final_resources": [],
        },
        "invocation_domain": {
            "identity": "domain",
            "revision": "1",
            "sites": [],
            "permitted_projections": [],
            "permitted_constructions": [],
            "permitted_transforms": [],
            "guards": [],
        },
        "allowed_effects": [],
        "explicit_order": [],
        "selection_policy": None,
        "bounds": {
            "max_expanded_states": "10000",
            "max_binding_candidates": "100000",
            "max_type_obligations": "10000",
            "max_branch_nodes": "100000",
            "resource_bounds": None,
            "max_sample_length": "32",
        },
    }


def valid_input() -> tuple[dict[str, object], CompositionInput]:
    declarations = library()
    graph = _graph(declarations)
    reference = signature_type_ref("truth")
    contract = SlotContract(reference, True, False)
    return graph, CompositionInput(
        "composition",
        "1",
        SemanticBasis.of(graph),
        (),
        (InitialInput(InputId("input"), contract, ARGUMENT_SOURCE, None),),
        (),
        GoalSpec((GoalPort(GoalPortId("goal"), contract, ANY_COMPATIBLE),), (), ()),
        InvocationDomain("domain", "1", (), (), (), (), ()),
        (),
        (),
        SearchBounds(),
    )


def no_operation_failure(_function: FunctionSignature, _definition: object) -> None:
    return None


def no_meaning(_function: FunctionSignature, _definition: object) -> tuple[object, ...]:
    return ()


def test_problem_wire_roundtrip_preserves_the_lean_json_shape() -> None:
    declarations = library()
    supplied = problem_wire()
    supplied["signatures"] = [
        {
            "reference": {"identity": "pure", "revision": "1", "content_digest": "digest"},
            "form": {"tag": "Pure"},
            "effect": {"tag": "PureFunction"},
            "inputs": [],
            "outcomes": [
                {
                    "id": "success",
                    "form": {"tag": "Success"},
                    "cause": {
                        "tag": "ValueContract",
                        "fields": {
                            "origin": {
                                "source": {
                                    "repository": "example",
                                    "revision": "1",
                                    "path": "source",
                                    "content_digest": "1" * 64,
                                },
                                "locator": [],
                            }
                        },
                    },
                    "value_ports": [],
                    "produced_resources": [],
                }
            ],
            "resource_inputs": [],
            "assumption_ref": "assumption",
            "handles_failure": None,
        }
    ]
    decoded, causes = decode_problem(declarations, supplied)
    assert encode_problem(declarations, decoded, causes) == supplied


@pytest.mark.parametrize(
    "mutation",
    [
        lambda value: value.update({"unknown": None}),
        lambda value: value.pop("revision"),
        lambda value: value["initial_inputs"][0].update({"source": {"tag": "Unknown"}}),
    ],
)
def test_problem_wire_rejects_unknown_keys_missing_keys_and_unknown_tags(mutation: object) -> None:
    supplied = copy.deepcopy(problem_wire())
    mutation(supplied)  # type: ignore[operator]
    with pytest.raises(WireFailure):
        decode_problem(library(), supplied)


def test_validation_returns_each_lean_composition_input_failure_constructor() -> None:
    graph, input_value = valid_input()
    context = ValueContext(graph)
    assert validate_composition_input(context,input_value, no_operation_failure) is None

    wrong_basis = copy.deepcopy(input_value)
    object.__setattr__(wrong_basis, "basis", SemanticBasis({}, ()))
    assert validate_composition_input(context,wrong_basis, no_operation_failure) == BASIS_MISMATCH

    duplicate = copy.deepcopy(input_value)
    object.__setattr__(duplicate, "initial_inputs", duplicate.initial_inputs * 2)
    assert isinstance(validate_composition_input(context,duplicate, no_operation_failure), DuplicateIdentity)

    missing_type = copy.deepcopy(input_value)
    missing_contract = SlotContract(signature_type_ref("missing"), True, False)
    object.__setattr__(missing_type, "initial_inputs", (InitialInput(InputId("input"), missing_contract, ARGUMENT_SOURCE, None),))
    assert isinstance(validate_composition_input(context,missing_type, no_operation_failure), UnresolvedType)

    missing_function = FunctionRef("missing", "1", "digest")
    unresolved_function = copy.deepcopy(input_value)
    object.__setattr__(unresolved_function, "invocation_domain", InvocationDomain("domain", "1", (InvocationSite(SiteId("site"), missing_function),), (), (), (), ()))
    assert isinstance(validate_composition_input(context,unresolved_function, no_operation_failure), UnresolvedFunction)

    invalid_signature = copy.deepcopy(input_value)
    signature = FunctionSignature(FunctionRef("function", "", "digest"), PURE_FUNCTION_FORM, CompositionEffect.PURE_FUNCTION, (), (), (), "assumption")
    object.__setattr__(invalid_signature, "signatures", (signature,))
    assert isinstance(validate_composition_input(context,invalid_signature, no_operation_failure), InvalidSignature)

    invalid_value = copy.deepcopy(input_value)
    contract = invalid_value.initial_inputs[0].contract
    object.__setattr__(invalid_value, "initial_inputs", (InitialInput(InputId("input"), contract, SuppliedValueSource(PresentValue("not a boolean")), None),))
    assert isinstance(validate_composition_input(context,invalid_value, no_operation_failure), InvalidInitialValue)

    invalid_domain = copy.deepcopy(input_value)
    object.__setattr__(invalid_domain, "goal", GoalSpec((), (), ()))
    assert isinstance(validate_composition_input(context,invalid_domain, no_operation_failure), EmptyGoal)

    invalid_resource = copy.deepcopy(input_value)
    object.__setattr__(invalid_resource, "initial_inputs", (InitialInput(InputId("input"), contract, ARGUMENT_SOURCE, LotId("missing")),))
    assert isinstance(validate_composition_input(context,invalid_resource, no_operation_failure), InvalidResourceDeclaration)


def test_explicit_site_order_names_the_invalid_pair() -> None:
    graph, input_value = valid_input()
    context = ValueContext(graph)
    same_site_order = copy.deepcopy(input_value)
    object.__setattr__(same_site_order, "explicit_order", ((SiteId("site"), SiteId("site")),))
    assert isinstance(validate_composition_input(context,same_site_order, no_operation_failure), ExplicitSiteOrderInvalid)


def test_prepared_input_can_only_be_constructed_by_preparation() -> None:
    graph, input_value = valid_input()
    prepared = prepare_direct_composition(graph, input_value, no_operation_failure, no_meaning)
    assert isinstance(prepared, PreparedCompositionInput)
    with pytest.raises(TypeError):
        PreparedCompositionInput(object(), graph, input_value, no_operation_failure, no_meaning, (), prepared.empty_checked, prepared.values)
    assert prepared.input == input_value


def inclusion_certificate(declarations: dict[str, object]) -> dict[str, Any]:
    nodes = declarations["nodes"]
    assert isinstance(nodes, list)
    shape = next(node["shape"] for node in nodes if isinstance(node, dict) and node.get("id") == "truth")
    contract = {"type_id": "truth", "required": True, "nullable": False}
    return {
        "basis": signature_basis(declarations, []),
        "source": contract,
        "destination": contract,
        "root": "0",
        "empty_types": [],
        "pairs": [{
            "pair": {"source": contract, "destination": contract, "source_tag": None},
            "source_shape": shape,
            "destination_shape": shape,
            "rule": {"tag": "SameDefinedType"},
            "children": [],
        }],
    }


def test_inclusion_basis_decode_failure_is_reported_at_the_basis_path() -> None:
    declarations = library()
    certificate = inclusion_certificate(declarations)
    certificate["basis"] = {}
    with pytest.raises(WireFailure) as caught:
        _decode_inclusion(_Context(declarations, _graph(declarations), signature_basis(declarations, [])), certificate, "$.p")
    assert (caught.value.kind, caught.value.path, caught.value.observed) == ("Syntax", "$.p.basis.signature_schema", "missing field")


def test_inclusion_basis_mismatch_is_reported_at_the_certificate_path() -> None:
    declarations = library()
    certificate = inclusion_certificate(declarations)
    certificate["basis"] = {**signature_basis(declarations, []), "graph_sha256": "0" * 64}
    with pytest.raises(WireFailure) as caught:
        _decode_inclusion(_Context(declarations, _graph(declarations), signature_basis(declarations, [])), certificate, "$.p")
    assert (caught.value.kind, caught.value.path, caught.value.observed) == ("Syntax", "$.p", "inclusion basis mismatch")


def test_inclusion_undeclared_pair_type_is_reported_at_the_certificate_path() -> None:
    declarations = library()
    certificate = inclusion_certificate(declarations)
    certificate["pairs"][0]["pair"]["source"]["type_id"] = "missing"
    with pytest.raises(WireFailure) as caught:
        _decode_inclusion(_Context(declarations, _graph(declarations), signature_basis(declarations, [])), certificate, "$")
    assert (caught.value.kind, caught.value.path, caught.value.observed) == ("Syntax", "$", "undeclared type")


def test_inclusion_unknown_rule_is_an_unknown_tag_failure() -> None:
    declarations = library()
    certificate = inclusion_certificate(declarations)
    certificate["pairs"][0]["rule"] = {"tag": "Other"}
    with pytest.raises(WireFailure) as caught:
        _decode_inclusion(_Context(declarations, _graph(declarations), signature_basis(declarations, [])), certificate, "$")
    assert (caught.value.kind, caught.value.path, caught.value.observed) == ("UnknownTag", "$.tag", "Other")


def test_composition_input_keeps_the_library_failure_as_a_typed_value() -> None:
    declarations = library()
    profile = declarations["profile"]
    assert isinstance(profile, dict)
    profile.update(
        reference={"identity": "", "revision": "1", "content_digest": "0" * 64},
        integer_domains=[], default_integer_domain="", numbers={"decimals": False}, grapheme_rules=None,
        format_bindings=[], bytes_policy=None, wrappers=[], tag=None,
    )
    _, composition_input = valid_input()
    prepared = prepare_composition_input(declarations, "0" * 64, composition_input, ())
    assert isinstance(prepared, InvalidLibrary)
    assert isinstance(prepared.failure, ProfileFailure)
    assert (prepared.failure.predicate, prepared.failure.location) == (ProfilePredicate.PR01, ("profile",))

