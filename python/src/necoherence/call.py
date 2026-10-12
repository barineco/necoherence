# SPDX-FileCopyrightText: 2026 barineco
# SPDX-License-Identifier: MIT

"""Calls whose declarations state their required input fields.

Each call evaluates one declaration and returns its result or a projection
failure. The call
``io(f, x)`` takes two inputs: ``f``, the declaration of which function,
and ``x``, a ``Request[Req]`` carrying a payload together with the field
names actually present on it. The function is itself an input to the
command - a declaration, not an executor - which is why it comes first in
the call, in the same order provenance records it: the declaration's
identity, then the direct input. ``io`` calls an ``Immediate`` declaration
and always receives a ``CallResult``. ``issue`` calls a ``Deferred``
declaration and receives a ``CallResult`` whose success value is a slot
standing for a delegation that may stay silent afterward. These two call
forms are the only entry points; there is no delay value and no combinator
to chain them.

``required`` and ``fields`` are both explicit lists of field names, never
inferred from an input type's own annotations: ``immediate_of`` and
``deferred_of`` take ``required`` directly, and a caller assembles a
``Request`` with the field names it is declaring present. Matching checks
only that every name in ``required`` appears in ``fields``; the payload
itself is opaque to ``io`` and ``issue``.
"""

from __future__ import annotations

from collections.abc import Callable
from dataclasses import dataclass


@dataclass(frozen=True, slots=True)
class Request[Req]:
    """A request value: a payload together with the field names present on it.

    ``payload`` is the declared input type's value, passed to a
    declaration's ``output`` unchanged. ``fields`` is the field names a
    caller is declaring present on that payload; matching reads this list,
    never the payload's own runtime attributes.
    """

    payload: Req
    fields: tuple[str, ...]


@dataclass(frozen=True, slots=True)
class Immediate[Req, Prd]:
    """Declaration of a function whose output settles at the call itself.

    ``identity`` names the declaration for provenance: it is what lets a
    caller's own record of outcomes point back to the step that produced
    one. ``required`` holds the input's field names, matching's only use
    for the input: no type object is kept, since none is needed once the
    names are read. ``output`` is the function from input to output, total
    over ``Req`` and closed over its own outcome. ``Prd`` is expected to
    already be a closed union of that function's own branches, so this
    declaration adds no failure vocabulary of its own.

    The public construction path is ``immediate_of``, which takes
    ``required`` explicitly. Direct construction is for module-internal
    use and for tests.
    """

    identity: str
    required: tuple[str, ...]
    output: Callable[[Req], Prd]


@dataclass(frozen=True, slots=True)
class Deferred[Req, Slot]:
    """Declaration of a function whose eventual reply may stay silent.

    Same shape as ``Immediate``, kept as a distinct type rather than a flag
    on one type: the distinction has to be visible to ``io``'s and
    ``issue``'s own parameter types, since which call form accepts a
    declaration is exactly what separates them. ``output`` returns a slot,
    the record of the issuance; the issuance is this step's whole output,
    and the delegation's eventual reply is a later observation judged by a
    separate call. The public construction path is ``deferred_of``.
    """

    identity: str
    required: tuple[str, ...]
    output: Callable[[Req], Slot]


@dataclass(frozen=True, slots=True)
class ProjectionFailed:
    """Declared failure when ``x`` is missing fields that an input shape requires.

    ``declaration`` is the identity of the ``Immediate`` or ``Deferred``
    whose input shape could not be matched. ``fields`` holds every missing
    field's name, not just the first, so a caller can fix its input in one
    pass instead of discovering the gaps one at a time. Both values are
    read off the call's own inputs, never off an exception.
    """

    declaration: str
    fields: tuple[str, ...]


@dataclass(frozen=True, slots=True)
class BoundaryDiagnosis[Outbound, Expectation, Observed]:
    """What a boundary failure carries: what was sent, expected, and seen.

    ``outbound`` is the query value together with its provenance.
    ``expectation`` is the shape of reply that was expected, including a
    deadline's observed time and limit where one applies. ``observed`` is
    the observation the judgment was actually made against.
    """

    outbound: Outbound
    expectation: Expectation
    observed: Observed


@dataclass(frozen=True, slots=True)
class CallOk[A]:
    """Successful branch of a ``CallResult``: the settled output."""

    value: A


@dataclass(frozen=True, slots=True)
class CallFailed:
    """Failed branch of a ``CallResult``: the declared projection failure."""

    failure: ProjectionFailed


type CallResult[A] = CallOk[A] | CallFailed


def immediate_of[Req, Prd](
    identity: str, required: tuple[str, ...], output: Callable[[Req], Prd]
) -> Immediate[Req, Prd]:
    """Build an ``Immediate`` declaration from an explicit required-name list."""
    return Immediate(identity=identity, required=required, output=output)


def deferred_of[Req, Slot](
    identity: str, required: tuple[str, ...], output: Callable[[Req], Slot]
) -> Deferred[Req, Slot]:
    """Build a ``Deferred`` declaration from an explicit required-name list."""
    return Deferred(identity=identity, required=required, output=output)


def _missing_fields(required: tuple[str, ...], present: tuple[str, ...]) -> tuple[str, ...]:
    """Names in ``required`` that ``present`` does not carry."""
    return tuple(name for name in required if name not in present)


def io[Req, Prd](f: Immediate[Req, Prd], x: Request[Req]) -> CallResult[Prd]:
    """Call ``f`` in one step: match ``x``'s declared fields, then output.

    ``io`` holds no state of its own; matching ``x.fields`` against ``f``'s
    declared ``required`` and calling ``f.output`` on ``x.payload`` are its
    whole job. This is the only call form for ``Immediate`` declarations.
    """
    missing = _missing_fields(f.required, x.fields)
    if missing:
        return CallFailed(ProjectionFailed(declaration=f.identity, fields=missing))
    return CallOk(f.output(x.payload))


def issue[Req, Slot](f: Deferred[Req, Slot], x: Request[Req]) -> CallResult[Slot]:
    """Call ``f`` in one step: match ``x``'s declared fields, then issue.

    This is the only call form for ``Deferred`` declarations; ``io``
    refuses them at the type level.
    """
    missing = _missing_fields(f.required, x.fields)
    if missing:
        return CallFailed(ProjectionFailed(declaration=f.identity, fields=missing))
    return CallOk(f.output(x.payload))
