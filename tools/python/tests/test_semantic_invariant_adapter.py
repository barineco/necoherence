# SPDX-FileCopyrightText: 2026 barineco
# SPDX-License-Identifier: AGPL-3.0-only

import importlib.util
from pathlib import Path

from necoherence.type_signatures import signature_basis
from v4_samples import library

SPEC = importlib.util.spec_from_file_location(
    "adapter", Path(__file__).parents[1] / "semantic_invariant_adapter.py"
)
assert SPEC is not None and SPEC.loader is not None
adapter = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(adapter)


def test_adapter_returns_typed_value_and_declaration_results():
    value=library()
    accepted=adapter.evaluate({"id":"value","kind":"value","library":value,"type_id":"text","value":{"text":"x"}})
    assert accepted=={"id":"value","status":"Accepted"}
    value["profile"]["reference"]["identity"]=""
    rejected=adapter.evaluate({"id":"profile","kind":"profile","profile":value["profile"]})
    assert rejected["failure"]["predicate"]=="PR01"


def test_adapter_rejects_v3_as_a_wire_failure():
    value=library(); entries=[{"identity":"root","definition":"root"}]; basis=signature_basis(value,entries)
    exchange={"schema":"ncoh-checked-generation@3","basis":basis,"signatures":value,"composition":None,"entrypoints":entries}
    result=adapter.evaluate({"id":"wire","kind":"wire","value":exchange})
    assert result["failure"]["classification"]=="UnsupportedSchema"
