# SPDX-FileCopyrightText: 2026 barineco
# SPDX-License-Identifier: MIT

import json
from copy import deepcopy
from pathlib import Path

import pytest

from necoherence.signature_values import ValueContext, ValueFailure, wrapDecode


VECTORS = json.loads(
    (Path(__file__).resolve().parents[2] / "comparison/declaration/wrapper_base64_vectors.json").read_text()
)
CASES = [
    (branch, case)
    for branch in VECTORS["branches"]
    for case in branch["cases"]
]


def test_wrapper_base64_vector_schema_and_coverage():
    assert VECTORS["schema"] == "wrapper-base64-vectors@1"
    assert len(VECTORS["branches"]) == 25
    assert len({branch["id"] for branch in VECTORS["branches"]}) == 25
    assert len(CASES) == 55
    assert len({case["id"] for _, case in CASES}) == 55


@pytest.mark.parametrize("branch,case", CASES, ids=[case["id"] for _, case in CASES])
def test_wrapper_base64_value_decision_matches_lean(branch, case):
    profile = VECTORS["profiles"][branch["profile"]]
    graph = VECTORS["type_graphs"][branch["type_graph"]]
    context = ValueContext.from_signature_nodes(profile, graph["nodes"])
    try:
        context.validate(graph["root"], case["input"])
    except ValueFailure as failure:
        tag, separator, argument = failure.condition.partition(":")
        condition = {"tag": tag}
        if separator:
            condition["value"] = argument
        actual = {
            "accepted": False,
            "condition": condition,
            "path": [
                {"tag": "Index" if type(step) is int else "Field", "value": str(step)}
                for step in failure.value_path
            ],
        }
    else:
        actual = {"accepted": True, "condition": None, "path": []}
    assert actual == case["expected"]


BASE64_CASES = [
    (branch, case) for branch, case in CASES
    if branch["id"].startswith(("1-", "2-", "3-"))
]


@pytest.mark.parametrize("branch,case", BASE64_CASES, ids=[case["id"] for _, case in BASE64_CASES])
def test_standalone_bytes_wrapper_decode_matches_lean(branch, case):
    profile = VECTORS["profiles"][branch["profile"]]
    wrapper = profile["bytes_policy"]["wrapper"]
    if case["expected"]["accepted"]:
        assert wrapDecode(profile, wrapper, case["input"]) == case["input"]["bytes"]
    else:
        with pytest.raises(ValueFailure):
            wrapDecode(profile, wrapper, case["input"])


UNKNOWN_FAILURE_CASES = [
    (branch, case) for branch, case in CASES
    if branch["id"].startswith("8-") or branch["id"] == "4-string-wrapper-format"
]


@pytest.mark.parametrize(
    "branch,case", UNKNOWN_FAILURE_CASES,
    ids=[case["id"] for _, case in UNKNOWN_FAILURE_CASES],
)
def test_unknown_wrapper_failure_keeps_nested_array_path(branch, case):
    profile = VECTORS["profiles"][branch["profile"]]
    graph = VECTORS["type_graphs"]["unknown"]
    context = ValueContext.from_signature_nodes(profile, graph["nodes"])
    with pytest.raises(ValueFailure) as caught:
        context.validate(graph["root"], {"nested": [case["input"]]})
    expected = case["expected"]
    condition = expected["condition"]
    assert caught.value.condition == condition["tag"] + (
        ":" + condition["value"] if "value" in condition else ""
    )
    assert caught.value.value_path == ("nested", 0, *(
        int(step["value"]) if step["tag"] == "Index" else step["value"]
        for step in expected["path"]
    ))


@pytest.mark.parametrize("graph_name", ["unknown", "sealed"])
@pytest.mark.parametrize("wrapped", [False, True])
@pytest.mark.parametrize("text,changes,condition", [
    ("other", {"const_value": "required"}, "ConstMismatch"),
    ("required", {"const_value": "required"}, None),
    ("other", {"enum_values": ["required"]}, "EnumMismatch"),
    ("required", {"enum_values": ["required"]}, None),
    ("", {"lengths": [{"unit": {"tag": "UnicodeScalars"}, "minimum": "1", "maximum": None}]}, "StringLength"),
    ("aa", {"lengths": [{"unit": {"tag": "UnicodeScalars"}, "minimum": None, "maximum": "1"}]}, "StringLength"),
    ("a", {"lengths": [{"unit": {"tag": "UnicodeScalars"}, "minimum": "1", "maximum": "1"}]}, None),
    ("é", {"lengths": [{"unit": {"tag": "Utf8Bytes"}, "minimum": None, "maximum": "1"}]}, "StringLength"),
    ("\ud800", {}, "InvalidDataModel"),
])
def test_sealed_string_leaf_constraints_keep_value_path(graph_name, wrapped, text, changes, condition):
    profile = deepcopy(VECTORS["profiles"]["default"])
    leaf = profile["tag"]["sealed"][0]["fields"][0]["leaf"]["value"]
    leaf.update(changes)
    graph = VECTORS["type_graphs"][graph_name]
    context = ValueContext.from_signature_nodes(profile, graph["nodes"])
    sealed = {"kind": "sealed", "label": {"text": text} if wrapped else text}
    value = {"nested": [sealed]} if graph_name == "unknown" else sealed
    if wrapped and condition == "InvalidDataModel":
        condition = "WrongValueKind:wrapper text"
    if condition is None:
        assert context.validate(graph["root"], value) == value
    else:
        with pytest.raises(ValueFailure) as caught:
            context.validate(graph["root"], value)
        assert caught.value.condition == condition
        assert caught.value.value_path == (("nested", 0, "label") if graph_name == "unknown" else ("label",))
