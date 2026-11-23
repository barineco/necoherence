# SPDX-FileCopyrightText: 2026 barineco
# SPDX-License-Identifier: MIT

"""Finite typed places, transitions, markings, goals, and checked witnesses."""

from __future__ import annotations

from collections.abc import Callable
from dataclasses import dataclass
from enum import Enum
from typing import assert_never


def _require_natural(**values: int) -> None:
    for name, value in values.items():
        if value < 0:
            raise ValueError(f"{name} must not be negative: {value}")


class TokenKind(Enum):
    INPUT = "input"
    OUTPUT = "output"
    FAILURE = "failure"
    EFFECT = "effect"
    OBSERVATION = "observation"
    ACCEPTED = "accepted"


@dataclass(frozen=True, slots=True)
class ColoredToken:
    target: str
    index: int
    revision: int
    kind: TokenKind

    def __post_init__(self) -> None:
        _require_natural(index=self.index, revision=self.revision)


@dataclass(frozen=True, slots=True)
class TypedPlace:
    identity: str
    token_type: str
    revision: int

    def __post_init__(self) -> None:
        _require_natural(revision=self.revision)


@dataclass(frozen=True, slots=True)
class TypedTransition:
    identity: str
    input_places: tuple[str, ...]
    output_places: tuple[str, ...]
    failure_places: tuple[str, ...]
    revision: int

    def __post_init__(self) -> None:
        _require_natural(revision=self.revision)


class BindingMode(Enum):
    READ = "read"
    CONSUME = "consume"


@dataclass(frozen=True, slots=True)
class InputBinding:
    transition_id: str
    name: str
    place: str
    token_type: str
    identity: str
    provenance: str
    multiplicity: int
    mode: BindingMode
    required_revision: int

    def __post_init__(self) -> None:
        _require_natural(
            multiplicity=self.multiplicity, required_revision=self.required_revision
        )


@dataclass(frozen=True, slots=True)
class DeclarationGraph:
    places: tuple[str, ...]
    transitions: tuple[str, ...]
    edges: tuple[tuple[str, str], ...]
    revision: int

    def __post_init__(self) -> None:
        _require_natural(revision=self.revision)


@dataclass(frozen=True, slots=True)
class DomainBound:
    target_identity: str
    index: int
    revision: int
    max_bindings: int
    max_search_steps: int

    def __post_init__(self) -> None:
        _require_natural(
            index=self.index,
            revision=self.revision,
            max_bindings=self.max_bindings,
            max_search_steps=self.max_search_steps,
        )


@dataclass(frozen=True, slots=True)
class Marking:
    places: tuple[tuple[str, tuple[ColoredToken, ...]], ...]


@dataclass(frozen=True, slots=True)
class PlaceHasAtLeast:
    place: str
    count: int

    def __post_init__(self) -> None:
        _require_natural(count=self.count)


@dataclass(frozen=True, slots=True)
class PlaceHasToken:
    place: str
    target: str
    index: int
    revision: int

    def __post_init__(self) -> None:
        _require_natural(index=self.index, revision=self.revision)


@dataclass(frozen=True, slots=True)
class And:
    left: GoalPredicate
    right: GoalPredicate


@dataclass(frozen=True, slots=True)
class Or:
    left: GoalPredicate
    right: GoalPredicate


@dataclass(frozen=True, slots=True)
class Not:
    value: GoalPredicate


type GoalPredicate = PlaceHasAtLeast | PlaceHasToken | And | Or | Not


@dataclass(frozen=True, slots=True)
class SolverInput:
    places: tuple[TypedPlace, ...]
    transitions: tuple[TypedTransition, ...]
    bindings: tuple[InputBinding, ...]
    goal: GoalPredicate
    graph: DeclarationGraph
    marking: Marking
    bound: DomainBound


@dataclass(frozen=True, slots=True)
class BindingBoundExhausted:
    limit: int

    def __post_init__(self) -> None:
        _require_natural(limit=self.limit)


@dataclass(frozen=True, slots=True)
class SearchStepBoundExhausted:
    limit: int

    def __post_init__(self) -> None:
        _require_natural(limit=self.limit)


type UnknownReason = BindingBoundExhausted | SearchStepBoundExhausted


@dataclass(frozen=True, slots=True)
class ReachabilityWitness:
    path: tuple[str, ...]
    final_marking: Marking


@dataclass(frozen=True, slots=True)
class AcyclicWitness:
    explored_markings: tuple[Marking, ...]
    steps: int
    frontier: tuple[Marking, ...]

    def __post_init__(self) -> None:
        _require_natural(steps=self.steps)


@dataclass(frozen=True, slots=True)
class ContractViolation:
    message: str


@dataclass(frozen=True, slots=True)
class InternalInvariantViolation:
    message: str


type SolverFailure = ContractViolation | InternalInvariantViolation


class _WitnessFailureValue:
    pass


@dataclass(frozen=True, slots=True)
class InputRevisionMismatch(_WitnessFailureValue):
    pass


@dataclass(frozen=True, slots=True)
class InitialMembership(_WitnessFailureValue):
    input_id: object


@dataclass(frozen=True, slots=True)
class ProducerMismatch(_WitnessFailureValue):
    value_ref: object


@dataclass(frozen=True, slots=True)
class ProjectionMismatch(_WitnessFailureValue):
    failure: object


@dataclass(frozen=True, slots=True)
class SourceConstraintMismatch(_WitnessFailureValue):
    value_ref: object


@dataclass(frozen=True, slots=True)
class Inclusion(_WitnessFailureValue):
    failure: object


@dataclass(frozen=True, slots=True)
class SuppliedValueMismatch(_WitnessFailureValue):
    value_ref: object


@dataclass(frozen=True, slots=True)
class ConstructionMismatch(_WitnessFailureValue):
    type_ref: object


@dataclass(frozen=True, slots=True)
class MissingBinding(_WitnessFailureValue):
    identity: str


@dataclass(frozen=True, slots=True)
class SignatureMismatch(_WitnessFailureValue):
    site_id: object


@dataclass(frozen=True, slots=True)
class GuardNotDominating(_WitnessFailureValue):
    value_ref: object


@dataclass(frozen=True, slots=True)
class IncompleteBranchCoverage(_WitnessFailureValue):
    identity: str


@dataclass(frozen=True, slots=True)
class FailureEmbeddingMismatch(_WitnessFailureValue):
    failure_embedding_id: object


@dataclass(frozen=True, slots=True)
class GoalMismatch(_WitnessFailureValue):
    pass


@dataclass(frozen=True, slots=True)
class RankViolation(_WitnessFailureValue):
    pass


@dataclass(frozen=True, slots=True)
class ResourceLoweringMismatch(_WitnessFailureValue):
    message: str


@dataclass(frozen=True, slots=True)
class ResourceReplayMismatch(_WitnessFailureValue):
    message: str


@dataclass(frozen=True, slots=True)
class ForgedClosure(_WitnessFailureValue):
    message: str


@dataclass(frozen=True, slots=True)
class ForgedAcyclicity(_WitnessFailureValue):
    message: str


@dataclass(frozen=True, slots=True)
class MissingEvidence(_WitnessFailureValue):
    message: str


type WitnessFailure = (
    InputRevisionMismatch
    | InitialMembership
    | ProducerMismatch
    | ProjectionMismatch
    | SourceConstraintMismatch
    | Inclusion
    | SuppliedValueMismatch
    | ConstructionMismatch
    | MissingBinding
    | SignatureMismatch
    | GuardNotDominating
    | IncompleteBranchCoverage
    | FailureEmbeddingMismatch
    | GoalMismatch
    | RankViolation
    | ResourceLoweringMismatch
    | ResourceReplayMismatch
    | ForgedClosure
    | ForgedAcyclicity
    | MissingEvidence
)


__all__ = [
    "AcyclicWitness",
    "And",
    "BindingBoundExhausted",
    "BindingMode",
    "ColoredToken",
    "ConstructionMismatch",
    "ContractViolation",
    "DeclarationGraph",
    "DomainBound",
    "FailureEmbeddingMismatch",
    "ForgedAcyclicity",
    "ForgedClosure",
    "GoalMismatch",
    "GoalPredicate",
    "GuardNotDominating",
    "IncompleteBranchCoverage",
    "Inclusion",
    "InitialMembership",
    "InputBinding",
    "InputRevisionMismatch",
    "InternalInvariantViolation",
    "Marking",
    "MissingBinding",
    "MissingEvidence",
    "Not",
    "Or",
    "PlaceHasAtLeast",
    "PlaceHasToken",
    "ProducerMismatch",
    "ProjectionMismatch",
    "RankViolation",
    "ReachabilityWitness",
    "ResourceLoweringMismatch",
    "ResourceReplayMismatch",
    "SearchStepBoundExhausted",
    "SignatureMismatch",
    "SolverFailure",
    "SolverInput",
    "SourceConstraintMismatch",
    "SuppliedValueMismatch",
    "TokenKind",
    "TypedPlace",
    "TypedTransition",
    "UnknownReason",
    "WitnessFailure",
]
