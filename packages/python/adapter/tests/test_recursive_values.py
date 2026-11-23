# SPDX-FileCopyrightText: 2026 barineco
# SPDX-License-Identifier: MIT

import pytest

from necoherence.signature_values import path_steps_json
from necoherence.signature_values import REFERENCE_CYCLE, PresentValue, ValueContext, ValueFailure, variant
from necoherence.type_signatures import _graph


def node(name, shape):
    return {"id": name, "shape": shape}


def product(fields=(), extras=None):
    return variant(
        "Product",
        {
            "fields": [
                {
                    "wire_name": name,
                    "slot": {"type_id": target, "required": True, "nullable": False},
                }
                for name, target in fields
            ],
            "extras": (
                variant("Reject")
                if extras is None
                else variant(
                    "Allow",
                    {
                        "key_format": None,
                        "value": {"type_id": extras, "nullable": False},
                    },
                )
            ),
        },
    )


def array(target):
    return variant(
        "Array",
        {
            "item": {"type_id": target, "nullable": False},
            "min_length": None,
            "max_length": None,
        },
    )


def union(branches):
    return variant(
        "TaggedUnion",
        {
            "branches": [
                {"wire_tag": tag, "target": target, "selector": variant("InternalTag")}
                for tag, target in branches
            ]
        },
    )


def context(nodes):
    return ValueContext(_graph({"profile": {"tag": {"key": "kind", "format": None, "sealed": []}}, "nodes": nodes, "definitions": []}))


def test_finite_recursive_leaf_not_and_or():
    ctx = context(
        [
            node(
                "Goal", union([(name, name) for name in ("leaf", "not", "and", "or")])
            ),
            node("leaf", product()),
            node("not", product([("goal", "Goal")])),
            node("and", product([("goals", "Goals")])),
            node("or", product([("goals", "Goals")])),
            node("Goals", array("Goal")),
        ]
    )
    leaf = {"kind": "leaf"}
    negated = {"kind": "not", "goal": leaf}
    for value in (
        leaf,
        negated,
        {"kind": "and", "goals": [leaf, negated]},
        {"kind": "or", "goals": [{"kind": "not", "goal": negated}, leaf]},
    ):
        assert ctx.validate("Goal", value) == value


def test_recursive_array_deeper_than_node_count_and_extras():
    ctx = context([node("Array", array("Array"))])
    value = []
    for _ in range(32):
        value = [value, []]
    assert ctx.validate("Array", value) == value
    ctx = context([node("Map", product(extras="Map"))])
    assert ctx.validate("Map", {"child": {"child": {}}, "sibling": {}})


@pytest.mark.parametrize(
    "shapes,trace",
    [
        ([node("A", variant("Alias", {"target": "A"}))], ("A",)),
        (
            [
                node("A", variant("Alias", {"target": "B"})),
                node("B", variant("Alias", {"target": "A"})),
            ],
            ("A", "B"),
        ),
        ([node("A", union([("loop", "A")]))], ("A",)),
        (
            [
                node("A", variant("Alias", {"target": "U"})),
                node("U", union([("loop", "A")])),
            ],
            ("A", "U"),
        ),
    ],
)
@pytest.mark.parametrize("child", [False, True])
def test_reference_cycles_preserve_failure_fields(shapes, trace, child):
    ctx = context([*shapes, node("Parent", product([("child", "A")]))])
    observed = {"kind": "loop"}
    value = {"child": observed} if child else observed
    with pytest.raises(ValueFailure) as caught:
        ctx.validate("Parent" if child else "A", value)
    failure = caught.value
    assert failure.type_ref == ctx.reference("A")
    assert failure.condition == REFERENCE_CYCLE
    assert path_steps_json(failure.value_path) == list((("child",) if child else ()))
    assert failure.observed == PresentValue(observed)
    assert failure.reference_trace == tuple(ctx.reference(name) for name in reversed((("Parent",) if child else ()) + trace))
    assert failure.definition_ref == {"source": ctx.reference("A")["source"], "name": "A"}
    assert failure.origin == {"source": ctx.reference("A")["source"], "pointer": []}
