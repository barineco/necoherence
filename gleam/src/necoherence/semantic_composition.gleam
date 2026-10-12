// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
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
  EmptySource
  InclusionBoolean
  IntegerIntersection
  FiniteStrings
  StringConditions
  BytesLength
  InclusionUnit
  JsonDomain
  PlainObjectDomain
  UnfoldSource
  UnfoldDestination
  InclusionArray
  InclusionProduct
  SourceUnion
  DestinationUnion
  SourceRecord
  DestinationRecord
  ProductTagCases
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
    root: Int,
    empty_types: List(types.TypeRef),
    pairs: List(PairEntry),
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

pub type CounterexampleCertificate {
  CounterexampleCertificate(
    basis: SemanticBasis,
    source: types.SlotContract,
    destination: types.SlotContract,
    value: types.SlotValue(kdl.JsonValue),
    destination_failure: types.ValueFailure,
  )
}

pub type CompatibilityDecision {
  Compatible(certificate: InclusionCertificate)
  Incompatible(certificate: CounterexampleCertificate)
  CompatibilityUnknown(obligations: List(TypeObligation))
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

pub opaque type CheckedInclusion {
  CheckedInclusion(
    graph: types.SemanticGraph,
    certificate: InclusionCertificate,
  )
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
  InvalidInvocationDomain(reason: String)
  InvalidResourceDeclaration(reason: String)
  InvalidBound(reason: String)
  OperationEffectMismatch(
    operation: types.DefinitionRef,
    expected: CompositionEffect,
    supplied: CompositionEffect,
  )
}

pub opaque type PreparedCompositionInput {
  PreparedCompositionInput(
    graph: types.SemanticGraph,
    input: CompositionInput,
    empty: List(types.TypeRef),
    initial_obligations: List(types.SemanticObligation),
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
  PlanTree(rank: Int, node: PlanNode)
}

pub type PlanNode {
  Invoke(
    invocation: InvocationPlan,
    arms: List(#(OutcomeId, PlanTree)),
    empty_outcomes: List(OutcomeId),
  )
  Guard(guard: GuardId, inspected: ValueRef, arms: List(#(GuardArm, PlanTree)))
  Return(terminal: ReturnPlan)
}

pub type CompositionPlan {
  CompositionPlan(
    input_identity: String,
    input_revision: String,
    root: PlanTree,
  )
}

pub type TraceStep {
  InvocationStep(invocation: InvocationPlan, outcome: OutcomeId)
  GuardStep(guard: GuardId, inspected: ValueRef, arm: GuardArm)
}

pub type BranchTrace {
  BranchTrace(steps: List(TraceStep), terminal: ReturnPlan)
}

pub type ResourceLotCorrespondence {
  ResourceLotCorrespondence(
    lot: ResourceLotRef,
    place: String,
    producer: ResourceProducer,
    token_target: String,
    token_type: String,
    revision: Int,
    quantity: Int,
    provenance: String,
  )
}

pub type ValueCorrespondence {
  ValueCorrespondence(
    producer: ProducerRef,
    place: String,
    token_target: String,
    revision: Int,
  )
}

pub type NormalizedResourceBinding {
  NormalizedResourceBinding(
    transition: String,
    lot: ResourceLotRef,
    read: Int,
    consume: Int,
    required_revision: Int,
  )
}

pub type ResourceCorrespondence {
  ResourceCorrespondence(
    lots: List(ResourceLotCorrespondence),
    values: List(ValueCorrespondence),
    normalized_bindings: List(NormalizedResourceBinding),
    execution_order: List(String),
  )
}

pub type ResourceTraceCertificate {
  ResourceTraceCertificate(
    trace: BranchTrace,
    lowering: resource.SolverInput,
    correspondence: ResourceCorrespondence,
    reachability: resource.ReachabilityWitness,
    acyclicity: resource.AcyclicWitness,
    value_sources: List(#(ProducerRef, types.SlotValue(kdl.JsonValue))),
  )
}

pub type CompositionWitness {
  CompositionWitness(
    input_snapshot: CompositionInput,
    initial_membership: List(#(InputId, types.SlotValue(kdl.JsonValue))),
    resource_traces: List(ResourceTraceCertificate),
  )
}

pub type RawComposition {
  RawComposition(
    plan: CompositionPlan,
    witness: CompositionWitness,
    selection: SelectionEvidence,
  )
}

pub opaque type CheckedComposition {
  CheckedComposition(prepared: PreparedCompositionInput, raw: RawComposition)
}

pub type WitnessFailure {
  InputRevisionMismatch
  InitialMembership(input: InputId)
  ProducerMismatch(value: ValueRef)
  ProjectionMismatch(failure: validation.ProjectionFailure)
  SourceConstraintMismatch(value: ValueRef)
  InclusionMismatch(failure: InclusionFailure)
  SuppliedValueMismatch(value: ValueRef)
  ConstructionMismatch(reference: types.TypeRef)
  MissingBinding(identity: String)
  SignatureMismatch(site: SiteId)
  GuardNotDominating(value: ValueRef)
  IncompleteBranchCoverage(identity: String)
  FailureEmbeddingMismatch(embedding: FailureEmbeddingId)
  GoalMismatch
  RankViolation
  ResourceLoweringMismatch(reason: String)
  ResourceReplayMismatch(reason: String)
  ForgedClosure(reason: String)
  ForgedAcyclicity(reason: String)
  MissingEvidence(reason: String)
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

pub type ConnectionFailure {
  ConnectionFailure(
    value: Option(ValueRef),
    destination: types.SlotContract,
    counterexample: CounterexampleCertificate,
  )
}

pub type CompositionEngineFailure {
  ContractViolation(reason: String)
  ResourceFailure(failure: resource.SolverFailure)
  Witness(failure: WitnessFailure)
}

pub type LoweringFailure {
  InvalidLowering(reason: String)
  UnknownLowering(obligation: UnresolvedObligation)
}

pub opaque type CheckedReachability {
  CheckedReachability(
    input: resource.SolverInput,
    witness: resource.ReachabilityWitness,
  )
}

pub opaque type CheckedClosure {
  CheckedClosure(input: resource.SolverInput, witness: resource.ClosureWitness)
}

pub opaque type CheckedAcyclic {
  CheckedAcyclic(input: resource.SolverInput, witness: resource.AcyclicWitness)
}

pub type AvailableValue {
  AvailableValue(
    producer: ProducerRef,
    contract: types.SlotContract,
    resource: Option(ResourceLotRef),
  )
}

pub type BranchFact {
  BranchFact(
    guard: GuardId,
    inspected: ValueRef,
    arm: GuardArm,
    refinement: Option(types.SlotContract),
    assumptions: List(validation.ProjectionAssumption),
    exact: Option(types.SlotValue(kdl.JsonValue)),
  )
}

pub type SearchState {
  SearchState(
    available: List(AvailableValue),
    used_sites: List(SiteId),
    used_guards: List(GuardId),
    facts: List(BranchFact),
    trace: List(TraceStep),
    pending_failure: Option(FailureOrigin),
  )
}

pub type ChoiceSkeleton {
  InvocationChoice(
    invocation: InvocationPlan,
    outcomes: List(OutcomeId),
    empty_outcomes: List(OutcomeId),
  )
  GuardChoice(guard: GuardId, inspected: ValueRef, arms: List(GuardArm))
}

pub type MissingSupply {
  MissingSupply(
    site: Option(SiteId),
    port: String,
    contract: types.SlotContract,
  )
}

pub type TerminalAssessment {
  Feasible(certificate: ResourceTraceCertificate)
  ResourceUnreachable(
    trace: BranchTrace,
    lowering: resource.SolverInput,
    correspondence: ResourceCorrespondence,
    closure: resource.ClosureWitness,
  )
  RejectedLowering(trace: BranchTrace, reason: String)
  EmptyValues(producers: List(ProducerRef))
  TerminalUnknown(obligations: List(UnresolvedObligation))
}

pub type TerminalCoverage {
  TerminalCoverage(terminal: ReturnPlan, assessment: TerminalAssessment)
}

pub type ChoiceCoverage {
  ChoiceCoverage(choice: ChoiceSkeleton, children: List(Int))
}

pub type ClosedSearchState {
  ClosedSearchState(
    state: SearchState,
    terminals: List(TerminalCoverage),
    choices: List(ChoiceCoverage),
    rejected_connections: List(ConnectionFailure),
    missing_supply: List(MissingSupply),
  )
}

pub type CompositionClosureWitness {
  CompositionClosureWitness(
    input_snapshot: CompositionInput,
    root: Int,
    states: List(ClosedSearchState),
  )
}

pub type SelectionEvidence {
  AnyFeasibleEvidence
  Unique(closure: CompositionClosureWitness, canonical_plan: String)
}

pub type CompositionDecision {
  Solved(composition: CheckedComposition, selection: SelectionEvidence)
  Unreachable(closure: CompositionClosureWitness)
  CompositionUnknown(
    obligations: List(UnresolvedObligation),
    frontier: List(SearchState),
    rejected_connections: List(ConnectionFailure),
  )
  Ambiguous(
    candidates: List(VerifiedCompositionCandidate),
    canonical_plans: List(String),
  )
}

pub opaque type VerifiedCompositionCandidate {
  VerifiedCompositionCandidate(
    prepared: PreparedCompositionInput,
    plan: CompositionPlan,
    witness: CompositionWitness,
  )
}

pub opaque type CheckedCompositionClosure {
  CheckedCompositionClosure(
    witness: CompositionClosureWitness,
    canonical_plans: List(String),
  )
}

pub const default_resource_token_bound = 100_000

pub fn default_search_bounds() -> SearchBounds {
  SearchBounds(10_000, 100_000, 10_000, 100_000, None)
}

pub fn semantic_basis(graph: types.SemanticGraph) -> SemanticBasis {
  SemanticBasis(graph.profile, graph.source_refs)
}

pub fn prepared_graph(
  prepared: PreparedCompositionInput,
) -> types.SemanticGraph {
  prepared.graph
}

pub fn prepared_input(prepared: PreparedCompositionInput) -> CompositionInput {
  prepared.input
}

pub fn prepared_empty(
  prepared: PreparedCompositionInput,
) -> List(types.TypeRef) {
  prepared.empty
}

pub fn prepared_initial_obligations(
  prepared: PreparedCompositionInput,
) -> List(types.SemanticObligation) {
  prepared.initial_obligations
}

pub fn checked_inclusion_graph(
  checked: CheckedInclusion,
) -> types.SemanticGraph {
  checked.graph
}

pub fn checked_inclusion_certificate(
  checked: CheckedInclusion,
) -> InclusionCertificate {
  checked.certificate
}

pub fn checked_prepared(
  checked: CheckedComposition,
) -> PreparedCompositionInput {
  checked.prepared
}

pub fn checked_plan(checked: CheckedComposition) -> CompositionPlan {
  checked.raw.plan
}

pub fn checked_witness(checked: CheckedComposition) -> CompositionWitness {
  checked.raw.witness
}

pub fn checked_raw(checked: CheckedComposition) -> RawComposition {
  checked.raw
}

pub fn candidate_prepared(
  candidate: VerifiedCompositionCandidate,
) -> PreparedCompositionInput {
  candidate.prepared
}

pub fn candidate_plan(
  candidate: VerifiedCompositionCandidate,
) -> CompositionPlan {
  candidate.plan
}

pub fn candidate_witness(
  candidate: VerifiedCompositionCandidate,
) -> CompositionWitness {
  candidate.witness
}

pub fn closure_witness(
  checked: CheckedCompositionClosure,
) -> CompositionClosureWitness {
  checked.witness
}

pub fn closure_canonical_plans(
  checked: CheckedCompositionClosure,
) -> List(String) {
  checked.canonical_plans
}

pub fn goal_unreachable(checked: CheckedCompositionClosure) -> Bool {
  checked.canonical_plans == []
}

pub fn reachability_input(
  checked: CheckedReachability,
) -> resource.SolverInput {
  checked.input
}

pub fn reachability_witness(
  checked: CheckedReachability,
) -> resource.ReachabilityWitness {
  checked.witness
}

pub fn resource_closure_input(checked: CheckedClosure) -> resource.SolverInput {
  checked.input
}

pub fn resource_closure_witness(
  checked: CheckedClosure,
) -> resource.ClosureWitness {
  checked.witness
}

pub fn acyclic_input(checked: CheckedAcyclic) -> resource.SolverInput {
  checked.input
}

pub fn acyclic_witness(checked: CheckedAcyclic) -> resource.AcyclicWitness {
  checked.witness
}

fn find(values: List(a), predicate: fn(a) -> Bool) -> Option(a) {
  case list.find(values, predicate) {
    Ok(value) -> Some(value)
    Error(_) -> None
  }
}

pub fn at(values: List(a), index: Int) -> Option(a) {
  case values {
    [value, ..] if index == 0 -> Some(value)
    [_, ..rest] if index > 0 -> at(rest, index - 1)
    _ -> None
  }
}

pub fn unique(values: List(a)) -> List(a) {
  list.fold(values, [], fn(result, value) {
    case list.contains(result, value) {
      True -> result
      False -> list.append(result, [value])
    }
  })
}

fn each(values: List(a), check: fn(a) -> Result(Nil, e)) -> Result(Nil, e) {
  case values {
    [] -> Ok(Nil)
    [value, ..rest] -> {
      use _ <- result.try(check(value))
      each(rest, check)
    }
  }
}

pub fn require(condition: Bool, failure: e) -> Result(Nil, e) {
  case condition {
    True -> Ok(Nil)
    False -> Error(failure)
  }
}

fn present_contract(reference: types.TypeRef) -> types.SlotContract {
  types.SlotContract(reference, True, False)
}

fn maximum(a: Int, b: Int) -> Int {
  case a >= b {
    True -> a
    False -> b
  }
}

fn minimum(a: Int, b: Int) -> Int {
  case a <= b {
    True -> a
    False -> b
  }
}

fn max_lower(a: Option(Int), b: Option(Int)) -> Option(Int) {
  case a, b {
    Some(a), Some(b) -> Some(maximum(a, b))
    Some(a), None -> Some(a)
    None, Some(b) -> Some(b)
    _, _ -> None
  }
}

fn min_upper(a: Option(Int), b: Option(Int)) -> Option(Int) {
  case a, b {
    Some(a), Some(b) -> Some(minimum(a, b))
    Some(a), None -> Some(a)
    None, Some(b) -> Some(b)
    _, _ -> None
  }
}

fn within(value: Int, lower: Option(Int), upper: Option(Int)) -> Bool {
  option.unwrap(option.map(lower, fn(bound) { value >= bound }), True)
  && option.unwrap(option.map(upper, fn(bound) { value <= bound }), True)
}

fn contained_bounds(
  smin: Option(Int),
  smax: Option(Int),
  dmin: Option(Int),
  dmax: Option(Int),
) -> Bool {
  option.unwrap(
    option.map(dmin, fn(bound) {
      option.unwrap(option.map(smin, fn(value) { value >= bound }), False)
    }),
    True,
  )
  && option.unwrap(
    option.map(dmax, fn(bound) {
      option.unwrap(option.map(smax, fn(value) { value <= bound }), False)
    }),
    True,
  )
}

fn contradictory(lower: Option(Int), upper: Option(Int)) -> Bool {
  case lower, upper {
    Some(a), Some(b) -> a > b
    _, _ -> False
  }
}

fn integer_domain(
  profile: types.SemanticProfile,
  spec: types.IntegerSpec,
) -> Option(types.IntegerDomain) {
  let name = option.unwrap(spec.domain, profile.default_integer_domain)
  find(profile.integer_domains, fn(binding) { binding.name == name })
  |> option.map(fn(binding) { binding.range })
}

fn integer_bounds(
  profile: types.SemanticProfile,
  spec: types.IntegerSpec,
) -> #(Option(Int), Option(Int)) {
  let #(lower, upper) = case integer_domain(profile, spec) {
    Some(types.IntegerInterval(a, b)) -> #(Some(a), Some(b))
    _ -> #(None, None)
  }
  #(
    max_lower(max_lower(lower, spec.minimum), spec.const_value),
    min_upper(min_upper(upper, spec.maximum), spec.const_value),
  )
}

fn finite_integers(
  profile: types.SemanticProfile,
  spec: types.IntegerSpec,
) -> Option(List(Int)) {
  let #(lower, upper) = integer_bounds(profile, spec)
  let values = case spec.const_value {
    Some(value) -> Some([value])
    None -> spec.enum_values
  }
  option.map(values, fn(values) {
    list.filter(values, fn(value) { within(value, lower, upper) })
  })
}

fn finite_strings(
  graph: types.SemanticGraph,
  reference: types.TypeRef,
  spec: types.StringSpec,
) -> Option(List(String)) {
  let values = case spec.const_value {
    Some(value) -> Some([value])
    None -> spec.enum_values
  }
  case values {
    None -> None
    Some(values) ->
      case
        list.any(values, fn(value) {
          case
            validation.declared_value_decision(
              graph,
              reference,
              kdl.JsonValueStr(value),
            )
          {
            types.UnresolvedValue(_) -> True
            _ -> False
          }
        })
      {
        True -> None
        False ->
          Some(
            list.filter(values, fn(value) {
              validation.declared_value_decision(
                graph,
                reference,
                kdl.JsonValueStr(value),
              )
              == types.AcceptedValue
            }),
          )
      }
  }
}

pub fn resolved_shape(
  graph: types.SemanticGraph,
  reference: types.TypeRef,
) -> Option(types.TypeShape) {
  resolve_shape(graph, reference, [])
}

fn resolve_shape(
  graph: types.SemanticGraph,
  reference: types.TypeRef,
  seen: List(types.TypeRef),
) -> Option(types.TypeShape) {
  case list.contains(seen, reference) {
    True -> None
    False ->
      case find(graph.nodes, fn(node) { node.reference == reference }) {
        None -> None
        Some(node) ->
          case node.shape {
            types.AliasShape(target, _) ->
              resolve_shape(graph, target, [reference, ..seen])
            shape -> Some(shape)
          }
      }
  }
}

fn locally_empty(
  graph: types.SemanticGraph,
  node: types.TypeNode,
  empty: List(types.TypeRef),
) -> Bool {
  case node.shape {
    types.AliasShape(target, _) -> list.contains(empty, target)
    types.IntegerShape(spec) -> {
      let #(lower, upper) = integer_bounds(graph.profile, spec)
      case finite_integers(graph.profile, spec) {
        Some(values) -> values == []
        None -> contradictory(lower, upper)
      }
    }
    types.StringShape(spec) ->
      case finite_strings(graph, node.reference, spec) {
        Some(values) -> values == []
        None ->
          list.any(spec.lengths, fn(bound) {
            contradictory(bound.minimum, bound.maximum)
          })
      }
    types.BytesShape(spec) -> contradictory(spec.minimum, spec.maximum)
    types.ProductShape(spec) ->
      list.any(spec.fields, fn(field) {
        field.slot.required
        && !field.slot.nullable
        && list.contains(empty, field.slot.type_ref)
      })
    types.ArrayShape(spec) ->
      contradictory(spec.min_length, spec.max_length)
      || option.unwrap(spec.min_length, 0) > 0
      && !spec.item.nullable
      && list.contains(empty, spec.item.type_ref)
    types.TaggedUnionShape(spec) ->
      list.all(spec.branches, fn(branch) { list.contains(empty, branch.target) })
    types.Never -> True
    _ -> False
  }
}

fn empty_types(graph: types.SemanticGraph) -> List(types.TypeRef) {
  empty_fixed_point(graph, list.map(graph.nodes, fn(node) { node.reference }))
}

fn empty_fixed_point(
  graph: types.SemanticGraph,
  empty: List(types.TypeRef),
) -> List(types.TypeRef) {
  let next =
    list.filter(empty, fn(reference) {
      case find(graph.nodes, fn(node) { node.reference == reference }) {
        Some(node) -> locally_empty(graph, node, empty)
        None -> False
      }
    })
  case next == empty {
    True -> empty
    False -> empty_fixed_point(graph, next)
  }
}

fn verify_empty_types(
  graph: types.SemanticGraph,
  empty: List(types.TypeRef),
) -> Bool {
  unique(empty) == empty
  && list.all(empty, fn(reference) {
    case find(graph.nodes, fn(node) { node.reference == reference }) {
      Some(node) -> locally_empty(graph, node, empty)
      None -> False
    }
  })
}

pub fn slot_empty(
  contract: types.SlotContract,
  empty: List(types.TypeRef),
) -> Bool {
  contract.required
  && !contract.nullable
  && list.contains(empty, contract.type_ref)
}

fn pair_child(
  source: types.TypeRef,
  destination: types.TypeRef,
  tag: Option(String),
) -> TypePair {
  TypePair(present_contract(source), present_contract(destination), tag)
}

fn element_slot(
  graph: types.SemanticGraph,
  contract: types.ElementContract,
) -> types.SlotContract {
  types.SlotContract(
    contract.type_ref,
    False,
    validation.element_allows_null(graph, contract),
  )
}

fn element_pair(
  graph: types.SemanticGraph,
  source: types.ElementContract,
  destination: types.ElementContract,
) -> TypePair {
  TypePair(element_slot(graph, source), element_slot(graph, destination), None)
}

fn type_obligation(
  pair: TypePair,
  reason: TypeObligationReason,
) -> TypeObligation {
  TypeObligation(pair, [], reason)
}

fn format_rule(
  graph: types.SemanticGraph,
  format_use: types.FormatUse,
) -> Option(types.FormatRule) {
  case format_use {
    types.InlineFormat(rule) -> Some(rule)
    types.NamedFormat(name) ->
      find(graph.profile.format_bindings, fn(binding) { binding.name == name })
      |> option.map(fn(binding) { binding.rule })
  }
}

fn format_rule_included(
  source: types.FormatRule,
  destination: types.FormatRule,
) -> Bool {
  source == destination
  || destination == types.Text
  || case destination {
    types.Choice(rules) ->
      list.any(rules, fn(rule) { format_rule_included(source, rule) })
    _ -> False
  }
}

fn format_included(
  graph: types.SemanticGraph,
  source: Option(types.FormatUse),
  destination: Option(types.FormatUse),
) -> Bool {
  case destination {
    None -> True
    Some(destination) ->
      case
        option.then(source, fn(format_use) { format_rule(graph, format_use) }),
        format_rule(graph, destination)
      {
        Some(source), Some(destination) ->
          format_rule_included(source, destination)
        _, _ -> False
      }
  }
}

pub fn collect(
  values: List(a),
  action: fn(a) -> Result(b, e),
) -> Result(List(b), e) {
  case values {
    [] -> Ok([])
    [value, ..rest] -> {
      use value <- result.try(action(value))
      use rest <- result.try(collect(rest, action))
      Ok([value, ..rest])
    }
  }
}

fn local_inclusion(
  graph: types.SemanticGraph,
  pair: TypePair,
  empty: List(types.TypeRef),
) -> Result(#(InclusionRule, List(TypePair)), TypeObligation) {
  use _ <- result.try(require(
    !{
      !pair.source.required
      && pair.destination.required
      || pair.source.nullable
      && !pair.destination.nullable
    },
    type_obligation(pair, TypePresence),
  ))
  case
    find(graph.nodes, fn(node) { node.reference == pair.source.type_ref }),
    find(graph.nodes, fn(node) { node.reference == pair.destination.type_ref })
  {
    Some(source), Some(destination) ->
      case
        list.contains(empty, source.reference),
        list.contains(empty, destination.reference)
      {
        True, _ -> Ok(#(EmptySource, []))
        False, True -> Error(type_obligation(pair, ConstraintImplication))
        False, False ->
          shape_inclusion(graph, pair, source.shape, destination.shape, empty)
      }
    _, _ -> Error(type_obligation(pair, ConstraintImplication))
  }
}

fn scalar_rule(
  pair: TypePair,
  condition: Bool,
  rule: InclusionRule,
) -> Result(#(InclusionRule, List(TypePair)), TypeObligation) {
  case condition {
    True -> Ok(#(rule, []))
    False -> Error(type_obligation(pair, ConstraintImplication))
  }
}

fn length_bound(
  spec: types.StringSpec,
  unit: types.StringLengthUnit,
) -> types.LengthBound {
  option.unwrap(
    find(spec.lengths, fn(bound) { bound.unit == unit }),
    types.LengthBound(unit, None, None),
  )
}

fn shape_inclusion(
  graph: types.SemanticGraph,
  pair: TypePair,
  source: types.TypeShape,
  destination: types.TypeShape,
  empty: List(types.TypeRef),
) -> Result(#(InclusionRule, List(TypePair)), TypeObligation) {
  case source, destination {
    types.AliasShape(target, _), _ ->
      Ok(#(UnfoldSource, [pair_child(target, pair.destination.type_ref, None)]))
    _, types.AliasShape(target, _) ->
      Ok(#(UnfoldDestination, [pair_child(pair.source.type_ref, target, None)]))
    _, types.UnknownShape(types.AnyValue) -> Ok(#(JsonDomain, []))
    types.UnknownShape(types.OrdinaryObject),
      types.UnknownShape(types.OrdinaryObject)
    -> Ok(#(PlainObjectDomain, []))
    types.BooleanShape(s), types.BooleanShape(d) ->
      scalar_rule(
        pair,
        d.const_value == None || s.const_value == d.const_value,
        InclusionBoolean,
      )
    types.IntegerShape(s), types.IntegerShape(d) -> {
      let #(smin, smax) = integer_bounds(graph.profile, s)
      let #(dmin, dmax) = integer_bounds(graph.profile, d)
      let allowed = case finite_integers(graph.profile, s) {
        Some(values) ->
          list.all(values, fn(value) {
            within(value, dmin, dmax)
            && option.unwrap(
              option.map(d.enum_values, fn(values) {
                list.contains(values, value)
              }),
              True,
            )
          })
        None -> contained_bounds(smin, smax, dmin, dmax)
      }
      scalar_rule(pair, allowed, IntegerIntersection)
    }
    types.StringShape(s), types.StringShape(d) ->
      case finite_strings(graph, pair.source.type_ref, s) {
        Some(values) ->
          scalar_rule(
            pair,
            list.all(values, fn(value) {
              validation.declared_value_decision(
                graph,
                pair.destination.type_ref,
                kdl.JsonValueStr(value),
              )
              == types.AcceptedValue
            }),
            FiniteStrings,
          )
        None -> {
          let units = [types.Utf8Bytes, types.UnicodeScalars, types.Graphemes]
          let lengths =
            list.all(units, fn(unit) {
              let sb = length_bound(s, unit)
              let db = length_bound(d, unit)
              contained_bounds(sb.minimum, sb.maximum, db.minimum, db.maximum)
            })
          scalar_rule(
            pair,
            d.const_value == None
              && d.enum_values == None
              && d.wrapper == s.wrapper
              && format_included(graph, s.format, d.format)
              && lengths,
            StringConditions,
          )
        }
      }
    types.BytesShape(s), types.BytesShape(d) ->
      scalar_rule(
        pair,
        contained_bounds(s.minimum, s.maximum, d.minimum, d.maximum),
        BytesLength,
      )
    types.RawBodyShape(s), types.RawBodyShape(d) ->
      scalar_rule(pair, s == d, BytesLength)
    types.UnitShape, types.UnitShape -> Ok(#(InclusionUnit, []))
    types.Never, _ -> Ok(#(EmptySource, []))
    types.ArrayShape(s), types.ArrayShape(d) -> {
      let smax = case
        !s.item.nullable && list.contains(empty, s.item.type_ref)
      {
        True -> Some(0)
        False -> s.max_length
      }
      let dmax = case
        !d.item.nullable && list.contains(empty, d.item.type_ref)
      {
        True -> Some(0)
        False -> d.max_length
      }
      use _ <- result.try(require(
        contained_bounds(s.min_length, smax, d.min_length, dmax),
        type_obligation(pair, ConstraintImplication),
      ))
      Ok(
        #(InclusionArray, case smax {
          Some(0) -> []
          _ -> [element_pair(graph, s.item, d.item)]
        }),
      )
    }
    types.ProductShape(s), types.ProductShape(d) ->
      product_inclusion(graph, pair, s, d)
    types.TaggedUnionShape(s), types.TaggedUnionShape(d) -> {
      use children <- result.try(
        collect(s.branches, fn(source) {
          case
            find(d.branches, fn(destination) {
              destination.wire_tag == source.wire_tag
              && destination.selector == source.selector
            })
          {
            Some(destination) ->
              Ok(pair_child(source.target, destination.target, None))
            None -> Error(type_obligation(pair, UnionRemainder))
          }
        }),
      )
      Ok(#(SourceUnion, children))
    }
    types.TaggedUnionShape(s), _ ->
      Ok(#(
        SourceUnion,
        list.map(s.branches, fn(branch) {
          pair_child(branch.target, pair.destination.type_ref, None)
        }),
      ))
    _, types.TaggedUnionShape(d) ->
      case
        find(d.branches, fn(branch) {
          resolved_shape(graph, pair.source.type_ref)
          |> option.map(fn(shape) {
            case branch.selector {
              types.Kind(kind) -> shape_kind(shape) == Some(kind)
              types.Otherwise -> True
              _ -> False
            }
          })
          |> option.unwrap(False)
        })
      {
        Some(branch) ->
          Ok(
            #(DestinationUnion, [
              pair_child(pair.source.type_ref, branch.target, None),
            ]),
          )
        None -> Error(type_obligation(pair, UnionRemainder))
      }
    types.SealedShape(stag, s), types.SealedShape(dtag, d) ->
      scalar_rule(pair, stag == dtag && s == d, StringConditions)
    _, _ -> Error(type_obligation(pair, ConstraintImplication))
  }
}

fn shape_kind(shape: types.TypeShape) -> Option(types.ValueKind) {
  case shape {
    types.BooleanShape(_) -> Some(types.BooleanKind)
    types.IntegerShape(_) | types.DecimalShape(_) -> Some(types.NumberKind)
    types.StringShape(_) | types.BytesShape(_) | types.RawBodyShape(_) ->
      Some(types.StringKind)
    types.ArrayShape(_) -> Some(types.ArrayKind)
    types.ProductShape(_) | types.SealedShape(_, _) -> Some(types.ObjectKind)
    types.UnitShape -> Some(types.NullKind)
    _ -> None
  }
}

fn product_inclusion(
  graph: types.SemanticGraph,
  pair: TypePair,
  source: types.ProductSpec,
  destination: types.ProductSpec,
) -> Result(#(InclusionRule, List(TypePair)), TypeObligation) {
  let tag_key = option.map(graph.profile.tag, fn(tag) { tag.key })
  use destination_children <- result.try(
    collect(destination.fields, fn(field) {
      case
        find(source.fields, fn(candidate) {
          candidate.wire_name == field.wire_name
        })
      {
        Some(source_field) ->
          Ok([TypePair(source_field.slot, field.slot, None)])
        None -> {
          use _ <- result.try(require(
            !field.slot.required && Some(field.wire_name) != tag_key,
            type_obligation(pair, ExtraField(field.wire_name)),
          ))
          case source.extras {
            types.RejectExtras ->
              Error(type_obligation(pair, ExtraField(field.wire_name)))
            types.AllowExtras(_, contract) ->
              Ok([
                TypePair(element_slot(graph, contract), field.slot, None),
              ])
          }
        }
      }
    }),
  )
  use source_children <- result.try(
    collect(source.fields, fn(field) {
      case
        find(destination.fields, fn(candidate) {
          candidate.wire_name == field.wire_name
        })
      {
        Some(_) -> Ok([])
        None ->
          case Some(field.wire_name) == tag_key {
            True -> Ok([])
            False ->
              case destination.extras {
                types.RejectExtras ->
                  Error(type_obligation(pair, ExtraField(field.wire_name)))
                types.AllowExtras(key_format, contract) -> {
                  use _ <- result.try(require(
                    format_included(
                      graph,
                      Some(types.InlineFormat(types.Literal(field.wire_name))),
                      key_format,
                    ),
                    type_obligation(pair, ExtraField(field.wire_name)),
                  ))
                  Ok([
                    TypePair(field.slot, element_slot(graph, contract), None),
                  ])
                }
              }
          }
      }
    }),
  )
  use extra_children <- result.try(case source.extras, destination.extras {
    types.RejectExtras, _ -> Ok([])
    types.AllowExtras(_, _), types.RejectExtras ->
      Error(type_obligation(pair, ExtraField("*")))
    types.AllowExtras(source_key, source_contract),
      types.AllowExtras(destination_key, destination_contract)
    -> {
      use _ <- result.try(require(
        format_included(graph, source_key, destination_key),
        type_obligation(pair, ExtraField("*")),
      ))
      Ok([element_pair(graph, source_contract, destination_contract)])
    }
  })
  Ok(#(
    InclusionProduct,
    list.append(
      list.flatten(destination_children),
      list.append(list.flatten(source_children), extra_children),
    ),
  ))
}

pub fn verify_inclusion(
  graph: types.SemanticGraph,
  source: types.SlotContract,
  destination: types.SlotContract,
  certificate: InclusionCertificate,
) -> Result(CheckedInclusion, InclusionFailure) {
  use _ <- result.try(require(
    certificate.basis == semantic_basis(graph),
    InclusionBasisMismatch,
  ))
  use _ <- result.try(require(
    certificate.source == source && certificate.destination == destination,
    ContractMismatch,
  ))
  let meaning =
    validation.meaning_obligations(graph, [
      source.type_ref,
      destination.type_ref,
    ])
  use _ <- result.try(case meaning {
    [] -> Ok(Nil)
    obligations -> Error(UndefinedMeaning(obligations))
  })
  use _ <- result.try(require(
    verify_empty_types(graph, certificate.empty_types),
    ForgedEmptiness,
  ))
  use _ <- result.try(require(
    option.map(at(certificate.pairs, certificate.root), fn(entry) { entry.pair })
      == Some(TypePair(source, destination, None)),
    MissingPair,
  ))
  use visited <- result.try(
    verify_pair_table(graph, certificate, [certificate.root], []),
  )
  use _ <- result.try(require(
    list.length(visited) == list.length(certificate.pairs),
    ChildCoverage(certificate.root),
  ))
  Ok(CheckedInclusion(graph, certificate))
}

fn remove_once(values: List(a), value: a) -> Option(List(a)) {
  case values {
    [] -> None
    [first, ..rest] ->
      case first == value {
        True -> Some(rest)
        False ->
          option.map(remove_once(rest, value), fn(rest) { [first, ..rest] })
      }
  }
}

fn same_multiset(a: List(a), b: List(a)) -> Bool {
  case a {
    [] -> b == []
    [first, ..rest] ->
      case remove_once(b, first) {
        None -> False
        Some(b) -> same_multiset(rest, b)
      }
  }
}

fn verify_pair_table(
  graph: types.SemanticGraph,
  certificate: InclusionCertificate,
  pending: List(Int),
  visited: List(Int),
) -> Result(List(Int), InclusionFailure) {
  case pending {
    [] -> Ok(visited)
    [index, ..rest] ->
      case list.contains(visited, index) {
        True -> verify_pair_table(graph, certificate, rest, visited)
        False ->
          case at(certificate.pairs, index) {
            None -> Error(MissingPair)
            Some(entry) -> {
              use _ <- result.try(require(
                option.map(
                  find(graph.nodes, fn(node) {
                    node.reference == entry.pair.source.type_ref
                  }),
                  fn(node) { node.shape },
                )
                  == Some(entry.source_shape)
                  && option.map(
                  find(graph.nodes, fn(node) {
                    node.reference == entry.pair.destination.type_ref
                  }),
                  fn(node) { node.shape },
                )
                  == Some(entry.destination_shape),
                PairMismatch(index),
              ))
              use local <- result.try(result.map_error(
                local_inclusion(graph, entry.pair, certificate.empty_types),
                InclusionUnresolved,
              ))
              let #(rule, children) = local
              use _ <- result.try(require(
                rule == entry.rule,
                RuleMismatch(index),
              ))
              let supplied =
                list.map(entry.children, fn(child) {
                  option.map(at(certificate.pairs, child), fn(entry) {
                    entry.pair
                  })
                })
              use _ <- result.try(require(
                same_multiset(list.map(children, Some), supplied),
                ChildCoverage(index),
              ))
              verify_pair_table(
                graph,
                certificate,
                list.append(entry.children, rest),
                [index, ..visited],
              )
            }
          }
      }
  }
}

pub fn verify_counterexample(
  graph: types.SemanticGraph,
  certificate: CounterexampleCertificate,
) -> Result(Nil, InclusionFailure) {
  use _ <- result.try(require(
    certificate.basis == semantic_basis(graph),
    InclusionBasisMismatch,
  ))
  use _ <- result.try(require(
    validation.accepts_slot(graph, certificate.source, certificate.value),
    CounterexampleMismatch,
  ))
  case
    validation.validate_slot(graph, certificate.destination, certificate.value)
  {
    Error(validation.Rejected(failure))
      if failure == certificate.destination_failure
    -> Ok(Nil)
    _ -> Error(CounterexampleMismatch)
  }
}

pub fn check_assignable(
  graph: types.SemanticGraph,
  source: types.SlotContract,
  destination: types.SlotContract,
  max_obligations: Int,
) -> CompatibilityDecision {
  let root = TypePair(source, destination, None)
  case
    validation.meaning_obligations(graph, [
      source.type_ref,
      destination.type_ref,
    ])
  {
    [first, ..rest] ->
      CompatibilityUnknown([type_obligation(root, TypeMeaning([first, ..rest]))])
    [] -> {
      let empty = empty_types(graph)
      case build_pair_table(graph, empty, [root], [], 0, max_obligations) {
        Ok(entries) ->
          Compatible(InclusionCertificate(
            semantic_basis(graph),
            source,
            destination,
            0,
            empty,
            entries,
          ))
        Error(obligation) ->
          case
            source_counterexample(graph, source, destination, max_obligations)
          {
            Some(certificate) -> Incompatible(certificate)
            None -> CompatibilityUnknown([obligation])
          }
      }
    }
  }
}

fn build_pair_table(
  graph: types.SemanticGraph,
  empty: List(types.TypeRef),
  pairs: List(TypePair),
  entries: List(PairEntry),
  position: Int,
  limit: Int,
) -> Result(List(PairEntry), TypeObligation) {
  case at(pairs, position) {
    None -> Ok(entries)
    Some(pair) -> {
      use _ <- result.try(require(
        position < limit,
        type_obligation(pair, ObligationBoundExhausted),
      ))
      use local <- result.try(local_inclusion(graph, pair, empty))
      let #(rule, children) = local
      case
        find(graph.nodes, fn(node) { node.reference == pair.source.type_ref }),
        find(graph.nodes, fn(node) {
          node.reference == pair.destination.type_ref
        })
      {
        Some(source), Some(destination) -> {
          let pairs = unique(list.append(pairs, children))
          let indices =
            filter_options(children, fn(child) { index_of(pairs, child, 0) })
          let entry =
            PairEntry(pair, source.shape, destination.shape, rule, indices)
          build_pair_table(
            graph,
            empty,
            pairs,
            list.append(entries, [entry]),
            position + 1,
            limit,
          )
        }
        _, _ -> Error(type_obligation(pair, ConstraintImplication))
      }
    }
  }
}

pub fn index_of(values: List(a), value: a, index: Int) -> Option(Int) {
  case values {
    [] -> None
    [first, ..rest] ->
      case first == value {
        True -> Some(index)
        False -> index_of(rest, value, index + 1)
      }
  }
}

fn codepoint_string(value: Int) -> Option(String) {
  case string.utf_codepoint(value) {
    Ok(codepoint) -> Some(string.from_utf_codepoints([codepoint]))
    Error(_) -> None
  }
}

fn dfa_shortest_word(
  spec: types.DfaSpec,
  fuel: Int,
  frontier: List(#(Int, String)),
  visited: List(Int),
) -> Option(String) {
  case fuel <= 0 {
    True -> None
    False ->
      case
        list.find(frontier, fn(entry) {
          list.contains(spec.accepting_states, entry.0)
        })
      {
        Ok(#(_, path)) -> Some(path)
        Error(_) -> {
          let reached =
            list.flat_map(frontier, fn(entry) {
              let #(state, path) = entry
              spec.transitions
              |> list.filter(fn(transition) { transition.from_state == state })
              |> list.map(fn(transition) {
                #(
                  transition.to_state,
                  path
                    <> option.unwrap(
                    codepoint_string(transition.first),
                    "\u{0}",
                  ),
                )
              })
            })
          let fresh =
            list.fold(reached, [], fn(kept, entry) {
              case
                list.contains(visited, entry.0)
                || list.any(kept, fn(known: #(Int, String)) {
                  known.0 == entry.0
                })
              {
                True -> kept
                False -> list.append(kept, [entry])
              }
            })
          dfa_shortest_word(
            spec,
            fuel - 1,
            fresh,
            list.append(visited, list.map(fresh, fn(entry) { entry.0 })),
          )
        }
      }
  }
}

fn identifier_samples(
  rule: types.FormatRule,
  first: String,
  rest: String,
  exact: Option(Int),
  min_length: Int,
  forbidden: List(String),
) -> List(String) {
  let lengths = case exact {
    Some(length) -> [length]
    None ->
      list.map(
        int.range(0, list.length(forbidden) + 1, [], fn(all, extra) {
          [extra, ..all]
        })
          |> list.reverse,
        fn(extra) { maximum(min_length, 1) + extra },
      )
  }
  let candidates =
    list.flat_map(lengths, fn(length) {
      list.flat_map(string.to_graphemes(first), fn(head) {
        case length == 1 {
          True -> [head]
          False ->
            list.map(string.to_graphemes(rest), fn(tail) {
              head <> string.repeat(tail, maximum(length - 1, 0))
            })
        }
      })
    })
  case list.find(candidates, fn(text) { validation.recognizes(rule, text) }) {
    Ok(text) -> [text]
    Error(_) -> []
  }
}

fn sequence_samples(limit: Int, parts: List(List(String))) -> List(String) {
  let heads = list.map(parts, list.first)
  case list.all(heads, result.is_ok) {
    False -> []
    True -> {
      let heads = result.values(heads)
      let varied =
        list.flat_map(
          list.index_map(parts, fn(samples, index) { #(samples, index) }),
          fn(entry) {
            let #(samples, index) = entry
            list.map(list.drop(samples, 1), fn(sample) {
              string.join(replace_at(heads, index, sample), "")
            })
          },
        )
      list.take([string.join(heads, ""), ..varied], limit)
    }
  }
}

fn format_samples(rule: types.FormatRule, limit: Int) -> List(String) {
  let inner = fn(part) { format_samples(part, limit) }
  let candidates = case rule {
    types.Literal(value) -> [value]
    types.Sequence(parts) -> sequence_samples(limit, list.map(parts, inner))
    types.Optional(part) -> ["", ..inner(part)]
    types.Choice(rules) -> list.flat_map(rules, inner)
    types.Labels(separator, minimum, _, _, part) ->
      list.map(inner(part), fn(sample) {
        string.join(list.repeat(sample, maximum(minimum, 1)), separator)
      })
    types.Bounded(_, _, part) -> inner(part)
    types.AsciiDfa(spec) ->
      case
        dfa_shortest_word(
          spec,
          spec.state_count + 1,
          [#(spec.initial_state, "")],
          [spec.initial_state],
        )
      {
        Some(word) -> [word]
        None -> []
      }
    types.Identifier(first, rest, exact, min_length, _, forbidden) ->
      identifier_samples(rule, first, rest, exact, min_length, forbidden)
    types.Timestamp(calendar) -> [
      string.pad_start(int.to_string(calendar.minimum_year), 4, "0")
      <> "-01-01T00:00:00Z",
    ]
    types.AbsoluteUri(_) ->
      case
        list.find(["a:", "a:b"], fn(text) { validation.recognizes(rule, text) })
      {
        Ok(text) -> [text]
        Error(_) -> []
      }
    types.LanguageTag(_) -> ["aa"]
    types.Text -> ["", "a"]
    types.Not(_) -> ["", "a", "0"]
  }
  list.take(
    list.filter(candidates, fn(text) { validation.recognizes(rule, text) }),
    limit,
  )
}

fn filter_options(values: List(a), action: fn(a) -> Option(b)) -> List(b) {
  list.filter_map(values, fn(value) { option.to_result(action(value), Nil) })
}

fn optional_values(values: List(Option(a))) -> List(a) {
  filter_options(values, fn(value) { value })
}

pub type SampleObligation {
  SampleBound
}

pub type SampleResult(a) {
  SampleResult(values: List(a), obligations: List(SampleObligation))
}

fn sample_measure(value: kdl.JsonValue) -> Int {
  case value {
    kdl.JsonValueNull | kdl.JsonValueBool(_) | kdl.JsonValueNum(_) -> 1
    kdl.JsonValueDec(text) | kdl.JsonValueStr(text) -> string.length(text)
    kdl.JsonValueArr(items) -> list.length(items)
    kdl.JsonValueObj(members) -> list.length(members)
  }
}

pub fn sample_value_fuel(
  graph: types.SemanticGraph,
  reference: types.TypeRef,
  active: List(types.TypeRef),
  fuel: Int,
  max_sample_length: Int,
) -> SampleResult(kdl.JsonValue) {
  let values = sample_values(graph, reference, active, fuel, 10_000)
  let #(values, bounded) =
    list.fold(values, #([], False), fn(state, value) {
      case sample_measure(value) <= max_sample_length {
        True -> #([value, ..state.0], state.1)
        False -> #(state.0, True)
      }
    })
  SampleResult(list.reverse(values), case bounded {
    True -> [SampleBound]
    False -> []
  })
}

pub fn samples(
  graph: types.SemanticGraph,
  reference: types.TypeRef,
  active: List(types.TypeRef),
  limit: Int,
) -> List(kdl.JsonValue) {
  sample_values(
    graph,
    reference,
    active,
    int.min(limit, list.length(graph.nodes) + 1),
    limit,
  )
}

fn sample_values(
  graph: types.SemanticGraph,
  reference: types.TypeRef,
  active: List(types.TypeRef),
  fuel: Int,
  limit: Int,
) -> List(kdl.JsonValue) {
  case fuel <= 0 || list.contains(active, reference) {
    True -> []
    False ->
      case find(graph.nodes, fn(node) { node.reference == reference }) {
        None -> []
        Some(node) -> {
          let values =
            shape_samples(
              graph,
              reference,
              node.shape,
              [reference, ..active],
              fuel,
              limit,
            )
          list.filter(values, fn(value) {
            validation.accepts_value(graph, reference, value)
          })
        }
      }
  }
}

fn shape_samples(
  graph: types.SemanticGraph,
  _reference: types.TypeRef,
  shape: types.TypeShape,
  active: List(types.TypeRef),
  fuel: Int,
  limit: Int,
) -> List(kdl.JsonValue) {
  case shape {
    types.BooleanShape(spec) ->
      case spec.const_value {
        Some(value) -> [kdl.JsonValueBool(value)]
        None -> [kdl.JsonValueBool(False), kdl.JsonValueBool(True)]
      }
    types.IntegerShape(spec) -> {
      let domain = case integer_domain(graph.profile, spec) {
        Some(types.IntegerInterval(minimum, maximum)) -> [minimum, maximum]
        _ -> []
      }
      list.map(
        list.flatten([
          optional_values([spec.const_value]),
          option.unwrap(spec.enum_values, []),
          optional_values([spec.minimum, spec.maximum]),
          domain,
          [0, 1, -1],
        ]),
        kdl.JsonValueNum,
      )
    }
    types.DecimalShape(_) -> [kdl.JsonValueDec("0"), kdl.JsonValueDec("1")]
    types.StringShape(spec) -> {
      let formats =
        option.unwrap(
          option.map(
            option.then(spec.format, fn(format_use) {
              format_rule(graph, format_use)
            }),
            fn(rule) { format_samples(rule, fuel) },
          ),
          [],
        )
      let counts =
        list.flat_map(spec.lengths, fn(bound) {
          optional_values([bound.minimum, bound.maximum])
        })
      let values =
        list.flatten([
          optional_values([spec.const_value]),
          option.unwrap(spec.enum_values, []),
          spec.examples,
          formats,
          ["", "a"],
          list.map(list.filter(counts, fn(count) { count >= 0 }), fn(count) {
            string.repeat("a", count)
          }),
        ])
      list.map(values, fn(text) {
        string_value(graph.profile, spec.wrapper, text)
      })
    }
    types.BytesShape(spec) -> {
      let counts =
        list.append(optional_values([spec.minimum, spec.maximum]), [0, 1])
      list.map(counts, fn(count) { bytes_value(graph.profile, count) })
    }
    types.RawBodyShape(_) -> [
      bytes_value(graph.profile, 0),
      bytes_value(graph.profile, 1),
    ]
    types.AliasShape(source, _) ->
      sample_values(graph, source, active, fuel - 1, limit)
    types.ProductShape(spec) ->
      product_samples(graph, spec, active, fuel, limit)
    types.ArrayShape(spec) -> {
      let items = element_samples(graph, spec.item, active, fuel - 1, limit)
      let counts =
        list.append(optional_values([spec.min_length, spec.max_length]), [0, 1])
      list.flat_map(counts, fn(count) {
        case count {
          0 -> [kdl.JsonValueArr([])]
          _ ->
            list.map(items, fn(item) {
              kdl.JsonValueArr(list.repeat(item, count))
            })
        }
      })
    }
    types.TaggedUnionShape(spec) ->
      list.flat_map(spec.branches, fn(branch) {
        list.filter_map(
          sample_values(graph, branch.target, active, fuel - 1, limit),
          fn(value) {
            option.to_result(
              select_branch_sample(graph.profile, branch, value),
              Nil,
            )
          },
        )
      })
    types.SealedShape(tag, refinements) ->
      sealed_samples(graph.profile, tag, refinements)
    types.Never -> []
    types.UnknownShape(_) -> [
      kdl.JsonValueObj([]),
      kdl.JsonValueNull,
      kdl.JsonValueBool(False),
      kdl.JsonValueNum(0),
      kdl.JsonValueStr(""),
      kdl.JsonValueArr([]),
    ]
    types.UnitShape -> [kdl.JsonValueNull]
    types.OpaqueShape(_) -> []
  }
}

fn wrap_text(
  profile: types.SemanticProfile,
  wrapper: String,
  text: String,
) -> kdl.JsonValue {
  case find(profile.wrappers, fn(item) { item.name == wrapper }) {
    Some(item) -> kdl.JsonValueObj([#(item.key, kdl.JsonValueStr(text))])
    None -> kdl.JsonValueStr(text)
  }
}

fn string_value(
  profile: types.SemanticProfile,
  wrapper: Option(String),
  text: String,
) -> kdl.JsonValue {
  case wrapper {
    Some(name) -> wrap_text(profile, name, text)
    None -> kdl.JsonValueStr(text)
  }
}

fn bytes_value(profile: types.SemanticProfile, count: Int) -> kdl.JsonValue {
  let text = case count {
    0 -> ""
    _ -> "AA=="
  }
  case profile.bytes_policy {
    Some(policy) ->
      case policy.wrapper {
        Some(name) -> wrap_text(profile, name, text)
        None -> kdl.JsonValueStr(text)
      }
    None -> kdl.JsonValueStr(text)
  }
}

fn select_branch_sample(
  profile: types.SemanticProfile,
  branch: types.UnionBranch,
  value: kdl.JsonValue,
) -> Option(kdl.JsonValue) {
  case branch.selector {
    types.InternalTag ->
      case profile.tag, value {
        Some(model), kdl.JsonValueObj(members) ->
          Some(
            kdl.JsonValueObj(put_member(
              members,
              model.key,
              kdl.JsonValueStr(branch.wire_tag),
            )),
          )
        _, _ -> None
      }
    types.MemberShape(tests) ->
      case value {
        kdl.JsonValueObj(members) ->
          Some(
            kdl.JsonValueObj(
              list.fold(tests, members, fn(current, member_test) {
                case member_test.1 {
                  types.AbsentMember ->
                    list.filter(current, fn(member) {
                      member.0 != member_test.0
                    })
                  types.FormatMember(_) ->
                    put_member(current, member_test.0, kdl.JsonValueStr("a"))
                }
              }),
            ),
          )
        _ -> None
      }
    types.Kind(_) | types.Otherwise -> Some(value)
  }
}

fn sealed_samples(
  profile: types.SemanticProfile,
  tag: String,
  refinements: List(types.SealedRefinement),
) -> List(kdl.JsonValue) {
  case
    profile.tag,
    find(
      option.unwrap(option.map(profile.tag, fn(model) { model.sealed }), []),
      fn(form) { form.tag == tag },
    )
  {
    Some(model), Some(form) -> {
      let members =
        list.fold(
          form.fields,
          [#(model.key, kdl.JsonValueStr(tag))],
          fn(items, field) {
            let leaf =
              option.unwrap(
                option.map(
                  find(refinements, fn(item) { item.key == field.key }),
                  fn(item) { item.leaf },
                ),
                field.leaf,
              )
            let value = case leaf {
              types.SealedString(_) -> kdl.JsonValueStr("")
              types.SealedInteger(_) -> kdl.JsonValueNum(0)
            }
            case field.required {
              True -> [#(field.key, value), ..items]
              False -> items
            }
          },
        )
      [kdl.JsonValueObj(members)]
    }
    _, _ -> []
  }
}

fn put_member(
  members: List(#(String, kdl.JsonValue)),
  name: String,
  value: kdl.JsonValue,
) -> List(#(String, kdl.JsonValue)) {
  case list.any(members, fn(member) { member.0 == name }) {
    True ->
      list.map(members, fn(member) {
        case member.0 == name {
          True -> #(name, value)
          False -> member
        }
      })
    False -> list.append(members, [#(name, value)])
  }
}

pub fn add_discriminator(
  tag_model: Option(types.TagModel),
  value: kdl.JsonValue,
  tag: String,
) -> Option(kdl.JsonValue) {
  case value, tag_model {
    kdl.JsonValueObj(members), Some(model) ->
      Some(
        kdl.JsonValueObj(put_member(members, model.key, kdl.JsonValueStr(tag))),
      )
    _, _ -> None
  }
}

fn element_samples(
  graph: types.SemanticGraph,
  contract: types.ElementContract,
  active: List(types.TypeRef),
  fuel: Int,
  limit: Int,
) -> List(kdl.JsonValue) {
  let values = sample_values(graph, contract.type_ref, active, fuel, limit)
  case contract.nullable && !list.contains(values, kdl.JsonValueNull) {
    True -> [kdl.JsonValueNull, ..values]
    False -> values
  }
}

fn product_samples(
  graph: types.SemanticGraph,
  spec: types.ProductSpec,
  active: List(types.TypeRef),
  fuel: Int,
  limit: Int,
) -> List(kdl.JsonValue) {
  let choices =
    list.map(spec.fields, fn(field) {
      #(
        field,
        sample_values(graph, field.slot.type_ref, active, fuel - 1, limit),
      )
    })
  let base = list.map(product_members(choices, fuel), kdl.JsonValueObj)
  let extras = case spec.extras {
    types.RejectExtras -> []
    types.AllowExtras(key_format, contract) -> {
      let keys = case key_format {
        Some(format_use) ->
          option.unwrap(
            option.map(format_rule(graph, format_use), fn(rule) {
              format_samples(rule, 1)
            }),
            [],
          )
        None -> ["x"]
      }
      list.flat_map(list.take(keys, 1), fn(key) {
        list.map(
          list.take(
            element_samples(graph, contract, active, fuel - 1, limit),
            1,
          ),
          fn(value) { kdl.JsonValueObj([#(key, value)]) },
        )
      })
    }
  }
  list.append(base, extras)
}

fn product_members(
  choices: List(#(types.FieldSpec, List(kdl.JsonValue))),
  limit: Int,
) -> List(List(#(String, kdl.JsonValue))) {
  case choices {
    [] -> [[]]
    [#(field, values), ..rest] -> {
      let remaining = product_members(rest, limit)
      let here =
        list.flatten([
          case field.slot.required {
            True -> []
            False -> [None]
          },
          case field.slot.nullable {
            True -> [Some(kdl.JsonValueNull)]
            False -> []
          },
          list.map(values, Some),
        ])
      list.take(
        list.flat_map(here, fn(value) {
          list.map(remaining, fn(members) {
            case value {
              None -> members
              Some(value) -> [#(field.wire_name, value), ..members]
            }
          })
        }),
        limit,
      )
    }
  }
}

pub fn slot_samples(
  graph: types.SemanticGraph,
  contract: types.SlotContract,
  limit: Int,
) -> List(types.SlotValue(kdl.JsonValue)) {
  slot_values(contract, samples(graph, contract.type_ref, [], limit))
}

fn slot_values(
  contract: types.SlotContract,
  values: List(kdl.JsonValue),
) -> List(types.SlotValue(kdl.JsonValue)) {
  list.flatten([
    case contract.required {
      True -> []
      False -> [types.Absent]
    },
    case contract.nullable {
      True -> [types.Null]
      False -> []
    },
    list.map(values, types.Present),
  ])
}

pub fn inclusion_samples(
  graph: types.SemanticGraph,
  source: types.TypeRef,
  destination: types.TypeRef,
  limit: Int,
) -> List(kdl.JsonValue) {
  let values = samples(graph, source, [], limit)
  let additional = case
    resolved_shape(graph, source),
    resolved_shape(graph, destination)
  {
    Some(types.ProductShape(source)), Some(types.ProductShape(destination)) ->
      list.flat_map(destination.fields, fn(field) {
        case
          list.any(source.fields, fn(declared) {
            declared.wire_name == field.wire_name
          })
        {
          True -> []
          False ->
            case values {
              [kdl.JsonValueObj(members), ..] ->
                list.map(
                  [
                    kdl.JsonValueNull,
                    kdl.JsonValueBool(True),
                    kdl.JsonValueStr("x"),
                    kdl.JsonValueStr("y"),
                    kdl.JsonValueNum(0),
                  ],
                  fn(value) {
                    kdl.JsonValueObj([#(field.wire_name, value), ..members])
                  },
                )
              _ -> []
            }
        }
      })
    _, _ -> []
  }
  list.append(values, additional)
}

pub fn inclusion_slot_samples(
  graph: types.SemanticGraph,
  source: types.SlotContract,
  destination: types.TypeRef,
  limit: Int,
) -> List(types.SlotValue(kdl.JsonValue)) {
  slot_values(
    source,
    inclusion_samples(graph, source.type_ref, destination, limit),
  )
}

fn source_counterexample(
  graph: types.SemanticGraph,
  source: types.SlotContract,
  destination: types.SlotContract,
  limit: Int,
) -> Option(CounterexampleCertificate) {
  list.find_map(
    inclusion_slot_samples(graph, source, destination.type_ref, limit),
    fn(value) {
      case validation.accepts_slot(graph, source, value) {
        False -> Error(Nil)
        True ->
          case validation.validate_slot(graph, destination, value) {
            Error(validation.Rejected(failure)) ->
              Ok(CounterexampleCertificate(
                semantic_basis(graph),
                source,
                destination,
                value,
                failure,
              ))
            _ -> Error(Nil)
          }
      }
    },
  )
  |> result_to_option
}

fn result_to_option(value: Result(a, b)) -> Option(a) {
  case value {
    Ok(value) -> Some(value)
    Error(_) -> None
  }
}

fn unique_ids(
  kind: String,
  identities: List(String),
) -> Result(Nil, CompositionInputFailure) {
  case identities {
    [] -> Ok(Nil)
    [identity, ..rest] -> {
      use _ <- result.try(require(
        identity != "" && !list.contains(rest, identity),
        DuplicateIdentity(kind, identity),
      ))
      unique_ids(kind, rest)
    }
  }
}

fn check_type(
  graph: types.SemanticGraph,
  reference: types.TypeRef,
) -> Result(Nil, CompositionInputFailure) {
  require(
    find(graph.nodes, fn(node) { node.reference == reference }) != None,
    UnresolvedType(reference),
  )
}

fn signature(
  input: CompositionInput,
  reference: FunctionRef,
) -> Option(FunctionSignature) {
  find(input.signatures, fn(signature) { signature.reference == reference })
}

fn site_signature(
  input: CompositionInput,
  site: SiteId,
) -> Option(FunctionSignature) {
  option.then(
    find(input.invocation_domain.sites, fn(candidate) { candidate.id == site }),
    fn(site) { signature(input, site.function) },
  )
}

fn outcome_contract(
  input: CompositionInput,
  site: SiteId,
  id: OutcomeId,
) -> Option(OutcomeContract) {
  option.then(site_signature(input, site), fn(function) {
    find(function.outcomes, fn(outcome) { outcome.id == id })
  })
}

fn source_constraint_accepts(
  constraint: SourceConstraint,
  value: ValueRef,
) -> Bool {
  case constraint, value.producer {
    AnyCompatible, _ -> True
    InitialOnly(id, path), Initial(actual) -> id == actual && path == value.path
    ProducedBy(s, o, p, path), InvocationOutcome(actual_s, actual_o, actual_p)
    -> s == actual_s && o == actual_o && p == actual_p && path == value.path
    _, _ -> False
  }
}

fn check_source_constraint(
  graph: types.SemanticGraph,
  input: CompositionInput,
  constraint: SourceConstraint,
) -> Result(Nil, CompositionInputFailure) {
  let source = case constraint {
    AnyCompatible -> None
    InitialOnly(id, path) ->
      option.map(
        find(input.initial_inputs, fn(initial) { initial.id == id }),
        fn(initial) { #(initial.contract, path) },
      )
    ProducedBy(site, outcome, port, path) ->
      option.then(outcome_contract(input, site, outcome), fn(outcome) {
        option.map(
          find(outcome.value_ports, fn(output) { output.id == port }),
          fn(output) { #(output.contract, path) },
        )
      })
  }
  case constraint, source {
    AnyCompatible, _ -> Ok(Nil)
    _, Some(pair) -> {
      use _ <- result.try(require(
        natural_path(pair.1),
        InvalidInvocationDomain("source constraint index is negative"),
      ))
      require(
        constraint_path_valid(graph, pair.0.type_ref, pair.1, []),
        InvalidInvocationDomain("invalid source constraint path"),
      )
    }
    _, _ -> Error(InvalidInvocationDomain("unresolved source constraint"))
  }
}

fn field_constraint(rule: ConstructionRule, field: String) -> SourceConstraint {
  option.unwrap(
    option.map(
      find(rule.field_constraints, fn(constraint) { constraint.field == field }),
      fn(constraint) { constraint.source },
    ),
    AnyCompatible,
  )
}

fn field_required(rule: ConstructionRule, field: types.FieldSpec) -> Bool {
  field.slot.required
  || list.any(rule.field_constraints, fn(constraint) {
    constraint.field == field.wire_name && constraint.presence == Required
  })
}

fn constraint_path_valid(
  graph: types.SemanticGraph,
  reference: types.TypeRef,
  path: types.ValuePath,
  seen: List(types.TypeRef),
) -> Bool {
  case find(graph.nodes, fn(node) { node.reference == reference }) {
    None -> False
    Some(node) ->
      case path {
        [] -> True
        [step, ..rest] ->
          case list.contains(seen, reference) {
            True -> False
            False ->
              case node.shape {
                types.AliasShape(target, _) ->
                  constraint_path_valid(graph, target, path, [reference, ..seen])
                types.ProductShape(spec) ->
                  case step {
                    types.Field(name) ->
                      option.unwrap(
                        option.map(
                          find(spec.fields, fn(field) {
                            field.wire_name == name
                          }),
                          fn(field) {
                            constraint_path_valid(
                              graph,
                              field.slot.type_ref,
                              rest,
                              [],
                            )
                          },
                        ),
                        False,
                      )
                    _ -> False
                  }
                types.ArrayShape(spec) ->
                  case step {
                    types.Index(index) ->
                      index >= 0
                      && constraint_path_valid(
                        graph,
                        spec.item.type_ref,
                        rest,
                        [],
                      )
                    _ -> False
                  }
                types.TaggedUnionShape(spec) ->
                  case step {
                    types.Variant(tag) ->
                      option.unwrap(
                        option.map(
                          find(spec.branches, fn(branch) {
                            branch.wire_tag == tag
                          }),
                          fn(branch) {
                            constraint_path_valid(
                              graph,
                              branch.target,
                              rest,
                              [],
                            )
                          },
                        ),
                        False,
                      )
                    _ -> False
                  }
                _ -> False
              }
          }
      }
  }
}

pub fn check_function(
  graph: types.SemanticGraph,
  input: CompositionInput,
  function: FunctionSignature,
) -> Result(Nil, CompositionInputFailure) {
  let fail = fn(reason) { InvalidSignature(function.reference, reason) }
  use _ <- result.try(require(
    function.reference.identity != ""
      && function.reference.revision != ""
      && function.reference.content_digest != ""
      && function.assumption_ref != "",
    fail("function provenance or signature assumption is absent"),
  ))
  use _ <- result.try(require(
    function.outcomes != [],
    fail("no declared outcome"),
  ))
  use _ <- result.try(unique_ids(
    "input port",
    list.map(function.inputs, fn(port) { port.id.value }),
  ))
  use _ <- result.try(unique_ids(
    "outcome",
    list.map(function.outcomes, fn(outcome) { outcome.id.value }),
  ))
  use _ <- result.try(unique_ids(
    "resource requirement",
    list.map(function.resource_inputs, fn(requirement) { requirement.id.value }),
  ))
  use _ <- result.try(require(
    function.effect == PureFunction,
    fail("pure/transform declaration has a non-pure effect"),
  ))
  use _ <- result.try(
    each(function.inputs, fn(port) {
      use _ <- result.try(check_type(graph, port.contract.type_ref))
      use _ <- result.try(check_source_constraint(
        graph,
        input,
        port.source_constraint,
      ))
      require(
        option.unwrap(
          option.map(port.resource_requirement, fn(id) {
            list.any(function.resource_inputs, fn(requirement) {
              requirement.id == id
            })
          }),
          True,
        ),
        fail("input port names an absent resource requirement"),
      )
    }),
  )
  use _ <- result.try(
    each(function.resource_inputs, fn(requirement) {
      use _ <- result.try(check_type(graph, requirement.token_type))
      require(
        requirement.multiplicity > 0 && requirement.required_revision >= 0,
        fail("resource multiplicity/revision is invalid"),
      )
    }),
  )
  use _ <- result.try(
    each(function.outcomes, fn(outcome) {
      use _ <- result.try(unique_ids(
        "output port",
        list.map(outcome.value_ports, fn(port) { port.id.value }),
      ))
      use _ <- result.try(unique_ids(
        "resource production",
        list.map(outcome.produced_resources, fn(production) {
          production.id.value
        }),
      ))
      use _ <- result.try(
        each(outcome.value_ports, fn(port) {
          use _ <- result.try(check_type(graph, port.contract.type_ref))
          require(
            option.unwrap(
              option.map(port.resource_production, fn(id) {
                list.any(outcome.produced_resources, fn(production) {
                  production.id == id
                })
              }),
              True,
            ),
            fail("output resource backing is unresolved"),
          )
        }),
      )
      each(outcome.produced_resources, fn(production) {
        use _ <- result.try(check_type(graph, production.token_type))
        require(
          production.quantity >= 0 && production.revision >= 0,
          InvalidResourceDeclaration("production quantity/revision is negative"),
        )
      })
    }),
  )
  case function.handles_failure {
    None -> Ok(Nil)
    Some(origin) -> check_failure_origin(input, origin)
  }
}

fn check_failure_origin(
  input: CompositionInput,
  origin: FailureOrigin,
) -> Result(Nil, CompositionInputFailure) {
  let valid = case origin {
    FunctionFailure(reference, id) ->
      option.unwrap(
        option.map(signature(input, reference), fn(function) {
          list.any(function.outcomes, fn(outcome) {
            outcome.id == id && outcome.form == DeclaredFailure
          })
        }),
        False,
      )
    GuardFailure(id, _) ->
      list.any(input.invocation_domain.guards, fn(guard) { guard.id == id })
  }
  require(valid, InvalidInvocationDomain("failure origin unresolved"))
}

type LotDeclaration {
  LotDeclaration(
    token_type: types.TypeRef,
    producer: ResourceProducer,
    revision: Int,
    quantity: Int,
    provenance: String,
  )
}

fn declared_lot(
  input: CompositionInput,
  reference: ResourceLotRef,
) -> Option(LotDeclaration) {
  case reference {
    InitialLot(id) ->
      option.map(
        find(input.initial_resources, fn(lot) { lot.id == id }),
        fn(lot) {
          LotDeclaration(
            lot.token_type,
            lot.producer,
            lot.revision,
            lot.quantity,
            lot.provenance,
          )
        },
      )
    ProducedLot(site, outcome, id) ->
      option.then(outcome_contract(input, site, outcome), fn(outcome_contract) {
        option.map(
          find(outcome_contract.produced_resources, fn(production) {
            production.id == id
          }),
          fn(production) {
            LotDeclaration(
              production.token_type,
              OutcomeResource(site, outcome),
              production.revision,
              production.quantity,
              production.provenance,
            )
          },
        )
      })
  }
}

fn check_bounds(bounds: SearchBounds) -> Result(Nil, CompositionInputFailure) {
  use _ <- result.try(require(
    bounds.max_expanded_states >= 0
      && bounds.max_binding_candidates >= 0
      && bounds.max_type_obligations >= 0
      && bounds.max_branch_nodes >= 0,
    InvalidBound("composition bounds must be natural numbers"),
  ))
  case bounds.resource_bounds {
    None -> Ok(Nil)
    Some(bound) ->
      require(
        bound.max_bindings >= 0
          && bound.max_search_steps >= 0
          && bound.max_tokens >= 0,
        InvalidBound("resource bounds must be natural numbers"),
      )
  }
}

fn check_construction(
  graph: types.SemanticGraph,
  input: CompositionInput,
  rule: ConstructionRule,
) -> Result(Nil, CompositionInputFailure) {
  use _ <- result.try(check_type(graph, rule.type_ref))
  case resolved_shape(graph, rule.type_ref) {
    Some(types.ProductShape(spec)) -> {
      use _ <- result.try(unique_ids(
        "nested construction field",
        list.map(rule.nested_fields, fn(pair) { pair.0 }),
      ))
      use _ <- result.try(unique_ids(
        "construction constrained field",
        list.map(rule.field_constraints, fn(constraint) { constraint.field }),
      ))
      use _ <- result.try(
        each(rule.field_constraints, fn(constraint) {
          use _ <- result.try(require(
            list.any(spec.fields, fn(field) {
              field.wire_name == constraint.field
            })
              && !list.any(rule.nested_fields, fn(nested) {
              nested.0 == constraint.field
            }),
            InvalidInvocationDomain(
              "construction constrained field is absent or nested",
            ),
          ))
          check_source_constraint(graph, input, constraint.source)
        }),
      )
      use _ <- result.try(
        each(rule.nested_fields, fn(pair) {
          let valid =
            option.unwrap(
              option.map(
                find(spec.fields, fn(field) { field.wire_name == pair.0 }),
                fn(field) {
                  list.any(
                    input.invocation_domain.permitted_constructions,
                    fn(rule) {
                      rule.identity == pair.1
                      && rule.type_ref == field.slot.type_ref
                    },
                  )
                },
              ),
              False,
            )
          require(
            valid,
            InvalidInvocationDomain("nested construction rule/type unresolved"),
          )
        }),
      )
      check_construction_cycle(input, rule.identity, [rule.identity], [])
    }
    _ ->
      Error(InvalidInvocationDomain("construction must name a resolved product"))
  }
}

fn check_construction_cycle(
  input: CompositionInput,
  root: String,
  pending: List(String),
  seen: List(String),
) -> Result(Nil, CompositionInputFailure) {
  case pending {
    [] -> Ok(Nil)
    [identity, ..rest] ->
      case list.contains(seen, identity) {
        True -> check_construction_cycle(input, root, rest, seen)
        False ->
          case
            find(input.invocation_domain.permitted_constructions, fn(rule) {
              rule.identity == identity
            })
          {
            None ->
              Error(InvalidInvocationDomain(
                "nested construction rule unresolved",
              ))
            Some(rule) -> {
              let children = list.map(rule.nested_fields, fn(pair) { pair.1 })
              use _ <- result.try(require(
                !list.contains(children, root),
                InvalidInvocationDomain(
                  "construction rules must form a finite acyclic expansion",
                ),
              ))
              check_construction_cycle(
                input,
                root,
                list.append(children, rest),
                [identity, ..seen],
              )
            }
          }
      }
  }
}

pub fn prepare_composition(
  graph: types.SemanticGraph,
  input: CompositionInput,
  check_signature: fn(FunctionSignature) -> Result(Nil, CompositionInputFailure),
) -> Result(PreparedCompositionInput, CompositionInputFailure) {
  prepare_input(graph, input, check_signature)
}

fn prepare_input(
  graph: types.SemanticGraph,
  input: CompositionInput,
  check_signature: fn(FunctionSignature) -> Result(Nil, CompositionInputFailure),
) -> Result(PreparedCompositionInput, CompositionInputFailure) {
  use _ <- result.try(require(
    input.basis == semantic_basis(graph),
    InputBasisMismatch,
  ))
  use _ <- result.try(check_bounds(input.bounds))
  use _ <- result.try(unique_ids(
    "input",
    list.map(input.initial_inputs, fn(value) { value.id.value }),
  ))
  use _ <- result.try(unique_ids(
    "site",
    list.map(input.invocation_domain.sites, fn(value) { value.id.value }),
  ))
  use _ <- result.try(unique_ids(
    "lot",
    list.map(input.initial_resources, fn(value) { value.id.value }),
  ))
  use _ <- result.try(unique_ids(
    "goal",
    list.map(input.goal.outputs, fn(value) { value.id.value }),
  ))
  use _ <- result.try(unique_ids(
    "failure embedding",
    list.map(input.goal.failures, fn(value) { value.id.value }),
  ))
  use _ <- result.try(unique_ids(
    "guard",
    list.map(input.invocation_domain.guards, fn(value) { value.id.value }),
  ))
  use _ <- result.try(
    each(input.signatures, fn(function) {
      require(
        list.length(
          list.filter(input.signatures, fn(candidate) {
            candidate.reference == function.reference
          }),
        )
          == 1,
        InvalidSignature(function.reference, "duplicate function revision"),
      )
    }),
  )
  use _ <- result.try(each(input.signatures, check_signature))
  use _ <- result.try(
    each(input.invocation_domain.sites, fn(site) {
      case signature(input, site.function) {
        None -> Error(UnresolvedFunction(site.function))
        Some(function) -> {
          use _ <- result.try(require(
            list.contains(input.allowed_effects, function.effect),
            InvalidInvocationDomain("effect not allowed at site"),
          ))
          require(
            function.form != DeclaredTransform
              || list.contains(
              input.invocation_domain.permitted_transforms,
              function.reference,
            ),
            InvalidInvocationDomain("transform not permitted at site"),
          )
        }
      }
    }),
  )
  use initial_obligations <- result.try(
    collect(input.initial_inputs, fn(initial) {
      use _ <- result.try(check_type(graph, initial.contract.type_ref))
      use _ <- result.try(require(
        option.unwrap(
          option.map(initial.resource, fn(id) {
            list.any(input.initial_resources, fn(lot) { lot.id == id })
          }),
          True,
        ),
        InvalidResourceDeclaration("initial backing lot unresolved"),
      ))
      case initial.source {
        Argument -> Ok([])
        SuppliedValue(value) ->
          case validation.validate_slot(graph, initial.contract, value) {
            Ok(_) -> Ok([])
            Error(validation.Rejected(failure)) ->
              Error(InvalidInitialValue(initial.id, failure))
            Error(validation.Unresolved(obligations)) -> Ok(obligations)
          }
      }
    }),
  )
  use _ <- result.try(
    each(input.initial_resources, fn(lot) {
      use _ <- result.try(check_type(graph, lot.token_type))
      require(
        lot.quantity >= 0
          && lot.revision >= 0
          && lot.provenance != ""
          && case lot.producer {
          InitialResource(identity, revision) ->
            identity != "" && revision != ""
          _ -> False
        },
        InvalidResourceDeclaration(
          "initial producer/provenance/quantity/revision invalid",
        ),
      )
    }),
  )
  use _ <- result.try(require(
    input.goal.outputs != [],
    InvalidInvocationDomain("goal has no output ports"),
  ))
  use _ <- result.try(
    each(input.goal.outputs, fn(goal) {
      use _ <- result.try(check_type(graph, goal.contract.type_ref))
      check_source_constraint(graph, input, goal.source_constraint)
    }),
  )
  use _ <- result.try(
    each(input.goal.failures, fn(embedding) {
      use _ <- result.try(check_type(graph, embedding.contract.type_ref))
      check_failure_origin(input, embedding.origin)
    }),
  )
  use _ <- result.try(
    each(input.invocation_domain.permitted_projections, fn(projection) {
      use _ <- result.try(check_type(graph, projection.source_type))
      require(
        natural_path(projection.path),
        InvalidInvocationDomain("projection index is negative"),
      )
    }),
  )
  use _ <- result.try(unique_ids(
    "construction",
    list.map(input.invocation_domain.permitted_constructions, fn(rule) {
      rule.identity
    }),
  ))
  use _ <- result.try(
    each(input.invocation_domain.permitted_constructions, fn(rule) {
      check_construction(graph, input, rule)
    }),
  )
  use _ <- result.try(
    each(input.invocation_domain.guards, fn(guard) {
      use _ <- result.try(check_type(graph, guard.source_type))
      use _ <- result.try(require(
        natural_path(guard.path),
        InvalidInvocationDomain("guard index is negative"),
      ))
      case guard.kind {
        Validate(contract) -> check_type(graph, contract.type_ref)
        _ -> Ok(Nil)
      }
    }),
  )
  use _ <- result.try(
    each(input.explicit_order, fn(pair) {
      require(
        pair.0 != pair.1
          && site_signature(input, pair.0) != None
          && site_signature(input, pair.1) != None,
        InvalidInvocationDomain("invalid explicit site order"),
      )
    }),
  )
  use _ <- result.try(
    each(
      list.append(
        input.goal.final_resources,
        list.flat_map(input.goal.failures, fn(embedding) {
          embedding.final_resources
        }),
      ),
      fn(goal) {
        require(
          goal.multiplicity >= 0
            && goal.revision >= 0
            && declared_lot(input, goal.lot) != None,
          InvalidResourceDeclaration(
            "goal resource lot/revision/multiplicity invalid",
          ),
        )
      },
    ),
  )
  Ok(PreparedCompositionInput(
    graph,
    input,
    empty_types(graph),
    list.flatten(initial_obligations),
  ))
}

fn resource_input_valid(
  input: resource.SolverInput,
) -> Result(Nil, WitnessFailure) {
  use _ <- result.try(
    result.map_error(resource.validate(input), fn(_) {
      ResourceReplayMismatch("invalid solver input")
    }),
  )
  require(
    !resource.binding_bound_exceeded(input),
    ResourceReplayMismatch("binding bound exhausted"),
  )
}

fn resource_neighbors(
  input: resource.SolverInput,
  marking: resource.Marking,
) -> List(resource.Marking) {
  list.filter_map(input.transitions, fn(transition) {
    let bindings = resource.bindings_for(input, transition.identity)
    case resource.transition_enabled_at(bindings, marking) {
      True -> Ok(resource.apply_branch_at(marking, transition, bindings))
      False -> Error(Nil)
    }
  })
}

fn replay_resource(
  input: resource.SolverInput,
  marking: resource.Marking,
  path: List(String),
) -> Result(resource.Marking, WitnessFailure) {
  case path {
    [] -> Ok(marking)
    [identity, ..rest] ->
      case
        find(input.transitions, fn(transition) {
          transition.identity == identity
        })
      {
        None -> Error(ResourceReplayMismatch("unknown transition"))
        Some(transition) -> {
          let bindings = resource.bindings_for(input, identity)
          use _ <- result.try(require(
            resource.transition_enabled_at(bindings, marking),
            ResourceReplayMismatch("disabled transition"),
          ))
          replay_resource(
            input,
            resource.apply_branch_at(marking, transition, bindings),
            rest,
          )
        }
      }
  }
}

pub fn verify_reachability_witness(
  input: resource.SolverInput,
  witness: resource.ReachabilityWitness,
) -> Result(CheckedReachability, WitnessFailure) {
  use _ <- result.try(resource_input_valid(input))
  use _ <- result.try(require(
    list.length(witness.path) <= input.bound.max_search_steps,
    ResourceReplayMismatch("path exceeds bound"),
  ))
  use marking <- result.try(replay_resource(input, input.marking, witness.path))
  use _ <- result.try(require(
    marking == witness.final_marking && resource.eval_goal(marking, input.goal),
    ResourceReplayMismatch("final marking or resource goal differs"),
  ))
  Ok(CheckedReachability(input, witness))
}

fn graph_reached(
  edges: List(List(Int)),
  pending: List(Int),
  seen: List(Int),
) -> Result(List(Int), WitnessFailure) {
  case pending {
    [] -> Ok(seen)
    [index, ..rest] ->
      case list.contains(seen, index) {
        True -> graph_reached(edges, rest, seen)
        False ->
          case at(edges, index) {
            None -> Error(ForgedClosure("missing graph successor"))
            Some(children) ->
              graph_reached(edges, list.append(children, rest), [index, ..seen])
          }
      }
  }
}

fn verify_finite_closure(
  input: resource.SolverInput,
  markings: List(resource.Marking),
  steps: Int,
  frontier: List(resource.Marking),
) -> Result(List(List(Int)), WitnessFailure) {
  use _ <- result.try(resource_input_valid(input))
  use _ <- result.try(require(
    frontier == []
      && steps == list.length(markings)
      && steps <= input.bound.max_search_steps
      && list.contains(markings, input.marking)
      && unique(markings) == markings,
    ForgedClosure(
      "initial marking, frontier, steps, duplicate marking or bound",
    ),
  ))
  use edges <- result.try(
    collect(markings, fn(marking) {
      use successors <- result.try(
        collect(resource_neighbors(input, marking), fn(successor) {
          option.to_result(
            index_of(markings, successor, 0),
            ForgedClosure("enabled successor omitted"),
          )
        }),
      )
      Ok(unique(successors))
    }),
  )
  use root <- result.try(option.to_result(
    index_of(markings, input.marking, 0),
    ForgedClosure("initial marking omitted"),
  ))
  use reached <- result.try(graph_reached(edges, [root], []))
  use _ <- result.try(require(
    list.length(reached) == list.length(markings),
    ForgedClosure("unreachable marking injected"),
  ))
  Ok(edges)
}

pub fn verify_closure_witness(
  input: resource.SolverInput,
  witness: resource.ClosureWitness,
) -> Result(CheckedClosure, WitnessFailure) {
  use _ <- result.try(verify_finite_closure(
    input,
    witness.explored_markings,
    witness.steps,
    witness.frontier,
  ))
  use _ <- result.try(require(
    !list.any(witness.explored_markings, fn(marking) {
      resource.eval_goal(marking, input.goal)
    }),
    ForgedClosure("closure contains a resource goal"),
  ))
  Ok(CheckedClosure(input, witness))
}

fn graph_acyclic(edges: List(List(Int)), remaining: List(Int)) -> Bool {
  case remaining {
    [] -> True
    _ -> {
      let roots =
        list.filter(remaining, fn(node) {
          !list.any(remaining, fn(parent) {
            list.contains(option.unwrap(at(edges, parent), []), node)
          })
        })
      case roots {
        [] -> False
        _ ->
          graph_acyclic(
            edges,
            list.filter(remaining, fn(node) { !list.contains(roots, node) }),
          )
      }
    }
  }
}

pub fn verify_acyclic_witness(
  input: resource.SolverInput,
  witness: resource.AcyclicWitness,
) -> Result(CheckedAcyclic, WitnessFailure) {
  use edges <- result.try(verify_finite_closure(
    input,
    witness.explored_markings,
    witness.steps,
    witness.frontier,
  ))
  use _ <- result.try(require(
    graph_acyclic(edges, list.index_map(edges, fn(_, index) { index })),
    ForgedAcyclicity("closed marking graph contains a cycle"),
  ))
  Ok(CheckedAcyclic(input, witness))
}

fn encode_tuple(parts: List(String)) -> String {
  string.concat(
    list.map(parts, fn(part) {
      int.to_string(string.byte_size(part)) <> ":" <> part
    }),
  )
}

fn type_identity(reference: types.TypeRef) -> String {
  source_type_identity(reference)
}

fn source_type_identity(reference: types.TypeRef) -> String {
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

fn function_identity(reference: FunctionRef) -> String {
  encode_tuple([
    reference.identity,
    reference.revision,
    reference.content_digest,
  ])
}

fn producer_identity(producer: ProducerRef) -> String {
  case producer {
    Initial(id) -> encode_tuple(["initial-value", id.value])
    InvocationOutcome(site, outcome, port) ->
      encode_tuple(["outcome-value", site.value, outcome.value, port.value])
  }
}

fn lot_identity(lot: ResourceLotRef) -> String {
  case lot {
    InitialLot(id) -> encode_tuple(["initial-lot", id.value])
    ProducedLot(site, outcome, production) ->
      encode_tuple(["produced-lot", site.value, outcome.value, production.value])
  }
}

fn invocation_identity(
  invocation: InvocationPlan,
  outcome: OutcomeId,
) -> String {
  encode_tuple([
    "invocation",
    invocation.site.value,
    function_identity(invocation.function),
    outcome.value,
  ])
}

fn production_identity(
  site: SiteId,
  outcome: OutcomeId,
  production: ProductionId,
) -> String {
  encode_tuple([
    "resource-production",
    site.value,
    outcome.value,
    production.value,
  ])
}

fn declared_value(
  input: CompositionInput,
  producer: ProducerRef,
) -> Option(#(types.SlotContract, Option(ResourceLotRef))) {
  case producer {
    Initial(id) ->
      option.map(
        find(input.initial_inputs, fn(initial) { initial.id == id }),
        fn(initial) {
          #(initial.contract, option.map(initial.resource, InitialLot))
        },
      )
    InvocationOutcome(site, outcome, port) ->
      option.then(outcome_contract(input, site, outcome), fn(outcome_contract) {
        option.map(
          find(outcome_contract.value_ports, fn(output) { output.id == port }),
          fn(output) {
            #(
              output.contract,
              option.map(output.resource_production, fn(production) {
                ProducedLot(site, outcome, production)
              }),
            )
          },
        )
      })
  }
}

fn binding_sources(binding: BindingExpr) -> List(ValueRef) {
  case binding {
    Source(value, _, _) -> [value]
    Product(_, _, fields) ->
      list.flat_map(fields, fn(pair) { binding_sources(pair.1) })
  }
}

fn add_requirement(
  requirements: List(#(ResourceLotRef, Int)),
  lot: ResourceLotRef,
  count: Int,
  consume: Bool,
) -> List(#(ResourceLotRef, Int)) {
  case list.any(requirements, fn(pair) { pair.0 == lot }) {
    False -> list.append(requirements, [#(lot, count)])
    True ->
      list.map(requirements, fn(pair) {
        case pair.0 == lot {
          True -> #(lot, case consume {
            True -> pair.1 + count
            False -> maximum(pair.1, count)
          })
          False -> pair
        }
      })
  }
}

fn token_cap(input: CompositionInput) -> Int {
  case input.bounds.resource_bounds {
    None -> default_resource_token_bound
    Some(bound) -> bound.max_tokens
  }
}

fn check_quantity(
  input: CompositionInput,
  quantity: Int,
) -> Result(Nil, LoweringFailure) {
  require(
    quantity <= token_cap(input),
    UnknownLowering(ResourceCapacityBound(quantity, token_cap(input))),
  )
}

type LoweredPhase {
  LoweredPhase(
    identity: String,
    revision: Int,
    value_reads: List(ProducerRef),
    reads: List(#(ResourceLotRef, Int)),
    consumes: List(#(ResourceLotRef, Int)),
    outputs: List(String),
  )
}

type TraceNet {
  TraceNet(
    lots: List(ResourceLotCorrespondence),
    values: List(ValueCorrespondence),
    places: List(resource.TypedPlace),
    marking: resource.Marking,
    phases: List(LoweredPhase),
  )
}

fn initial_net(
  prepared: PreparedCompositionInput,
) -> Result(TraceNet, LoweringFailure) {
  let input = prepared.input
  use lots <- result.try(
    collect(input.initial_resources, fn(lot) {
      use _ <- result.try(check_quantity(input, lot.quantity))
      case lot.producer {
        InitialResource(identity, revision) ->
          Ok(ResourceLotCorrespondence(
            InitialLot(lot.id),
            lot_identity(InitialLot(lot.id)),
            lot.producer,
            encode_tuple(["initial-resource", identity, revision, lot.id.value]),
            type_identity(lot.token_type),
            lot.revision,
            lot.quantity,
            lot.provenance,
          ))
        _ -> Error(InvalidLowering("initial lot has a produced identity"))
      }
    }),
  )
  let values =
    list.map(input.initial_inputs, fn(initial) {
      let producer = Initial(initial.id)
      let place = producer_identity(producer)
      ValueCorrespondence(producer, place, place, 0)
    })
  let places =
    list.append(
      list.map(lots, fn(lot) {
        resource.TypedPlace(lot.place, lot.token_type, lot.revision)
      }),
      list.map(input.initial_inputs, fn(initial) {
        resource.TypedPlace(
          producer_identity(Initial(initial.id)),
          type_identity(initial.contract.type_ref),
          0,
        )
      }),
    )
  let marking =
    resource.Marking(list.append(
      list.map(lots, fn(lot) {
        #(
          lot.place,
          list.repeat(
            resource.ColoredToken(
              lot.token_target,
              0,
              lot.revision,
              resource.TokenInput,
            ),
            lot.quantity,
          ),
        )
      }),
      list.map(values, fn(value) {
        #(value.place, [
          resource.ColoredToken(value.token_target, 0, 0, resource.TokenInput),
        ])
      }),
    ))
  Ok(TraceNet(lots, values, places, marking, []))
}

fn lower_trace_steps(
  prepared: PreparedCompositionInput,
  net: TraceNet,
  steps: List(TraceStep),
) -> Result(TraceNet, LoweringFailure) {
  case steps {
    [] -> Ok(net)
    [GuardStep(guard, inspected, _), ..rest] -> {
      let phase =
        LoweredPhase(
          encode_tuple([
            "guard",
            guard.value,
            producer_identity(inspected.producer),
          ]),
          0,
          [inspected.producer],
          [],
          [],
          [],
        )
      lower_trace_steps(
        prepared,
        TraceNet(..net, phases: list.append(net.phases, [phase])),
        rest,
      )
    }
    [InvocationStep(invocation, outcome), ..rest] -> {
      use function <- result.try(option.to_result(
        site_signature(prepared.input, invocation.site),
        InvalidLowering("unresolved site"),
      ))
      use contract <- result.try(option.to_result(
        find(function.outcomes, fn(candidate) { candidate.id == outcome }),
        InvalidLowering("unresolved outcome"),
      ))
      let sources =
        list.flat_map(invocation.bindings, fn(pair) { binding_sources(pair.1) })
      let value_reads =
        unique(list.map(sources, fn(source) { source.producer }))
      let reads =
        list.fold(sources, [], fn(reads, source) {
          case declared_value(prepared.input, source.producer) {
            Some(#(_, Some(lot))) -> add_requirement(reads, lot, 1, False)
            _ -> reads
          }
        })
      use requirements <- result.try(
        collect(function.resource_inputs, fn(requirement) {
          use binding <- result.try(option.to_result(
            find(invocation.resources, fn(binding) {
              binding.requirement == requirement.id
            }),
            InvalidLowering("resource binding missing"),
          ))
          use lot <- result.try(option.to_result(
            find(net.lots, fn(lot) { lot.lot == binding.lot }),
            InvalidLowering("resource producer unavailable"),
          ))
          Ok(#(requirement, lot.lot))
        }),
      )
      let #(reads, consumes) =
        list.fold(requirements, #(reads, []), fn(acc, entry) {
          case entry.0.mode {
            resource.Read -> #(
              add_requirement(acc.0, entry.1, entry.0.multiplicity, False),
              acc.1,
            )
            resource.Consume -> #(
              acc.0,
              add_requirement(acc.1, entry.1, entry.0.multiplicity, True),
            )
          }
        })
      let identity = invocation_identity(invocation, outcome)
      let values =
        list.map(contract.value_ports, fn(port) {
          let producer = InvocationOutcome(invocation.site, outcome, port.id)
          ValueCorrespondence(
            producer,
            producer_identity(producer),
            identity,
            0,
          )
        })
      let places =
        list.map(contract.value_ports, fn(port) {
          resource.TypedPlace(
            producer_identity(InvocationOutcome(
              invocation.site,
              outcome,
              port.id,
            )),
            type_identity(port.contract.type_ref),
            0,
          )
        })
      use productions <- result.try(
        collect(contract.produced_resources, fn(production) {
          use _ <- result.try(check_quantity(
            prepared.input,
            production.quantity,
          ))
          let lot = ProducedLot(invocation.site, outcome, production.id)
          let place = lot_identity(lot)
          let target =
            production_identity(invocation.site, outcome, production.id)
          Ok(#(
            ResourceLotCorrespondence(
              lot,
              place,
              OutcomeResource(invocation.site, outcome),
              target,
              type_identity(production.token_type),
              production.revision,
              production.quantity,
              production.provenance,
            ),
            LoweredPhase(
              target,
              production.revision,
              [],
              [],
              [],
              list.repeat(place, production.quantity),
            ),
          ))
        }),
      )
      let phase =
        LoweredPhase(
          identity,
          0,
          value_reads,
          reads,
          consumes,
          list.map(values, fn(value) { value.place }),
        )
      let net =
        TraceNet(
          ..net,
          lots: list.append(
            net.lots,
            list.map(productions, fn(pair) { pair.0 }),
          ),
          values: list.append(net.values, values),
          places: list.flatten([
            net.places,
            places,
            list.map(productions, fn(pair) {
              resource.TypedPlace(
                pair.0.place,
                pair.0.token_type,
                pair.0.revision,
              )
            }),
          ]),
          phases: list.flatten([
            net.phases,
            [phase],
            list.map(productions, fn(pair) { pair.1 }),
          ]),
        )
      lower_trace_steps(prepared, net, rest)
    }
  }
}

type ControlNet {
  ControlNet(
    net: TraceNet,
    transitions: List(resource.TypedTransition),
    bindings: List(resource.InputBinding),
    normalized: List(NormalizedResourceBinding),
    execution_order: List(String),
    previous_control: String,
    previous_target: String,
    previous_revision: Int,
    maximum_tokens: Int,
  )
}

fn lower_phase(
  input: CompositionInput,
  state: ControlNet,
  phase: LoweredPhase,
  index: Int,
) -> Result(ControlNet, LoweringFailure) {
  let permit = encode_tuple(["permit", phase.identity])
  let next_control = encode_tuple(["control", int.to_string(index + 1)])
  let controls = [
    resource.InputBinding(
      phase.identity,
      "order",
      state.previous_control,
      "control",
      state.previous_target,
      "selected branch order",
      1,
      resource.Consume,
      state.previous_revision,
    ),
    resource.InputBinding(
      phase.identity,
      "permit",
      permit,
      "control",
      permit,
      "finite site permit",
      1,
      resource.Consume,
      0,
    ),
  ]
  use values <- result.try(
    collect(phase.value_reads, fn(producer) {
      use value <- result.try(option.to_result(
        find(state.net.values, fn(value) { value.producer == producer }),
        InvalidLowering("input value correspondence unavailable"),
      ))
      use declaration <- result.try(option.to_result(
        declared_value(input, producer),
        InvalidLowering("input value declaration unavailable"),
      ))
      Ok(resource.InputBinding(
        phase.identity,
        encode_tuple(["value-read", value.place]),
        value.place,
        type_identity(declaration.0.type_ref),
        value.token_target,
        producer_identity(producer),
        1,
        resource.Read,
        value.revision,
      ))
    }),
  )
  let references =
    unique(
      list.map(list.append(phase.reads, phase.consumes), fn(pair) { pair.0 }),
    )
  use lots <- result.try(
    collect(references, fn(reference) {
      use lot <- result.try(option.to_result(
        find(state.net.lots, fn(lot) { lot.lot == reference }),
        InvalidLowering("normalization names an unavailable lot"),
      ))
      let read =
        option.unwrap(
          option.map(
            find(phase.reads, fn(pair) { pair.0 == reference }),
            fn(pair) { pair.1 },
          ),
          0,
        )
      let consume =
        option.unwrap(
          option.map(
            find(phase.consumes, fn(pair) { pair.0 == reference }),
            fn(pair) { pair.1 },
          ),
          0,
        )
      let bindings =
        filter_options(
          [
            #("read", resource.Read, read),
            #("consume", resource.Consume, consume),
          ],
          fn(entry) {
            case entry.2 == 0 {
              True -> None
              False ->
                Some(resource.InputBinding(
                  phase.identity,
                  encode_tuple([entry.0, lot.place]),
                  lot.place,
                  lot.token_type,
                  lot.token_target,
                  lot.provenance,
                  entry.2,
                  entry.1,
                  lot.revision,
                ))
            }
          },
        )
      Ok(#(
        lot.place,
        bindings,
        NormalizedResourceBinding(
          phase.identity,
          reference,
          read,
          consume,
          lot.revision,
        ),
      ))
    }),
  )
  let input_places =
    list.flatten([
      [state.previous_control, permit],
      list.map(values, fn(binding) { binding.place }),
      list.map(lots, fn(entry) { entry.0 }),
    ])
  let outputs = list.append(phase.outputs, [next_control])
  let net =
    TraceNet(
      ..state.net,
      places: list.append(state.net.places, [
        resource.TypedPlace(permit, "control", 0),
        resource.TypedPlace(next_control, "control", phase.revision),
      ]),
      marking: resource.Marking(
        list.append(state.net.marking.places, [
          #(permit, [resource.ColoredToken(permit, 0, 0, resource.TokenInput)]),
        ]),
      ),
    )
  Ok(ControlNet(
    net,
    list.append(state.transitions, [
      resource.TypedTransition(
        phase.identity,
        input_places,
        outputs,
        [],
        phase.revision,
      ),
    ]),
    list.flatten([
      state.bindings,
      controls,
      values,
      list.flat_map(lots, fn(entry) { entry.1 }),
    ]),
    list.append(state.normalized, list.map(lots, fn(entry) { entry.2 })),
    list.append(state.execution_order, [phase.identity]),
    next_control,
    phase.identity,
    phase.revision,
    state.maximum_tokens + list.length(outputs) + 1,
  ))
}

fn lower_phases(
  input: CompositionInput,
  state: ControlNet,
  phases: List(LoweredPhase),
  index: Int,
) -> Result(ControlNet, LoweringFailure) {
  case phases {
    [] -> Ok(state)
    [phase, ..rest] -> {
      use state <- result.try(lower_phase(input, state, phase, index))
      lower_phases(input, state, rest, index + 1)
    }
  }
}

fn terminal_parts(
  input: CompositionInput,
  terminal: ReturnPlan,
) -> Result(#(List(BindingExpr), List(ResourceGoal)), LoweringFailure) {
  case terminal {
    ReturnSuccess(outputs) ->
      Ok(#(list.map(outputs, fn(pair) { pair.1 }), input.goal.final_resources))
    ReturnFailure(id, value) ->
      case find(input.goal.failures, fn(embedding) { embedding.id == id }) {
        Some(embedding) -> Ok(#([value], embedding.final_resources))
        None -> Error(InvalidLowering("unresolved failure embedding"))
      }
  }
}

fn lower_return_goal(
  input: CompositionInput,
  net: TraceNet,
  goal: resource.GoalPredicate,
  bindings: List(BindingExpr),
) -> Result(resource.GoalPredicate, LoweringFailure) {
  let sources = list.flat_map(bindings, binding_sources)
  list.fold(sources, Ok(goal), fn(acc, source) {
    use goal <- result.try(acc)
    use value <- result.try(option.to_result(
      find(net.values, fn(value) { value.producer == source.producer }),
      InvalidLowering("return value producer unavailable"),
    ))
    let goal =
      resource.GoalAnd(
        goal,
        resource.PlaceHasToken(
          value.place,
          value.token_target,
          0,
          value.revision,
        ),
      )
    case declared_value(input, source.producer) {
      Some(#(_, Some(reference))) -> {
        use lot <- result.try(option.to_result(
          find(net.lots, fn(lot) { lot.lot == reference }),
          InvalidLowering("return resource backing unavailable"),
        ))
        Ok(resource.GoalAnd(goal, resource.PlaceHasAtLeast(lot.place, 1)))
      }
      _ -> Ok(goal)
    }
  })
}

fn lower_final_resources(
  input: CompositionInput,
  net: TraceNet,
  goal: resource.GoalPredicate,
  requirements: List(ResourceGoal),
) -> Result(#(TraceNet, resource.GoalPredicate), LoweringFailure) {
  case requirements {
    [] -> Ok(#(net, goal))
    [requirement, ..rest] -> {
      use lot <- result.try(
        case find(net.lots, fn(lot) { lot.lot == requirement.lot }) {
          Some(lot) -> Ok(lot)
          None -> {
            use declaration <- result.try(option.to_result(
              declared_lot(input, requirement.lot),
              InvalidLowering("terminal resource declaration unavailable"),
            ))
            case requirement.lot {
              InitialLot(_) ->
                Error(InvalidLowering(
                  "initial resource correspondence unavailable",
                ))
              ProducedLot(site, outcome, production) ->
                Ok(ResourceLotCorrespondence(
                  requirement.lot,
                  lot_identity(requirement.lot),
                  declaration.producer,
                  production_identity(site, outcome, production),
                  type_identity(declaration.token_type),
                  declaration.revision,
                  0,
                  declaration.provenance,
                ))
            }
          }
        },
      )
      let net = case
        list.any(net.lots, fn(candidate) { candidate.lot == lot.lot })
      {
        True -> net
        False ->
          TraceNet(
            ..net,
            lots: list.append(net.lots, [lot]),
            places: list.append(net.places, [
              resource.TypedPlace(lot.place, lot.token_type, lot.revision),
            ]),
          )
      }
      let goal =
        resource.GoalAnd(
          goal,
          resource.PlaceHasAtLeast(lot.place, requirement.multiplicity),
        )
      let goal = case requirement.multiplicity == 0 {
        True -> goal
        False ->
          resource.GoalAnd(
            goal,
            resource.PlaceHasToken(
              lot.place,
              lot.token_target,
              0,
              requirement.revision,
            ),
          )
      }
      lower_final_resources(input, net, goal, rest)
    }
  }
}

fn natural_path(path: types.ValuePath) -> Bool {
  list.all(path, fn(step) {
    case step {
      types.Index(index) -> index >= 0
      _ -> True
    }
  })
}

fn trace_token_bound(input: CompositionInput, trace: BranchTrace) -> Int {
  let initial =
    1
    + list.length(input.initial_inputs)
    + list.fold(input.initial_resources, 0, fn(total, lot) {
      total + lot.quantity
    })
  list.fold(trace.steps, initial, fn(total, step) {
    case step {
      GuardStep(_, _, _) -> total + 2
      InvocationStep(invocation, id) ->
        case outcome_contract(input, invocation.site, id) {
          None -> total
          Some(outcome) ->
            total
            + list.length(outcome.value_ports)
            + 2
            + list.fold(outcome.produced_resources, 0, fn(total, production) {
              total + production.quantity + 2
            })
        }
    }
  })
}

pub fn lower_resource_trace(
  prepared: PreparedCompositionInput,
  trace: BranchTrace,
) -> Result(#(resource.SolverInput, ResourceCorrespondence), LoweringFailure) {
  use state <- result.try(
    result.map_error(replay_trace(prepared, trace.steps), fn(_) {
      InvalidLowering(
        "trace has an invalid binding, producer, outcome, guard or revision",
      )
    }),
  )
  use _ <- result.try(
    result.map_error(check_return(prepared, state, trace.terminal), fn(_) {
      InvalidLowering("trace has an invalid typed terminal")
    }),
  )
  use _ <- result.try(check_quantity(
    prepared.input,
    trace_token_bound(prepared.input, trace),
  ))
  use net <- result.try(initial_net(prepared))
  use net <- result.try(lower_trace_steps(prepared, net, trace.steps))
  let root_control = encode_tuple(["control", "0"])
  let net =
    TraceNet(
      ..net,
      places: list.append(net.places, [
        resource.TypedPlace(root_control, "control", 0),
      ]),
      marking: resource.Marking(
        list.append(net.marking.places, [
          #(root_control, [
            resource.ColoredToken("control-root", 0, 0, resource.TokenInput),
          ]),
        ]),
      ),
    )
  let count =
    list.fold(net.marking.places, 0, fn(count, place) {
      count + list.length(place.1)
    })
  use control <- result.try(lower_phases(
    prepared.input,
    ControlNet(net, [], [], [], [], root_control, "control-root", 0, count),
    net.phases,
    0,
  ))
  use _ <- result.try(check_quantity(prepared.input, control.maximum_tokens))
  use terminal <- result.try(terminal_parts(prepared.input, trace.terminal))
  let goal =
    resource.PlaceHasToken(
      control.previous_control,
      control.previous_target,
      0,
      control.previous_revision,
    )
  use goal <- result.try(lower_return_goal(
    prepared.input,
    control.net,
    goal,
    terminal.0,
  ))
  use final <- result.try(lower_final_resources(
    prepared.input,
    control.net,
    goal,
    terminal.1,
  ))
  let #(net, goal) = final
  let edges =
    list.flat_map(control.transitions, fn(transition) {
      list.append(
        list.map(transition.input_places, fn(place) {
          #(place, transition.identity)
        }),
        list.map(transition.output_places, fn(place) {
          #(transition.identity, place)
        }),
      )
    })
  let graph =
    resource.DeclarationGraph(
      list.map(net.places, fn(place) { place.identity }),
      list.map(control.transitions, fn(transition) { transition.identity }),
      edges,
      0,
    )
  let #(max_bindings, max_steps) = case prepared.input.bounds.resource_bounds {
    None -> #(
      list.length(control.bindings),
      list.length(control.transitions) + 1,
    )
    Some(bound) -> #(bound.max_bindings, bound.max_search_steps)
  }
  let bound =
    resource.DomainBound(prepared.input.identity, 0, 0, max_bindings, max_steps)
  let input =
    resource.SolverInput(
      net.places,
      control.transitions,
      control.bindings,
      goal,
      graph,
      net.marking,
      bound,
    )
  use _ <- result.try(
    result.map_error(resource.validate(input), fn(_) {
      InvalidLowering("lowered declaration rejected")
    }),
  )
  Ok(#(
    input,
    ResourceCorrespondence(
      net.lots,
      net.values,
      control.normalized,
      control.execution_order,
    ),
  ))
}

fn strip_prefix(values: List(a), prefix: List(a)) -> Option(List(a)) {
  case prefix {
    [] -> Some(values)
    [first, ..rest] ->
      case values {
        [value, ..values] if first == value -> strip_prefix(values, rest)
        _ -> None
      }
  }
}

fn starts_with_path(path: types.ValuePath, prefix: types.ValuePath) -> Bool {
  strip_prefix(path, prefix) != None
}

pub fn initial_state(prepared: PreparedCompositionInput) -> SearchState {
  SearchState(
    list.map(prepared.input.initial_inputs, fn(initial) {
      AvailableValue(
        Initial(initial.id),
        initial.contract,
        option.map(initial.resource, InitialLot),
      )
    }),
    [],
    [],
    [],
    [],
    None,
  )
}

fn relative_assumption(
  assumption: validation.ProjectionAssumption,
  prefix: types.ValuePath,
) -> Option(validation.ProjectionAssumption) {
  case assumption {
    validation.Present(path) ->
      option.map(strip_prefix(path, prefix), validation.Present)
    validation.NonNull(path) ->
      option.map(strip_prefix(path, prefix), validation.NonNull)
    validation.Variant(path, tag) ->
      option.map(strip_prefix(path, prefix), fn(path) {
        validation.Variant(path, tag)
      })
    validation.IndexPresent(path, index) ->
      option.map(strip_prefix(path, prefix), fn(path) {
        validation.IndexPresent(path, index)
      })
  }
}

pub fn effective_projection(
  prepared: PreparedCompositionInput,
  state: SearchState,
  value: ValueRef,
) -> Result(validation.ProjectionCertificate, WitnessFailure) {
  use source <- result.try(option.to_result(
    find(state.available, fn(source) { source.producer == value.producer }),
    ProducerMismatch(value),
  ))
  let fact =
    find(list.reverse(state.facts), fn(fact) {
      fact.inspected.producer == value.producer
      && fact.refinement != None
      && starts_with_path(value.path, fact.inspected.path)
    })
  let #(contract, prefix) = case fact {
    Some(fact) -> #(
      option.unwrap(fact.refinement, source.contract),
      fact.inspected.path,
    )
    None -> #(source.contract, [])
  }
  let assumptions =
    filter_options(
      list.flat_map(
        list.filter(state.facts, fn(fact) {
          fact.inspected.producer == value.producer
        }),
        fn(fact) { fact.assumptions },
      ),
      fn(assumption) { relative_assumption(assumption, prefix) },
    )
  use path <- result.try(option.to_result(
    strip_prefix(value.path, prefix),
    GuardNotDominating(value),
  ))
  result.map_error(
    validation.project_slot(prepared.graph, contract, path, assumptions),
    ProjectionMismatch,
  )
}

pub fn project_owned(
  tag_model: Option(types.TagModel),
  value: types.SlotValue(kdl.JsonValue),
  path: types.ValuePath,
) -> types.SlotValue(kdl.JsonValue) {
  case value {
    types.Absent -> types.Absent
    types.Null -> types.Null
    types.Present(value) -> validation.value_at_path(tag_model, value, path)
  }
}

fn exact_value(
  tag_model: Option(types.TagModel),
  input: CompositionInput,
  state: SearchState,
  value: ValueRef,
) -> Option(types.SlotValue(kdl.JsonValue)) {
  case
    find(list.reverse(state.facts), fn(fact) {
      fact.inspected.producer == value.producer
      && fact.exact != None
      && starts_with_path(value.path, fact.inspected.path)
    })
  {
    Some(fact) ->
      option.then(fact.exact, fn(exact) {
        option.map(strip_prefix(value.path, fact.inspected.path), fn(path) {
          project_owned(tag_model, exact, path)
        })
      })
    None ->
      case value.producer {
        Initial(id) ->
          option.then(
            find(input.initial_inputs, fn(initial) { initial.id == id }),
            fn(initial) {
              case initial.source {
                SuppliedValue(value_at_root) ->
                  Some(project_owned(tag_model, value_at_root, value.path))
                Argument -> None
              }
            },
          )
        _ -> None
      }
  }
}

fn path_permitted(
  input: CompositionInput,
  contract: types.SlotContract,
  path: types.ValuePath,
) -> Bool {
  path == []
  || list.any(input.invocation_domain.permitted_projections, fn(projection) {
    projection.source_type == contract.type_ref && projection.path == path
  })
  || list.any(input.invocation_domain.guards, fn(guard) {
    guard.source_type == contract.type_ref && guard.path == path
  })
}

fn ensure_possible(
  prepared: PreparedCompositionInput,
  state: SearchState,
  value: ValueRef,
  contract: types.SlotContract,
) -> Result(Nil, WitnessFailure) {
  let possible = case
    exact_value(prepared.graph.profile.tag, prepared.input, state, value)
  {
    Some(exact) -> validation.accepts_slot(prepared.graph, contract, exact)
    None ->
      !slot_empty(contract, prepared.empty)
      && slot_samples(
        prepared.graph,
        contract,
        prepared.input.bounds.max_type_obligations,
      )
      != []
  }
  require(possible, MissingEvidence("no accepted value from producer"))
}

fn binding_may_have_present_null(
  prepared: PreparedCompositionInput,
  state: SearchState,
  binding: BindingExpr,
) -> Bool {
  case binding {
    Source(value, projection, _) ->
      case
        exact_value(prepared.graph.profile.tag, prepared.input, state, value)
      {
        Some(types.Present(kdl.JsonValueNull)) -> True
        Some(_) -> False
        None ->
          validation.accepts_value(
            prepared.graph,
            projection.destination.type_ref,
            kdl.JsonValueNull,
          )
      }
    Product(_, _, _) -> False
  }
}

fn discriminator_safe(
  _graph: types.SemanticGraph,
  value: types.SlotValue(kdl.JsonValue),
) -> Bool {
  case value {
    types.Present(kdl.JsonValueStr(_)) -> True
    types.Absent -> True
    _ -> False
  }
}

fn binding_discriminator_safe(
  prepared: PreparedCompositionInput,
  state: SearchState,
  binding: BindingExpr,
) -> Bool {
  case binding {
    Source(value, projection, _) ->
      case
        exact_value(prepared.graph.profile.tag, prepared.input, state, value)
      {
        Some(exact) -> discriminator_safe(prepared.graph, exact)
        None ->
          case resolved_shape(prepared.graph, projection.destination.type_ref) {
            Some(types.StringShape(spec)) ->
              option.unwrap(
                option.map(
                  finite_strings(
                    prepared.graph,
                    projection.destination.type_ref,
                    spec,
                  ),
                  fn(values) {
                    !projection.destination.nullable
                    && list.all(values, fn(value) {
                      discriminator_safe(
                        prepared.graph,
                        types.Present(kdl.JsonValueStr(value)),
                      )
                    })
                  },
                ),
                False,
              )
            _ -> False
          }
      }
    _ -> False
  }
}

fn check_binding(
  prepared: PreparedCompositionInput,
  state: SearchState,
  binding: BindingExpr,
  destination: types.SlotContract,
  constraint: SourceConstraint,
) -> Result(Nil, WitnessFailure) {
  case binding {
    Source(value, projection, compatibility) -> {
      use _ <- result.try(require(
        source_constraint_accepts(constraint, value),
        SourceConstraintMismatch(value),
      ))
      use source <- result.try(option.to_result(
        find(state.available, fn(source) { source.producer == value.producer }),
        ProducerMismatch(value),
      ))
      use _ <- result.try(require(
        path_permitted(prepared.input, source.contract, value.path),
        ProjectionMismatch(validation.CertificateMismatch(
          "projection is outside the finite domain",
        )),
      ))
      use computed <- result.try(effective_projection(prepared, state, value))
      use _ <- result.try(require(
        computed == projection,
        ProjectionMismatch(validation.CertificateMismatch(
          "source, path or dominating guard differs",
        )),
      ))
      use _ <- result.try(result.map_error(
        validation.check_projection_certificate(prepared.graph, projection),
        ProjectionMismatch,
      ))
      use _ <- result.try(ensure_possible(
        prepared,
        state,
        value,
        projection.destination,
      ))
      case compatibility {
        Inclusion(certificate) ->
          result.map(
            result.map_error(
              verify_inclusion(
                prepared.graph,
                projection.destination,
                destination,
                certificate,
              ),
              InclusionMismatch,
            ),
            fn(_) { Nil },
          )
        SuppliedBindingValue(supplied) ->
          require(
            exact_value(
              prepared.graph.profile.tag,
              prepared.input,
              state,
              value,
            )
              == Some(supplied)
              && validation.accepts_slot(
              prepared.graph,
              projection.destination,
              supplied,
            )
              && validation.accepts_slot(prepared.graph, destination, supplied),
            SuppliedValueMismatch(value),
          )
      }
    }
    Product(construction, reference, fields) -> {
      use rule <- result.try(option.to_result(
        find(prepared.input.invocation_domain.permitted_constructions, fn(rule) {
          rule.identity == construction && rule.type_ref == reference
        }),
        ConstructionMismatch(reference),
      ))
      use _ <- result.try(require(
        constraint == AnyCompatible && reference == destination.type_ref,
        ConstructionMismatch(reference),
      ))
      case resolved_shape(prepared.graph, reference) {
        Some(types.ProductShape(spec)) -> {
          use _ <- result.try(require(
            unique(list.map(fields, fn(pair) { pair.0 }))
              == list.map(fields, fn(pair) { pair.0 }),
            ConstructionMismatch(reference),
          ))
          use _ <- result.try(
            each(fields, fn(pair) {
              use field <- result.try(option.to_result(
                find(spec.fields, fn(field) { field.wire_name == pair.0 }),
                ConstructionMismatch(reference),
              ))
              use _ <- result.try(case pair.1 {
                Product(nested, _, _) ->
                  require(
                    list.contains(rule.nested_fields, #(pair.0, nested)),
                    ConstructionMismatch(reference),
                  )
                _ -> Ok(Nil)
              })
              use _ <- result.try(require(
                field.slot.nullable
                  || !binding_may_have_present_null(prepared, state, pair.1),
                ConstructionMismatch(reference),
              ))
              use _ <- result.try(check_binding(
                prepared,
                state,
                pair.1,
                field.slot,
                field_constraint(rule, pair.0),
              ))
              use _ <- result.try(require(
                graph_field_allowed(prepared.graph, pair.0),
                ConstructionMismatch(reference),
              ))
              require(
                option.unwrap(
                  option.map(prepared.graph.profile.tag, fn(model) {
                    pair.0 != model.key
                  }),
                  True,
                )
                  || binding_discriminator_safe(prepared, state, pair.1),
                ConstructionMismatch(reference),
              )
            }),
          )
          use _ <- result.try(require(
            list.all(spec.fields, fn(field) {
              !field_required(rule, field)
              || list.any(fields, fn(pair) { pair.0 == field.wire_name })
            }),
            ConstructionMismatch(reference),
          ))
          case validation.meaning_obligations(prepared.graph, [reference]) {
            [] -> Ok(Nil)
            reasons -> Error(InclusionMismatch(UndefinedMeaning(reasons)))
          }
        }
        _ -> Error(ConstructionMismatch(reference))
      }
    }
  }
}

fn graph_field_allowed(_graph: types.SemanticGraph, _name: String) -> Bool {
  True
}

fn outcome_empty(
  prepared: PreparedCompositionInput,
  outcome: OutcomeContract,
) -> Bool {
  list.all(outcome.value_ports, fn(port) {
    validation.meaning_obligations(prepared.graph, [port.contract.type_ref])
    == []
  })
  && list.any(outcome.value_ports, fn(port) {
    slot_empty(port.contract, prepared.empty)
  })
}

fn must_handle_failure(origin: FailureOrigin) -> Bool {
  case origin {
    FunctionFailure(_, _) | GuardFailure(_, GuardRejected) -> True
    _ -> False
  }
}

fn failure_pending(state: SearchState) -> Bool {
  option.unwrap(option.map(state.pending_failure, must_handle_failure), False)
}

fn handles_pending(function: FunctionSignature, state: SearchState) -> Bool {
  function.handles_failure == state.pending_failure
  || function.handles_failure == None
  && !failure_pending(state)
}

fn state_lots(
  input: CompositionInput,
  state: SearchState,
) -> List(ResourceLotRef) {
  list.append(
    list.map(input.initial_resources, fn(lot) { InitialLot(lot.id) }),
    list.flat_map(state.trace, fn(step) {
      case step {
        InvocationStep(invocation, outcome) ->
          option.unwrap(
            option.map(
              outcome_contract(input, invocation.site, outcome),
              fn(outcome_contract) {
                list.map(outcome_contract.produced_resources, fn(production) {
                  ProducedLot(invocation.site, outcome, production.id)
                })
              },
            ),
            [],
          )
        _ -> []
      }
    }),
  )
}

fn resource_identity_accepts(
  constraint: ResourceIdentityConstraint,
  producer: ResourceProducer,
) -> Bool {
  case constraint {
    AnyResource -> True
    Exactly(expected) -> expected == producer
  }
}

fn failure_value_used(
  state: SearchState,
  origin: FailureOrigin,
  sources: List(ValueRef),
) -> Bool {
  case origin {
    FunctionFailure(function, outcome) -> {
      let site =
        list.find_map(list.reverse(state.trace), fn(step) {
          case step {
            InvocationStep(invocation, actual)
              if invocation.function == function && actual == outcome
            -> Ok(invocation.site)
            _ -> Error(Nil)
          }
        })
      case site {
        Error(_) -> False
        Ok(site) ->
          list.any(sources, fn(source) {
            case source.producer {
              InvocationOutcome(actual_site, actual_outcome, _) ->
                actual_site == site && actual_outcome == outcome
              _ -> False
            }
          })
      }
    }
    GuardFailure(guard, arm) ->
      option.unwrap(
        option.map(
          find(list.reverse(state.facts), fn(fact) {
            fact.guard == guard && fact.arm == arm
          }),
          fn(fact) {
            list.any(sources, fn(source) {
              source.producer == fact.inspected.producer
              && starts_with_path(source.path, fact.inspected.path)
            })
          },
        ),
        False,
      )
  }
}

fn check_invocation(
  prepared: PreparedCompositionInput,
  state: SearchState,
  invocation: InvocationPlan,
) -> Result(Nil, WitnessFailure) {
  use function <- result.try(option.to_result(
    site_signature(prepared.input, invocation.site),
    SignatureMismatch(invocation.site),
  ))
  use _ <- result.try(require(
    function.reference == invocation.function
      && !list.contains(state.used_sites, invocation.site)
      && handles_pending(function, state),
    SignatureMismatch(invocation.site),
  ))
  use _ <- result.try(case function.form {
    Operation(_) -> {
      let reasons =
        validation.meaning_obligations(
          prepared.graph,
          list.append(
            list.map(function.inputs, fn(port) { port.contract.type_ref }),
            list.flat_map(function.outcomes, fn(outcome) {
              list.map(outcome.value_ports, fn(port) { port.contract.type_ref })
            }),
          ),
        )
      case reasons {
        [] -> Ok(Nil)
        reasons -> Error(InclusionMismatch(UndefinedMeaning(reasons)))
      }
    }
    _ -> Ok(Nil)
  })
  use _ <- result.try(require(
    !list.any(prepared.input.explicit_order, fn(pair) {
      pair.1 == invocation.site && !list.contains(state.used_sites, pair.0)
    }),
    RankViolation,
  ))
  use _ <- result.try(require(
    list.length(invocation.bindings) == list.length(function.inputs)
      && list.length(invocation.resources)
      == list.length(function.resource_inputs),
    MissingBinding(invocation.site.value),
  ))
  use _ <- result.try(
    each(function.inputs, fn(port) {
      let bindings =
        list.filter(invocation.bindings, fn(pair) { pair.0 == port.id })
      case bindings {
        [pair] -> {
          use _ <- result.try(check_binding(
            prepared,
            state,
            pair.1,
            port.contract,
            port.source_constraint,
          ))
          case port.resource_requirement {
            None -> Ok(Nil)
            Some(id) -> {
              use resource_binding <- result.try(option.to_result(
                find(invocation.resources, fn(binding) {
                  binding.requirement == id
                }),
                MissingBinding(id.value),
              ))
              let sources = binding_sources(pair.1)
              require(
                case sources {
                  [source] ->
                    option.then(
                      declared_value(prepared.input, source.producer),
                      fn(pair) { pair.1 },
                    )
                    == Some(resource_binding.lot)
                  _ -> False
                },
                ResourceLoweringMismatch("input backing lot differs"),
              )
            }
          }
        }
        _ -> Error(MissingBinding(port.id.value))
      }
    }),
  )
  let available_lots = state_lots(prepared.input, state)
  use _ <- result.try(
    each(function.resource_inputs, fn(requirement) {
      case
        list.filter(invocation.resources, fn(binding) {
          binding.requirement == requirement.id
        })
      {
        [binding] -> {
          use _ <- result.try(require(
            list.contains(available_lots, binding.lot),
            MissingBinding(requirement.id.value),
          ))
          use lot <- result.try(option.to_result(
            declared_lot(prepared.input, binding.lot),
            ResourceLoweringMismatch("resource lot unresolved"),
          ))
          use _ <- result.try(require(
            lot.revision == requirement.required_revision
              && resource_identity_accepts(requirement.identity, lot.producer),
            ResourceLoweringMismatch("resource revision/identity differs"),
          ))
          result.map(
            result.map_error(
              verify_inclusion(
                prepared.graph,
                present_contract(lot.token_type),
                present_contract(requirement.token_type),
                binding.inclusion,
              ),
              InclusionMismatch,
            ),
            fn(_) { Nil },
          )
        }
        _ -> Error(MissingBinding(requirement.id.value))
      }
    }),
  )
  case function.handles_failure {
    None -> Ok(Nil)
    Some(origin) ->
      require(
        failure_value_used(
          state,
          origin,
          list.flat_map(invocation.bindings, fn(pair) {
            binding_sources(pair.1)
          }),
        ),
        MissingEvidence("handler does not receive the actual failure value"),
      )
  }
}

fn after_invocation(
  state: SearchState,
  invocation: InvocationPlan,
  outcome: OutcomeContract,
) -> SearchState {
  let available =
    list.map(outcome.value_ports, fn(port) {
      AvailableValue(
        InvocationOutcome(invocation.site, outcome.id, port.id),
        port.contract,
        option.map(port.resource_production, fn(production) {
          ProducedLot(invocation.site, outcome.id, production)
        }),
      )
    })
  SearchState(
    ..state,
    available: list.append(state.available, available),
    used_sites: list.append(state.used_sites, [invocation.site]),
    trace: list.append(state.trace, [InvocationStep(invocation, outcome.id)]),
    pending_failure: case outcome.form {
      Success -> None
      DeclaredFailure -> Some(FunctionFailure(invocation.function, outcome.id))
    },
  )
}

pub fn guard_declaration(
  input: CompositionInput,
  id: GuardId,
) -> Option(DeclaredGuard) {
  find(input.invocation_domain.guards, fn(guard) { guard.id == id })
}

fn guard_value_failure(
  reference: types.TypeRef,
  condition: types.ValueCondition,
) -> types.ValueFailure {
  types.ValueFailure(
    reference,
    types.DefinitionRef(reference.source, reference.definition_name),
    types.occurrence(reference),
    [],
    condition,
    types.Present(kdl.JsonValueStr("guard input")),
    [reference],
  )
}

pub fn evaluate_guard_arm(
  graph: types.SemanticGraph,
  guard: DeclaredGuard,
  inspected: types.SlotValue(kdl.JsonValue),
) -> Result(GuardArm, types.ValueDecision) {
  case guard.kind {
    Validate(contract) ->
      case validation.validate_slot(graph, contract, inspected) {
        Ok(_) -> Ok(GuardAccepted)
        Error(validation.Rejected(_)) -> Ok(GuardRejected)
        Error(validation.Unresolved(reasons)) ->
          Error(types.UnresolvedValue(reasons))
      }
    Presence ->
      Ok(case inspected {
        types.Absent -> GuardAbsent
        types.Null -> GuardNull
        types.Present(_) -> GuardPresent
      })
    Variants ->
      case inspected, graph.profile.tag {
        types.Absent, _ -> Ok(GuardAbsent)
        types.Null, _ -> Ok(GuardNull)
        types.Present(kdl.JsonValueObj(members)), Some(model) ->
          case list.key_find(members, model.key) {
            Ok(kdl.JsonValueStr(tag)) -> {
              let assumptions =
                filter_options(
                  list.index_map(guard.path, fn(step, index) { #(step, index) }),
                  fn(pair) {
                    case pair.0 {
                      types.Variant(tag) ->
                        Some(validation.Variant(
                          list.take(guard.path, pair.1),
                          tag,
                        ))
                      _ -> None
                    }
                  },
                )
              case
                validation.project_slot(
                  graph,
                  present_contract(guard.source_type),
                  guard.path,
                  assumptions,
                )
              {
                Error(validation.ProjectionUnresolved(reasons)) ->
                  Error(types.UnresolvedValue(reasons))
                Error(_) ->
                  Error(
                    types.RejectedValue(guard_value_failure(
                      guard.source_type,
                      types.InvalidDataModelCondition,
                    )),
                  )
                Ok(projection) ->
                  case resolved_shape(graph, projection.destination.type_ref) {
                    Some(types.TaggedUnionShape(spec)) ->
                      case
                        find(spec.branches, fn(branch) {
                          branch.wire_tag == tag
                        })
                      {
                        Some(_) -> Ok(GuardVariant(tag))
                        None ->
                          case
                            list.any(spec.branches, fn(branch) {
                              branch.selector == types.Otherwise
                            })
                          {
                            True -> Ok(UnknownVariant)
                            False ->
                              Error(
                                types.RejectedValue(guard_value_failure(
                                  guard.source_type,
                                  types.NoBranchSelectedCondition,
                                )),
                              )
                          }
                      }
                    _ ->
                      Error(
                        types.RejectedValue(guard_value_failure(
                          guard.source_type,
                          types.InvalidDataModelCondition,
                        )),
                      )
                  }
              }
            }
            _ ->
              Error(
                types.RejectedValue(guard_value_failure(
                  guard.source_type,
                  types.InvalidTagCondition,
                )),
              )
          }
        _, _ ->
          Error(
            types.RejectedValue(guard_value_failure(
              guard.source_type,
              types.WrongValueKindCondition("tagged object"),
            )),
          )
      }
  }
}

fn guard_arms(
  prepared: PreparedCompositionInput,
  state: SearchState,
  guard: DeclaredGuard,
  inspected: ValueRef,
) -> Result(List(GuardArm), WitnessFailure) {
  use _ <- result.try(require(
    !list.contains(state.used_guards, guard.id),
    GuardNotDominating(inspected),
  ))
  use source <- result.try(option.to_result(
    find(state.available, fn(source) { source.producer == inspected.producer }),
    ProducerMismatch(inspected),
  ))
  use _ <- result.try(require(
    source.contract.type_ref == guard.source_type
      && inspected.path == guard.path,
    GuardNotDominating(inspected),
  ))
  use projected <- result.try(effective_projection(prepared, state, inspected))
  use _ <- result.try(case guard.kind {
    Validate(contract) ->
      case validation.meaning_obligations(prepared.graph, [contract.type_ref]) {
        [] -> Ok(Nil)
        reasons -> Error(InclusionMismatch(UndefinedMeaning(reasons)))
      }
    _ -> Ok(Nil)
  })
  case
    exact_value(prepared.graph.profile.tag, prepared.input, state, inspected)
  {
    Some(value) ->
      result.map(
        result.map_error(
          evaluate_guard_arm(prepared.graph, guard, value),
          fn(_) { MissingEvidence("guard value is not defined") },
        ),
        fn(arm) { [arm] },
      )
    None ->
      case guard.kind {
        Validate(destination) ->
          case
            slots_disjoint(
              prepared.graph,
              projected.destination,
              destination,
              prepared.empty,
            )
          {
            True -> Ok([GuardRejected])
            False ->
              case
                check_assignable(
                  prepared.graph,
                  projected.destination,
                  destination,
                  prepared.input.bounds.max_type_obligations,
                )
              {
                Compatible(_) -> Ok([GuardAccepted])
                _ -> Ok([GuardAccepted, GuardRejected])
              }
          }
        Presence | Variants -> {
          let absent = case projected.destination.required {
            True -> []
            False -> [GuardAbsent]
          }
          let null = case projected.destination.nullable {
            True -> [GuardNull]
            False -> []
          }
          use present <- result.try(
            case list.contains(prepared.empty, projected.destination.type_ref) {
              True -> Ok([])
              False ->
                case guard.kind {
                  Presence -> Ok([GuardPresent])
                  _ ->
                    case
                      resolved_shape(
                        prepared.graph,
                        projected.destination.type_ref,
                      )
                    {
                      Some(types.TaggedUnionShape(spec)) ->
                        Ok(
                          list.append(
                            list.map(
                              list.filter(spec.branches, fn(branch) {
                                !list.contains(prepared.empty, branch.target)
                              }),
                              fn(branch) { GuardVariant(branch.wire_tag) },
                            ),
                            case
                              list.any(spec.branches, fn(branch) {
                                branch.selector == types.Otherwise
                              })
                            {
                              True -> [UnknownVariant]
                              False -> []
                            },
                          ),
                        )
                      _ -> Error(GuardNotDominating(inspected))
                    }
                }
            },
          )
          Ok(list.flatten([absent, null, present]))
        }
      }
  }
}

fn after_guard(
  prepared: PreparedCompositionInput,
  state: SearchState,
  guard: DeclaredGuard,
  inspected: ValueRef,
  arm: GuardArm,
) -> Result(SearchState, WitnessFailure) {
  use projected <- result.try(effective_projection(prepared, state, inspected))
  use fact <- result.try(case arm {
    GuardPresent | UnknownVariant ->
      Ok(BranchFact(
        guard.id,
        inspected,
        arm,
        Some(types.SlotContract(projected.destination.type_ref, True, False)),
        [],
        None,
      ))
    GuardVariant(tag) ->
      Ok(BranchFact(
        guard.id,
        inspected,
        arm,
        None,
        [validation.Variant(inspected.path, tag)],
        None,
      ))
    GuardAbsent ->
      Ok(BranchFact(guard.id, inspected, arm, None, [], Some(types.Absent)))
    GuardNull ->
      Ok(BranchFact(guard.id, inspected, arm, None, [], Some(types.Null)))
    GuardAccepted ->
      case guard.kind {
        Validate(contract) ->
          Ok(BranchFact(guard.id, inspected, arm, Some(contract), [], None))
        _ -> Error(GuardNotDominating(inspected))
      }
    GuardRejected -> Ok(BranchFact(guard.id, inspected, arm, None, [], None))
  })
  let fact = case
    exact_value(prepared.graph.profile.tag, prepared.input, state, inspected)
  {
    Some(exact) -> BranchFact(..fact, exact: Some(exact))
    None -> fact
  }
  let failed_arm = case arm {
    GuardAbsent | GuardNull | UnknownVariant | GuardRejected -> True
    _ -> False
  }
  let pending = case !failure_pending(state) && failed_arm {
    True -> Some(GuardFailure(guard.id, arm))
    False -> state.pending_failure
  }
  Ok(
    SearchState(
      ..state,
      used_guards: list.append(state.used_guards, [guard.id]),
      facts: list.append(state.facts, [fact]),
      trace: list.append(state.trace, [GuardStep(guard.id, inspected, arm)]),
      pending_failure: pending,
    ),
  )
}

pub fn check_return(
  prepared: PreparedCompositionInput,
  state: SearchState,
  terminal: ReturnPlan,
) -> Result(Bool, WitnessFailure) {
  case terminal {
    ReturnSuccess(outputs) -> {
      use _ <- result.try(require(
        !failure_pending(state)
          && list.length(outputs) == list.length(prepared.input.goal.outputs),
        GoalMismatch,
      ))
      use _ <- result.try(
        each(prepared.input.goal.outputs, fn(goal) {
          case list.filter(outputs, fn(pair) { pair.0 == goal.id }) {
            [pair] ->
              check_binding(
                prepared,
                state,
                pair.1,
                goal.contract,
                goal.source_constraint,
              )
            _ -> Error(GoalMismatch)
          }
        }),
      )
      Ok(True)
    }
    ReturnFailure(id, value) -> {
      use embedding <- result.try(option.to_result(
        find(prepared.input.goal.failures, fn(embedding) { embedding.id == id }),
        FailureEmbeddingMismatch(id),
      ))
      use _ <- result.try(require(
        state.pending_failure == Some(embedding.origin),
        FailureEmbeddingMismatch(id),
      ))
      use _ <- result.try(check_binding(
        prepared,
        state,
        value,
        embedding.contract,
        AnyCompatible,
      ))
      use _ <- result.try(require(
        failure_value_used(state, embedding.origin, binding_sources(value)),
        FailureEmbeddingMismatch(id),
      ))
      Ok(False)
    }
  }
}

fn replay_trace(
  prepared: PreparedCompositionInput,
  steps: List(TraceStep),
) -> Result(SearchState, WitnessFailure) {
  replay_trace_steps(prepared, initial_state(prepared), steps)
}

fn replay_trace_steps(
  prepared: PreparedCompositionInput,
  state: SearchState,
  steps: List(TraceStep),
) -> Result(SearchState, WitnessFailure) {
  case steps {
    [] -> Ok(state)
    [InvocationStep(invocation, id), ..rest] -> {
      use _ <- result.try(check_invocation(prepared, state, invocation))
      use outcome <- result.try(option.to_result(
        outcome_contract(prepared.input, invocation.site, id),
        IncompleteBranchCoverage(id.value),
      ))
      use _ <- result.try(require(
        !outcome_empty(prepared, outcome),
        IncompleteBranchCoverage(id.value),
      ))
      replay_trace_steps(
        prepared,
        after_invocation(state, invocation, outcome),
        rest,
      )
    }
    [GuardStep(id, inspected, arm), ..rest] -> {
      use guard <- result.try(option.to_result(
        guard_declaration(prepared.input, id),
        GuardNotDominating(inspected),
      ))
      use arms <- result.try(guard_arms(prepared, state, guard, inspected))
      use _ <- result.try(require(
        list.contains(arms, arm),
        GuardNotDominating(inspected),
      ))
      use state <- result.try(after_guard(
        prepared,
        state,
        guard,
        inspected,
        arm,
      ))
      replay_trace_steps(prepared, state, rest)
    }
  }
}

fn shape_domain(shape: types.TypeShape) -> Int {
  case shape {
    types.BooleanShape(_) -> 0
    types.IntegerShape(_) | types.DecimalShape(_) -> 1
    types.StringShape(_) | types.BytesShape(_) | types.RawBodyShape(_) -> 2
    types.UnitShape -> 3
    types.ArrayShape(_) -> 4
    types.ProductShape(_)
    | types.TaggedUnionShape(_)
    | types.SealedShape(_, _) -> 5
    types.UnknownShape(_) -> 6
    types.Never | types.AliasShape(_, _) | types.OpaqueShape(_) -> 7
  }
}

fn slots_disjoint(
  graph: types.SemanticGraph,
  source: types.SlotContract,
  destination: types.SlotContract,
  empty: List(types.TypeRef),
) -> Bool {
  case
    !source.required
    && !destination.required
    || source.nullable
    && destination.nullable
  {
    True -> False
    False ->
      case
        list.contains(empty, source.type_ref)
        || list.contains(empty, destination.type_ref)
      {
        True -> True
        False ->
          case
            resolved_shape(graph, source.type_ref),
            resolved_shape(graph, destination.type_ref)
          {
            Some(types.IntegerShape(s)), Some(types.IntegerShape(d)) -> {
              let #(smin, smax) = integer_bounds(graph.profile, s)
              let #(dmin, dmax) = integer_bounds(graph.profile, d)
              case finite_integers(graph.profile, s) {
                Some(values) ->
                  list.all(values, fn(value) {
                    !within(value, dmin, dmax)
                    || option.unwrap(
                      option.map(d.enum_values, fn(values) {
                        !list.contains(values, value)
                      }),
                      False,
                    )
                  })
                None ->
                  case finite_integers(graph.profile, d) {
                    Some(values) ->
                      list.all(values, fn(value) { !within(value, smin, smax) })
                    None ->
                      contradictory(
                        max_lower(smin, dmin),
                        min_upper(smax, dmax),
                      )
                  }
              }
            }
            Some(types.BooleanShape(s)), Some(types.BooleanShape(d)) ->
              case s.const_value, d.const_value {
                Some(s), Some(d) -> s != d
                _, _ -> False
              }
            Some(types.StringShape(s)), Some(types.StringShape(d)) ->
              case finite_strings(graph, source.type_ref, s) {
                Some(values) ->
                  list.all(values, fn(value) {
                    case
                      validation.declared_value_decision(
                        graph,
                        destination.type_ref,
                        kdl.JsonValueStr(value),
                      )
                    {
                      types.RejectedValue(_) -> True
                      _ -> False
                    }
                  })
                None ->
                  case finite_strings(graph, destination.type_ref, d) {
                    Some(values) ->
                      list.all(values, fn(value) {
                        case
                          validation.declared_value_decision(
                            graph,
                            source.type_ref,
                            kdl.JsonValueStr(value),
                          )
                        {
                          types.RejectedValue(_) -> True
                          _ -> False
                        }
                      })
                    None ->
                      list.any(
                        [types.Utf8Bytes, types.UnicodeScalars, types.Graphemes],
                        fn(unit) {
                          let sb = length_bound(s, unit)
                          let db = length_bound(d, unit)
                          contradictory(
                            max_lower(sb.minimum, db.minimum),
                            min_upper(sb.maximum, db.maximum),
                          )
                        },
                      )
                  }
              }
            Some(types.ArrayShape(s)), Some(types.ArrayShape(d)) ->
              contradictory(
                max_lower(s.min_length, d.min_length),
                min_upper(s.max_length, d.max_length),
              )
            Some(types.TaggedUnionShape(s)), Some(types.TaggedUnionShape(d)) ->
              !list.any(s.branches, fn(source_branch) {
                list.any(d.branches, fn(destination_branch) {
                  source_branch.wire_tag == destination_branch.wire_tag
                  && source_branch.selector == destination_branch.selector
                })
              })
            Some(types.UnknownShape(types.AnyValue)), Some(_)
            | Some(_), Some(types.UnknownShape(types.AnyValue))
            -> False
            Some(s), Some(d) ->
              shape_domain(s) < 6
              && shape_domain(d) < 6
              && shape_domain(s) != shape_domain(d)
            _, _ -> False
          }
      }
  }
}

fn evaluated_binding(
  tag_model: Option(types.TagModel),
  binding: BindingExpr,
  values: List(#(ProducerRef, types.SlotValue(kdl.JsonValue))),
) -> Option(types.SlotValue(kdl.JsonValue)) {
  case binding {
    Source(value, _, _) ->
      option.map(find(values, fn(pair) { pair.0 == value.producer }), fn(pair) {
        project_owned(tag_model, pair.1, value.path)
      })
    Product(_, _, fields) -> {
      let members =
        list.fold(fields, Some([]), fn(acc, pair) {
          option.then(acc, fn(members) {
            option.map(evaluated_binding(tag_model, pair.1, values), fn(value) {
              case value {
                types.Absent -> members
                types.Null ->
                  list.append(members, [#(pair.0, kdl.JsonValueNull)])
                types.Present(value) -> list.append(members, [#(pair.0, value)])
              }
            })
          })
        })
      option.map(members, fn(members) {
        types.Present(kdl.JsonValueObj(members))
      })
    }
  }
}

pub fn verify_value_models(
  prepared: PreparedCompositionInput,
  state: SearchState,
  values: List(#(ProducerRef, types.SlotValue(kdl.JsonValue))),
) -> Result(Nil, WitnessFailure) {
  use _ <- result.try(require(
    list.length(values) == list.length(state.available),
    MissingEvidence("producer value coverage"),
  ))
  use _ <- result.try(
    each(state.available, fn(source) {
      let value_ref = ValueRef(source.producer, [])
      case list.filter(values, fn(pair) { pair.0 == source.producer }) {
        [pair] -> {
          use _ <- result.try(require(
            validation.accepts_slot(prepared.graph, source.contract, pair.1),
            ProducerMismatch(value_ref),
          ))
          case source.producer {
            Initial(id) ->
              case
                find(prepared.input.initial_inputs, fn(initial) {
                  initial.id == id
                })
              {
                Some(InitialInput(_, _, SuppliedValue(expected), _)) ->
                  require(expected == pair.1, SuppliedValueMismatch(value_ref))
                _ -> Ok(Nil)
              }
            _ -> Ok(Nil)
          }
        }
        _ -> Error(ProducerMismatch(value_ref))
      }
    }),
  )
  each(state.trace, fn(step) {
    case step {
      GuardStep(id, inspected, arm) -> {
        use guard <- result.try(option.to_result(
          guard_declaration(prepared.input, id),
          GuardNotDominating(inspected),
        ))
        use value <- result.try(option.to_result(
          find(values, fn(pair) { pair.0 == inspected.producer }),
          ProducerMismatch(inspected),
        ))
        require(
          evaluate_guard_arm(
            prepared.graph,
            guard,
            project_owned(prepared.graph.profile.tag, value.1, inspected.path),
          )
            == Ok(arm),
          GuardNotDominating(inspected),
        )
      }
      InvocationStep(invocation, _) -> {
        use function <- result.try(option.to_result(
          site_signature(prepared.input, invocation.site),
          SignatureMismatch(invocation.site),
        ))
        each(function.inputs, fn(port) {
          use binding <- result.try(option.to_result(
            find(invocation.bindings, fn(pair) { pair.0 == port.id }),
            MissingBinding(port.id.value),
          ))
          use value <- result.try(option.to_result(
            evaluated_binding(prepared.graph.profile.tag, binding.1, values),
            MissingBinding(port.id.value),
          ))
          require(
            validation.accepts_slot(prepared.graph, port.contract, value),
            MissingEvidence("no accepted actual input"),
          )
        })
      }
    }
  })
}

pub fn verify_return_values(
  prepared: PreparedCompositionInput,
  terminal: ReturnPlan,
  values: List(#(ProducerRef, types.SlotValue(kdl.JsonValue))),
) -> Result(Nil, WitnessFailure) {
  case terminal {
    ReturnSuccess(outputs) ->
      each(prepared.input.goal.outputs, fn(goal) {
        use binding <- result.try(option.to_result(
          find(outputs, fn(pair) { pair.0 == goal.id }),
          GoalMismatch,
        ))
        use value <- result.try(option.to_result(
          evaluated_binding(prepared.graph.profile.tag, binding.1, values),
          GoalMismatch,
        ))
        require(
          validation.accepts_slot(prepared.graph, goal.contract, value),
          GoalMismatch,
        )
      })
    ReturnFailure(id, binding) -> {
      use embedding <- result.try(option.to_result(
        find(prepared.input.goal.failures, fn(embedding) { embedding.id == id }),
        GoalMismatch,
      ))
      use value <- result.try(option.to_result(
        evaluated_binding(prepared.graph.profile.tag, binding, values),
        GoalMismatch,
      ))
      require(
        validation.accepts_slot(prepared.graph, embedding.contract, value),
        GoalMismatch,
      )
    }
  }
}

pub fn resource_trace_meaning(
  prepared: PreparedCompositionInput,
  correspondence: ResourceCorrespondence,
) -> Result(Nil, UnresolvedObligation) {
  each(correspondence.lots, fn(lot) {
    case declared_lot(prepared.input, lot.lot) {
      None -> Ok(Nil)
      Some(declaration) -> {
        use _ <- result.try(
          case
            validation.meaning_obligations(prepared.graph, [
              declaration.token_type,
            ])
          {
            [] -> Ok(Nil)
            reasons -> Error(UnresolvedMeaning(reasons))
          },
        )
        let contract = present_contract(declaration.token_type)
        require(
          lot.quantity == 0
            || samples(
            prepared.graph,
            declaration.token_type,
            [],
            prepared.input.bounds.max_type_obligations,
          )
            != [],
          UnresolvedTypeObligation(None, [
            type_obligation(
              TypePair(contract, contract, None),
              TypeInhabitation,
            ),
          ]),
        )
      }
    }
  })
}

pub type CandidateBudget {
  CandidateBudget(
    bindings: Int,
    branch_nodes: Int,
    exhausted_bindings: Bool,
    exhausted_branches: Bool,
  )
}

pub fn fresh_budget() -> CandidateBudget {
  CandidateBudget(0, 0, False, False)
}

pub type Enumeration {
  Enumeration(
    terminals: List(ReturnPlan),
    choices: List(ChoiceSkeleton),
    unknown: List(UnresolvedObligation),
    failures: List(ConnectionFailure),
    missing: List(MissingSupply),
    budget: CandidateBudget,
  )
}

type EnumerationContext {
  EnumerationContext(
    prepared: PreparedCompositionInput,
    state: SearchState,
    budget: CandidateBudget,
    unknown: List(UnresolvedObligation),
    failures: List(ConnectionFailure),
    missing: List(MissingSupply),
  )
}

fn take_binding(context: EnumerationContext) -> #(Bool, EnumerationContext) {
  case
    context.budget.bindings
    >= context.prepared.input.bounds.max_binding_candidates
  {
    True -> #(
      False,
      EnumerationContext(
        ..context,
        budget: CandidateBudget(..context.budget, exhausted_bindings: True),
      ),
    )
    False -> #(
      True,
      EnumerationContext(
        ..context,
        budget: CandidateBudget(
          ..context.budget,
          bindings: context.budget.bindings + 1,
        ),
      ),
    )
  }
}

fn add_unknown(
  context: EnumerationContext,
  obligation: UnresolvedObligation,
) -> EnumerationContext {
  EnumerationContext(
    ..context,
    unknown: list.append(context.unknown, [obligation]),
  )
}

fn add_failure(
  context: EnumerationContext,
  value: Option(ValueRef),
  destination: types.SlotContract,
  certificate: CounterexampleCertificate,
) -> EnumerationContext {
  EnumerationContext(
    ..context,
    failures: list.append(context.failures, [
      ConnectionFailure(value, destination, certificate),
    ]),
  )
}

fn enumeration_error(
  context: EnumerationContext,
  failure: WitnessFailure,
) -> EnumerationContext {
  case failure {
    ProjectionMismatch(validation.ProjectionUnresolved(reasons))
    | InclusionMismatch(UndefinedMeaning(reasons)) ->
      add_unknown(context, UnresolvedMeaning(reasons))
    _ -> context
  }
}

fn compatibility(
  context: EnumerationContext,
  source: types.SlotContract,
  destination: types.SlotContract,
  value: Option(ValueRef),
) -> #(Option(InclusionCertificate), EnumerationContext) {
  case
    check_assignable(
      context.prepared.graph,
      source,
      destination,
      context.prepared.input.bounds.max_type_obligations,
    )
  {
    Compatible(certificate) -> #(Some(certificate), context)
    Incompatible(certificate) -> #(
      None,
      add_failure(context, value, destination, certificate),
    )
    CompatibilityUnknown(obligations) -> #(
      None,
      add_unknown(context, UnresolvedTypeObligation(value, obligations)),
    )
  }
}

fn source_binding(
  context: EnumerationContext,
  value: ValueRef,
  destination: types.SlotContract,
  constraint: SourceConstraint,
) -> #(Option(BindingExpr), EnumerationContext) {
  case effective_projection(context.prepared, context.state, value) {
    Error(failure) -> #(None, enumeration_error(context, failure))
    Ok(projection) ->
      case
        exact_value(
          context.prepared.graph.profile.tag,
          context.prepared.input,
          context.state,
          value,
        )
      {
        Some(supplied) ->
          case
            validation.validate_slot(
              context.prepared.graph,
              projection.destination,
              supplied,
            )
          {
            Error(validation.Unresolved(reasons)) -> #(
              None,
              add_unknown(context, UnresolvedMeaning(reasons)),
            )
            Error(_) -> #(None, context)
            Ok(_) ->
              case
                validation.validate_slot(
                  context.prepared.graph,
                  destination,
                  supplied,
                )
              {
                Ok(_) -> {
                  let binding =
                    Source(value, projection, SuppliedBindingValue(supplied))
                  #(
                    case
                      check_binding(
                        context.prepared,
                        context.state,
                        binding,
                        destination,
                        constraint,
                      )
                    {
                      Ok(_) -> Some(binding)
                      _ -> None
                    },
                    context,
                  )
                }
                Error(validation.Rejected(failure)) -> #(
                  None,
                  add_failure(
                    context,
                    Some(value),
                    destination,
                    CounterexampleCertificate(
                      semantic_basis(context.prepared.graph),
                      projection.destination,
                      destination,
                      supplied,
                      failure,
                    ),
                  ),
                )
                Error(validation.Unresolved(reasons)) -> #(
                  None,
                  add_unknown(context, UnresolvedMeaning(reasons)),
                )
              }
          }
        None ->
          case slot_empty(projection.destination, context.prepared.empty) {
            True -> #(None, context)
            False ->
              case
                slot_samples(
                  context.prepared.graph,
                  projection.destination,
                  context.prepared.input.bounds.max_type_obligations,
                )
              {
                [] -> #(
                  None,
                  add_unknown(
                    context,
                    Inhabitation(value.producer, projection.destination),
                  ),
                )
                _ -> {
                  let #(certificate, context) =
                    compatibility(
                      context,
                      projection.destination,
                      destination,
                      Some(value),
                    )
                  case certificate {
                    None -> #(None, context)
                    Some(certificate) -> {
                      let binding =
                        Source(value, projection, Inclusion(certificate))
                      #(
                        case
                          check_binding(
                            context.prepared,
                            context.state,
                            binding,
                            destination,
                            constraint,
                          )
                        {
                          Ok(_) -> Some(binding)
                          _ -> None
                        },
                        context,
                      )
                    }
                  }
                }
              }
          }
      }
  }
}

fn source_bindings(
  context: EnumerationContext,
  destination: types.SlotContract,
  constraint: SourceConstraint,
) -> #(List(BindingExpr), EnumerationContext) {
  list.fold(context.state.available, #([], context), fn(acc, source) {
    let #(bindings, context) = acc
    case
      slot_empty(source.contract, context.prepared.empty)
      || context.budget.exhausted_bindings
    {
      True -> acc
      False -> {
        let paths =
          unique(
            list.flatten([
              [[]],
              list.map(
                list.filter(
                  context.prepared.input.invocation_domain.permitted_projections,
                  fn(projection) {
                    projection.source_type == source.contract.type_ref
                  },
                ),
                fn(projection) { projection.path },
              ),
              list.map(
                list.filter(context.state.facts, fn(fact) {
                  fact.inspected.producer == source.producer
                }),
                fn(fact) { fact.inspected.path },
              ),
            ]),
          )
        list.fold(paths, #(bindings, context), fn(acc, path) {
          case
            source_constraint_accepts(
              constraint,
              ValueRef(source.producer, path),
            )
          {
            False -> acc
            True -> {
              let #(bindings, context) = acc
              let #(allowed, context) = take_binding(context)
              case allowed {
                False -> #(bindings, context)
                True -> {
                  let #(binding, context) =
                    source_binding(
                      context,
                      ValueRef(source.producer, path),
                      destination,
                      constraint,
                    )
                  #(
                    case binding {
                      None -> bindings
                      Some(binding) -> list.append(bindings, [binding])
                    },
                    context,
                  )
                }
              }
            }
          }
        })
      }
    }
  })
}

fn cross_options(
  prefixes: List(a),
  options: List(b),
  context: EnumerationContext,
  append: fn(a, b) -> a,
) -> #(List(a), EnumerationContext) {
  list.fold(prefixes, #([], context), fn(acc, prefix) {
    list.fold(options, acc, fn(acc, choice) {
      let #(products, context) = acc
      let #(allowed, context) = take_binding(context)
      #(
        case allowed {
          True -> list.append(products, [append(prefix, choice)])
          False -> products
        },
        context,
      )
    })
  })
}

fn construction_bindings(
  context: EnumerationContext,
  destination: types.SlotContract,
  identity: String,
) -> #(List(BindingExpr), EnumerationContext) {
  case
    find(
      context.prepared.input.invocation_domain.permitted_constructions,
      fn(rule) {
        rule.identity == identity && rule.type_ref == destination.type_ref
      },
    )
  {
    None -> #([], context)
    Some(rule) ->
      case resolved_shape(context.prepared.graph, rule.type_ref) {
        Some(types.ProductShape(spec)) -> {
          let #(products, context) =
            list.fold(spec.fields, #([[]], context), fn(acc, field) {
              let #(products, context) = acc
              case products == [] || context.budget.exhausted_bindings {
                True -> acc
                False -> {
                  let #(choices, context) =
                    source_bindings(
                      context,
                      field.slot,
                      field_constraint(rule, field.wire_name),
                    )
                  let #(nested_choices, context) = case
                    find(rule.nested_fields, fn(pair) {
                      pair.0 == field.wire_name
                    })
                  {
                    None -> #([], context)
                    Some(pair) ->
                      construction_bindings(context, field.slot, pair.1)
                  }
                  let choices = list.append(choices, nested_choices)
                  list.fold(products, #([], context), fn(acc, fields) {
                    let #(next, context) = acc
                    let next = case field_required(rule, field) {
                      True -> next
                      False -> list.append(next, [fields])
                    }
                    let #(variants, context) =
                      cross_options(
                        [fields],
                        choices,
                        context,
                        fn(fields, binding) {
                          list.append(fields, [#(field.wire_name, binding)])
                        },
                      )
                    #(list.append(next, variants), context)
                  })
                }
              }
            })
          let bindings =
            list.map(products, fn(fields) {
              Product(rule.identity, rule.type_ref, fields)
            })
          #(
            list.filter(bindings, fn(binding) {
              check_binding(
                context.prepared,
                context.state,
                binding,
                destination,
                AnyCompatible,
              )
              == Ok(Nil)
            }),
            context,
          )
        }
        _ -> #([], context)
      }
  }
}

fn binding_options(
  context: EnumerationContext,
  destination: types.SlotContract,
  constraint: SourceConstraint,
) -> #(List(BindingExpr), EnumerationContext) {
  let #(bindings, context) = source_bindings(context, destination, constraint)
  case constraint {
    AnyCompatible ->
      list.fold(
        list.filter(
          context.prepared.input.invocation_domain.permitted_constructions,
          fn(rule) { rule.type_ref == destination.type_ref },
        ),
        #(bindings, context),
        fn(acc, rule) {
          let #(bindings, context) = acc
          let #(constructed, context) =
            construction_bindings(context, destination, rule.identity)
          #(list.append(bindings, constructed), context)
        },
      )
    _ -> #(bindings, context)
  }
}

fn resource_binding_options(
  context: EnumerationContext,
  function: FunctionSignature,
) -> #(List(List(ResourceBinding)), EnumerationContext) {
  let lots = state_lots(context.prepared.input, context.state)
  list.fold(function.resource_inputs, #([[]], context), fn(acc, requirement) {
    let #(bindings, context) = acc
    let #(options, context) =
      list.fold(lots, #([], context), fn(acc, reference) {
        let #(options, context) = acc
        let #(allowed, context) = take_binding(context)
        case allowed, declared_lot(context.prepared.input, reference) {
          True, Some(lot) ->
            case
              lot.revision == requirement.required_revision
              && resource_identity_accepts(requirement.identity, lot.producer)
            {
              False -> #(options, context)
              True -> {
                let #(certificate, context) =
                  compatibility(
                    context,
                    present_contract(lot.token_type),
                    present_contract(requirement.token_type),
                    None,
                  )
                #(
                  case certificate {
                    None -> options
                    Some(inclusion) ->
                      list.append(options, [
                        ResourceBinding(requirement.id, reference, inclusion),
                      ])
                  },
                  context,
                )
              }
            }
          _, _ -> #(options, context)
        }
      })
    cross_options(bindings, options, context, fn(bindings, option) {
      list.append(bindings, [option])
    })
  })
}

fn enumerate_terminals(
  context: EnumerationContext,
) -> #(List(ReturnPlan), EnumerationContext) {
  let #(goals, context) = case failure_pending(context.state) {
    True -> #([], context)
    False ->
      list.fold(
        context.prepared.input.goal.outputs,
        #([[]], context),
        fn(acc, goal) {
          let #(goals, context) = acc
          let #(bindings, context) =
            binding_options(context, goal.contract, goal.source_constraint)
          let context = case bindings {
            [] ->
              EnumerationContext(
                ..context,
                missing: list.append(context.missing, [
                  MissingSupply(None, goal.id.value, goal.contract),
                ]),
              )
            _ -> context
          }
          cross_options(goals, bindings, context, fn(goals, binding) {
            list.append(goals, [#(goal.id, binding)])
          })
        },
      )
  }
  let terminals = list.map(goals, ReturnSuccess)
  case context.state.pending_failure {
    None -> #(terminals, context)
    Some(origin) ->
      list.fold(
        list.filter(context.prepared.input.goal.failures, fn(embedding) {
          embedding.origin == origin
        }),
        #(terminals, context),
        fn(acc, embedding) {
          let #(terminals, context) = acc
          let #(bindings, context) =
            binding_options(context, embedding.contract, AnyCompatible)
          let failures =
            list.filter(
              list.map(bindings, fn(value) {
                ReturnFailure(embedding.id, value)
              }),
              fn(terminal) {
                case check_return(context.prepared, context.state, terminal) {
                  Ok(_) -> True
                  _ -> False
                }
              },
            )
          #(list.append(terminals, failures), context)
        },
      )
  }
}

fn enumerate_invocations(
  context: EnumerationContext,
) -> #(List(ChoiceSkeleton), EnumerationContext) {
  list.fold(
    context.prepared.input.invocation_domain.sites,
    #([], context),
    fn(acc, site) {
      let #(choices, context) = acc
      let blocked =
        list.contains(context.state.used_sites, site.id)
        || list.any(context.prepared.input.explicit_order, fn(pair) {
          pair.1 == site.id && !list.contains(context.state.used_sites, pair.0)
        })
      case blocked, signature(context.prepared.input, site.function) {
        False, Some(function) ->
          case handles_pending(function, context.state) {
            False -> acc
            True -> {
              let #(bindings, context) =
                list.fold(function.inputs, #([[]], context), fn(acc, port) {
                  let #(bindings, context) = acc
                  let #(options, context) =
                    binding_options(
                      context,
                      port.contract,
                      port.source_constraint,
                    )
                  let context = case options {
                    [] ->
                      EnumerationContext(
                        ..context,
                        missing: list.append(context.missing, [
                          MissingSupply(
                            Some(site.id),
                            port.id.value,
                            port.contract,
                          ),
                        ]),
                      )
                    _ -> context
                  }
                  cross_options(
                    bindings,
                    options,
                    context,
                    fn(bindings, option) {
                      list.append(bindings, [#(port.id, option)])
                    },
                  )
                })
              case bindings {
                [] -> #(choices, context)
                _ -> {
                  let #(resources, context) =
                    resource_binding_options(context, function)
                  let outcomes =
                    list.map(
                      list.filter(function.outcomes, fn(outcome) {
                        !outcome_empty(context.prepared, outcome)
                      }),
                      fn(outcome) { outcome.id },
                    )
                  let empty =
                    list.map(
                      list.filter(function.outcomes, fn(outcome) {
                        outcome_empty(context.prepared, outcome)
                      }),
                      fn(outcome) { outcome.id },
                    )
                  case outcomes {
                    [] -> #(choices, context)
                    _ ->
                      list.fold(
                        bindings,
                        #(choices, context),
                        fn(acc, bindings) {
                          list.fold(resources, acc, fn(acc, resources) {
                            let #(choices, context) = acc
                            let #(allowed, context) = take_binding(context)
                            case allowed {
                              False -> #(choices, context)
                              True -> {
                                let invocation =
                                  InvocationPlan(
                                    site.id,
                                    function.reference,
                                    bindings,
                                    resources,
                                  )
                                case
                                  check_invocation(
                                    context.prepared,
                                    context.state,
                                    invocation,
                                  )
                                {
                                  Ok(_) -> #(
                                    list.append(choices, [
                                      InvocationChoice(
                                        invocation,
                                        outcomes,
                                        empty,
                                      ),
                                    ]),
                                    context,
                                  )
                                  Error(failure) -> #(
                                    choices,
                                    enumeration_error(context, failure),
                                  )
                                }
                              }
                            }
                          })
                        },
                      )
                  }
                }
              }
            }
          }
        _, _ -> acc
      }
    },
  )
}

fn enumerate_guards(
  context: EnumerationContext,
) -> #(List(ChoiceSkeleton), EnumerationContext) {
  list.fold(
    context.prepared.input.invocation_domain.guards,
    #([], context),
    fn(acc, guard) {
      let #(choices, context) = acc
      case list.contains(context.state.used_guards, guard.id) {
        True -> acc
        False ->
          list.fold(
            list.filter(context.state.available, fn(source) {
              source.contract.type_ref == guard.source_type
            }),
            #(choices, context),
            fn(acc, source) {
              let #(choices, context) = acc
              let #(allowed, context) = take_binding(context)
              case allowed {
                False -> #(choices, context)
                True -> {
                  let inspected = ValueRef(source.producer, guard.path)
                  case
                    guard_arms(
                      context.prepared,
                      context.state,
                      guard,
                      inspected,
                    )
                  {
                    Ok([]) -> #(choices, context)
                    Ok(arms) -> #(
                      list.append(choices, [
                        GuardChoice(guard.id, inspected, arms),
                      ]),
                      context,
                    )
                    Error(failure) -> #(
                      choices,
                      enumeration_error(context, failure),
                    )
                  }
                }
              }
            },
          )
      }
    },
  )
}

pub fn enumerate_state(
  prepared: PreparedCompositionInput,
  state: SearchState,
  budget: CandidateBudget,
) -> Enumeration {
  let context = EnumerationContext(prepared, state, budget, [], [], [])
  let #(terminals, context) = enumerate_terminals(context)
  let #(invocations, context) = enumerate_invocations(context)
  let #(guards, context) = enumerate_guards(context)
  let context = case context.budget.exhausted_bindings {
    True -> add_unknown(context, BindingBoundExhausted)
    False -> context
  }
  Enumeration(
    terminals,
    list.append(invocations, guards),
    context.unknown,
    context.failures,
    context.missing,
    context.budget,
  )
}

pub fn choice_states(
  prepared: PreparedCompositionInput,
  state: SearchState,
  choice: ChoiceSkeleton,
) -> Result(List(SearchState), WitnessFailure) {
  case choice {
    InvocationChoice(invocation, outcomes, _) -> {
      use _ <- result.try(check_invocation(prepared, state, invocation))
      collect(outcomes, fn(id) {
        use outcome <- result.try(option.to_result(
          outcome_contract(prepared.input, invocation.site, id),
          IncompleteBranchCoverage(id.value),
        ))
        Ok(after_invocation(state, invocation, outcome))
      })
    }
    GuardChoice(id, inspected, arms) -> {
      use guard <- result.try(option.to_result(
        guard_declaration(prepared.input, id),
        GuardNotDominating(inspected),
      ))
      collect(arms, fn(arm) {
        after_guard(prepared, state, guard, inspected, arm)
      })
    }
  }
}

fn verify_trace_certificate(
  prepared: PreparedCompositionInput,
  state: SearchState,
  terminal: ReturnPlan,
  certificate: ResourceTraceCertificate,
) -> Result(Nil, WitnessFailure) {
  let trace = BranchTrace(state.trace, terminal)
  use _ <- result.try(require(
    certificate.trace == trace,
    ResourceLoweringMismatch("branch trace differs"),
  ))
  use _ <- result.try(verify_value_models(
    prepared,
    state,
    certificate.value_sources,
  ))
  use _ <- result.try(verify_return_values(
    prepared,
    terminal,
    certificate.value_sources,
  ))
  use computed <- result.try(
    result.map_error(lower_resource_trace(prepared, trace), fn(_) {
      ResourceLoweringMismatch("cannot reconstruct the finite resource trace")
    }),
  )
  let #(input, correspondence) = computed
  use _ <- result.try(require(
    certificate.lowering == input
      && certificate.correspondence == correspondence,
    ResourceLoweringMismatch("solver input/correspondence differs"),
  ))
  use _ <- result.try(
    result.map_error(resource_trace_meaning(prepared, correspondence), fn(_) {
      MissingEvidence("resource meaning/inhabitation unavailable")
    }),
  )
  use _ <- result.try(require(
    certificate.reachability.path == correspondence.execution_order,
    ResourceReplayMismatch("path does not execute the exact selected trace"),
  ))
  use _ <- result.try(verify_reachability_witness(
    input,
    certificate.reachability,
  ))
  use _ <- result.try(verify_acyclic_witness(input, certificate.acyclicity))
  Ok(Nil)
}

fn verify_terminal_assessment(
  prepared: PreparedCompositionInput,
  state: SearchState,
  terminal: ReturnPlan,
  assessment: TerminalAssessment,
) -> Result(Nil, WitnessFailure) {
  use _ <- result.try(check_return(prepared, state, terminal))
  let trace = BranchTrace(state.trace, terminal)
  case assessment {
    Feasible(certificate) ->
      verify_trace_certificate(prepared, state, terminal, certificate)
    ResourceUnreachable(supplied, input, correspondence, closure) -> {
      use _ <- result.try(require(
        supplied == trace,
        ResourceLoweringMismatch("unreachable trace differs"),
      ))
      use computed <- result.try(
        result.map_error(lower_resource_trace(prepared, trace), fn(_) {
          ResourceLoweringMismatch("unreachable lowering reconstruction failed")
        }),
      )
      use _ <- result.try(require(
        computed == #(input, correspondence),
        ResourceLoweringMismatch("unreachable lowering differs"),
      ))
      use _ <- result.try(verify_closure_witness(input, closure))
      Ok(Nil)
    }
    RejectedLowering(supplied, reason) -> {
      use _ <- result.try(require(
        supplied == trace,
        ResourceLoweringMismatch("rejected trace differs"),
      ))
      require(
        lower_resource_trace(prepared, trace) == Error(InvalidLowering(reason)),
        ResourceLoweringMismatch("lowering rejection is forged"),
      )
    }
    EmptyValues(producers) -> {
      let actual =
        list.map(
          list.filter(state.available, fn(source) {
            slot_empty(source.contract, prepared.empty)
          }),
          fn(source) { source.producer },
        )
      require(
        actual != [] && actual == producers,
        MissingEvidence("empty source proof is forged"),
      )
    }
    TerminalUnknown(_) ->
      Error(ForgedClosure("unresolved terminal in a closed witness"))
  }
}

fn sorted(values: List(String)) -> List(String) {
  list.sort(values, string.compare)
}

fn path_identity(path: types.ValuePath) -> String {
  encode_tuple(
    list.map(path, fn(step) {
      case step {
        types.Field(name) -> encode_tuple(["field", name])
        types.Index(index) -> encode_tuple(["index", int.to_string(index)])
        types.Variant(tag) -> encode_tuple(["variant", tag])
      }
    }),
  )
}

fn guard_arm_identity(arm: GuardArm) -> String {
  case arm {
    GuardPresent -> encode_tuple(["present"])
    GuardAbsent -> encode_tuple(["absent"])
    GuardNull -> encode_tuple(["null"])
    GuardVariant(tag) -> encode_tuple(["variant", tag])
    UnknownVariant -> encode_tuple(["unknown-variant"])
    GuardAccepted -> encode_tuple(["accepted"])
    GuardRejected -> encode_tuple(["rejected"])
  }
}

fn binding_key(binding: BindingExpr) -> String {
  case binding {
    Source(value, _, _) ->
      encode_tuple([
        "source",
        producer_identity(value.producer),
        path_identity(value.path),
      ])
    Product(construction, reference, fields) ->
      encode_tuple([
        "construct",
        construction,
        type_identity(reference),
        encode_tuple(
          sorted(
            list.map(fields, fn(pair) {
              encode_tuple([pair.0, binding_key(pair.1)])
            }),
          ),
        ),
      ])
  }
}

fn invocation_key(invocation: InvocationPlan) -> String {
  let bindings =
    sorted(
      list.map(invocation.bindings, fn(pair) {
        encode_tuple([pair.0.value, binding_key(pair.1)])
      }),
    )
  let resources =
    sorted(
      list.map(invocation.resources, fn(binding) {
        encode_tuple([binding.requirement.value, lot_identity(binding.lot)])
      }),
    )
  encode_tuple([
    "invoke",
    invocation.site.value,
    function_identity(invocation.function),
    encode_tuple(bindings),
    encode_tuple(resources),
  ])
}

fn return_key(terminal: ReturnPlan) -> String {
  case terminal {
    ReturnSuccess(outputs) ->
      encode_tuple([
        "success",
        encode_tuple(
          sorted(
            list.map(outputs, fn(pair) {
              encode_tuple([pair.0.value, binding_key(pair.1)])
            }),
          ),
        ),
      ])
    ReturnFailure(id, value) ->
      encode_tuple(["failure", id.value, binding_key(value)])
  }
}

fn choice_key(choice: ChoiceSkeleton) -> String {
  case choice {
    InvocationChoice(invocation, outcomes, empty) ->
      encode_tuple([
        "invocation-choice",
        invocation_key(invocation),
        encode_tuple(sorted(list.map(outcomes, fn(id) { id.value }))),
        encode_tuple(sorted(list.map(empty, fn(id) { id.value }))),
      ])
    GuardChoice(id, inspected, arms) ->
      encode_tuple([
        "guard-choice",
        id.value,
        producer_identity(inspected.producer),
        path_identity(inspected.path),
        encode_tuple(sorted(list.map(arms, guard_arm_identity))),
      ])
  }
}

fn trace_step_key(step: TraceStep) -> String {
  case step {
    InvocationStep(invocation, outcome) ->
      encode_tuple(["invoke", invocation_key(invocation), outcome.value])
    GuardStep(id, inspected, arm) ->
      encode_tuple([
        "guard",
        id.value,
        producer_identity(inspected.producer),
        path_identity(inspected.path),
        guard_arm_identity(arm),
      ])
  }
}

fn order_free(input: CompositionInput, invocation: InvocationPlan) -> Bool {
  option.unwrap(
    option.map(signature(input, invocation.function), fn(function) {
      function.effect == PureFunction
      && case function.outcomes {
        [outcome] ->
          outcome.form == Success
          && outcome.produced_resources == []
          && list.all(function.resource_inputs, fn(requirement) {
            requirement.mode == resource.Read
          })
        _ -> False
      }
    }),
    False,
  )
}

fn canonical_trace(input: CompositionInput, trace: BranchTrace) -> String {
  let #(parts, unordered) =
    list.fold(trace.steps, #([], []), fn(acc, step) {
      let #(parts, unordered) = acc
      case step {
        InvocationStep(invocation, outcome) -> {
          let key = encode_tuple([invocation_key(invocation), outcome.value])
          case order_free(input, invocation) {
            True -> #(parts, list.append(unordered, [key]))
            False -> #(list.flatten([parts, sorted(unordered), [key]]), [])
          }
        }
        GuardStep(id, inspected, arm) -> #(
          list.flatten([
            parts,
            sorted(unordered),
            [
              encode_tuple([
                "guard",
                id.value,
                producer_identity(inspected.producer),
                path_identity(inspected.path),
                guard_arm_identity(arm),
              ]),
            ],
          ]),
          [],
        )
      }
    })
  encode_tuple(
    list.flatten([parts, sorted(unordered), [return_key(trace.terminal)]]),
  )
}

pub type CandidateTree {
  CandidateTree(
    tree: PlanTree,
    success: Bool,
    certificates: List(ResourceTraceCertificate),
    nodes: Int,
  )
}

pub fn candidate_key(
  input: CompositionInput,
  candidate: CandidateTree,
) -> String {
  certificate_key(input, candidate.certificates)
}

fn certificate_key(
  input: CompositionInput,
  certificates: List(ResourceTraceCertificate),
) -> String {
  encode_tuple(
    sorted(
      list.map(certificates, fn(certificate) {
        canonical_trace(input, certificate.trace)
      }),
    ),
  )
}

pub fn distinct_candidates(
  input: CompositionInput,
  candidates: List(CandidateTree),
) -> List(CandidateTree) {
  let #(result, _) =
    list.fold(candidates, #([], []), fn(acc, candidate) {
      let #(result, keys) = acc
      let key = candidate_key(input, candidate)
      case list.contains(keys, key) {
        True -> acc
        False -> #(list.append(result, [candidate]), [key, ..keys])
      }
    })
  result
}

pub fn merge_choice(
  input: CompositionInput,
  state: SearchState,
  choice: ChoiceSkeleton,
  children: List(List(CandidateTree)),
  budget: CandidateBudget,
) -> #(List(CandidateTree), CandidateBudget) {
  case
    children == [] || list.any(children, fn(candidates) { candidates == [] })
  {
    True -> #([], budget)
    False -> {
      let #(products, budget) =
        list.fold(children, #([[]], budget), fn(acc, candidates) {
          let #(prefixes, budget) = acc
          list.fold(prefixes, #([], budget), fn(acc, prefix) {
            list.fold(candidates, acc, fn(acc, candidate) {
              let #(products, budget) = acc
              case budget.branch_nodes >= input.bounds.max_branch_nodes {
                True -> #(
                  products,
                  CandidateBudget(..budget, exhausted_branches: True),
                )
                False -> #(
                  list.append(products, [list.append(prefix, [candidate])]),
                  CandidateBudget(
                    ..budget,
                    branch_nodes: budget.branch_nodes + 1,
                  ),
                )
              }
            })
          })
        })
      let #(candidates, budget) =
        list.fold(products, #([], budget), fn(acc, product) {
          let #(candidates, budget) = acc
          let nodes =
            1
            + list.fold(product, 0, fn(count, candidate) {
              count + candidate.nodes
            })
          case nodes > input.bounds.max_branch_nodes {
            True -> #(
              candidates,
              CandidateBudget(..budget, exhausted_branches: True),
            )
            False -> {
              let node = case choice {
                InvocationChoice(invocation, outcomes, empty) ->
                  Invoke(
                    invocation,
                    list.zip(
                      outcomes,
                      list.map(product, fn(candidate) { candidate.tree }),
                    ),
                    empty,
                  )
                GuardChoice(id, inspected, arms) ->
                  Guard(
                    id,
                    inspected,
                    list.zip(
                      arms,
                      list.map(product, fn(candidate) { candidate.tree }),
                    ),
                  )
              }
              let candidate =
                CandidateTree(
                  PlanTree(list.length(state.trace), node),
                  list.any(product, fn(candidate) { candidate.success }),
                  list.flat_map(product, fn(candidate) {
                    candidate.certificates
                  }),
                  nodes,
                )
              #([candidate, ..candidates], budget)
            }
          }
        })
      #(distinct_candidates(input, list.reverse(candidates)), budget)
    }
  }
}

pub fn replace_at(values: List(a), index: Int, value: a) -> List(a) {
  list.index_map(values, fn(current, position) {
    case position == index {
      True -> value
      False -> current
    }
  })
}

fn same_search_state(
  prepared: PreparedCompositionInput,
  actual: SearchState,
  expected: SearchState,
) -> Bool {
  actual == expected
  || actual.available == expected.available
  && actual.used_sites == expected.used_sites
  && actual.used_guards == expected.used_guards
  && actual.facts == expected.facts
  && actual.pending_failure == expected.pending_failure
  && list.map(actual.trace, trace_step_key)
  == list.map(expected.trace, trace_step_key)
  && replay_trace(prepared, actual.trace) == Ok(actual)
}

fn closed_reached(
  witness: CompositionClosureWitness,
  pending: List(Int),
  seen: List(Int),
) -> Result(List(Int), WitnessFailure) {
  case pending {
    [] -> Ok(seen)
    [index, ..rest] ->
      case list.contains(seen, index) {
        True -> closed_reached(witness, rest, seen)
        False -> {
          use record <- result.try(option.to_result(
            at(witness.states, index),
            ForgedClosure("search successor missing"),
          ))
          closed_reached(
            witness,
            list.append(
              list.flat_map(record.choices, fn(choice) { choice.children }),
              rest,
            ),
            [index, ..seen],
          )
        }
      }
  }
}

fn verify_closed_record(
  prepared: PreparedCompositionInput,
  witness: CompositionClosureWitness,
  index: Int,
  record: ClosedSearchState,
  budget: CandidateBudget,
) -> Result(CandidateBudget, WitnessFailure) {
  use _ <- result.try(require(
    !list.any(list.take(witness.states, index), fn(previous) {
      previous.state == record.state
    }),
    ForgedClosure("duplicate search state"),
  ))
  let expected = enumerate_state(prepared, record.state, budget)
  use _ <- result.try(require(
    expected.unknown == [] && !expected.budget.exhausted_bindings,
    ForgedClosure("unresolved type/binding frontier"),
  ))
  use _ <- result.try(require(
    same_multiset(
      list.map(record.terminals, fn(coverage) { return_key(coverage.terminal) }),
      list.map(expected.terminals, return_key),
    )
      && same_multiset(
      list.map(record.choices, fn(coverage) { choice_key(coverage.choice) }),
      list.map(expected.choices, choice_key),
    ),
    ForgedClosure("terminal or enabled successor coverage differs"),
  ))
  use _ <- result.try(require(
    record.rejected_connections == expected.failures
      && record.missing_supply == expected.missing,
    ForgedClosure("source counterexamples or missing supplies differ"),
  ))
  use _ <- result.try(
    each(record.rejected_connections, fn(failure) {
      result.map_error(
        verify_counterexample(prepared.graph, failure.counterexample),
        InclusionMismatch,
      )
    }),
  )
  use _ <- result.try(
    each(record.terminals, fn(coverage) {
      verify_terminal_assessment(
        prepared,
        record.state,
        coverage.terminal,
        coverage.assessment,
      )
    }),
  )
  use _ <- result.try(
    each(record.choices, fn(coverage) {
      use children <- result.try(choice_states(
        prepared,
        record.state,
        coverage.choice,
      ))
      use _ <- result.try(require(
        list.length(children) == list.length(coverage.children),
        ForgedClosure("outcome/guard successors omitted"),
      ))
      each(list.zip(children, coverage.children), fn(pair) {
        let valid =
          option.unwrap(
            option.map(at(witness.states, pair.1), fn(child_record) {
              same_search_state(prepared, child_record.state, pair.0)
            }),
            False,
          )
        require(
          valid && list.length(pair.0.trace) > list.length(record.state.trace),
          ForgedClosure("source, branch, rank or resource state differs"),
        )
      })
    }),
  )
  Ok(expected.budget)
}

type ClosureReplay {
  ClosureReplay(
    memo: List(Option(List(CandidateTree))),
    active: List(Int),
    budget: CandidateBudget,
  )
}

fn replay_closed_candidates(
  prepared: PreparedCompositionInput,
  witness: CompositionClosureWitness,
  index: Int,
  replay: ClosureReplay,
) -> Result(#(List(CandidateTree), ClosureReplay), WitnessFailure) {
  case option.flatten(at(replay.memo, index)) {
    Some(candidates) -> Ok(#(candidates, replay))
    None -> {
      use _ <- result.try(require(
        !list.contains(replay.active, index),
        ForgedClosure("cyclic finite invocation search graph"),
      ))
      use record <- result.try(option.to_result(
        at(witness.states, index),
        ForgedClosure("missing search state"),
      ))
      let replay = ClosureReplay(..replay, active: [index, ..replay.active])
      let candidates =
        filter_options(record.terminals, fn(coverage) {
          case coverage.assessment {
            Feasible(certificate) ->
              Some(CandidateTree(
                PlanTree(
                  list.length(record.state.trace),
                  Return(coverage.terminal),
                ),
                case coverage.terminal {
                  ReturnSuccess(_) -> True
                  _ -> False
                },
                [certificate],
                1,
              ))
            _ -> None
          }
        })
      use _ <- result.try(require(
        list.all(candidates, fn(candidate) {
          candidate.nodes <= prepared.input.bounds.max_branch_nodes
        }),
        ForgedClosure("terminal plan evidence exceeds bound"),
      ))
      use completed <- result.try(
        list.fold(record.choices, Ok(#(candidates, replay)), fn(acc, coverage) {
          use acc <- result.try(acc)
          use visited <- result.try(
            list.fold(coverage.children, Ok(#([], acc.1)), fn(acc, child) {
              use acc <- result.try(acc)
              use child <- result.try(replay_closed_candidates(
                prepared,
                witness,
                child,
                acc.1,
              ))
              Ok(#(list.append(acc.0, [child.0]), child.1))
            }),
          )
          let #(children, replay) = visited
          let #(merged, budget) =
            merge_choice(
              prepared.input,
              record.state,
              coverage.choice,
              children,
              replay.budget,
            )
          use _ <- result.try(require(
            !budget.exhausted_branches,
            ForgedClosure("branch evidence exceeds bound"),
          ))
          Ok(#(
            list.append(acc.0, merged),
            ClosureReplay(..replay, budget: budget),
          ))
        }),
      )
      let #(candidates, replay) = completed
      let candidates = distinct_candidates(prepared.input, candidates)
      let replay =
        ClosureReplay(
          ..replay,
          active: list.filter(replay.active, fn(active) { active != index }),
          memo: replace_at(replay.memo, index, Some(candidates)),
        )
      Ok(#(candidates, replay))
    }
  }
}

pub fn verify_composition_closure(
  prepared: PreparedCompositionInput,
  witness: CompositionClosureWitness,
) -> Result(CheckedCompositionClosure, WitnessFailure) {
  use _ <- result.try(require(
    witness.input_snapshot == prepared.input,
    InputRevisionMismatch,
  ))
  use _ <- result.try(require(
    prepared.initial_obligations == [],
    ForgedClosure("initial supplied values still have semantic obligations"),
  ))
  use _ <- result.try(require(
    option.map(at(witness.states, witness.root), fn(record) { record.state })
      == Some(initial_state(prepared)),
    ForgedClosure("initial search state missing"),
  ))
  use reached <- result.try(closed_reached(witness, [witness.root], []))
  use _ <- result.try(require(
    list.length(reached) == list.length(witness.states),
    ForgedClosure("extraneous search state"),
  ))
  use budget <- result.try(
    list.fold(
      list.index_map(witness.states, fn(record, index) { #(index, record) }),
      Ok(fresh_budget()),
      fn(acc, pair) {
        use budget <- result.try(acc)
        verify_closed_record(prepared, witness, pair.0, pair.1, budget)
      },
    ),
  )
  let expanded =
    list.length(
      list.filter(witness.states, fn(record) { record.choices != [] }),
    )
  use _ <- result.try(require(
    expanded <= prepared.input.bounds.max_expanded_states,
    ForgedClosure("state bound exceeded"),
  ))
  let replay =
    ClosureReplay(list.repeat(None, list.length(witness.states)), [], budget)
  use replayed <- result.try(replay_closed_candidates(
    prepared,
    witness,
    witness.root,
    replay,
  ))
  let plans =
    list.map(
      list.filter(replayed.0, fn(candidate) { candidate.success }),
      fn(candidate) { candidate_key(prepared.input, candidate) },
    )
  Ok(CheckedCompositionClosure(witness, plans))
}

pub fn verify_unreachable_composition(
  prepared: PreparedCompositionInput,
  witness: CompositionClosureWitness,
) -> Result(Nil, WitnessFailure) {
  use checked <- result.try(verify_composition_closure(prepared, witness))
  require(
    goal_unreachable(checked),
    ForgedClosure("closed domain contains a complete success plan"),
  )
}

pub fn decide_unreachable(
  prepared: PreparedCompositionInput,
  closure: CompositionClosureWitness,
) -> Result(CompositionDecision, CompositionEngineFailure) {
  use _ <- result.try(result.map_error(
    verify_unreachable_composition(prepared, closure),
    Witness,
  ))
  Ok(Unreachable(closure))
}

pub fn decide_ambiguous(
  prepared: PreparedCompositionInput,
  first: CandidateTree,
  second: CandidateTree,
) -> Result(CompositionDecision, CompositionEngineFailure) {
  use candidates <- result.try(
    collect([first, second], fn(candidate) {
      verified_candidate(prepared, candidate)
    }),
  )
  let keys = [
    candidate_key(prepared.input, first),
    candidate_key(prepared.input, second),
  ]
  use _ <- result.try(require(
    unique(keys) == keys,
    ContractViolation("ambiguous candidates have the same canonical plan"),
  ))
  Ok(Ambiguous(candidates, keys))
}

fn verify_initial_membership(
  prepared: PreparedCompositionInput,
  witness: CompositionWitness,
) -> Result(Nil, WitnessFailure) {
  use _ <- result.try(require(
    witness.input_snapshot == prepared.input,
    InputRevisionMismatch,
  ))
  use _ <- result.try(require(
    list.length(witness.initial_membership)
      == list.length(prepared.input.initial_inputs),
    MissingEvidence("initial input coverage"),
  ))
  each(prepared.input.initial_inputs, fn(initial) {
    case
      list.filter(witness.initial_membership, fn(pair) { pair.0 == initial.id })
    {
      [pair] -> {
        use _ <- result.try(require(
          validation.accepts_slot(prepared.graph, initial.contract, pair.1),
          InitialMembership(initial.id),
        ))
        case initial.source {
          SuppliedValue(value) ->
            require(value == pair.1, InitialMembership(initial.id))
          Argument -> Ok(Nil)
        }
      }
      _ -> Error(InitialMembership(initial.id))
    }
  })
}

type PlanVerification {
  PlanVerification(success: Bool, used_certificates: List(Int), nodes: Int)
}

fn verify_plan_tree(
  prepared: PreparedCompositionInput,
  state: SearchState,
  tree: PlanTree,
  parent_rank: Option(Int),
  witness: CompositionWitness,
  verified: PlanVerification,
) -> Result(PlanVerification, WitnessFailure) {
  let verified = PlanVerification(..verified, nodes: verified.nodes + 1)
  use _ <- result.try(require(
    tree.rank >= 0
      && verified.nodes <= prepared.input.bounds.max_branch_nodes
      && option.unwrap(
      option.map(parent_rank, fn(rank) { tree.rank > rank }),
      True,
    ),
    RankViolation,
  ))
  case tree.node {
    Return(terminal) -> {
      use success <- result.try(check_return(prepared, state, terminal))
      let trace = BranchTrace(state.trace, terminal)
      let certificates =
        list.filter(
          list.index_map(witness.resource_traces, fn(certificate, index) {
            #(index, certificate)
          }),
          fn(pair) { pair.1.trace == trace },
        )
      case certificates {
        [pair] -> {
          use _ <- result.try(verify_trace_certificate(
            prepared,
            state,
            terminal,
            pair.1,
          ))
          Ok(
            PlanVerification(
              ..verified,
              success: verified.success || success,
              used_certificates: unique([pair.0, ..verified.used_certificates]),
            ),
          )
        }
        _ ->
          Error(MissingEvidence(
            "exact resource/producer certificate for branch",
          ))
      }
    }
    Invoke(invocation, arms, empty) -> {
      use _ <- result.try(check_invocation(prepared, state, invocation))
      use function <- result.try(option.to_result(
        site_signature(prepared.input, invocation.site),
        SignatureMismatch(invocation.site),
      ))
      let expected =
        list.map(
          list.filter(function.outcomes, fn(outcome) {
            !outcome_empty(prepared, outcome)
          }),
          fn(outcome) { outcome.id },
        )
      let expected_empty =
        list.map(
          list.filter(function.outcomes, fn(outcome) {
            outcome_empty(prepared, outcome)
          }),
          fn(outcome) { outcome.id },
        )
      use _ <- result.try(require(
        arms != []
          && same_multiset(list.map(arms, fn(pair) { pair.0 }), expected)
          && same_multiset(empty, expected_empty),
        IncompleteBranchCoverage(invocation.site.value),
      ))
      list.fold(arms, Ok(verified), fn(acc, pair) {
        use verified <- result.try(acc)
        use outcome <- result.try(option.to_result(
          find(function.outcomes, fn(outcome) { outcome.id == pair.0 }),
          IncompleteBranchCoverage(pair.0.value),
        ))
        verify_plan_tree(
          prepared,
          after_invocation(state, invocation, outcome),
          pair.1,
          Some(tree.rank),
          witness,
          verified,
        )
      })
    }
    Guard(id, inspected, arms) -> {
      use guard <- result.try(option.to_result(
        guard_declaration(prepared.input, id),
        GuardNotDominating(inspected),
      ))
      use expected <- result.try(guard_arms(prepared, state, guard, inspected))
      use _ <- result.try(require(
        arms != []
          && same_multiset(list.map(arms, fn(pair) { pair.0 }), expected),
        IncompleteBranchCoverage(id.value),
      ))
      list.fold(arms, Ok(verified), fn(acc, pair) {
        use verified <- result.try(acc)
        use next <- result.try(after_guard(
          prepared,
          state,
          guard,
          inspected,
          pair.0,
        ))
        verify_plan_tree(
          prepared,
          next,
          pair.1,
          Some(tree.rank),
          witness,
          verified,
        )
      })
    }
  }
}

fn check_candidate(
  prepared: PreparedCompositionInput,
  plan: CompositionPlan,
  witness: CompositionWitness,
) -> Result(Nil, WitnessFailure) {
  use _ <- result.try(require(
    plan.input_identity == prepared.input.identity
      && plan.input_revision == prepared.input.revision,
    InputRevisionMismatch,
  ))
  use _ <- result.try(verify_initial_membership(prepared, witness))
  use verified <- result.try(verify_plan_tree(
    prepared,
    initial_state(prepared),
    plan.root,
    None,
    witness,
    PlanVerification(False, [], 0),
  ))
  use _ <- result.try(require(verified.success, GoalMismatch))
  require(
    list.length(verified.used_certificates)
      == list.length(witness.resource_traces),
    MissingEvidence("extraneous resource/producer branch evidence"),
  )
}

pub fn verify_composition(
  prepared: PreparedCompositionInput,
  raw: RawComposition,
) -> Result(CheckedComposition, WitnessFailure) {
  use _ <- result.try(check_candidate(prepared, raw.plan, raw.witness))
  let key = certificate_key(prepared.input, raw.witness.resource_traces)
  use _ <- result.try(case raw.selection {
    AnyFeasibleEvidence ->
      require(
        prepared.input.selection_policy == Some(AnyFeasible),
        MissingEvidence("selection evidence disagrees with caller policy"),
      )
    Unique(closure, canonical_plan) -> {
      use _ <- result.try(require(
        prepared.input.selection_policy != Some(AnyFeasible),
        MissingEvidence("selection evidence disagrees with caller policy"),
      ))
      use checked <- result.try(verify_composition_closure(prepared, closure))
      require(
        checked.canonical_plans == [key] && canonical_plan == key,
        MissingEvidence(
          "unique selection is not established by the finite closed domain",
        ),
      )
    }
  })
  Ok(CheckedComposition(prepared, raw))
}

fn initial_membership(
  prepared: PreparedCompositionInput,
) -> Result(
  List(#(InputId, types.SlotValue(kdl.JsonValue))),
  CompositionEngineFailure,
) {
  collect(prepared.input.initial_inputs, fn(initial) {
    use value <- result.try(case initial.source {
      SuppliedValue(value) -> Ok(value)
      Argument ->
        option.to_result(
          at(
            slot_samples(
              prepared.graph,
              initial.contract,
              prepared.input.bounds.max_type_obligations,
            ),
            0,
          ),
          ContractViolation("feasible branch omitted initial inhabitation"),
        )
    })
    Ok(#(initial.id, value))
  })
}

pub fn candidate_components(
  prepared: PreparedCompositionInput,
  candidate: CandidateTree,
) -> Result(#(CompositionPlan, CompositionWitness), CompositionEngineFailure) {
  use membership <- result.try(initial_membership(prepared))
  let plan =
    CompositionPlan(
      prepared.input.identity,
      prepared.input.revision,
      candidate.tree,
    )
  let witness =
    CompositionWitness(prepared.input, membership, candidate.certificates)
  use _ <- result.try(result.map_error(
    check_candidate(prepared, plan, witness),
    Witness,
  ))
  Ok(#(plan, witness))
}

fn verified_candidate(
  prepared: PreparedCompositionInput,
  candidate: CandidateTree,
) -> Result(VerifiedCompositionCandidate, CompositionEngineFailure) {
  use components <- result.try(candidate_components(prepared, candidate))
  Ok(VerifiedCompositionCandidate(prepared, components.0, components.1))
}
