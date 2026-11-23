#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 barineco
# SPDX-License-Identifier: AGPL-3.0-only

from __future__ import annotations

import copy
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[3]
HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT / "verification" / "declaration"))
import signature_admission_exhaustive as exhaustive  # noqa: E402
GENERATOR = ROOT / "verification/declaration/signature_generator/Cargo.toml"

WITNESS_FAILURE_NAMES = {
    "ResourceReplayMismatch",
    "ForgedClosure",
    "ForgedAcyclicity",
}

ADMISSION_FAILURE_NAMES = {
    "UnsupportedSchema": "unsupportedSchema",
    "EntrypointsEmpty": "entrypointsEmpty",
    "EntrypointIdentityEmpty": "entrypointIdentityEmpty",
    "EntrypointDuplicate": "entrypointDuplicate",
    "EntrypointUnresolved": "entrypointUnresolved",
    "Library": "library",
    "Certificate": "certificate",
    "Wire": "wire",
    "CompositionInput": "compositionInput",
    "Composition": "composition",
}

FAILURE_NAMES = {
    "composition": "composition",
    "compositionInput": "compositionInput",
    "wire": "wire",
    **ADMISSION_FAILURE_NAMES,
    **{name: name for name in WITNESS_FAILURE_NAMES},
}

FAILURE_NAME_MAP = {
    language: FAILURE_NAMES for language in ("lean", "rust")
}

DETAIL_CONSTRUCTORS = {
    "InputRevisionMismatch": "inputRevisionMismatch",
    "InitialMembership": "initialMembership",
    "ProducerMismatch": "producerMismatch",
    "ProjectionMismatch": "projectionMismatch",
    "SourceConstraintMismatch": "sourceConstraintMismatch",
    "Inclusion": "inclusion",
    "SuppliedValueMismatch": "suppliedValueMismatch",
    "ConstructionMismatch": "constructionMismatch",
    "MissingBinding": "missingBinding",
    "SignatureMismatch": "signatureMismatch",
    "GuardNotDominating": "guardNotDominating",
    "IncompleteBranchCoverage": "incompleteBranchCoverage",
    "FailureEmbeddingMismatch": "failureEmbeddingMismatch",
    "GoalMismatch": "goalMismatch",
    "RankViolation": "rankViolation",
    "ResourceLoweringMismatch": "resourceLoweringMismatch",
    "ResourceReplayMismatch": "resourceReplayMismatch",
    "ForgedClosure": "forgedClosure",
    "ForgedAcyclicity": "forgedAcyclicity",
    "MissingEvidence": "missingEvidence",
    "BasisMismatch": "basisMismatch",
    "DuplicateIdentity": "duplicateIdentity",
    "UnresolvedType": "unresolvedType",
    "UnresolvedFunction": "unresolvedFunction",
    "InvalidSignature": "invalidSignature",
    "InvalidInitialValue": "invalidInitialValue",
    "SiteEffectNotPermitted": "siteEffectNotPermitted",
    "TransformNotPermitted": "transformNotPermitted",
    "EmptyGoal": "emptyGoal",
    "GoalSourceConstraintUndefined": "goalSourceConstraintUndefined",
    "FailureEmbeddingOriginUndefined": "failureEmbeddingOriginUndefined",
    "ConstructionNotProduct": "constructionNotProduct",
    "FieldConstraintUnknownField": "fieldConstraintUnknownField",
    "ConstrainedNestedField": "constrainedNestedField",
    "ConstructionFieldSourceUndefined": "constructionFieldSourceUndefined",
    "NestedFieldUndeclared": "nestedFieldUndeclared",
    "NestedConstructionMismatch": "nestedConstructionMismatch",
    "CyclicConstruction": "cyclicConstruction",
    "ExplicitSiteOrderInvalid": "explicitSiteOrderInvalid",
    "InvalidEmptyTypeClosure": "invalidEmptyTypeClosure",
    "InvalidResourceDeclaration": "invalidResourceDeclaration",
    "InvalidLibrary": "invalidLibrary",
    "UnsupportedSchema": "unsupportedSchema",
    "UnknownField": "unknownField",
    "UnknownTag": "unknownTag",
    "Syntax": "syntax",
}

DETAIL_NAME_MAP = {
    language: {
        **DETAIL_CONSTRUCTORS,
        **{canonical_name: canonical_name for canonical_name in DETAIL_CONSTRUCTORS.values()},
    }
    for language in FAILURE_NAME_MAP
}


def canonical(value: object) -> str:
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"))


def command(argv: list[str], *, cwd: Path = ROOT, input_text: str | None = None) -> str:
    result = subprocess.run(argv, cwd=cwd, input=input_text, text=True, capture_output=True)
    if result.returncode:
        raise RuntimeError(f"{' '.join(argv)} failed\nstdout:\n{result.stdout}\nstderr:\n{result.stderr}")
    return result.stdout


def cargo() -> str:
    direct = Path.home() / ".cargo/bin/cargo"
    return str(direct) if direct.exists() else "cargo"


def generator(argument: str) -> dict:
    return json.loads(command([cargo(), "run", "--locked", "--quiet", "--manifest-path", str(GENERATOR), "--bin", "signatures", "--", argument]))


def generated_unique(exchange: str) -> dict:
    manifest = HERE / "rust_driver/Cargo.toml"
    output = command(
        [cargo(), "run", "--locked", "--quiet", "--manifest-path", str(manifest),
         "--bin", "generate_unique"],
        input_text=exchange,
    )
    return json.loads(output)


def generated_pure() -> dict:
    manifest = HERE / "rust_driver/Cargo.toml"
    output = command(
        [cargo(), "run", "--locked", "--quiet", "--manifest-path", str(manifest),
         "--bin", "generate_pure"],
    )
    return json.loads(output)


def generated_ambiguous() -> dict:
    manifest = HERE / "rust_driver/Cargo.toml"
    output = command(
        [cargo(), "run", "--locked", "--quiet", "--manifest-path", str(manifest),
         "--bin", "generate_ambiguous"],
    )
    return json.loads(output)


def generation_envelope(library: dict, entrypoints: list[dict]) -> str:
    request = canonical({"library": library, "entrypoints": entrypoints}) + "\n"
    response = json.loads(command([cargo(), "run", "--locked", "--quiet", "--manifest-path", str(GENERATOR), "--bin", "rust_generation_envelope"], input_text=request))
    if "exchange" not in response:
        raise RuntimeError(f"generation envelope failed: {response.get('error')}")
    return response["exchange"]


def inclusion_exchange() -> tuple[dict, str]:
    sys.path.insert(0, str(ROOT / "verification/declaration"))
    from semantic_invariant_inputs import library, tagged, string_spec

    value = library()
    value["nodes"] = [node for node in value["nodes"] if node["id"] != "union"]
    field = lambda name, target, required=True, nullable=False: {
        "wire_name": name, "slot": {"type_id": target, "required": required, "nullable": nullable}}
    allow = lambda target, nullable=False: tagged("Allow", fields={"key_format": None, "value": {"type_id": target, "nullable": nullable}})
    value["nodes"].extend([
        {"id": "order-source", "shape": tagged("Product", {"fields": [field("alpha", "text"), field("integer", "wide")], "extras": tagged("Reject")})},
        {"id": "order-destination", "shape": tagged("Product", {"fields": [field("integer", "wide"), field("alpha", "text")], "extras": tagged("Reject")})},
        {"id": "source-field-source", "shape": tagged("Product", {"fields": [field("x", "narrow")], "extras": tagged("Reject")})},
        {"id": "source-field-destination", "shape": tagged("Product", {"fields": [], "extras": tagged("Allow", fields={"key_format": tagged("Inline", tagged("Literal", "x")), "value": {"type_id": "narrow", "nullable": False}})})},
        {"id": "extras-value-source", "shape": tagged("Product", {"fields": [], "extras": tagged("Allow", fields={"key_format": tagged("Inline", tagged("Literal", "x")), "value": {"type_id": "zero-to-nine", "nullable": False}})})},
        {"id": "extras-value-destination", "shape": tagged("Product", {"fields": [], "extras": tagged("Allow", fields={"key_format": tagged("Inline", tagged("Literal", "x")), "value": {"type_id": "zero-to-ten", "nullable": False}})})},
        {"id": "extras-field-source", "shape": tagged("Product", {"fields": [], "extras": allow("zero-to-nine")})},
        {"id": "extras-field-optional", "shape": tagged("Product", {"fields": [field("y", "zero-to-ten", False)], "extras": allow("zero-to-ten")})},
        {"id": "extras-field-required", "shape": tagged("Product", {"fields": [field("y", "zero-to-ten")], "extras": allow("zero-to-ten")})},
        {"id": "inner-source", "shape": tagged("Product", {"fields": [field("x", "text")], "extras": allow("text", True)})},
        {"id": "inner-destination", "shape": tagged("Product", {"fields": [field("x", "text"), field("y", "text", False)], "extras": allow("text", True)})},
        {"id": "nested-source", "shape": tagged("Product", {"fields": [field("inner", "inner-source")], "extras": allow("text", True)})},
        {"id": "nested-destination", "shape": tagged("Product", {"fields": [field("inner", "inner-destination")], "extras": allow("text", True)})},
        {"id": "array-source", "shape": tagged("Array", {"item": {"type_id": "inner-source", "nullable": False}, "min_length": None, "max_length": None})},
        {"id": "array-destination", "shape": tagged("Array", {"item": {"type_id": "inner-destination", "nullable": False}, "min_length": None, "max_length": None})},
    ])
    exchange = generation_envelope(value, [{"identity": "root", "definition": "root"}])
    return json.loads(exchange)["basis"], exchange


def changed_exchange(original: dict, change) -> tuple[dict, str]:
    value = copy.deepcopy(original)
    change(value["composition"]["derivation"])
    digest = hashlib.sha256(canonical(value["composition"]).encode()).hexdigest()
    value["basis"]["problem_sha256"] = digest
    value["basis"]["observations_sha256"] = exhaustive.observations_digest(value["composition"])
    return copy.deepcopy(value["basis"]), canonical(value)


def changed_composition(original: dict, change) -> tuple[dict, str]:
    value = copy.deepcopy(original)
    change(value["composition"])
    value["basis"]["problem_sha256"] = hashlib.sha256(canonical(value["composition"]).encode()).hexdigest()
    value["basis"]["observations_sha256"] = exhaustive.observations_digest(value["composition"])
    return copy.deepcopy(value["basis"]), canonical(value)


def changed_document(original: dict, change) -> tuple[dict, str]:
    value = copy.deepcopy(original)
    change(value)
    value["basis"]["problem_sha256"] = hashlib.sha256(canonical(value["composition"]).encode()).hexdigest()
    value["basis"]["observations_sha256"] = exhaustive.observations_digest(value["composition"])
    return copy.deepcopy(value["basis"]), canonical(value)


def graph_sha256(library: dict) -> str:
    definitions = []
    for definition in sorted(library["definitions"], key=lambda row: row["id"]):
        projected = copy.deepcopy(definition)
        shape = projected["shape"]
        if shape["tag"] == "Operation":
            for outcome in sorted(shape["value"]["outcomes"], key=lambda row: row["id"]):
                outcome["cause"] = {"tag": outcome["cause"]["tag"]}
        definitions.append(projected)
    graph = {
        "profile": library["profile"],
        "nodes": sorted(library["nodes"], key=lambda row: row["id"]),
        "definitions": definitions,
    }
    return hashlib.sha256(canonical(graph).encode()).hexdigest()


def invalid_initial_value(composition: dict) -> None:
    supplied = {"tag": "SuppliedValue", "value": {"tag": "Present", "value": {"tag": "Bool", "value": True}}}
    composition["problem"]["initial_inputs"][0]["source"] = copy.deepcopy(supplied)
    composition["derivation"]["witness"]["input_snapshot"]["initial_inputs"][0]["source"] = copy.deepcopy(supplied)


def problem_initial_value_only(composition: dict) -> None:
    supplied = {"tag": "SuppliedValue", "value": {"tag": "Present", "value": {"tag": "Bool", "value": True}}}
    composition["problem"]["initial_inputs"][0]["source"] = supplied


def nested_presence_guard(composition: dict) -> None:
    snapshots = (composition["problem"], composition["derivation"]["witness"]["input_snapshot"])
    for snapshot in snapshots:
        second_input = copy.deepcopy(snapshot["initial_inputs"][0])
        second_input["id"] = "second-argument"
        snapshot["initial_inputs"].append(second_input)
        second_guard = copy.deepcopy(snapshot["invocation_domain"]["guards"][0])
        second_guard["id"] = "second-presence"
        snapshot["invocation_domain"]["guards"].append(second_guard)
    composition["derivation"]["witness"]["initial_membership"].append(
        ["second-argument", {"tag": "Absent"}])
    arms = composition["derivation"]["plan"]["root"]["node"]["fields"]["arms"]
    inner = []
    for tag in ("Absent", "Null", "Present"):
        arm = next(arm for arm in arms if arm[0]["tag"] == tag)
        child = copy.deepcopy(arm[1])
        child["rank"] = "2"
        inner.append([{"tag": tag}, child])
    index = next(index for index, arm in enumerate(arms) if arm[0]["tag"] == "Absent")
    arms[index][1] = {"node": {"tag": "Guard", "fields": {
        "arms": inner, "guard": "second-presence",
        "inspected": {"path": [], "producer": {"tag": "Initial", "value": "second-argument"}}}},
        "rank": "1"}


def forged_resource_requirement(derivation: dict) -> None:
    derivation["plan"]["root"]["node"]["fields"]["invocation"]["resources"][0]["requirement"] = "forged"


def initial_resource_removed(composition: dict) -> None:
    for snapshot in (composition["problem"], composition["derivation"]["witness"]["input_snapshot"]):
        snapshot["initial_inputs"][0]["resource"] = None


def required_resource_revision_changed(composition: dict) -> None:
    for snapshot in (composition["problem"], composition["derivation"]["witness"]["input_snapshot"]):
        snapshot["signatures"][0]["resource_inputs"][0]["required_revision"] = "1"


def pending_failure_terminal(derivation: dict) -> None:
    arms = derivation["plan"]["root"]["node"]["fields"]["arms"]
    absent = next(arm for arm in arms if arm[0]["tag"] == "Absent")
    present = next(arm for arm in arms if arm[0]["tag"] == "Present")
    absent[1] = copy.deepcopy(present[1])


def order_and_missing_binding(composition: dict) -> None:
    for snapshot in (composition["problem"], composition["derivation"]["witness"]["input_snapshot"]):
        second = copy.deepcopy(snapshot["invocation_domain"]["sites"][0])
        second["id"] = "second"
        snapshot["invocation_domain"]["sites"].append(second)
        snapshot["explicit_order"].append(["second", "operation"])
    composition["derivation"]["plan"]["root"]["node"]["fields"]["invocation"]["bindings"] = []


def optional_initial_source(composition: dict) -> None:
    for snapshot in (composition["problem"], composition["derivation"]["witness"]["input_snapshot"]):
        snapshot["initial_inputs"][0]["contract"]["required"] = False
    fields = composition["derivation"]["plan"]["root"]["node"]["fields"]["invocation"]["bindings"][0][1]["fields"]
    fields["projection"]["source"]["required"] = False
    fields["projection"]["destination"]["required"] = False
    fields["compatibility"]["value"]["source"]["required"] = False


def undefined_text_meaning(value: dict) -> None:
    old_digest = value["basis"]["graph_sha256"]
    text = next(node for node in value["signatures"]["nodes"] if node["id"] == "text")
    text["shape"]["value"]["lengths"] = [
        {"unit": {"tag": "Graphemes"}, "minimum": None, "maximum": "8"}
    ]
    new_digest = graph_sha256(value["signatures"])

    def replace_digest(item):
        if isinstance(item, dict):
            for key, child in item.items():
                item[key] = replace_digest(child)
        elif isinstance(item, list):
            for index, child in enumerate(item):
                item[index] = replace_digest(child)
        elif item == old_digest:
            return new_digest
        return item

    replace_digest(value)


def undefined_operation_meaning(value: dict) -> None:
    undefined_text_meaning(value)
    composition = value["composition"]
    for snapshot in (composition["problem"], composition["derivation"]["witness"]["input_snapshot"]):
        outcome = copy.deepcopy(snapshot["signatures"][0]["outcomes"][0])
        outcome["id"] = "undefined"
        outcome["form"] = {"tag": "DeclaredFailure"}
        outcome["cause"] = {"tag": "ExternalCondition", "fields": {"specification": outcome["cause"]["fields"]["origin"]}}
        outcome["value_ports"][0]["contract"]["type_id"] = "text"
        snapshot["signatures"][0]["outcomes"].append(outcome)
    arms = composition["derivation"]["plan"]["root"]["node"]["fields"]["arms"]
    arms.append(["undefined", copy.deepcopy(arms[0][1])])


def merged_independent_sequence(left: dict, right: dict) -> tuple[dict, str]:
    value = copy.deepcopy(left)
    left_closure = value["composition"]["derivation"]["selection"]["fields"]["closure"]
    right_closure = copy.deepcopy(
        right["composition"]["derivation"]["selection"]["fields"]["closure"]
    )
    for snapshot in (
        value["composition"]["problem"],
        value["composition"]["derivation"]["witness"]["input_snapshot"],
        left_closure["input_snapshot"],
        right_closure["input_snapshot"],
    ):
        snapshot["explicit_order"] = []
    states = []
    state_ids = {}
    for closure in (left_closure, right_closure):
        for node in closure["states"]:
            key = canonical(node["state"])
            if key not in state_ids:
                state_ids[key] = str(len(states))
                states.append({
                    "state": copy.deepcopy(node["state"]),
                    "choices": [],
                    "terminals": [],
                    "rejected_connections": [],
                    "missing_supply": [],
                })
    for closure in (left_closure, right_closure):
        remap = {
            str(index): state_ids[canonical(node["state"])]
            for index, node in enumerate(closure["states"])
        }
        for node in closure["states"]:
            target = states[int(state_ids[canonical(node["state"])])]
            choices = copy.deepcopy(node["choices"])
            for choice in choices:
                choice["children"] = [remap[child] for child in choice["children"]]
            for field in ("choices", "terminals", "rejected_connections", "missing_supply"):
                for item in choices if field == "choices" else node[field]:
                    if canonical(item) not in {canonical(existing) for existing in target[field]}:
                        target[field].append(item)
    left_closure["states"] = states
    value["basis"]["problem_sha256"] = hashlib.sha256(
        canonical(value["composition"]).encode()
    ).hexdigest()
    value["basis"]["observations_sha256"] = exhaustive.observations_digest(value["composition"])
    return copy.deepcopy(value["basis"]), canonical(value)


def cases() -> dict:
    expected, exchange = inclusion_exchange()
    pairs = [
        ("C1", "not-a", "not-a"), ("C2", "c2-source", "c2-destination"),
        ("P-field-order", "order-source", "order-destination"),
        ("P-source-field-extras", "source-field-source", "source-field-destination"),
        ("P-extras-value", "extras-value-source", "extras-value-destination"),
        ("P-extras-value-reverse", "extras-value-destination", "extras-value-source"),
        ("P-extras-optional", "extras-field-source", "extras-field-optional"),
        ("P-extras-required", "extras-field-source", "extras-field-required"),
        ("C3", "c3-source", "c3-destination"), ("C4", "zero-to-nine", "zero-to-ten"),
        ("C5", "scalar-one", "scalar-two"), ("I1", "text", "not-a"),
        ("I2", "i2-source", "i2-destination"), ("I3", "i3-source", "i3-destination"),
        ("I4", "zero-to-ten", "zero-to-nine"), ("I5", "scalar-two", "scalar-one"),
        ("I6", "i6-source", "i6-destination"), ("I7", "bytes-source", "ordinary-object"),
        ("nested-presence", "nested-source", "nested-destination"),
        ("array-presence", "array-source", "array-destination"),
    ]
    result = [{"case": f"inclusion/{name}", "kind": "inclusion", "expected": canonical(expected),
               "exchange": exchange, "source": source, "destination": destination}
              for name, source, destination in pairs]
    composition = generator("composition")
    result.append({"case": "generation/accepted", "kind": "generation",
                   "expected": canonical(composition["basis"]), "exchange": canonical(composition)})
    basis, altered = changed_exchange(
        composition,
        lambda d: d["witness"]["resource_traces"][0]["lowering"]["graph"].__setitem__(
            "revision",
            str(int(d["witness"]["resource_traces"][0]["lowering"]["graph"]["revision"]) + 1),
        ),
    )
    result.append({"case": "generation/wire-resource-lowering-changed", "kind": "generation",
                   "expected": canonical(basis), "exchange": altered})
    execution_scenarios = ["presence", "validate", "flow", "field", "index"]
    generated_scenarios = execution_scenarios + [
        "pure", "sequence",
        "independent_sequence_left", "independent_sequence_right",
    ]
    execution_exchanges = json.loads(command(
        [cargo(), "run", "--locked", "--quiet", "--manifest-path",
         str(ROOT / "verification/execution/rust_driver/Cargo.toml"), "--bin", "generate"],
        input_text=canonical({"scenarios": generated_scenarios})))
    for scenario in execution_scenarios:
        derived = json.loads(execution_exchanges[scenario])
        result.append({"case": f"generation/execution-{scenario}", "kind": "generation",
                       "expected": canonical(derived["basis"]), "exchange": canonical(derived)})
    presence = json.loads(execution_exchanges["presence"])
    basis, altered = changed_composition(presence, invalid_initial_value)
    result.append({"case": "rejection/composition-input-invalid-initial-value", "kind": "generation",
                   "expected": canonical(basis), "exchange": altered})
    basis, altered = changed_exchange(presence, pending_failure_terminal)
    result.append({"case": "rejection/pending-failure-success-terminal", "kind": "generation",
                   "expected": canonical(basis), "exchange": altered})
    basis, altered = changed_composition(presence, problem_initial_value_only)
    result.append({"case": "rejection/composition-input-before-snapshot", "kind": "generation",
                   "expected": canonical(basis), "exchange": altered})
    basis, altered = changed_composition(presence, nested_presence_guard)
    result.append({"case": "rejection/nested-presence-guard", "kind": "generation",
                   "expected": canonical(basis), "exchange": altered})
    flow = json.loads(execution_exchanges["flow"])
    basis, altered = changed_exchange(flow, forged_resource_requirement)
    result.append({"case": "rejection/resource-requirement-forged", "kind": "generation",
                   "expected": canonical(basis), "exchange": altered})
    basis, altered = changed_composition(flow, initial_resource_removed)
    result.append({"case": "rejection/initial-resource-removed", "kind": "generation",
                   "expected": canonical(basis), "exchange": altered})
    basis, altered = changed_composition(flow, required_resource_revision_changed)
    result.append({"case": "rejection/required-resource-revision-changed", "kind": "generation",
                   "expected": canonical(basis), "exchange": altered})
    ordered = json.loads(execution_exchanges["pure"])
    basis, altered = changed_composition(ordered, order_and_missing_binding)
    result.append({"case": "rejection/order-and-missing-binding", "kind": "generation",
                   "expected": canonical(basis), "exchange": altered})
    basis, altered = changed_composition(ordered, optional_initial_source)
    result.append({"case": "rejection/inclusion-unresolved-presence", "kind": "generation",
                   "expected": canonical(basis), "exchange": altered})
    undefined = json.loads(execution_exchanges["sequence"])
    basis, altered = changed_document(undefined, undefined_operation_meaning)
    result.append({"case": "rejection/operation-undefined-meaning", "kind": "generation",
                   "expected": canonical(basis), "exchange": altered})
    mutations = [
        ("plan-branch-deleted", lambda d: d["plan"]["root"]["node"]["fields"]["arms"].pop()),
        ("binding-producer-replaced", lambda d: d["plan"]["root"]["node"]["fields"]["arms"][1][1]["node"]["fields"]["invocation"]["bindings"][0][1]["fields"]["value"]["producer"]["fields"].__setitem__("site", "handler")),
        ("resource-trace-changed", lambda d: d["witness"]["resource_traces"][0]["reachability"]["path"].append("forged")),
        ("resource-acyclic-explored-marking-deleted", lambda d: d["witness"]["resource_traces"][0]["acyclicity"]["explored_markings"].pop()),
        ("resource-acyclic-explored-marking-added", lambda d: d["witness"]["resource_traces"][0]["acyclicity"]["explored_markings"].append(copy.deepcopy(d["witness"]["resource_traces"][0]["acyclicity"]["explored_markings"][0]))),
        ("selection-key-changed", lambda d: d["selection"].__setitem__("tag", "LeastCost")),
        ("input-snapshot-changed", lambda d: d["witness"]["input_snapshot"].__setitem__("revision", "2")),
    ]
    for name, mutate in mutations:
        basis, altered = changed_exchange(composition, mutate)
        result.append({"case": f"generation/{name}", "kind": "generation",
                       "expected": canonical(basis), "exchange": altered})
    kept = copy.deepcopy(composition)
    kept["composition"]["derivation"]["plan"]["root"]["node"]["fields"]["arms"].pop()
    result.append({"case": "generation/derivation-changed-basis-kept", "kind": "generation",
                   "expected": canonical(composition["basis"]), "exchange": canonical(kept)})

    unique = generated_unique(canonical(composition))
    result.append({"case": "unique/accepted", "kind": "generation",
                   "expected": canonical(unique["basis"]), "exchange": canonical(unique)})
    basis, altered = changed_exchange(
        unique,
        lambda d: d["selection"]["fields"].__setitem__("canonical_plan", "forged"),
    )
    result.append({"case": "unique/wire-canonical-plan-forged", "kind": "generation",
                   "expected": canonical(basis), "exchange": altered})
    for mutation in ("local", "initial", "successor", "frontier", "obligations"):
        result.append({"case": f"unique/closure-{mutation}", "kind": "closure",
                       "expected": canonical(unique["basis"]), "exchange": canonical(unique),
                       "mutation": mutation})
    result.append({"case": "unique/canonical-plan-key-changed", "kind": "selection",
                   "expected": canonical(unique["basis"]), "exchange": canonical(unique),
                   "mutation": "canonical-plan-key"})
    ambiguous = generated_ambiguous()
    result.append({"case": "unique/multiple-canonical-programs", "kind": "generation",
                   "expected": canonical(ambiguous["basis"]), "exchange": canonical(ambiguous)})
    independent_basis, independent_exchange = merged_independent_sequence(
        json.loads(execution_exchanges["independent_sequence_left"]),
        json.loads(execution_exchanges["independent_sequence_right"]),
    )
    result.append({"case": "unique/independent-pure-before-http", "kind": "generation",
                   "expected": canonical(independent_basis), "exchange": independent_exchange})

    def any_policy_with_unique(c):
        c["problem"]["selection_policy"] = {"tag": "AnyFeasible"}
        c["derivation"]["witness"]["input_snapshot"]["selection_policy"] = {"tag": "AnyFeasible"}
        c["derivation"]["selection"]["fields"]["closure"]["input_snapshot"]["selection_policy"] = {"tag": "AnyFeasible"}
    basis, altered = changed_composition(unique, any_policy_with_unique)
    result.append({"case": "unique/evidence-for-any-feasible-policy", "kind": "generation",
                   "expected": canonical(basis), "exchange": altered})

    unspecified = copy.deepcopy(composition)
    unspecified["composition"]["problem"]["selection_policy"] = None
    unspecified["composition"]["derivation"]["witness"]["input_snapshot"]["selection_policy"] = None
    unspecified["basis"]["problem_sha256"] = hashlib.sha256(canonical(unspecified["composition"]).encode()).hexdigest()
    unspecified["basis"]["observations_sha256"] = exhaustive.observations_digest(unspecified["composition"])
    result.append({"case": "unique/any-feasible-with-unspecified-policy", "kind": "generation",
                   "expected": canonical(unspecified["basis"]), "exchange": canonical(unspecified)})

    pure = generated_pure()
    witness_mutations = [
        ("input-revision-mismatch", composition,
         lambda d: d["plan"].__setitem__("input_revision", "forged")),
        ("producer-mismatch", json.loads(execution_exchanges["presence"]),
         lambda d: d["plan"]["root"]["node"]["fields"]["inspected"].__setitem__(
             "producer", {"tag": "Initial", "value": "missing"})),
        ("source-constraint-mismatch", pure,
         lambda d: d["plan"]["root"]["node"]["fields"]["invocation"]["bindings"][0][1]["fields"]["value"].__setitem__(
             "producer", {"tag": "Initial", "value": "missing"})),
        ("projection-mismatch", pure,
         lambda d: d["plan"]["root"]["node"]["fields"]["invocation"]["bindings"][0][1]["fields"]["projection"]["destination"].__setitem__(
             "required", False)),
        ("inclusion", pure,
         lambda d: d["plan"]["root"]["node"]["fields"]["invocation"]["bindings"][0][1]["fields"]["compatibility"]["value"]["pairs"][0].__setitem__(
             "rule", {"tag": "Unit"})),
        ("supplied-value-mismatch", json.loads(execution_exchanges["presence"]),
         lambda d: d["plan"]["root"]["node"]["fields"]["arms"][0][1]["node"]["value"]["fields"]["value"]["fields"]["compatibility"]["fields"].__setitem__(
             "value", {"tag": "Null"})),
        ("construction-mismatch", json.loads(execution_exchanges["flow"]),
         lambda d: d["plan"]["root"]["node"]["fields"]["invocation"]["bindings"][0][1]["fields"].__setitem__(
             "construction", "forged")),
        ("signature-mismatch", pure,
         lambda d: d["plan"]["root"]["node"]["fields"]["invocation"]["function"].__setitem__(
             "identity", "forged")),
        ("guard-not-dominating", json.loads(execution_exchanges["presence"]),
         lambda d: d["plan"]["root"]["node"]["fields"]["inspected"].__setitem__(
             "path", [{"tag": "Field", "value": "forged"}])),
        ("failure-embedding-mismatch", json.loads(execution_exchanges["presence"]),
         lambda d: d["plan"]["root"]["node"]["fields"]["arms"][0][1]["node"]["value"]["fields"].__setitem__(
             "embedding", "forged")),
        ("goal-mismatch", pure,
         lambda d: d["plan"]["root"]["node"]["fields"]["arms"][0][1]["node"]["value"].__setitem__(
             "value", [])),
        ("rank-violation", pure,
         lambda d: d["plan"]["root"]["node"]["fields"]["arms"][0][1].__setitem__(
             "rank", "0")),
        ("resource-replay-mismatch", composition,
         lambda d: d["witness"]["resource_traces"][0]["reachability"]["final_marking"]["places"][2].__setitem__(
             1, [])),
    ]
    for name, source, mutate in witness_mutations:
        basis, altered = changed_exchange(source, mutate)
        result.append({"case": f"witness-constructor/{name}", "kind": "generation",
                       "expected": canonical(basis), "exchange": altered})
    basis, altered = changed_exchange(
        pure,
        lambda d: d["plan"]["root"]["node"]["fields"]["invocation"].__setitem__(
            "bindings", []),
    )
    result.append({"case": "rejection/wire-root-invocation-bindings-empty", "kind": "generation",
                   "expected": canonical(basis), "exchange": altered})
    basis, altered = changed_exchange(
        pure, lambda d: d["plan"]["root"]["node"]["fields"]["arms"].pop())
    result.append({"case": "rejection/root-invoke-last-arm-deleted", "kind": "generation",
                   "expected": canonical(basis), "exchange": altered})
    basis, altered = changed_exchange(
        pure,
        lambda d: d["witness"]["initial_membership"][0].__setitem__(
            1, {"tag": "Present", "value": {"tag": "String", "value": "x"}}),
    )
    result.append({"case": "rejection/initial-membership-string", "kind": "generation",
                   "expected": canonical(basis), "exchange": altered})
    for operation, mutation in [("reachability", "valid"), ("reachability", "final-marking"),
                                ("closure", "valid"), ("closure", "steps"),
                                ("acyclic", "valid"), ("acyclic", "frontier"),
                                ("acyclic", "cycle")]:
        result.append({"case": f"witness/{operation}-{mutation}", "kind": "witness", "operation": operation, "mutation": mutation})
    return {"schema": "ncoh-composition-comparison@1", "cases": result}


def runners(input_path: Path) -> dict[str, list[str]]:
    return {
        "lean": ["lake", "env", "lean", "--run", "../verification/lean_runner.lean", str(input_path)],
        "rust": [cargo(), "run", "--locked", "--quiet", "--manifest-path", str(HERE / "rust_driver/Cargo.toml"), "--bin", "composition_comparison_driver", "--", str(input_path)],
    }


def normalized(language: str, row: dict) -> dict:
    value = dict(row)
    failure = value.get("failure")
    if failure is None:
        return value
    mapped = FAILURE_NAME_MAP[language].get(failure)
    if mapped is None:
        raise RuntimeError(f"{language} returned an unmapped failure name: {failure}")
    value["failure"] = mapped
    detail = value.get("detail")
    if detail is not None:
        detail = dict(detail)
        constructor = detail.get("constructor")
        mapped_constructor = DETAIL_NAME_MAP[language].get(constructor)
        if mapped_constructor is None:
            raise RuntimeError(
                f"{language} returned an unmapped detail constructor: {constructor}"
            )
        detail["constructor"] = mapped_constructor
        value["detail"] = detail
    return value


def main() -> int:
    selected = set(sys.argv[1:])
    with tempfile.TemporaryDirectory(prefix="ncoh-composition-") as directory:
        path = Path(directory) / "cases.json"
        path.write_text(canonical(cases()), encoding="utf-8")
        outputs = {}
        specs = runners(path)
        if selected:
            specs = {language: argv for language, argv in specs.items() if language in selected}
        for language, argv in specs.items():
            cwd = ROOT / "solver/composition/lean" if language == "lean" else ROOT
            outputs[language] = {row["case"]: row for row in json.loads(command(argv, cwd=cwd))}
        if "lean" not in outputs:
            for identity in next(iter(outputs.values())):
                print(canonical({"case": identity, "results": {language: table[identity] for language, table in outputs.items()}}))
            return 0
        failed = False
        for identity in outputs["lean"]:
            rows = [outputs[language][identity] for language in outputs]
            print(canonical({"case": identity, "results": dict(zip(outputs, rows))}))
            expected_row = normalized("lean", outputs["lean"][identity])
            for language, table in outputs.items():
                if normalized(language, table[identity]) != expected_row:
                    failed = True
                    print(f"{identity}: {language} differs from Lean", file=sys.stderr)
        return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
