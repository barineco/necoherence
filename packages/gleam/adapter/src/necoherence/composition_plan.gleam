// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import neco_quotient_application as quotient
import necoherence/exact_json as kdl
import necoherence/semantic_types as types
import necoherence/semantic_validation as validation
import necoherence/typed_mapping as resource

pub type SemanticBasis {
  SemanticBasis(profile: types.SemanticProfile, sources: List(types.SourceRef))
}

pub type FunctionRef {
  FunctionRef(identity: String, revision: String, content_digest: String)
}

pub type InputId {
  InputId(value: String)
}

pub type PortId {
  PortId(value: String)
}

pub type SiteId {
  SiteId(value: String)
}

pub type OutcomeId {
  OutcomeId(value: String)
}

pub type GoalPortId {
  GoalPortId(value: String)
}

pub type LotId {
  LotId(value: String)
}

pub type RequirementId {
  RequirementId(value: String)
}

pub type ProductionId {
  ProductionId(value: String)
}

pub type GuardId {
  GuardId(value: String)
}

pub type FailureEmbeddingId {
  FailureEmbeddingId(value: String)
}

pub type TypePair {
  TypePair(
    source: types.SlotContract,
    destination: types.SlotContract,
    source_tag: Option(String),
  )
}

pub type InclusionRule {
  SameDefinedType
  EmptySource
  InclusionBoolean
  IntegerIntersection
  FiniteStrings
  StringConditions
  BytesLength
  InclusionUnit
  UnfoldSource
  UnfoldDestination
  InclusionArray
  InclusionProduct
  SourceUnion
  DestinationUnion
}

pub type PairEntry {
  PairEntry(
    pair: TypePair,
    source_shape: types.TypeShape,
    destination_shape: types.TypeShape,
    rule: InclusionRule,
    children: List(Int),
  )
}

pub type InclusionCertificate {
  InclusionCertificate(
    basis: SemanticBasis,
    source: types.SlotContract,
    destination: types.SlotContract,
    empty_types: List(types.TypeRef),
    pairs: List(PairEntry),
    root: Int,
  )
}

pub type TypeObligationReason {
  TypeMeaning(obligations: List(types.SemanticObligation))
  ConstraintImplication
  TypePresence
  UnionRemainder
  ExtraField(name: String)
  TypeInhabitation
  ObligationBoundExhausted
}

pub type TypeObligation {
  TypeObligation(
    pair: TypePair,
    path: types.ValuePath,
    reason: TypeObligationReason,
  )
}

pub type InclusionFailure {
  InclusionBasisMismatch
  ContractMismatch
  UndefinedMeaning(obligations: List(types.SemanticObligation))
  MissingPair
  PairMismatch(index: Int)
  RuleMismatch(index: Int)
  ChildCoverage(index: Int)
  ForgedEmptiness
  CounterexampleMismatch
  InclusionUnresolved(obligation: TypeObligation)
}

pub type ProducerRef {
  Initial(id: InputId)
  InvocationOutcome(site: SiteId, outcome: OutcomeId, port: PortId)
}

pub type ValueRef {
  ValueRef(producer: ProducerRef, path: types.ValuePath)
}

pub type SourceConstraint {
  AnyCompatible
  InitialOnly(input: InputId, path: types.ValuePath)
  ProducedBy(
    site: SiteId,
    outcome: OutcomeId,
    port: PortId,
    path: types.ValuePath,
  )
}

pub type ResourceLotRef {
  InitialLot(id: LotId)
  ProducedLot(site: SiteId, outcome: OutcomeId, production: ProductionId)
}

pub type ResourceProducer {
  InitialResource(identity: String, revision: String)
  OutcomeResource(site: SiteId, outcome: OutcomeId)
}

pub type ResourceIdentityConstraint {
  AnyResource
  Exactly(producer: ResourceProducer)
}

pub type ResourceLot {
  ResourceLot(
    id: LotId,
    token_type: types.TypeRef,
    producer: ResourceProducer,
    revision: Int,
    quantity: Int,
    provenance: String,
  )
}

pub type ResourceRequirement {
  ResourceRequirement(
    id: RequirementId,
    token_type: types.TypeRef,
    mode: resource.BindingMode,
    multiplicity: Int,
    required_revision: Int,
    identity: ResourceIdentityConstraint,
  )
}

pub type ResourceProduction {
  ResourceProduction(
    id: ProductionId,
    token_type: types.TypeRef,
    revision: Int,
    quantity: Int,
    provenance: String,
  )
}

pub type InitialSource {
  Argument
  SuppliedValue(value: types.SlotValue(kdl.JsonValue))
}

pub type InitialInput {
  InitialInput(
    id: InputId,
    contract: types.SlotContract,
    source: InitialSource,
    resource: Option(LotId),
  )
}

pub type InputPort {
  InputPort(
    id: PortId,
    contract: types.SlotContract,
    source_constraint: SourceConstraint,
    resource_requirement: Option(RequirementId),
  )
}

pub type OutputPort {
  OutputPort(
    id: PortId,
    contract: types.SlotContract,
    resource_production: Option(ProductionId),
  )
}

pub type OutcomeForm {
  Success
  DeclaredFailure
}

pub type OutcomeContract {
  OutcomeContract(
    id: OutcomeId,
    form: OutcomeForm,
    value_ports: List(OutputPort),
    produced_resources: List(ResourceProduction),
  )
}

pub type FunctionForm {
  Pure
  Operation(reference: types.DefinitionRef)
  DeclaredTransform
}

pub type CompositionEffect {
  PureFunction
  HttpRequestResponse
  DataOnly
}

pub type GuardArm {
  GuardPresent
  GuardAbsent
  GuardNull
  GuardVariant(tag: String)
  UnknownVariant
  GuardAccepted
  GuardRejected
}

pub type FailureOrigin {
  FunctionFailure(function: FunctionRef, outcome: OutcomeId)
  GuardFailure(guard: GuardId, arm: GuardArm)
}

pub type FunctionSignature {
  FunctionSignature(
    reference: FunctionRef,
    form: FunctionForm,
    effect: CompositionEffect,
    inputs: List(InputPort),
    outcomes: List(OutcomeContract),
    resource_inputs: List(ResourceRequirement),
    assumption_ref: String,
    handles_failure: Option(FailureOrigin),
  )
}

pub type InvocationSite {
  InvocationSite(id: SiteId, function: FunctionRef)
}

pub type PermittedProjection {
  PermittedProjection(source_type: types.TypeRef, path: types.ValuePath)
}

pub type GuardKind {
  Presence
  Variants
  Validate(contract: types.SlotContract)
}

pub type DeclaredGuard {
  DeclaredGuard(
    id: GuardId,
    source_type: types.TypeRef,
    path: types.ValuePath,
    kind: GuardKind,
  )
}

pub type FieldPresence {
  Required
  Optional
}

pub type FieldConstraint {
  FieldConstraint(
    field: String,
    source: SourceConstraint,
    presence: FieldPresence,
  )
}

pub type ConstructionRule {
  ConstructionRule(
    identity: String,
    type_ref: types.TypeRef,
    nested_fields: List(#(String, String)),
    field_constraints: List(FieldConstraint),
  )
}

pub type InvocationDomain {
  InvocationDomain(
    identity: String,
    revision: String,
    sites: List(InvocationSite),
    permitted_projections: List(PermittedProjection),
    permitted_constructions: List(ConstructionRule),
    permitted_transforms: List(FunctionRef),
    guards: List(DeclaredGuard),
  )
}

pub type ResourceGoal {
  ResourceGoal(lot: ResourceLotRef, multiplicity: Int, revision: Int)
}

pub type GoalPort {
  GoalPort(
    id: GoalPortId,
    contract: types.SlotContract,
    source_constraint: SourceConstraint,
  )
}

pub type FailureEmbedding {
  FailureEmbedding(
    id: FailureEmbeddingId,
    origin: FailureOrigin,
    contract: types.SlotContract,
    final_resources: List(ResourceGoal),
  )
}

pub type GoalSpec {
  GoalSpec(
    outputs: List(GoalPort),
    failures: List(FailureEmbedding),
    final_resources: List(ResourceGoal),
  )
}

pub type SelectionPolicy {
  RequireUnique
  AnyFeasible
}

pub type ResourceBounds {
  ResourceBounds(max_bindings: Int, max_search_steps: Int, max_tokens: Int)
}

pub type SearchBounds {
  SearchBounds(
    max_expanded_states: Int,
    max_binding_candidates: Int,
    max_type_obligations: Int,
    max_branch_nodes: Int,
    max_sample_length: Int,
    resource_bounds: Option(ResourceBounds),
  )
}

pub type CompositionInput {
  CompositionInput(
    identity: String,
    revision: String,
    basis: SemanticBasis,
    signatures: List(FunctionSignature),
    initial_inputs: List(InitialInput),
    initial_resources: List(ResourceLot),
    goal: GoalSpec,
    invocation_domain: InvocationDomain,
    allowed_effects: List(CompositionEffect),
    explicit_order: List(#(SiteId, SiteId)),
    selection_policy: Option(SelectionPolicy),
    bounds: SearchBounds,
  )
}

pub type CompositionInputFailure {
  InputBasisMismatch
  DuplicateIdentity(kind: String, identity: String)
  UnresolvedType(reference: types.TypeRef)
  UnresolvedFunction(reference: FunctionRef)
  InvalidSignature(function: FunctionRef, reason: String)
  InvalidInitialValue(input: InputId, failure: types.ValueFailure)
  SiteEffectNotPermitted(site: SiteId, effect: CompositionEffect)
  TransformNotPermitted(function: FunctionRef)
  EmptyGoal
  GoalSourceConstraintUndefined(port: GoalPortId, constraint: SourceConstraint)
  FailureEmbeddingOriginUndefined(
    embedding: FailureEmbeddingId,
    origin: FailureOrigin,
  )
  ConstructionNotProduct(identity: String, reference: types.TypeRef)
  FieldConstraintUnknownField(identity: String, field: String)
  ConstrainedNestedField(identity: String, field: String)
  ConstructionFieldSourceUndefined(
    identity: String,
    constraint: FieldConstraint,
  )
  NestedFieldUndeclared(identity: String, field: String)
  NestedConstructionMismatch(
    identity: String,
    field: String,
    nested: String,
    reference: types.TypeRef,
  )
  CyclicConstruction(identity: String)
  ExplicitSiteOrderInvalid(before: SiteId, after: SiteId)
  InvalidEmptyTypeClosure(failure: InclusionFailure)
  InvalidResourceDeclaration(reason: String)
  InvalidLibrary(failure: types.LibraryCheckFailure)
}

pub opaque type PreparedCompositionInput {
  PreparedCompositionInput(
    validation: validation.PreparedGraph,
    input: CompositionInput,
    operation_checker: fn(FunctionSignature, types.DefinitionRef) ->
      Result(Nil, CompositionInputFailure),
    operation_meaning: fn(FunctionSignature, types.DefinitionRef) ->
      List(types.SemanticObligation),
    empty_refs: List(types.TypeRef),
  )
}

pub type BindingCompatibility {
  Inclusion(certificate: InclusionCertificate)
  SuppliedBindingValue(value: types.SlotValue(kdl.JsonValue))
}

pub type BindingExpr {
  Source(
    value: ValueRef,
    projection: validation.ProjectionCertificate,
    compatibility: BindingCompatibility,
  )
  Product(
    construction: String,
    type_ref: types.TypeRef,
    fields: List(#(String, BindingExpr)),
  )
}

pub type ResourceBinding {
  ResourceBinding(
    requirement: RequirementId,
    lot: ResourceLotRef,
    inclusion: InclusionCertificate,
  )
}

pub type InvocationPlan {
  InvocationPlan(
    site: SiteId,
    function: FunctionRef,
    bindings: List(#(PortId, BindingExpr)),
    resources: List(ResourceBinding),
  )
}

pub type ReturnPlan {
  ReturnSuccess(outputs: List(#(GoalPortId, BindingExpr)))
  ReturnFailure(embedding: FailureEmbeddingId, value: BindingExpr)
}

pub type PlanTree {
  Invoke(
    rank: Int,
    invocation: InvocationPlan,
    arms: List(#(OutcomeId, PlanTree)),
    empty_outcomes: List(OutcomeId),
  )
  Guard(
    rank: Int,
    guard: GuardId,
    inspected: ValueRef,
    arms: List(#(GuardArm, PlanTree)),
  )
  ReturnValue(rank: Int, terminal: ReturnPlan)
}

pub type CompositionPlan {
  CompositionPlan(
    input_identity: String,
    input_revision: String,
    root: PlanTree,
  )
}

pub type PreparedTree {
  PreparedInvoke(
    invocation: InvocationPlan,
    arms: Option(quotient.KeyedBlocks(OutcomeId, PreparedTree)),
  )
  PreparedGuard(
    guard: GuardId,
    inspected: ValueRef,
    arms: Option(quotient.KeyedBlocks(GuardArm, PreparedTree)),
  )
  PreparedReturn(terminal: ReturnPlan)
}

fn prepare_tree(tree: PlanTree) -> PreparedTree {
  case tree {
    Invoke(_, invocation, arms, _) ->
      PreparedInvoke(
        invocation,
        option.from_result(
          quotient.keyed_blocks_of(
            list.map(arms, fn(arm) { #(arm.0, prepare_tree(arm.1)) }),
          ),
        ),
      )
    Guard(_, guard, inspected, arms) ->
      PreparedGuard(
        guard,
        inspected,
        option.from_result(
          quotient.keyed_blocks_of(
            list.map(arms, fn(arm) { #(arm.0, prepare_tree(arm.1)) }),
          ),
        ),
      )
    ReturnValue(_, terminal) -> PreparedReturn(terminal)
  }
}

pub opaque type CheckedComposition {
  CheckedComposition(
    prepared: PreparedCompositionInput,
    plan: CompositionPlan,
    root: PreparedTree,
  )
}

pub type UnresolvedObligation {
  UnresolvedTypeObligation(
    value: Option(ValueRef),
    obligations: List(TypeObligation),
  )
  UnresolvedMeaning(obligations: List(types.SemanticObligation))
  Inhabitation(producer: ProducerRef, contract: types.SlotContract)
  BranchInhabitation
  StateBoundExhausted
  BindingBoundExhausted
  BranchBoundExhausted
  ResourceSolverUnknown(reason: resource.UnknownReason)
  ResourceCapacityBound(required: Int, limit: Int)
  UnresolvedUniqueness
}

pub fn semantic_basis_of(graph: types.SemanticGraph) -> SemanticBasis {
  SemanticBasis(graph.profile, graph.source_refs)
}

pub fn prepared_graph(
  prepared: PreparedCompositionInput,
) -> types.SemanticGraph {
  validation.prepared_graph(prepared.validation)
}

pub fn prepared_validation(
  prepared: PreparedCompositionInput,
) -> validation.PreparedGraph {
  prepared.validation
}

pub fn prepared_input(prepared: PreparedCompositionInput) -> CompositionInput {
  prepared.input
}

pub fn checked_prepared(
  checked: CheckedComposition,
) -> PreparedCompositionInput {
  checked.prepared
}

pub fn checked_plan(checked: CheckedComposition) -> CompositionPlan {
  checked.plan
}

@internal
pub fn checked_root(checked: CheckedComposition) -> PreparedTree {
  checked.root
}

@internal
pub fn admitted_composition(
  prepared: PreparedCompositionInput,
  plan: CompositionPlan,
) -> CheckedComposition {
  CheckedComposition(prepared, plan, prepare_tree(plan.root))
}

pub fn signature(
  input: CompositionInput,
  reference: FunctionRef,
) -> Option(FunctionSignature) {
  option.from_result(
    list.find(input.signatures, fn(signature) {
      signature.reference == reference
    }),
  )
}

pub fn site_signature(
  input: CompositionInput,
  site: SiteId,
) -> Option(FunctionSignature) {
  option.then(
    option.from_result(
      list.find(input.invocation_domain.sites, fn(candidate) {
        candidate.id == site
      }),
    ),
    fn(site) { signature(input, site.function) },
  )
}

pub fn encode_tuple(parts: List(String)) -> String {
  string.concat(
    list.map(parts, fn(part) {
      int.to_string(string.byte_size(part)) <> ":" <> part
    }),
  )
}

pub fn type_identity(reference: types.TypeRef) -> String {
  let #(presence, revision) = case reference.source.declared_revision {
    None -> #("none", "")
    Some(revision) -> #("some", int.to_string(revision))
  }
  encode_tuple([
    "type",
    reference.source.repository,
    reference.source.revision,
    reference.source.path,
    reference.source.content_digest,
    reference.source.document_id,
    presence,
    revision,
    reference.definition_name,
    encode_tuple(reference.pointer),
  ])
}

pub fn function_identity(reference: FunctionRef) -> String {
  encode_tuple([
    reference.identity,
    reference.revision,
    reference.content_digest,
  ])
}

pub fn producer_identity(producer: ProducerRef) -> String {
  case producer {
    Initial(id) -> encode_tuple(["initial-value", id.value])
    InvocationOutcome(site, outcome, port) ->
      encode_tuple(["outcome-value", site.value, outcome.value, port.value])
  }
}

pub fn lot_identity(lot: ResourceLotRef) -> String {
  case lot {
    InitialLot(id) -> encode_tuple(["initial-lot", id.value])
    ProducedLot(site, outcome, production) ->
      encode_tuple(["produced-lot", site.value, outcome.value, production.value])
  }
}

pub fn prepared_composition_input(
  prepared: validation.PreparedGraph,
  input: CompositionInput,
  operation_checker: fn(FunctionSignature, types.DefinitionRef) ->
    Result(Nil, CompositionInputFailure),
  operation_meaning: fn(FunctionSignature, types.DefinitionRef) ->
    List(types.SemanticObligation),
  empty_refs: List(types.TypeRef),
) -> PreparedCompositionInput {
  PreparedCompositionInput(
    prepared,
    input,
    operation_checker,
    operation_meaning,
    empty_refs,
  )
}

pub fn prepared_operation_checker(
  prepared: PreparedCompositionInput,
) -> fn(FunctionSignature, types.DefinitionRef) ->
  Result(Nil, CompositionInputFailure) {
  prepared.operation_checker
}

pub fn prepared_operation_meaning(
  prepared: PreparedCompositionInput,
) -> fn(FunctionSignature, types.DefinitionRef) ->
  List(types.SemanticObligation) {
  prepared.operation_meaning
}

pub fn prepared_empty_refs(
  prepared: PreparedCompositionInput,
) -> List(types.TypeRef) {
  prepared.empty_refs
}
