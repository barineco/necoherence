# SPDX-FileCopyrightText: 2026 barineco
# SPDX-License-Identifier: MIT

"""A ValueContext prepares a graph once; validation through it prepares nothing and keeps no input."""

from __future__ import annotations

import gc
import time
import weakref
from collections.abc import Callable
from typing import Any, cast

import pytest

from necoherence import semantic_composition as sc
from necoherence import signature_values as sv
from necoherence.signature_values import DecimalLiteral, JsonFailure, ValueContext, exact_from_json, variant
from necoherence.type_signatures import _graph
from v4_samples import profile, string_spec


class Mapping(dict[str, Any]):
    """A weakly referenceable stand-in for a JSON object."""


class Sequence(list[Any]):
    """A weakly referenceable stand-in for a JSON array."""


def _nodes() -> list[dict[str, Any]]:
    pair = {
        "fields": [{"wire_name": "a", "slot": {"type_id": "Bool", "required": True, "nullable": False}}],
        "extras": variant("Reject"),
    }
    items = {"item": {"type_id": "Pair", "nullable": False}, "min_length": None, "max_length": None}
    graphemes = [{"unit": variant("Graphemes"), "minimum": "1", "maximum": "5"}]
    return [
        {"id": "Bool", "shape": variant("Boolean", {"const_value": None})},
        {"id": "Pair", "shape": variant("Product", pair)},
        {"id": "Items", "shape": variant("Array", items)},
        {"id": "Name", "shape": variant("String", string_spec(lengths=graphemes))},
        {"id": "Opaque", "shape": variant("Opaque", {"type_name": "external"})},
        {"id": "Holder", "shape": variant("Array", {"item": {"type_id": "Opaque", "nullable": False}, "min_length": None, "max_length": None})},
    ]


def _rules() -> dict[str, Any]:
    return {"properties": [], "indic_conjunct": [], "extended_pictographic": []}


def _context(padding: int = 0) -> ValueContext:
    value = profile()
    value["grapheme_rules"] = _rules()
    filler = [{"id": f"F{index}", "shape": variant("Boolean", {"const_value": None})} for index in range(padding)]
    return ValueContext(_graph({"profile": value, "nodes": [*_nodes(), *filler], "definitions": []}))


def _slot(ctx: ValueContext, name: str, required: bool = True, nullable: bool = False) -> sc.SlotContract:
    return sc.SlotContract(sc.TypeRef(ctx.reference(name)["source"], name, ()), required, nullable)


ACCEPTED_ITEMS = [{"a": True} for _ in range(25)]
REJECTED_ITEMS = [*ACCEPTED_ITEMS, {"a": 1}]


class Calls:
    def __init__(self, monkeypatch: pytest.MonkeyPatch) -> None:
        self.counts: dict[str, int] = {}
        self.keys: list[object] = []
        self._monkeypatch = monkeypatch

    def count(self, owner: object, name: str) -> None:
        original = getattr(owner, name)
        self.counts[name] = 0

        def wrapper(*args: Any, **keywords: Any) -> Any:
            self.counts[name] += 1
            return original(*args, **keywords)

        self._monkeypatch.setattr(owner, name, wrapper)

    def watch_keys(self) -> None:
        original = sv.ref_key

        def wrapper(reference: object) -> object:
            self.keys.append(reference)
            return original(reference)

        self._monkeypatch.setattr(sv, "ref_key", wrapper)


def _install(monkeypatch: pytest.MonkeyPatch) -> Calls:
    calls = Calls(monkeypatch)
    for name in ("meaning_obligations", "_obligations", "_reachable_types", "_meaning_reasons", "_node_children", "_link"):
        calls.count(ValueContext, name)
    for name in ("build_grapheme_tables", "_grapheme_table", "prepare_grapheme_rules", "prepare_profile"):
        calls.count(sv, name)
    calls.count(ValueContext, "__init__")
    calls.watch_keys()
    return calls


def _operations(ctx: ValueContext) -> list[tuple[str, Callable[[Any], object], object]]:
    items = _slot(ctx, "Items")
    optional = _slot(ctx, "Items", False, True)
    native = sc._type_ref_native(items.type_ref)
    return [
        ("validate_value", lambda value: ctx.validate_value("Items", value), "Items"),
        ("accepts_value", lambda value: sc.accepts_value(ctx, items.type_ref, value), native),
        ("accepts_slot", lambda value: sc.accepts_slot(ctx, items, sc.PresentValue(value)), native),
        ("validate_slot", lambda value: sc.validate_slot(ctx, items, sc.PresentValue(value)), native),
        ("accepts_slot_absent", lambda value: sc.accepts_slot(ctx, optional, sc.ABSENT_VALUE), native),
        ("accepts_slot_null", lambda value: sc.accepts_slot(ctx, optional, sc.NULL_VALUE), native),
    ]


@pytest.mark.parametrize("name", ["validate_value", "accepts_value", "accepts_slot", "validate_slot", "accepts_slot_absent", "accepts_slot_null"])
def test_repeated_validation_prepares_nothing(name: str, monkeypatch: pytest.MonkeyPatch) -> None:
    ctx = _context()
    operation, root = next((run, root) for label, run, root in _operations(ctx) if label == name)
    calls = _install(monkeypatch)
    repeat = 5
    for _ in range(repeat):
        operation(ACCEPTED_ITEMS)
        operation(REJECTED_ITEMS)
    assert calls.counts == {key: 0 for key in calls.counts}
    assert calls.keys == [root] * (2 * repeat)


def test_the_unresolved_decision_of_a_blocked_reference_still_lists_its_obligations(monkeypatch: pytest.MonkeyPatch) -> None:
    ctx = _context()
    decision = sc.accepts_value(ctx, sc.TypeRef(ctx.reference("Holder")["source"], "Holder", ()), [])
    assert isinstance(decision, sc.ValueUnresolved)
    assert [cast(dict[str, Any], item)["reason"]["tag"] for item in decision.obligations] == ["OpaqueType"]


def test_the_key_count_does_not_follow_the_size_of_the_value(monkeypatch: pytest.MonkeyPatch) -> None:
    ctx = _context()
    calls = _install(monkeypatch)
    for size in (1, 10, 400):
        before = len(calls.keys)
        assert isinstance(ctx.validate_value("Items", [{"a": True}] * size), sv.ValidatedValue)
        assert len(calls.keys) - before == 1


def test_a_context_is_built_once_for_the_validations_that_use_it(monkeypatch: pytest.MonkeyPatch) -> None:
    built = {"count": 0}
    original = ValueContext.__init__

    def counting(self: ValueContext, graph: Any) -> None:
        built["count"] += 1
        original(self, graph)

    monkeypatch.setattr(ValueContext, "__init__", counting)
    ctx = _context()
    assert built["count"] == 1
    for _ in range(10):
        sc.accepts_slot(ctx, _slot(ctx, "Items"), sc.PresentValue(ACCEPTED_ITEMS))
    assert built["count"] == 1


def test_a_graph_is_released_with_its_context() -> None:
    value = profile()
    value["grapheme_rules"] = _rules()
    graph = Mapping(_graph({"profile": value, "nodes": _nodes(), "definitions": []}))
    ctx = ValueContext(graph)
    assert isinstance(ctx.validate_value("Items", ACCEPTED_ITEMS), sv.ValidatedValue)
    released = weakref.ref(graph)
    del ctx, graph
    gc.collect()
    assert released() is None


def test_a_validated_value_is_released_by_a_context_that_stays_alive() -> None:
    ctx = _context()
    items = Sequence(Mapping({"a": True}) for _ in range(3))
    members = [weakref.ref(item) for item in items]
    released = weakref.ref(items)
    items_slot = _slot(ctx, "Items")
    assert isinstance(ctx.validate_value("Items", sv._value_json(items)), sv.ValidatedValue)
    assert isinstance(sc.accepts_slot(ctx, items_slot, sc.PresentValue(items)), sc.ValueAccepted)
    assert isinstance(sc.validate_slot(ctx, items_slot, sc.PresentValue(items)), sc.ValidatedSlot)
    assert isinstance(ctx.materialize_defaults("Items", items), sv.DefaultedValue)
    del items
    gc.collect()
    assert released() is None
    assert all(member() is None for member in members)


def test_one_materialization_validates_once_per_default_and_once_for_the_result(monkeypatch: pytest.MonkeyPatch) -> None:
    flag = variant("Boolean", {"const_value": None, "default_value": False})
    number = variant("Integer", {"domain": None, "minimum": None, "maximum": None, "const_value": None, "enum_values": None, "default_value": "0"})
    fields = [
        {"wire_name": name, "slot": {"type_id": target, "required": False, "nullable": False}}
        for name, target in (("flag", "flag"), ("number", "number"))
    ]
    shapes = {"flag": flag, "number": number, "object": variant("Product", {"fields": fields, "extras": variant("Reject")})}
    ctx = ValueContext(_graph({"profile": profile(), "nodes": [{"id": name, "shape": shape} for name, shape in shapes.items()], "definitions": []}))
    for before, defaults in (({}, 2), ({"flag": True}, 1), ({"flag": True, "number": 1}, 0)):
        calls = Calls(monkeypatch)
        calls.count(ValueContext, "_validate_resolved")
        defaulted = ctx.materialize_defaults("object", before)
        assert len(defaulted.applications) == defaults
        assert calls.counts["_validate_resolved"] == defaults + 1
        monkeypatch.undo()


def test_an_exponent_of_five_billion_is_rejected_before_its_digits_are_expanded() -> None:
    for spelling in ("1e5000000000", "1.5E+5000000000", "-1e-5000000000", "1e10000"):
        started = time.perf_counter()
        with pytest.raises(JsonFailure) as caught:
            exact_from_json([{"n": DecimalLiteral(spelling)}])
        assert time.perf_counter() - started < 1.0
        assert (caught.value.kind, caught.value.path, caught.value.observed) == ("Syntax", "$", "exponent too large")


def test_an_exponent_below_the_limit_is_converted() -> None:
    assert exact_from_json(DecimalLiteral("1e9")) == 10**9
    assert exact_from_json(DecimalLiteral("1.5e-3")) == DecimalLiteral("0.0015")
