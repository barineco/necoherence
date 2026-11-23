# SPDX-FileCopyrightText: 2026 barineco
# SPDX-License-Identifier: MIT

"""Shared fixtures for the composition execution tests."""

from __future__ import annotations

from dataclasses import replace


from necoherence.semantic_composition import (
    InitialLotRef,
    InitialResourceProducer,
    LotId,
    RequirementId,
    TypeRef,
    ResourceBinding,
    ResourceLot,
    ResourceRequirement,
    GuardFailureOrigin,
    GuardId,
    PureFunctionForm,
    UnitGuardArm,
    UnitGuardKind,
    ValidateGuardKind,
    VariantGuardArm,
    DeclaredGuard,
    FunctionFailureOrigin,
    ABSENT_VALUE,
    NULL_VALUE,
    ANY_COMPATIBLE,
    ANY_RESOURCE_IDENTITY,
    ARGUMENT_SOURCE,
    CompositionInput,
    CompositionEffect,
    CompositionPlan,
    DefinitionRef,
    GoalPort,
    GoalPortId,
    GoalSpec,
    FieldStep,
    FunctionRef,
    FunctionSignature,
    InitialInput,
    InitialProducer,
    InputId,
    InputPort,
    InvalidInitialValue,
    IndexStep,
    InvocationDomain,
    InvocationPlan,
    InvocationSite,
    OperationFunctionForm,
    OutcomeContract,
    OutcomeForm,
    OutcomeId,
    PortId,
    PresentValue,
    PreparedCompositionInput,
    ReturnPlanTree,
    SearchBounds,
    SelectionPolicy,
    SemanticBasis,
    SiteId,
    SlotContract,
    SourceBindingExpr,
    SuccessReturnPlan,
    SuppliedValueCompatibility,
    SuppliedValueSource,
    UndefinedMeaningInclusion,
    ValueRef,
    VariantStep,
    NonNullAssumption,
    PresentAssumption,
    ProjectionCertificate,
    ProjectionCertificateMismatch,
    UnresolvedProjection,
    VariantSelectionUndetermined,
    VariantAssumption,
    prepare_direct_composition,
    project_slot,
    value_at_path,
)
from necoherence.typed_mapping import (
    BindingMode,
    ColoredToken,
    ForgedClosure,
    GuardNotDominating,
    IncompleteBranchCoverage,
    Inclusion,
    InputRevisionMismatch,
    MissingBinding,
    MissingEvidence,
    Marking,
    ResourceLoweringMismatch,
    ProducerMismatch,
    ProjectionMismatch,
    And,
    PlaceHasToken,
)


def signature_type_ref(identity: str) -> TypeRef:
    return TypeRef(
        {
            "repository": "ncoh-type-signatures",
            "revision": "1",
            "path": "",
            "content_digest": "",
            "document_id": "",
            "declared_revision": None,
        },
        identity,
    )


def prepared_input(policy: SelectionPolicy | None = SelectionPolicy.ANY_FEASIBLE) -> PreparedCompositionInput:
    graph = {
        "profile": {
            "reference": {"identity": "test", "revision": "1", "content_digest": "0" * 64},
            "source_refs": [],
        },
        "nodes": [
            {
                "id": "truth",
                "reference": {
                    "source": {
                        "repository": "ncoh-type-signatures",
                        "revision": "1",
                        "path": "",
                        "content_digest": "",
                        "document_id": "",
                        "declared_revision": None,
                    },
                    "definition_name": "truth",
                    "pointer": [],
                },
                "shape": {"tag": "Boolean", "value": {"const_value": None, "default_value": None}},
            }
        ],
        "definitions": [],
    }
    contract = SlotContract(signature_type_ref("truth"), True, False)
    input_value = CompositionInput(
        "composition", "1", SemanticBasis.of(graph), (),
        (InitialInput(InputId("input"), contract, SuppliedValueSource(PresentValue(False)), None),),
        (), GoalSpec((GoalPort(GoalPortId("goal"), contract, ANY_COMPATIBLE),), (), ()),
        InvocationDomain("domain", "1", (), (), (), (), ()), (), (), SearchBounds(), policy,
    )
    prepared = prepare_direct_composition(graph, input_value, lambda _function, _definition: None, lambda _function, _definition: ())
    assert isinstance(prepared, PreparedCompositionInput)
    return prepared


def resource_invocation_fixture(
    initial_resource: str | None,
    lot_revision: int = 0,
    required_revision: int = 0,
    requirement: str = "requirement",
    bound_lot: str = "lot",
) -> tuple[PreparedCompositionInput, InvocationPlan]:
    base = prepared_input()
    contract = base.input.initial_inputs[0].contract
    token = contract.type_ref
    reference = FunctionRef("resource-function", "1", "digest")
    site = InvocationSite(SiteId("site"), reference)
    function = FunctionSignature(
        reference,
        PureFunctionForm(),
        CompositionEffect.PURE_FUNCTION,
        (InputPort(PortId("input"), contract, ANY_COMPATIBLE, RequirementId("requirement")),),
        (OutcomeContract(OutcomeId("success"), OutcomeForm.SUCCESS, (), ()),),
        (ResourceRequirement(
            RequirementId("requirement"), token, BindingMode.READ, 1, required_revision, ANY_RESOURCE_IDENTITY
        ),),
        "assumption",
    )
    initial = replace(
        base.input.initial_inputs[0], resource=None if initial_resource is None else LotId(initial_resource)
    )
    lots = (ResourceLot(LotId("lot"), token, InitialResourceProducer("holder", "1"), lot_revision, 1, "test"),)
    input_value = replace(
        base.input,
        signatures=(function,),
        initial_inputs=(initial,),
        initial_resources=lots,
        invocation_domain=replace(base.input.invocation_domain, sites=(site,)),
        allowed_effects=(CompositionEffect.PURE_FUNCTION,),
    )
    prepared = prepare_direct_composition(
        base.graph, input_value, lambda _function, _definition: None, lambda _function, _definition: ()
    )
    assert isinstance(prepared, PreparedCompositionInput)
    projection = project_slot(contract, (), (), prepared.values)
    assert isinstance(projection, ProjectionCertificate)
    supplied = initial.source
    assert isinstance(supplied, SuppliedValueSource)
    binding = SourceBindingExpr(
        ValueRef(InitialProducer(initial.id), ()), projection, SuppliedValueCompatibility(supplied.value)
    )
    resource = ResourceBinding(RequirementId(requirement), InitialLotRef(LotId(bound_lot)), None)  # type: ignore[arg-type]
    return prepared, InvocationPlan(site.id, reference, ((PortId("input"), binding),), (resource,))


def plan_of(prepared: PreparedCompositionInput) -> CompositionPlan:
    initial = prepared.input.initial_inputs[0]
    assert isinstance(initial.source, SuppliedValueSource)
    supplied = initial.source.value
    projection = project_slot(initial.contract, (), (), prepared.values)
    assert isinstance(projection, ProjectionCertificate)
    binding = SourceBindingExpr(
        ValueRef(InitialProducer(initial.id), ()), projection, SuppliedValueCompatibility(supplied)
    )
    terminal = SuccessReturnPlan(((prepared.input.goal.outputs[0].id, binding),))
    return CompositionPlan(prepared.input.identity, prepared.input.revision, ReturnPlanTree(0, terminal))

