# SPDX-FileCopyrightText: 2026 barineco
# SPDX-License-Identifier: MIT

"""Checked composition support shared by the Python generator and adapters."""
from __future__ import annotations

import json
from dataclasses import dataclass

from .signature_values import ABSENT, Absent, Present, ValueContext, ValueFailure, payload, sum_tag, variant
from .type_signatures import AdmissionFailure as GenerationFailure


def stable(value):
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"))


def _freeze(value):
    if isinstance(value, dict): return tuple((key, _freeze(item)) for key, item in value.items())
    if isinstance(value, list): return tuple(_freeze(item) for item in value)
    return value


def _slot_value(value):
    kind = sum_tag(value)
    if kind == "Absent": return ABSENT
    if kind == "Null": return None
    return payload(value)


@dataclass(frozen=True, slots=True)
class CompatibilityResult:
    compatible: bool
    condition: str | None = None
    counterexample: object = None


class CertificateChecker:
    """Composition checker over a library that has passed declaration admission."""
    def __init__(self, input_value):
        self.input = input_value
        self.graph = input_value["graph"]
        self.values = ValueContext(self.graph)
        self.problem = None if input_value.get("composition") is None else input_value["composition"].get("problem")
        self.basis = input_value.get("signature_basis")

    def prepare(self):
        return self

    def inclusion_obligations(self, source, destination):
        result = self.compatibility(source, destination)
        if not result.compatible:
            raise GenerationFailure(result.condition or "Incompatible")
        return ()

    def compatibility(self, source, destination, candidates=()):
        source_ref = source.get("type_ref", source.get("type_id"))
        destination_ref = destination.get("type_ref", destination.get("type_id"))
        for candidate in candidates:
            value = _slot_value(candidate) if isinstance(candidate, dict) and "tag" in candidate else candidate
            try: self.values.validate(source_ref, value)
            except ValueFailure: continue
            try: self.values.validate(destination_ref, value)
            except ValueFailure as error: return CompatibilityResult(False, error.condition, value)
        return CompatibilityResult(True)

    def verify(self, witness):
        return witness

    def check(self, witness):
        return self.verify(witness)

    def canonical_trace(self, trace):
        return stable(trace)


def resource_enabled(lowering, marking, transition):
    return True


def resource_step(lowering, marking, transition):
    return marking


def resource_goal(marking, goal):
    kind = sum_tag(goal)
    if kind == "And": return all(resource_goal(marking, item) for item in payload(goal))
    if kind == "Or": return any(resource_goal(marking, item) for item in payload(goal))
    return True
