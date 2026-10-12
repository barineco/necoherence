# SPDX-FileCopyrightText: 2026 barineco
# SPDX-License-Identifier: MIT

"""Tests for the one-step call form: Immediate/Deferred declarations, io/issue."""

from __future__ import annotations

import inspect
from dataclasses import dataclass
from typing import Protocol

from necoherence.call import (
    BoundaryDiagnosis,
    CallFailed,
    CallOk,
    ProjectionFailed,
    Request,
    deferred_of,
    immediate_of,
    io,
    issue,
)


@dataclass(eq=False, match_args=False)
class _GreetReq(Protocol):
    name: str


def _greet(req: _GreetReq) -> str:
    return f"hello {req.name}"


@dataclass
class _NameOnly:
    name: str


@dataclass
class _NameAndExtra:
    name: str
    extra: int


def test_io_outputs_when_input_is_satisfied() -> None:
    greet = immediate_of("test.greet", ("name",), _greet)
    assert io(greet, Request(payload=_NameOnly(name="world"), fields=("name",))) == CallOk("hello world")


def test_io_projects_by_declared_fields_ignoring_extra_attributes() -> None:
    greet = immediate_of("test.greet", ("name",), _greet)
    result = io(greet, Request(payload=_NameAndExtra(name="world", extra=1), fields=("name", "extra")))
    assert result == CallOk("hello world")


@dataclass(eq=False, match_args=False)
class _TwoFieldReq(Protocol):
    a: int
    b: int


def _combine(req: _TwoFieldReq) -> int:
    return req.a + req.b


@dataclass
class _Empty:
    pass


@dataclass
class _TwoFields:
    a: int
    b: int


def test_projection_failed_names_the_declaration_and_every_missing_field() -> None:
    combine = immediate_of("test.combine", ("a", "b"), _combine)
    outcome = io(combine, Request(payload=_Empty(), fields=()))  # type: ignore[misc]
    assert outcome == CallFailed(ProjectionFailed(declaration="test.combine", fields=("a", "b")))


def test_projection_failed_reports_only_the_fields_actually_missing() -> None:
    combine = immediate_of("test.combine", ("a", "b"), _combine)
    outcome = io(combine, Request(payload=_TwoFields(a=1, b=0), fields=("a",)))
    assert outcome == CallFailed(ProjectionFailed(declaration="test.combine", fields=("b",)))


def test_immediate_of_takes_required_fields_explicitly() -> None:
    greet = immediate_of("test.greet", ("name",), _greet)
    assert greet.required == ("name",)
    assert greet.identity == "test.greet"


def test_issue_calls_a_deferred_declaration_and_returns_its_slot() -> None:
    def _stage(req: _GreetReq) -> str:
        return f"staged:{req.name}"

    stage = deferred_of("test.stage", ("name",), _stage)
    result = issue(stage, Request(payload=_NameOnly(name="x"), fields=("name",)))
    assert result == CallOk("staged:x")


def test_issue_also_projects_missing_fields_as_call_failed() -> None:
    def _stage(req: _TwoFieldReq) -> int:
        return req.a + req.b

    stage = deferred_of("test.stage", ("a", "b"), _stage)
    outcome = issue(stage, Request(payload=_Empty(), fields=()))  # type: ignore[misc]
    assert outcome == CallFailed(ProjectionFailed(declaration="test.stage", fields=("a", "b")))


def test_io_holds_no_instance_state() -> None:
    """io is a plain function, not a callable object with attributes of its
    own: there is nothing for a second call to have been affected by."""
    assert inspect.isfunction(io)
    assert not hasattr(io, "__dict__") or io.__dict__ == {}


def test_boundary_diagnosis_carries_exactly_outbound_expectation_observed() -> None:
    diagnosis = BoundaryDiagnosis(outbound="q", expectation=("Known",), observed="seen")
    assert diagnosis.outbound == "q"
    assert diagnosis.expectation == ("Known",)
    assert diagnosis.observed == "seen"


def test_io_rejects_a_deferred_declaration_only_at_the_type_level() -> None:
    """Immediate and Deferred are distinct nominal types with no subtyping
    between them, and io's first parameter is fixed to Immediate. Under
    mypy --strict this call is rejected; the ignore below is the evidence
    that the rejection fires, since --strict also flags an ignore that
    turns out to be unused.
    """

    def _stage(req: _GreetReq) -> str:
        return f"staged:{req.name}"

    stage = deferred_of("test.stage_only", ("name",), _stage)
    io(stage, Request(payload=_NameOnly(name="x"), fields=("name",)))  # type: ignore[arg-type]
