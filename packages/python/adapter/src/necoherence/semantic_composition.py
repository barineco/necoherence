# SPDX-FileCopyrightText: 2026 barineco
# SPDX-License-Identifier: MIT

"""Typed inputs and checked preparation for semantic composition."""

from __future__ import annotations

import copy
import typing
from collections.abc import Callable, Iterable, Mapping, Sequence
from dataclasses import dataclass, fields, is_dataclass, replace
from enum import Enum
from typing import SupportsIndex, TypeAlias, cast

from .library_check import LibraryCheckFailure
from .signature_values import (
    ABSENT_VALUE,
    MISSING_REQUIRED,
    NULL_NOT_ALLOWED,
    NULL_VALUE,
    AbsentValue,
    FieldStep,
    IndexStep,
    NullValue,
    PathStep,
    PresentValue,
    SlotValue,
    MemberCertificate,
    ValidatedValue,
    ValidationCertificateMismatch,
    ValidationFailure,
    ValidationUnresolved,
    ValidationValueFailure,
    ValueContext,
    ValueFailure,
    ValuePath,
    VariantStep,
    _value_json,
    integer,
    variant,
)
from .typed_mapping import (
    BindingMode,
    SolverFailure,
    UnknownReason,
    WitnessFailure,
)

if typing.TYPE_CHECKING:
    from .semantic_empty_types import CheckedEmptyTypes

JsonObject: TypeAlias = Mapping[str, object]
SemanticGraph: TypeAlias = Mapping[str, object]


@dataclass(frozen=True, slots=True)
class TypeRef:
    source: JsonObject
    definition_name: str
    pointer: tuple[object, ...] = ()


@dataclass(frozen=True, slots=True)
class DefinitionRef:
    source: JsonObject
    name: str


@dataclass(frozen=True, slots=True)
class SlotContract:
    type_ref: TypeRef
    required: bool
    nullable: bool


@dataclass(frozen=True, slots=True)
class SemanticBasis:
    profile: JsonObject
    sources: tuple[JsonObject, ...]

    @classmethod
    def of(cls, graph: SemanticGraph) -> SemanticBasis:
        profile = _mapping(graph.get("profile"), "graph.profile")
        source_refs = _source_refs(graph)
        return cls(copy.deepcopy(profile), tuple(copy.deepcopy(_mapping(value, "source")) for value in source_refs))


@dataclass(frozen=True, slots=True)
class FunctionRef:
    identity: str
    revision: str
    content_digest: str


@dataclass(frozen=True, slots=True)
class InputId:
    value: str


@dataclass(frozen=True, slots=True)
class PortId:
    value: str


@dataclass(frozen=True, slots=True)
class SiteId:
    value: str


@dataclass(frozen=True, slots=True)
class OutcomeId:
    value: str


@dataclass(frozen=True, slots=True)
class GoalPortId:
    value: str


@dataclass(frozen=True, slots=True)
class LotId:
    value: str


@dataclass(frozen=True, slots=True)
class RequirementId:
    value: str


@dataclass(frozen=True, slots=True)
class ProductionId:
    value: str


@dataclass(frozen=True, slots=True)
class GuardId:
    value: str


@dataclass(frozen=True, slots=True)
class FailureEmbeddingId:
    value: str


@dataclass(frozen=True, slots=True)
class TypePair:
    source: SlotContract
    destination: SlotContract
    source_tag: str | None = None


class InclusionRule(Enum):
    SAME_DEFINED_TYPE = "sameDefinedType"
    EMPTY_SOURCE = "emptySource"
    BOOLEAN = "boolean"
    INTEGER_INTERSECTION = "integerIntersection"
    FINITE_STRINGS = "finiteStrings"
    STRING_CONDITIONS = "stringConditions"
    BYTES_LENGTH = "bytesLength"
    UNIT = "unit"
    UNFOLD_SOURCE = "unfoldSource"
    UNFOLD_DESTINATION = "unfoldDestination"
    ARRAY = "array"
    PRODUCT = "product"
    SOURCE_UNION = "sourceUnion"
    DESTINATION_UNION = "destinationUnion"


@dataclass(frozen=True, slots=True)
class PairEntry:
    pair: TypePair
    source_shape: object
    destination_shape: object
    rule: InclusionRule
    children: tuple[int, ...]


@dataclass(frozen=True, slots=True)
class InclusionCertificate:
    basis: SemanticBasis
    source: SlotContract
    destination: SlotContract
    empty_types: tuple[TypeRef, ...]
    pairs: tuple[PairEntry, ...]
    root: int



@dataclass(frozen=True, slots=True)
class MeaningObligationReason:
    obligations: tuple[object, ...]


@dataclass(frozen=True, slots=True)
class ExtraFieldReason:
    name: str


class UnitTypeObligationReason(Enum):
    CONSTRAINT_IMPLICATION = "constraintImplication"
    PRESENCE = "presence"
    UNION_REMAINDER = "unionRemainder"
    INHABITATION = "inhabitation"
    OBLIGATION_BOUND_EXHAUSTED = "obligationBoundExhausted"


TypeObligationReason: TypeAlias = MeaningObligationReason | ExtraFieldReason | UnitTypeObligationReason


@dataclass(frozen=True, slots=True)
class TypeObligation:
    pair: TypePair
    path: ValuePath
    reason: TypeObligationReason


@dataclass(frozen=True, slots=True)
class UnresolvedInclusion:
    obligation: TypeObligation


@dataclass(frozen=True, slots=True)
class PairMismatch:
    index: int



@dataclass(frozen=True, slots=True)
class RuleMismatch:
    index: int



@dataclass(frozen=True, slots=True)
class ChildCoverage:
    index: int



@dataclass(frozen=True, slots=True)
class UndefinedMeaningInclusion:
    obligations: tuple[object, ...]


class UnitInclusionFailure(Enum):
    BASIS_MISMATCH = "basisMismatch"
    CONTRACT_MISMATCH = "contractMismatch"
    MISSING_PAIR = "missingPair"
    FORGED_EMPTINESS = "forgedEmptiness"
    COUNTEREXAMPLE_MISMATCH = "counterexampleMismatch"


InclusionFailure: TypeAlias = (
    UnitInclusionFailure
    | UndefinedMeaningInclusion
    | PairMismatch
    | RuleMismatch
    | ChildCoverage
    | UnresolvedInclusion
)


@dataclass(frozen=True, slots=True)
class InitialProducer:
    id: InputId


@dataclass(frozen=True, slots=True)
class InvocationOutcomeProducer:
    site: SiteId
    outcome: OutcomeId
    port: PortId


ProducerRef: TypeAlias = InitialProducer | InvocationOutcomeProducer


@dataclass(frozen=True, slots=True)
class ValueRef:
    producer: ProducerRef
    path: ValuePath


@dataclass(frozen=True, slots=True)
class AnyCompatible:
    pass


@dataclass(frozen=True, slots=True)
class InitialOnly:
    id: InputId
    path: ValuePath


@dataclass(frozen=True, slots=True)
class ProducedBy:
    site: SiteId
    outcome: OutcomeId
    port: PortId
    path: ValuePath


ANY_COMPATIBLE = AnyCompatible()
SourceConstraint: TypeAlias = AnyCompatible | InitialOnly | ProducedBy


def _source_constraint_accepts(constraint: SourceConstraint, value: ValueRef) -> bool:
    if isinstance(constraint, AnyCompatible):
        return True
    if isinstance(constraint, InitialOnly) and isinstance(value.producer, InitialProducer):
        return constraint.id == value.producer.id and constraint.path == value.path
    if isinstance(constraint, ProducedBy) and isinstance(value.producer, InvocationOutcomeProducer):
        return (
            constraint.site == value.producer.site
            and constraint.outcome == value.producer.outcome
            and constraint.port == value.producer.port
            and constraint.path == value.path
        )
    return False


@dataclass(frozen=True, slots=True)
class InitialLotRef:
    id: LotId


@dataclass(frozen=True, slots=True)
class ProducedLotRef:
    site: SiteId
    outcome: OutcomeId
    production: ProductionId


ResourceLotRef: TypeAlias = InitialLotRef | ProducedLotRef


@dataclass(frozen=True, slots=True)
class InitialResourceProducer:
    identity: str
    revision: str


@dataclass(frozen=True, slots=True)
class InvocationResourceProducer:
    site: SiteId
    outcome: OutcomeId


ResourceProducer: TypeAlias = InitialResourceProducer | InvocationResourceProducer


@dataclass(frozen=True, slots=True)
class AnyResourceIdentity:
    pass


@dataclass(frozen=True, slots=True)
class ExactResourceIdentity:
    producer: ResourceProducer


ANY_RESOURCE_IDENTITY = AnyResourceIdentity()
ResourceIdentityConstraint: TypeAlias = AnyResourceIdentity | ExactResourceIdentity


@dataclass(frozen=True, slots=True)
class ResourceLot:
    id: LotId
    token_type: TypeRef
    producer: ResourceProducer
    revision: int
    quantity: int
    provenance: str



@dataclass(frozen=True, slots=True)
class ResourceRequirement:
    id: RequirementId
    token_type: TypeRef
    mode: BindingMode
    multiplicity: int
    required_revision: int
    identity: ResourceIdentityConstraint



@dataclass(frozen=True, slots=True)
class ResourceProduction:
    id: ProductionId
    token_type: TypeRef
    revision: int
    quantity: int
    provenance: str



@dataclass(frozen=True, slots=True)
class ArgumentSource:
    pass


@dataclass(frozen=True, slots=True)
class SuppliedValueSource:
    value: SlotValue


ARGUMENT_SOURCE = ArgumentSource()
InitialSource: TypeAlias = ArgumentSource | SuppliedValueSource


@dataclass(frozen=True, slots=True)
class InitialInput:
    id: InputId
    contract: SlotContract
    source: InitialSource
    resource: LotId | None


@dataclass(frozen=True, slots=True)
class InputPort:
    id: PortId
    contract: SlotContract
    source_constraint: SourceConstraint
    resource_requirement: RequirementId | None


@dataclass(frozen=True, slots=True)
class OutputPort:
    id: PortId
    contract: SlotContract
    resource_production: ProductionId | None


class OutcomeForm(Enum):
    SUCCESS = "success"
    DECLARED_FAILURE = "declaredFailure"


@dataclass(frozen=True, slots=True)
class OutcomeContract:
    id: OutcomeId
    form: OutcomeForm
    value_ports: tuple[OutputPort, ...]
    produced_resources: tuple[ResourceProduction, ...]


@dataclass(frozen=True, slots=True)
class PureFunctionForm:
    pass


@dataclass(frozen=True, slots=True)
class OperationFunctionForm:
    definition: DefinitionRef


@dataclass(frozen=True, slots=True)
class DeclaredTransformForm:
    pass


PURE_FUNCTION_FORM = PureFunctionForm()
DECLARED_TRANSFORM_FORM = DeclaredTransformForm()
FunctionForm: TypeAlias = PureFunctionForm | OperationFunctionForm | DeclaredTransformForm


class CompositionEffect(Enum):
    PURE_FUNCTION = "pureFunction"
    HTTP_REQUEST_RESPONSE = "httpRequestResponse"
    DATA_ONLY = "dataOnly"


@dataclass(frozen=True, slots=True)
class VariantGuardArm:
    tag: str


class UnitGuardArm(Enum):
    PRESENT = "present"
    ABSENT = "absent"
    NULL = "null"
    UNKNOWN_VARIANT = "unknownVariant"
    ACCEPTED = "accepted"
    REJECTED = "rejected"


GuardArm: TypeAlias = UnitGuardArm | VariantGuardArm


@dataclass(frozen=True, slots=True)
class FunctionFailureOrigin:
    function: FunctionRef
    outcome: OutcomeId


@dataclass(frozen=True, slots=True)
class GuardFailureOrigin:
    guard: GuardId
    arm: GuardArm


FailureOrigin: TypeAlias = FunctionFailureOrigin | GuardFailureOrigin


@dataclass(frozen=True, slots=True)
class FunctionSignature:
    reference: FunctionRef
    form: FunctionForm
    effect: CompositionEffect
    inputs: tuple[InputPort, ...]
    outcomes: tuple[OutcomeContract, ...]
    resource_inputs: tuple[ResourceRequirement, ...]
    assumption_ref: str
    handles_failure: FailureOrigin | None = None


@dataclass(frozen=True, slots=True)
class InvocationSite:
    id: SiteId
    function: FunctionRef


@dataclass(frozen=True, slots=True)
class PermittedProjection:
    source_type: TypeRef
    path: ValuePath


@dataclass(frozen=True, slots=True)
class ValidateGuardKind:
    contract: SlotContract


class UnitGuardKind(Enum):
    PRESENCE = "presence"
    VARIANTS = "variants"


GuardKind: TypeAlias = UnitGuardKind | ValidateGuardKind


@dataclass(frozen=True, slots=True)
class DeclaredGuard:
    id: GuardId
    source_type: TypeRef
    path: ValuePath
    kind: GuardKind


class FieldPresence(Enum):
    REQUIRED = "required"
    OPTIONAL = "optional"


@dataclass(frozen=True, slots=True)
class FieldConstraint:
    field: str
    source: SourceConstraint
    presence: FieldPresence


@dataclass(frozen=True, slots=True)
class ConstructionRule:
    identity: str
    type_ref: TypeRef
    nested_fields: tuple[tuple[str, str], ...]
    field_constraints: tuple[FieldConstraint, ...] = ()

    def field_constraint(self, name: str) -> SourceConstraint:
        return next((item.source for item in self.field_constraints if item.field == name), ANY_COMPATIBLE)

    def field_required(self, name: str) -> bool:
        return any(item.field == name and item.presence is FieldPresence.REQUIRED for item in self.field_constraints)


@dataclass(frozen=True, slots=True)
class InvocationDomain:
    identity: str
    revision: str
    sites: tuple[InvocationSite, ...]
    permitted_projections: tuple[PermittedProjection, ...]
    permitted_constructions: tuple[ConstructionRule, ...]
    permitted_transforms: tuple[FunctionRef, ...]
    guards: tuple[DeclaredGuard, ...]


@dataclass(frozen=True, slots=True)
class ResourceGoal:
    lot: ResourceLotRef
    multiplicity: int
    revision: int



@dataclass(frozen=True, slots=True)
class GoalPort:
    id: GoalPortId
    contract: SlotContract
    source_constraint: SourceConstraint


@dataclass(frozen=True, slots=True)
class FailureEmbedding:
    id: FailureEmbeddingId
    origin: FailureOrigin
    contract: SlotContract
    final_resources: tuple[ResourceGoal, ...]


@dataclass(frozen=True, slots=True)
class GoalSpec:
    outputs: tuple[GoalPort, ...]
    failures: tuple[FailureEmbedding, ...]
    final_resources: tuple[ResourceGoal, ...]


class SelectionPolicy(Enum):
    REQUIRE_UNIQUE = "requireUnique"
    ANY_FEASIBLE = "anyFeasible"


@dataclass(frozen=True, slots=True)
class ResourceBounds:
    max_bindings: int
    max_search_steps: int
    max_tokens: int



@dataclass(frozen=True, slots=True)
class SearchBounds:
    max_expanded_states: int = 10_000
    max_binding_candidates: int = 100_000
    max_type_obligations: int = 10_000
    max_branch_nodes: int = 100_000
    max_sample_length: int = 32
    resource_bounds: ResourceBounds | None = None



@dataclass(frozen=True, slots=True)
class CompositionInput:
    identity: str
    revision: str
    basis: SemanticBasis
    signatures: tuple[FunctionSignature, ...]
    initial_inputs: tuple[InitialInput, ...]
    initial_resources: tuple[ResourceLot, ...]
    goal: GoalSpec
    invocation_domain: InvocationDomain
    allowed_effects: tuple[CompositionEffect, ...]
    explicit_order: tuple[tuple[SiteId, SiteId], ...]
    bounds: SearchBounds
    selection_policy: SelectionPolicy | None = None


@dataclass(frozen=True, slots=True)
class BasisMismatch:
    pass


@dataclass(frozen=True, slots=True)
class DuplicateIdentity:
    kind: str
    identity: str


@dataclass(frozen=True, slots=True)
class UnresolvedType:
    ref: TypeRef


@dataclass(frozen=True, slots=True)
class UnresolvedFunction:
    ref: FunctionRef


@dataclass(frozen=True, slots=True)
class InvalidSignature:
    ref: FunctionRef
    reason: str


@dataclass(frozen=True, slots=True)
class InvalidInitialValue:
    id: InputId
    failure: ValueFailure


@dataclass(frozen=True, slots=True)
class SiteEffectNotPermitted:
    site: SiteId
    effect: CompositionEffect


@dataclass(frozen=True, slots=True)
class TransformNotPermitted:
    function: FunctionRef


@dataclass(frozen=True, slots=True)
class EmptyGoal:
    pass


@dataclass(frozen=True, slots=True)
class GoalSourceConstraintUndefined:
    port: GoalPortId
    constraint: SourceConstraint


@dataclass(frozen=True, slots=True)
class FailureEmbeddingOriginUndefined:
    embedding: FailureEmbeddingId
    origin: FailureOrigin


@dataclass(frozen=True, slots=True)
class ConstructionNotProduct:
    identity: str
    type_ref: TypeRef


@dataclass(frozen=True, slots=True)
class FieldConstraintUnknownField:
    identity: str
    field: str


@dataclass(frozen=True, slots=True)
class ConstrainedNestedField:
    identity: str
    field: str


@dataclass(frozen=True, slots=True)
class ConstructionFieldSourceUndefined:
    identity: str
    constraint: FieldConstraint


@dataclass(frozen=True, slots=True)
class NestedFieldUndeclared:
    identity: str
    field: str


@dataclass(frozen=True, slots=True)
class NestedConstructionMismatch:
    identity: str
    field: str
    nested: str
    type_ref: TypeRef


@dataclass(frozen=True, slots=True)
class CyclicConstruction:
    identity: str


@dataclass(frozen=True, slots=True)
class ExplicitSiteOrderInvalid:
    before: SiteId
    after: SiteId


@dataclass(frozen=True, slots=True)
class InvalidEmptyTypeClosure:
    failure: InclusionFailure


@dataclass(frozen=True, slots=True)
class InvalidLibrary:
    failure: LibraryCheckFailure


@dataclass(frozen=True, slots=True)
class InvalidResourceDeclaration:
    reason: str


BASIS_MISMATCH = BasisMismatch()
CompositionInputFailure: TypeAlias = (
    BasisMismatch
    | DuplicateIdentity
    | UnresolvedType
    | UnresolvedFunction
    | InvalidSignature
    | InvalidInitialValue
    | SiteEffectNotPermitted
    | TransformNotPermitted
    | EmptyGoal
    | GoalSourceConstraintUndefined
    | FailureEmbeddingOriginUndefined
    | ConstructionNotProduct
    | FieldConstraintUnknownField
    | ConstrainedNestedField
    | ConstructionFieldSourceUndefined
    | NestedFieldUndeclared
    | NestedConstructionMismatch
    | CyclicConstruction
    | ExplicitSiteOrderInvalid
    | InvalidEmptyTypeClosure
    | InvalidLibrary
    | InvalidResourceDeclaration
)


@dataclass(frozen=True, slots=True)
class InclusionCompatibility:
    certificate: InclusionCertificate


@dataclass(frozen=True, slots=True)
class SuppliedValueCompatibility:
    value: SlotValue


BindingCompatibility: TypeAlias = InclusionCompatibility | SuppliedValueCompatibility


@dataclass(frozen=True, slots=True)
class SourceBindingExpr:
    value: ValueRef
    projection: object
    compatibility: BindingCompatibility


@dataclass(frozen=True, slots=True)
class ProductBindingExpr:
    construction: str
    type_ref: TypeRef
    fields: tuple[tuple[str, BindingExpr], ...]


BindingExpr: TypeAlias = SourceBindingExpr | ProductBindingExpr


@dataclass(frozen=True, slots=True)
class ResourceBinding:
    requirement: RequirementId
    lot: ResourceLotRef
    inclusion: InclusionCertificate


@dataclass(frozen=True, slots=True)
class InvocationPlan:
    site: SiteId
    function: FunctionRef
    bindings: tuple[tuple[PortId, BindingExpr], ...]
    resources: tuple[ResourceBinding, ...]


@dataclass(frozen=True, slots=True)
class SuccessReturnPlan:
    outputs: tuple[tuple[GoalPortId, BindingExpr], ...]


@dataclass(frozen=True, slots=True)
class FailureReturnPlan:
    embedding: FailureEmbeddingId
    value: BindingExpr


ReturnPlan: TypeAlias = SuccessReturnPlan | FailureReturnPlan


@dataclass(frozen=True, slots=True)
class InvokePlanTree:
    rank: int
    invocation: InvocationPlan
    arms: tuple[tuple[OutcomeId, PlanTree], ...]
    empty_outcomes: tuple[OutcomeId, ...]



@dataclass(frozen=True, slots=True)
class GuardPlanTree:
    rank: int
    guard: GuardId
    inspected: ValueRef
    arms: tuple[tuple[GuardArm, PlanTree], ...]



@dataclass(frozen=True, slots=True)
class ReturnPlanTree:
    rank: int
    terminal: ReturnPlan



PlanTree: TypeAlias = InvokePlanTree | GuardPlanTree | ReturnPlanTree


def _tree_node_count(tree: PlanTree) -> int:
    if isinstance(tree, ReturnPlanTree):
        return 1
    if isinstance(tree, InvokePlanTree):
        return 1 + _outcome_node_count(tree.arms)
    return 1 + _guard_node_count(tree.arms)


def _outcome_node_count(arms: tuple[tuple[OutcomeId, PlanTree], ...]) -> int:
    return sum(_tree_node_count(child) for _, child in arms)


def _guard_node_count(arms: tuple[tuple[GuardArm, PlanTree], ...]) -> int:
    return sum(_tree_node_count(child) for _, child in arms)


@dataclass(frozen=True, slots=True)
class CompositionPlan:
    input_identity: str
    input_revision: str
    root: PlanTree


@dataclass(frozen=True, slots=True)
class TypeUnresolvedObligation:
    value: ValueRef | None
    obligations: tuple[TypeObligation, ...]


@dataclass(frozen=True, slots=True)
class MeaningUnresolvedObligation:
    obligations: tuple[object, ...]


@dataclass(frozen=True, slots=True)
class InhabitationUnresolvedObligation:
    producer: ProducerRef
    contract: SlotContract


@dataclass(frozen=True, slots=True)
class ResourceSolverUnknown:
    reason: UnknownReason


@dataclass(frozen=True, slots=True)
class ResourceCapacityBound:
    required: int
    limit: int



class UnitUnresolvedObligation(Enum):
    STATE_BOUND_EXHAUSTED = "stateBoundExhausted"
    BINDING_BOUND_EXHAUSTED = "bindingBoundExhausted"
    BRANCH_BOUND_EXHAUSTED = "branchBoundExhausted"
    UNRESOLVED_UNIQUENESS = "unresolvedUniqueness"


UnresolvedObligation: TypeAlias = (
    TypeUnresolvedObligation
    | MeaningUnresolvedObligation
    | InhabitationUnresolvedObligation
    | UnitUnresolvedObligation
    | ResourceSolverUnknown
    | ResourceCapacityBound
)


@dataclass(frozen=True, slots=True)
class InvalidLowering:
    reason: str


@dataclass(frozen=True, slots=True)
class UnknownLowering:
    obligation: UnresolvedObligation


LoweringFailure: TypeAlias = InvalidLowering | UnknownLowering


@dataclass(frozen=True, slots=True)
class CompositionContractViolation:
    reason: str


@dataclass(frozen=True, slots=True)
class ResourceEngineFailure:
    failure: SolverFailure


@dataclass(frozen=True, slots=True)
class WitnessEngineFailure:
    failure: WitnessFailure


CompositionEngineFailure: TypeAlias = CompositionContractViolation | ResourceEngineFailure | WitnessEngineFailure


@dataclass(frozen=True, slots=True)
class PresentAssumption:
    path: ValuePath


@dataclass(frozen=True, slots=True)
class NonNullAssumption:
    path: ValuePath


@dataclass(frozen=True, slots=True)
class VariantAssumption:
    path: ValuePath
    tag: str


@dataclass(frozen=True, slots=True)
class IndexPresentAssumption:
    path: ValuePath
    index: int


ProjectionAssumption: TypeAlias = PresentAssumption | NonNullAssumption | VariantAssumption | IndexPresentAssumption


@dataclass(frozen=True, slots=True)
class ProjectionCertificate:
    profile: object
    source_refs: tuple[object, ...]
    source: SlotContract
    path: ValuePath
    assumptions: tuple[ProjectionAssumption, ...]
    destination: SlotContract


@dataclass(frozen=True, slots=True)
class WrongShape:
    type_ref: TypeRef
    path: ValuePath


@dataclass(frozen=True, slots=True)
class MissingField:
    type_ref: TypeRef
    name: str


@dataclass(frozen=True, slots=True)
class MissingVariant:
    type_ref: TypeRef
    tag: str


@dataclass(frozen=True, slots=True)
class BranchAssumptionRequired:
    path: ValuePath
    tag: str


@dataclass(frozen=True, slots=True)
class VariantSelectionUndetermined:
    path: ValuePath
    tag: str


@dataclass(frozen=True, slots=True)
class UnresolvedProjection:
    obligations: tuple[object, ...]


@dataclass(frozen=True, slots=True)
class ProjectionCertificateMismatch:
    condition: str


ProjectionFailure: TypeAlias = (
    WrongShape
    | MissingField
    | MissingVariant
    | BranchAssumptionRequired
    | VariantSelectionUndetermined
    | UnresolvedProjection
    | ProjectionCertificateMismatch
)


@dataclass(frozen=True, slots=True)
class ValueAccepted:
    pass


@dataclass(frozen=True, slots=True)
class ValueRejected:
    failure: ValueFailure


@dataclass(frozen=True, slots=True)
class ValueUnresolved:
    obligations: tuple[object, ...]


VALUE_ACCEPTED = ValueAccepted()
ValueDecision: TypeAlias = ValueAccepted | ValueRejected | ValueUnresolved


_validated_slot_token = object()


@dataclass(frozen=True, slots=True, init=False)
class ValidatedSlot:
    certificate: MemberCertificate

    def __init__(self, token: object, certificate: MemberCertificate) -> None:
        if token is not _validated_slot_token:
            raise TypeError("validated slot requires validation")
        object.__setattr__(self, "certificate", certificate)


@dataclass(frozen=True, slots=True)
class LotDeclaration:
    token_type: TypeRef
    producer: ResourceProducer
    revision: int
    quantity: int
    provenance: str


OperationChecker: TypeAlias = Callable[[FunctionSignature, DefinitionRef], CompositionInputFailure | None]
OperationMeaning: TypeAlias = Callable[[FunctionSignature, DefinitionRef], Sequence[object]]
_prepared_composition_token = object()


class _ImmutableMapping(Mapping[str, object]):
    __slots__ = ("_values",)

    def __init__(self, values: Mapping[str, object]) -> None:
        self._values = dict(values)

    def __getitem__(self, key: str) -> object:
        return self._values[key]

    def __iter__(self):
        return iter(self._values)

    def __len__(self) -> int:
        return len(self._values)

    def __repr__(self) -> str:
        return repr(self._values)

    def __eq__(self, other: object) -> bool:
        return isinstance(other, Mapping) and self._values == other

    def __deepcopy__(self, memo: dict[int, object]) -> _ImmutableMapping:
        return self


class _ImmutableList(list[object]):
    def _immutable(self, *args: object, **kwargs: object) -> None:
        raise TypeError("immutable list")

    __setitem__ = _immutable
    __delitem__ = _immutable
    append = _immutable
    clear = _immutable
    extend = _immutable
    insert = _immutable
    pop = _immutable
    remove = _immutable
    reverse = _immutable
    sort = _immutable

    def __add__(self, value: Iterable[object], /) -> _ImmutableList:
        return _ImmutableList(list.__add__(self, cast(list[object], value)))

    def __iadd__(self, value: Iterable[object], /) -> _ImmutableList:
        raise TypeError("immutable list")

    def __imul__(self, value: SupportsIndex, /) -> _ImmutableList:
        raise TypeError("immutable list")

    def __deepcopy__(self, memo: dict[int, object]) -> _ImmutableList:
        return self


def _immutable_copy(value: object) -> object:
    if isinstance(value, Mapping):
        return _ImmutableMapping({key: _immutable_copy(item) for key, item in value.items()})
    if isinstance(value, list):
        return _ImmutableList(_immutable_copy(item) for item in value)
    if isinstance(value, tuple):
        return tuple(_immutable_copy(item) for item in value)
    if is_dataclass(value) and not isinstance(value, type):
        return replace(value, **{
            field.name: _immutable_copy(getattr(value, field.name)) for field in fields(value)
        })
    return copy.deepcopy(value)


@dataclass(frozen=True, slots=True, init=False)
class PreparedCompositionInput:
    graph: SemanticGraph
    input: CompositionInput
    operation_checker: OperationChecker
    operation_meaning: OperationMeaning
    empty_refs: tuple[TypeRef, ...]
    empty_checked: CheckedEmptyTypes
    values: ValueContext

    def __init__(
        self,
        token: object,
        graph: SemanticGraph,
        input_value: CompositionInput,
        operation_checker: OperationChecker,
        operation_meaning: OperationMeaning,
        empty_refs: tuple[TypeRef, ...],
        empty_checked: CheckedEmptyTypes,
        values: ValueContext,
    ) -> None:
        if token is not _prepared_composition_token:
            raise TypeError("prepared composition input requires validation")
        object.__setattr__(self, "graph", graph)
        object.__setattr__(self, "input", input_value)
        object.__setattr__(self, "operation_checker", operation_checker)
        object.__setattr__(self, "operation_meaning", operation_meaning)
        object.__setattr__(self, "empty_refs", empty_refs)
        object.__setattr__(self, "empty_checked", empty_checked)
        object.__setattr__(self, "values", values)


def validate_composition_input(
    context: ValueContext,
    input_value: CompositionInput,
    operation_checker: OperationChecker,
) -> CompositionInputFailure | None:
    graph = cast(SemanticGraph, context.graph)
    if input_value.basis != SemanticBasis.of(graph):
        return BASIS_MISMATCH
    return _validate_composition_input(graph, context, input_value, operation_checker)


def _validate_composition_input(
    graph: SemanticGraph,
    context: ValueContext,
    input_value: CompositionInput,
    operation_checker: OperationChecker,
) -> CompositionInputFailure | None:
    from .semantic_identity import function_identity

    failure: CompositionInputFailure | None
    for kind, identities in (
        ("input", (value.id.value for value in input_value.initial_inputs)),
        ("site", (value.id.value for value in input_value.invocation_domain.sites)),
        ("lot", (value.id.value for value in input_value.initial_resources)),
        ("goal", (value.id.value for value in input_value.goal.outputs)),
        ("failure embedding", (value.id.value for value in input_value.goal.failures)),
        ("function", (function_identity(value.reference) for value in input_value.signatures)),
        ("guard", (value.id.value for value in input_value.invocation_domain.guards)),
    ):
        failure = _unique_ids(kind, identities)
        if failure is not None:
            return failure
    for function in input_value.signatures:
        def invalid(reason: str) -> InvalidSignature:
            return InvalidSignature(function.reference, reason)
        if (
            not function.reference.identity
            or not function.reference.revision
            or not function.reference.content_digest
            or not function.assumption_ref
            or not function.outcomes
        ):
            return invalid("identity, revision, digest, assumptions, or outcomes")
        for kind, identities in (
            ("input port", (port.id.value for port in function.inputs)),
            ("outcome", (outcome.id.value for outcome in function.outcomes)),
            ("resource requirement", (item.id.value for item in function.resource_inputs)),
        ):
            failure = _unique_ids(kind, identities)
            if failure is not None:
                return failure
        if isinstance(function.form, (PureFunctionForm, DeclaredTransformForm)):
            if function.effect is not CompositionEffect.PURE_FUNCTION:
                return invalid("pure function effect")
        else:
            failure = operation_checker(function, function.form.definition)
            if failure is not None:
                return failure
        for port in function.inputs:
            failure = _check_type(graph, port.contract.type_ref)
            if failure is not None:
                return failure
            if not _source_constraint_defined(context, input_value, port.source_constraint):
                return invalid("input source constraint")
            if port.resource_requirement is not None and not any(
                item.id == port.resource_requirement for item in function.resource_inputs
            ):
                return invalid("input resource requirement")
        for requirement in function.resource_inputs:
            failure = _check_type(graph, requirement.token_type)
            if failure is not None:
                return failure
            if requirement.multiplicity == 0:
                return invalid("zero resource multiplicity")
        for outcome in function.outcomes:
            failure = _unique_ids("output port", (port.id.value for port in outcome.value_ports))
            if failure is not None:
                return failure
            failure = _unique_ids("resource production", (item.id.value for item in outcome.produced_resources))
            if failure is not None:
                return failure
            for output_port in outcome.value_ports:
                failure = _check_type(graph, output_port.contract.type_ref)
                if failure is not None:
                    return failure
                if output_port.resource_production is not None and not any(
                    item.id == output_port.resource_production for item in outcome.produced_resources
                ):
                    return invalid("output resource production")
            for production in outcome.produced_resources:
                failure = _check_type(graph, production.token_type)
                if failure is not None:
                    return failure
        if function.handles_failure is not None and not _failure_origin_defined(input_value, function.handles_failure):
            return invalid("failure handler origin")
    for site in input_value.invocation_domain.sites:
        resolved_function = _signature(input_value, site.function)
        if resolved_function is None:
            return UnresolvedFunction(site.function)
        if resolved_function.effect not in input_value.allowed_effects:
            return SiteEffectNotPermitted(site.id, resolved_function.effect)
        if isinstance(resolved_function.form, DeclaredTransformForm) and resolved_function.reference not in input_value.invocation_domain.permitted_transforms:
            return TransformNotPermitted(resolved_function.reference)
    for initial in input_value.initial_inputs:
        failure = _check_type(graph, initial.contract.type_ref)
        if failure is not None:
            return failure
        if isinstance(initial.source, SuppliedValueSource):
            decision = accepts_slot(context, initial.contract, initial.source.value)
            if isinstance(decision, ValueRejected):
                return InvalidInitialValue(initial.id, decision.failure)
        if initial.resource is not None and not any(lot.id == initial.resource for lot in input_value.initial_resources):
            return InvalidResourceDeclaration("initial backing lot")
    for lot in input_value.initial_resources:
        failure = _check_type(graph, lot.token_type)
        if failure is not None:
            return failure
        if not isinstance(lot.producer, InitialResourceProducer):
            return InvalidResourceDeclaration("initial lot has an invocation producer")
        if not lot.producer.identity or not lot.producer.revision or not lot.provenance:
            return InvalidResourceDeclaration("initial producer or provenance")
    if not input_value.goal.outputs:
        return EmptyGoal()
    for goal in input_value.goal.outputs:
        failure = _check_type(graph, goal.contract.type_ref)
        if failure is not None:
            return failure
        if not _source_constraint_defined(context, input_value, goal.source_constraint):
            return GoalSourceConstraintUndefined(goal.id, goal.source_constraint)
    for embedding in input_value.goal.failures:
        failure = _check_type(graph, embedding.contract.type_ref)
        if failure is not None:
            return failure
        if not _failure_origin_defined(input_value, embedding.origin):
            return FailureEmbeddingOriginUndefined(embedding.id, embedding.origin)
    for projection in input_value.invocation_domain.permitted_projections:
        failure = _check_type(graph, projection.source_type)
        if failure is not None:
            return failure
    failure = _unique_ids("construction", (rule.identity for rule in input_value.invocation_domain.permitted_constructions))
    if failure is not None:
        return failure
    rules = input_value.invocation_domain.permitted_constructions
    edge_count = sum(len(rule.nested_fields) for rule in rules)
    for construction in rules:
        failure = _check_type(graph, construction.type_ref)
        if failure is not None:
            return failure
        product = _resolved_shape(graph, construction.type_ref)
        if product is None or _tag(product) != "Product":
            return ConstructionNotProduct(construction.identity, construction.type_ref)
        failure = _unique_ids("nested field", (name for name, _ in construction.nested_fields))
        if failure is not None:
            return failure
        failure = _unique_ids("field constraint", (item.field for item in construction.field_constraints))
        if failure is not None:
            return failure
        fields = _shape_payload(product).get("fields", ())
        for constraint in construction.field_constraints:
            if not _field_named(fields, constraint.field):
                return FieldConstraintUnknownField(construction.identity, constraint.field)
            if any(name == constraint.field for name, _ in construction.nested_fields):
                return ConstrainedNestedField(construction.identity, constraint.field)
            if not _source_constraint_defined(context, input_value, constraint.source):
                return ConstructionFieldSourceUndefined(construction.identity, constraint)
        for name, nested in construction.nested_fields:
            field = _field_named(fields, name)
            if field is None:
                return NestedFieldUndeclared(construction.identity, name)
            slot = _mapping(field.get("slot"), "field.slot")
            expected = _type_ref_from_native(slot.get("type_ref"))
            if not any(rule.identity == nested and rule.type_ref == expected for rule in rules):
                return NestedConstructionMismatch(construction.identity, name, nested, expected)
            reached = _construction_reachable(rules, len(rules) + edge_count + 1, (nested,), ())
            if construction.identity in reached:
                return CyclicConstruction(construction.identity)
    for guard in input_value.invocation_domain.guards:
        failure = _check_type(graph, guard.source_type)
        if failure is not None:
            return failure
        if isinstance(guard.kind, ValidateGuardKind):
            failure = _check_type(graph, guard.kind.contract.type_ref)
            if failure is not None:
                return failure
    for before, after in input_value.explicit_order:
        if before == after or _site_signature(input_value, before) is None or _site_signature(input_value, after) is None:
            return ExplicitSiteOrderInvalid(before, after)
    terminal_goals = input_value.goal.final_resources + tuple(
        goal for embedding in input_value.goal.failures for goal in embedding.final_resources
    )
    for terminal_goal in terminal_goals:
        if _declared_lot(input_value, terminal_goal.lot) is None:
            return InvalidResourceDeclaration("terminal resource lot")
    return None


def _verify_empty_closure_input(
    context: ValueContext, refs: Sequence[TypeRef]
) -> CheckedEmptyTypes | CompositionInputFailure:
    from .semantic_empty_types import CheckedEmptyTypes, verify_empty_types

    empty_checked = verify_empty_types(context, refs)
    if not isinstance(empty_checked, CheckedEmptyTypes):
        return InvalidEmptyTypeClosure(empty_checked)
    return empty_checked


def prepare_direct_composition(
    graph: SemanticGraph,
    input_value: CompositionInput,
    operation_checker: OperationChecker,
    operation_meaning: OperationMeaning,
) -> PreparedCompositionInput | CompositionInputFailure:
    owned_graph = cast(SemanticGraph, _immutable_copy(graph))
    return _prepare_direct_composition(
        owned_graph, ValueContext(owned_graph), input_value, operation_checker, operation_meaning
    )


def _prepare_direct_composition(
    owned_graph: SemanticGraph,
    context: ValueContext,
    input_value: CompositionInput,
    operation_checker: OperationChecker,
    operation_meaning: OperationMeaning,
) -> PreparedCompositionInput | CompositionInputFailure:
    from .semantic_empty_types import CheckedEmptyTypes, empty_types

    if input_value.basis != SemanticBasis.of(owned_graph):
        return BASIS_MISMATCH
    failure = _validate_composition_input(owned_graph, context, input_value, operation_checker)
    if failure is not None:
        return failure
    owned_input = cast(CompositionInput, _immutable_copy(input_value))
    refs = empty_types(context)
    empty_checked = _verify_empty_closure_input(context, refs)
    if not isinstance(empty_checked, CheckedEmptyTypes):
        return empty_checked
    return PreparedCompositionInput(
        _prepared_composition_token,
        owned_graph,
        owned_input,
        operation_checker,
        operation_meaning,
        refs,
        empty_checked,
        context,
    )


def _mapping(value: object, path: str) -> JsonObject:
    if not isinstance(value, Mapping):
        raise TypeError(f"{path} must be a mapping")
    return value


def _sequence(value: object, path: str) -> Sequence[object]:
    if not isinstance(value, Sequence) or isinstance(value, (str, bytes, bytearray)):
        raise TypeError(f"{path} must be a sequence")
    return value


def _type_ref_from_native(value: object) -> TypeRef:
    row = _mapping(value, "type reference")
    return TypeRef(
        _mapping(row.get("source"), "type reference source"),
        str(row.get("definition_name")),
        tuple(_sequence(row.get("pointer", ()), "type reference pointer")),
    )


def _type_ref_native(reference: TypeRef) -> dict[str, object]:
    return {
        "source": copy.deepcopy(dict(reference.source)),
        "definition_name": reference.definition_name,
        "pointer": list(reference.pointer),
    }


def _obligation_at(graph: SemanticGraph, reference: dict[str, object], path: ValuePath, reason: object) -> dict[str, object]:
    return {
        "type_ref": reference,
        "origin": {"source": reference["source"], "pointer": reference["pointer"]},
        "value_path": tuple(path),
        "profile": _profile(graph)["reference"],
        "reason": reason,
    }


def _nodes(graph: SemanticGraph) -> Sequence[object]:
    return _sequence(graph.get("nodes", ()), "graph.nodes")


def _profile(graph: SemanticGraph) -> JsonObject:
    return _mapping(graph.get("profile"), "graph.profile")


def _source_refs(graph: SemanticGraph) -> Sequence[object]:
    return _sequence(graph.get("source_refs", ()), "graph.source_refs")


def _find_type(graph: SemanticGraph, reference: TypeRef) -> JsonObject | None:
    for value in _nodes(graph):
        node = _mapping(value, "graph node")
        native = node.get("reference")
        if native is not None and _type_ref_from_native(native) == reference:
            return node
    return None


def _tag(value: JsonObject) -> str | None:
    tag = value.get("tag")
    return tag if isinstance(tag, str) else None


def _shape_payload(shape: JsonObject) -> JsonObject:
    return _mapping(shape.get("value", shape.get("fields", {})), "shape payload")


def _field_named(values: object, name: str) -> JsonObject | None:
    for value in _sequence(values, "fields"):
        field = _mapping(value, "field")
        if field.get("wire_name") == name:
            return field
    return None


def _resolved_shape_fuel(graph: SemanticGraph, fuel: int, reference: TypeRef) -> JsonObject | None:
    current = reference
    for _ in range(fuel):
        node = _find_type(graph, current)
        if node is None:
            return None
        shape = _mapping(node.get("shape"), "node.shape")
        if _tag(shape) != "Alias":
            return shape
        current = _type_ref_from_native(_shape_payload(shape).get("target"))
    return None


def _resolved_shape(graph: SemanticGraph, reference: TypeRef) -> JsonObject | None:
    return _resolved_shape_fuel(graph, len(_nodes(graph)) + 1, reference)


def _check_slot(
    context: ValueContext, slot: SlotContract, value: SlotValue
) -> ValidatedValue | ValidationFailure | None:
    native = _type_ref_native(slot.type_ref)
    if isinstance(value, AbsentValue):
        obligations = tuple(context.meaning_remaining(native))
        if obligations:
            return ValidationUnresolved(obligations)
        if slot.required:
            return ValidationValueFailure(context.failure_at(native, (), value, MISSING_REQUIRED))
        return None
    if isinstance(value, NullValue):
        obligations = tuple(context.meaning_remaining(native))
        if obligations:
            return ValidationUnresolved(obligations)
        if not slot.nullable:
            return ValidationValueFailure(context.failure_at(native, (), value, NULL_NOT_ALLOWED))
        return None
    return context.validate_value(native, _value_json(value.value))


def validate_slot(
    context: ValueContext, slot: SlotContract, value: SlotValue
) -> ValidatedSlot | ValidationFailure:
    checked = _check_slot(context, slot, value)
    if isinstance(checked, (ValidationValueFailure, ValidationUnresolved, ValidationCertificateMismatch)):
        return checked
    graph = context.graph
    return ValidatedSlot(
        _validated_slot_token,
        MemberCertificate(
            _profile(graph).get("reference"),
            tuple(_source_refs(graph)),
            slot,
            value,
            None if checked is None else checked.proof,
        ),
    )


def _decision_of(
    context: ValueContext, reference: TypeRef, result: ValidatedValue | ValidationFailure | None
) -> ValueDecision:
    if isinstance(result, ValidationValueFailure):
        return ValueRejected(result.failure)
    if isinstance(result, ValidationUnresolved):
        return ValueUnresolved(result.obligations)
    if isinstance(result, ValidationCertificateMismatch):
        return ValueUnresolved(
            (context.obligation_at(_type_ref_native(reference), (), variant("CertificateMismatch", result.condition)),)
        )
    return VALUE_ACCEPTED


def accepts_value(context: ValueContext, reference: TypeRef, value: object) -> ValueDecision:
    return _decision_of(context, reference, context.validate_value(_type_ref_native(reference), _value_json(value)))


def accepts_slot(context: ValueContext, slot: SlotContract, value: SlotValue) -> ValueDecision:
    return _decision_of(context, slot.type_ref, _check_slot(context, slot, value))


def _tag_matches(profile: JsonObject, members: Mapping[str, object], tag: str) -> bool:
    model = profile.get("tag")
    if model is None:
        return False
    return members.get(str(_mapping(model, "tag model").get("key"))) == tag


def value_at_path(profile: JsonObject, value: object, path: ValuePath) -> SlotValue:
    if not path:
        return PresentValue(value)
    step, rest = path[0], path[1:]
    if value is None:
        return NULL_VALUE
    if isinstance(step, FieldStep) and isinstance(value, Mapping):
        if step.value not in value:
            return ABSENT_VALUE
        child = value[step.value]
        return NULL_VALUE if child is None else value_at_path(profile, child, rest)
    if (
        isinstance(step, IndexStep)
        and isinstance(value, Sequence)
        and not isinstance(value, (str, bytes, bytearray))
    ):
        if step.value >= len(value):
            return ABSENT_VALUE
        child = value[step.value]
        return NULL_VALUE if child is None else value_at_path(profile, child, rest)
    if isinstance(step, VariantStep) and isinstance(value, Mapping):
        return value_at_path(profile, value, rest) if _tag_matches(profile, value, step.value) else ABSENT_VALUE
    return ABSENT_VALUE


def _projected_value(profile: JsonObject, source: SlotValue, path: ValuePath) -> SlotValue:
    if isinstance(source, PresentValue):
        return value_at_path(profile, source.value, path)
    return source


def _strengthen_projection(
    slot: SlotContract, path: ValuePath, assumptions: tuple[ProjectionAssumption, ...]
) -> SlotContract:
    observed = any(
        isinstance(value, (PresentAssumption, VariantAssumption, IndexPresentAssumption)) and value.path == path
        for value in assumptions
    )
    if observed:
        return SlotContract(slot.type_ref, True, False)
    if any(isinstance(value, NonNullAssumption) and value.path == path for value in assumptions):
        return SlotContract(slot.type_ref, slot.required, False)
    return slot


def _selector_precedes_internal_tag(branch: JsonObject, tag: str) -> bool:
    selector = _mapping(branch.get("selector"), "branch.selector")
    kind = _tag(selector)
    if kind == "InternalTag":
        return branch.get("wire_tag") != tag
    if kind == "Kind":
        return _tag(_mapping(_shape_payload(selector), "selector.kind")) != "Object"
    return False


def _projectable_tag_branch(branches: Sequence[object], tag: str) -> JsonObject | None:
    for value in branches:
        branch = _mapping(value, "union branch")
        if branch.get("wire_tag") == tag:
            selector = _mapping(branch.get("selector"), "branch.selector")
            return branch if _tag(selector) == "InternalTag" else None
        if not _selector_precedes_internal_tag(branch, tag):
            return None
    return None


def _project_contract(
    graph: SemanticGraph,
    assumptions: tuple[ProjectionAssumption, ...],
    fuel: int,
    slot: SlotContract,
    traversed: ValuePath,
    remaining: ValuePath,
) -> SlotContract | ProjectionFailure:
    while True:
        if fuel == 0:
            return UnresolvedProjection((_obligation_at(graph, _type_ref_native(slot.type_ref), traversed, variant("MembershipBound")),))
        fuel -= 1
        slot = _strengthen_projection(slot, traversed, assumptions)
        if not remaining:
            return slot
        step = remaining[0]
        node = _find_type(graph, slot.type_ref)
        if node is None:
            return UnresolvedProjection((_obligation_at(graph, _type_ref_native(slot.type_ref), traversed, variant("UnresolvedType")),))
        shape = _mapping(node.get("shape"), "node.shape")
        details = _shape_payload(shape)
        kind = _tag(shape)
        if kind == "Alias":
            slot = SlotContract(_type_ref_from_native(details.get("target")), slot.required, slot.nullable)
            continue
        if kind == "Product" and isinstance(step, FieldStep):
            field = _field_named(details.get("fields", ()), step.value)
            if field is None:
                return MissingField(slot.type_ref, step.value)
            child = _mapping(field.get("slot"), "field.slot")
            slot = SlotContract(
                _type_ref_from_native(child.get("type_ref")),
                slot.required and bool(child.get("required")),
                slot.nullable or bool(child.get("nullable")),
            )
        elif kind == "Array" and isinstance(step, IndexStep):
            child = _mapping(details.get("item"), "array.item")
            minimum = details.get("min_length")
            present = step.value < (0 if minimum is None else integer(minimum)) or any(
                isinstance(value, IndexPresentAssumption)
                and value.path == traversed
                and value.index == step.value
                for value in assumptions
            )
            slot = SlotContract(_type_ref_from_native(child.get("type_ref")), slot.required and present, True)
        elif kind == "TaggedUnion" and isinstance(step, VariantStep):
            if not any(
                isinstance(value, VariantAssumption) and value.path == traversed and value.tag == step.value
                for value in assumptions
            ):
                return BranchAssumptionRequired(traversed, step.value)
            branches = _sequence(details.get("branches", ()), "union.branches")
            branch = next(
                (
                    _mapping(value, "union branch")
                    for value in branches
                    if _mapping(value, "union branch").get("wire_tag") == step.value
                ),
                None,
            )
            if branch is None:
                return MissingVariant(slot.type_ref, step.value)
            if _profile(graph).get("tag") is None:
                return VariantSelectionUndetermined(traversed, step.value)
            selected = _projectable_tag_branch(branches, step.value)
            if selected is None or selected != branch:
                return VariantSelectionUndetermined(traversed, step.value)
            slot = SlotContract(_type_ref_from_native(branch.get("target")), slot.required, slot.nullable)
        else:
            return WrongShape(slot.type_ref, traversed)
        traversed += (step,)
        remaining = remaining[1:]


def project_slot(
    source: SlotContract,
    path: ValuePath,
    assumptions: tuple[ProjectionAssumption, ...],
    context: ValueContext,
) -> ProjectionCertificate | ProjectionFailure:
    graph: SemanticGraph = context.graph
    obligations = tuple(context.meaning_remaining(_type_ref_native(source.type_ref)))
    if obligations:
        return UnresolvedProjection(obligations)
    destination = _project_contract(
        graph, assumptions, (len(path) + 1) * (len(_nodes(graph)) + 1), source, (), path
    )
    if isinstance(destination, ProjectionFailure):
        return destination
    destination_obligations = tuple(context.meaning_remaining(_type_ref_native(destination.type_ref)))
    if destination_obligations:
        return UnresolvedProjection(destination_obligations)
    return ProjectionCertificate(
        _profile(graph).get("reference"),
        tuple(_source_refs(graph)),
        source,
        path,
        assumptions,
        destination,
    )


def _check_projection_certificate(
    graph: SemanticGraph, certificate: ProjectionCertificate, context: ValueContext
) -> ProjectionCertificate | ProjectionFailure:
    if certificate.profile != _profile(graph).get("reference") or certificate.source_refs != tuple(
        _source_refs(graph)
    ):
        return ProjectionCertificateMismatch("profile or source revisions")
    computed = project_slot(certificate.source, certificate.path, certificate.assumptions, context)
    if isinstance(computed, ProjectionFailure):
        return computed
    if computed != certificate:
        return ProjectionCertificateMismatch("projection contract or guards")
    return computed


def _unique_ids(kind: str, identities: Iterable[str]) -> DuplicateIdentity | None:
    seen: set[str] = set()
    for identity in identities:
        if not identity or identity in seen:
            return DuplicateIdentity(kind, identity)
        seen.add(identity)
    return None


def _present_contract(reference: TypeRef) -> SlotContract:
    return SlotContract(reference, True, False)


def _check_type(graph: SemanticGraph, reference: TypeRef) -> UnresolvedType | None:
    return None if _find_type(graph, reference) is not None else UnresolvedType(reference)


def _signature(input_value: CompositionInput, reference: FunctionRef) -> FunctionSignature | None:
    return next((item for item in input_value.signatures if item.reference == reference), None)


def _site_signature(input_value: CompositionInput, site: SiteId) -> FunctionSignature | None:
    declaration = next((item for item in input_value.invocation_domain.sites if item.id == site), None)
    return None if declaration is None else _signature(input_value, declaration.function)


def _declared_value(
    input_value: CompositionInput, producer: ProducerRef
) -> tuple[SlotContract, ResourceLotRef | None] | None:
    if isinstance(producer, InitialProducer):
        initial = next((item for item in input_value.initial_inputs if item.id == producer.id), None)
        if initial is None:
            return None
        return initial.contract, None if initial.resource is None else InitialLotRef(initial.resource)
    function = _site_signature(input_value, producer.site)
    if function is None:
        return None
    outcome = next((item for item in function.outcomes if item.id == producer.outcome), None)
    if outcome is None:
        return None
    port = next((item for item in outcome.value_ports if item.id == producer.port), None)
    if port is None:
        return None
    return port.contract, (
        None
        if port.resource_production is None
        else ProducedLotRef(producer.site, outcome.id, port.resource_production)
    )


def _declared_lot(input_value: CompositionInput, reference: ResourceLotRef) -> LotDeclaration | None:
    if isinstance(reference, InitialLotRef):
        lot = next((item for item in input_value.initial_resources if item.id == reference.id), None)
        if lot is None:
            return None
        return LotDeclaration(lot.token_type, lot.producer, lot.revision, lot.quantity, lot.provenance)
    function = _site_signature(input_value, reference.site)
    if function is None:
        return None
    branch = next((item for item in function.outcomes if item.id == reference.outcome), None)
    if branch is None:
        return None
    production = next((item for item in branch.produced_resources if item.id == reference.production), None)
    if production is None:
        return None
    return LotDeclaration(
        production.token_type,
        InvocationResourceProducer(reference.site, reference.outcome),
        production.revision,
        production.quantity,
        production.provenance,
    )


def _constraint_path_defined(context: ValueContext, contract: SlotContract, path: ValuePath) -> bool:
    assumptions = tuple(
        VariantAssumption(path[:index], step.value)
        for index, step in enumerate(path)
        if isinstance(step, VariantStep)
    )
    return not isinstance(project_slot(contract, path, assumptions, context), ProjectionFailure)


def _source_constraint_defined(context: ValueContext, input_value: CompositionInput, constraint: SourceConstraint) -> bool:
    if isinstance(constraint, AnyCompatible):
        return True
    producer: ProducerRef
    if isinstance(constraint, InitialOnly):
        producer = InitialProducer(constraint.id)
    else:
        producer = InvocationOutcomeProducer(constraint.site, constraint.outcome, constraint.port)
    declared = _declared_value(input_value, producer)
    return declared is not None and _constraint_path_defined(context, declared[0], constraint.path)


def _failure_origin_defined(input_value: CompositionInput, origin: FailureOrigin) -> bool:
    if isinstance(origin, FunctionFailureOrigin):
        function = _signature(input_value, origin.function)
        return function is not None and any(
            item.id == origin.outcome and item.form is OutcomeForm.DECLARED_FAILURE for item in function.outcomes
        )
    return any(item.id == origin.guard for item in input_value.invocation_domain.guards)


def _construction_reachable(
    rules: tuple[ConstructionRule, ...], fuel: int, pending: tuple[str, ...], seen: tuple[str, ...]
) -> tuple[str, ...]:
    if fuel == 0 or not pending:
        return seen
    identity, *rest = pending
    if identity in seen:
        return _construction_reachable(rules, fuel - 1, tuple(rest), seen)
    rule = next((item for item in rules if item.identity == identity), None)
    children = () if rule is None else tuple(child for _, child in rule.nested_fields)
    return _construction_reachable(rules, fuel - 1, children + tuple(rest), (identity,) + seen)


_public_aliases = {
    "BindingCompatibility",
    "BindingExpr",
    "CompositionEngineFailure",
    "CompositionInputFailure",
    "FailureOrigin",
    "FunctionForm",
    "GuardArm",
    "GuardKind",
    "InclusionFailure",
    "InitialSource",
    "LoweringFailure",
    "PathStep",
    "PlanTree",
    "ProducerRef",
    "ProjectionAssumption",
    "ResourceIdentityConstraint",
    "ResourceLotRef",
    "ResourceProducer",
    "ReturnPlan",
    "SlotValue",
    "SourceConstraint",
    "TypeObligationReason",
    "UnresolvedObligation",
    "ValueDecision",
    "ValuePath",
    "WitnessFailure",
}
__all__ = sorted(
    _public_aliases
    | {
        name
        for name, value in globals().items()
        if not name.startswith("_")
        and (getattr(value, "__module__", None) == __name__ or name.isupper())
    }
)
