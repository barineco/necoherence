// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

use crate::semantic_composition::*;
use crate::typed_mapping as resource;

macro_rules! wire_identifier {
    ($($type:ty),* $(,)?) => { $(
        impl WireEncode for $type {
            fn serialize_wire<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
                self.0.serialize_wire(serializer)
            }
        }
        impl WireDecode for $type {
            fn decode_wire(value: &ExchangeJson, path: &str) -> Decoded<Self> {
                String::decode_wire(value, path).map(Self)
            }
            fn json_schema(registry: &mut SchemaRegistry) -> serde_json::Value {
                String::json_schema(registry)
            }
        }
    )* };
}

wire_record!(SlotContract {
    type_ref: TypeRef,
    required: bool,
    nullable: bool
});
wire_record!(ElementContract {
    type_ref: TypeRef,
    nullable: bool
});
wire_enum!(ExtraMembers; units [Reject]; tuples []; records [Allow { key_format:Option<FormatUse>, value:ElementContract }]);
wire_record!(FieldSpec {
    wire_name: String,
    slot: SlotContract,
    origin: OccurrenceRef
});
wire_record!(ProductSpec { fields:Vec<FieldSpec>, extras:ExtraMembers });
wire_record!(ArraySpec { item:ElementContract, min_length:Option<BigUint>, max_length:Option<BigUint> });
wire_record!(UnionBranch {
    target: TypeRef,
    wire_tag: String,
    selector: BranchSelector,
    origin: OccurrenceRef
});
wire_record!(UnionSpec { branches:Vec<UnionBranch> });
wire_enum!(TypeShape; units [Unit,Never]; tuples [Unknown(UnknownKind),Boolean(BooleanSpec),Integer(IntegerSpec),Decimal(DecimalSpec),String(StringSpec),Bytes(LengthSpec),Product(ProductSpec),Array(ArraySpec),TaggedUnion(UnionSpec)]; records [Sealed { tag:String,refinements:Vec<SealedRefinement> },Alias { target:TypeRef,reference_text:String },RawBody { encoding:String },Opaque { type_name:String }]);
wire_record!(TypeNode { reference:TypeRef, shape:TypeShape, description:Option<String>, attributes:Vec<OccurrenceRef>, extensions:Vec<OccurrenceRef> });
wire_enum!(SemanticReason; units [MissingGraphemeRules,MissingBytesPolicy,DecimalNotAdmitted,IntegerBound,MissingTagModel,UnresolvedType,MembershipBound]; tuples [UnknownFormat(String),UnknownIntegerDomain(String),UnknownWrapper(String),WrapperPayload(String),UnknownSealedTag(String),OpaqueType(String),UninterpretedExtension(String),InvalidProfile(String),CertificateMismatch(String),ProjectionUnavailable(String)]; records []);
wire_record!(SemanticObligation {
    type_ref: TypeRef,
    origin: OccurrenceRef,
    value_path: ValuePath,
    profile: ProfileRef,
    reason: SemanticReason
});
wire_enum!(MeaningObligation; units [Mo01,Mo02,Mo03,Mo04,Mo05,Mo06,Mo07,Mo08,Mo09,Mo10,Mo11]; tuples []; records []);
wire_record!(MeaningFailure { type_ref:TypeRef,predicate:MeaningObligation,location:Vec<String> });
wire_enum!(ProjectionAssumption; units []; tuples [Present(ValuePath),NonNull(ValuePath)]; records [Variant { path:ValuePath,tag:String },IndexPresent { path:ValuePath,index:BigUint }]);
wire_record!(ProjectionCertificate { profile:ProfileRef,source_refs:Vec<SourceIdentity>,source:SlotContract,path:ValuePath,assumptions:Vec<ProjectionAssumption>,destination:SlotContract });
wire_identifier!(
    InputId,
    PortId,
    SiteId,
    OutcomeId,
    GoalPortId,
    LotId,
    RequirementId,
    ProductionId,
    GuardId,
    FailureEmbeddingId
);
wire_record!(SemanticBasis { profile: VersionedSemanticProfile, sources: Vec<SourceIdentity> });
wire_record!(FunctionRef {
    identity: String,
    revision: String,
    content_digest: String
});
wire_enum!(InclusionRule; units [EmptySource,Presence,Unknown,Boolean,Integer,String,Bytes,Unit,Never,UnfoldSource,UnfoldDestination,Array,Product,SourceUnion,DestinationUnion,Sealed]; tuples []; records []);
wire_record!(InclusionCertificate {
    basis: SemanticBasis,
    source: SlotContract,
    destination: SlotContract,
    rule: InclusionRule
});
wire_enum!(TypeObligationReason; units [ConstraintImplication,Presence,UnionRemainder,Inhabitation,ObligationBoundExhausted]; tuples [Meaning(Vec<SemanticObligation>),ExtraField(String)]; records []);
wire_record!(TypeObligation {
    source: TypeRef,
    destination: TypeRef,
    reason: TypeObligationReason
});
wire_record!(CounterexampleCertificate {
    basis: SemanticBasis,
    source: SlotContract,
    destination: SlotContract,
    value: SlotValue,
    destination_failure: ValueFailure
});
wire_enum!(ProducerRef; units []; tuples [Initial(InputId)]; records [InvocationOutcome { site: SiteId, outcome: OutcomeId, port: PortId }]);
wire_record!(ValueRef {
    producer: ProducerRef,
    path: ValuePath
});
wire_enum!(SourceConstraint; units [AnyCompatible]; tuples []; records [InitialOnly { input: InputId, path: ValuePath }, ProducedBy { site: SiteId, outcome: OutcomeId, port: PortId, path: ValuePath }]);
wire_enum!(ResourceLotRef; units []; tuples [Initial(LotId)]; records [Produced { site: SiteId, outcome: OutcomeId, production: ProductionId }]);
wire_enum!(ResourceProducer; units []; tuples []; records [Initial { identity: String, revision: String }, InvocationOutcome { site: SiteId, outcome: OutcomeId }]);
wire_enum!(ResourceIdentityConstraint; units [Any]; tuples [Exactly(ResourceProducer)]; records []);
wire_record!(ResourceLot {
    id: LotId,
    token_type: TypeRef,
    producer: ResourceProducer,
    revision: BigUint,
    quantity: BigUint,
    provenance: String
});
wire_enum!(resource::BindingMode; units [Read, Consume]; tuples []; records []);
wire_record!(ResourceRequirement {
    id: RequirementId,
    token_type: TypeRef,
    mode: resource::BindingMode,
    multiplicity: BigUint,
    required_revision: BigUint,
    identity: ResourceIdentityConstraint
});
wire_record!(ResourceProduction {
    id: ProductionId,
    token_type: TypeRef,
    revision: BigUint,
    quantity: BigUint,
    provenance: String
});
wire_enum!(InitialSource; units [Argument]; tuples [SuppliedValue(SlotValue)]; records []);
wire_record!(InitialInput { id: InputId, contract: SlotContract, source: InitialSource, resource: Option<LotId> });
wire_record!(InputPort { id: PortId, contract: SlotContract, source_constraint: SourceConstraint, resource_requirement: Option<RequirementId> });
wire_record!(OutputPort { id: PortId, contract: SlotContract, resource_production: Option<ProductionId> });
wire_enum!(crate::semantic_composition::OutcomeForm; units [Success, DeclaredFailure]; tuples []; records []);
wire_record!(OutcomeContract { id: OutcomeId, form: crate::semantic_composition::OutcomeForm, value_ports: Vec<OutputPort>, produced_resources: Vec<ResourceProduction> });
wire_enum!(FunctionForm; units [Pure, DeclaredTransform]; tuples [Operation(DefinitionRef)]; records []);
wire_enum!(CompositionEffect; units [PureFunction, HttpRequestResponse, DataOnly]; tuples []; records []);
wire_enum!(GuardArm; units [Present, Absent, Null, UnknownVariant, Accepted, Rejected]; tuples [Variant(String)]; records []);
wire_enum!(FailureOrigin; units []; tuples []; records [Function { function: FunctionRef, outcome: OutcomeId }, Guard { guard: GuardId, arm: GuardArm }]);
wire_record!(FunctionSignature { reference: FunctionRef, form: FunctionForm, effect: CompositionEffect, inputs: Vec<InputPort>, outcomes: Vec<OutcomeContract>, resource_inputs: Vec<ResourceRequirement>, assumption_ref: String, handles_failure: Option<FailureOrigin> });
wire_record!(InvocationSite {
    id: SiteId,
    function: FunctionRef
});
wire_record!(PermittedProjection {
    source_type: TypeRef,
    path: ValuePath
});
wire_enum!(GuardKind; units [Presence, Variants]; tuples [Validate(SlotContract)]; records []);
wire_record!(DeclaredGuard {
    id: GuardId,
    source_type: TypeRef,
    path: ValuePath,
    kind: GuardKind
});
wire_enum!(FieldPresence; units [Required, Optional]; tuples []; records []);
wire_record!(FieldConstraint {
    field: String,
    source: SourceConstraint,
    presence: FieldPresence
});
wire_record!(ConstructionRule { identity: String, type_ref: TypeRef, nested_fields: Vec<(String, String)>, field_constraints: Vec<FieldConstraint> });
wire_record!(InvocationDomain { identity: String, revision: String, sites: Vec<InvocationSite>, permitted_projections: Vec<PermittedProjection>, permitted_constructions: Vec<ConstructionRule>, permitted_transforms: Vec<FunctionRef>, guards: Vec<DeclaredGuard> });
wire_record!(ResourceGoal {
    lot: ResourceLotRef,
    multiplicity: BigUint,
    revision: BigUint
});
wire_record!(GoalPort {
    id: GoalPortId,
    contract: SlotContract,
    source_constraint: SourceConstraint
});
wire_record!(FailureEmbedding { id: FailureEmbeddingId, origin: FailureOrigin, contract: SlotContract, final_resources: Vec<ResourceGoal> });
wire_record!(GoalSpec { outputs: Vec<GoalPort>, failures: Vec<FailureEmbedding>, final_resources: Vec<ResourceGoal> });
wire_enum!(SelectionPolicy; units [RequireUnique, AnyFeasible]; tuples []; records []);
wire_record!(ResourceBounds {
    max_bindings: BigUint,
    max_search_steps: BigUint,
    max_tokens: usize
});
wire_record!(SearchBounds { max_expanded_states: usize, max_binding_candidates: usize, max_type_obligations: usize, max_branch_nodes: usize, resource_bounds: Option<ResourceBounds>, max_sample_length: usize });
wire_record!(CompositionInput { identity: String, revision: String, basis: SemanticBasis, signatures: Vec<FunctionSignature>, initial_inputs: Vec<InitialInput>, initial_resources: Vec<ResourceLot>, goal: GoalSpec, invocation_domain: InvocationDomain, allowed_effects: Vec<CompositionEffect>, explicit_order: Vec<(SiteId, SiteId)>, selection_policy: Option<SelectionPolicy>, bounds: SearchBounds });
wire_enum!(BindingCompatibility; units []; tuples [Inclusion(Arc<InclusionCertificate>)]; records [SuppliedValue { value: SlotValue }]);
wire_enum!(BindingExpr; units []; tuples []; records [
    Source { value: ValueRef, projection: ProjectionCertificate, compatibility: BindingCompatibility },
    Product { construction: String, type_ref: TypeRef, fields: Vec<(String, BindingExpr)> }
]);
wire_record!(ResourceBinding { requirement: RequirementId, lot: ResourceLotRef, inclusion: Arc<InclusionCertificate> });
wire_record!(InvocationPlan { site: SiteId, function: FunctionRef, bindings: Vec<(PortId, BindingExpr)>, resources: Vec<ResourceBinding> });
wire_enum!(ReturnPlan; units []; tuples [Success(Vec<(GoalPortId, BindingExpr)>)]; records [Failure { embedding: FailureEmbeddingId, value: BindingExpr }]);
wire_record!(PlanTree {
    rank: usize,
    node: PlanNode
});
wire_enum!(PlanNode; units []; tuples [Return(ReturnPlan)]; records [
    Invoke { invocation: InvocationPlan, arms: Vec<(OutcomeId, PlanTree)>, empty_outcomes: Vec<OutcomeId> },
    Guard { guard: GuardId, inspected: ValueRef, arms: Vec<(GuardArm, PlanTree)> }
]);
wire_record!(CompositionPlan {
    input_identity: String,
    input_revision: String,
    root: PlanTree
});
wire_enum!(TraceStep; units []; tuples []; records [Invocation { invocation: InvocationPlan, outcome: OutcomeId }, Guard { guard: GuardId, inspected: ValueRef, arm: GuardArm }]);
wire_record!(BranchTrace { steps: Vec<TraceStep>, terminal: ReturnPlan });
wire_record!(ResourceLotCorrespondence {
    lot: ResourceLotRef,
    place: String,
    producer: ResourceProducer,
    token_target: String,
    token_type: String,
    revision: BigUint,
    quantity: BigUint,
    provenance: String
});
wire_record!(ValueCorrespondence {
    producer: ProducerRef,
    place: String,
    token_target: String,
    revision: BigUint
});
wire_record!(NormalizedResourceBinding {
    transition: String,
    lot: ResourceLotRef,
    read: BigUint,
    consume: BigUint,
    required_revision: BigUint
});
wire_record!(ResourceCorrespondence { lots: Vec<ResourceLotCorrespondence>, values: Vec<ValueCorrespondence>, normalized_bindings: Vec<NormalizedResourceBinding>, execution_order: Vec<String> });
wire_record!(ResourceTraceCertificate { trace: BranchTrace, lowering: resource::SolverInput, correspondence: ResourceCorrespondence, reachability: resource::ReachabilityWitness, acyclicity: resource::AcyclicWitness, value_sources: Vec<(ProducerRef, SlotValue)> });
wire_record!(CompositionWitness { input_snapshot: CompositionInput, initial_membership: Vec<(InputId, SlotValue)>, resource_traces: Vec<ResourceTraceCertificate> });
wire_record!(RawComposition { plan: CompositionPlan, witness: CompositionWitness, selection: Arc<SelectionEvidence> });
wire_enum!(UnresolvedObligation; units [BranchInhabitation, StateBoundExhausted, BindingBoundExhausted, BranchBoundExhausted, UnresolvedUniqueness]; tuples [Meaning(Vec<MeaningFailure>), SemanticMeaning(Vec<SemanticObligation>), ResourceSolverUnknown(resource::UnknownReason)]; records [
    Type { value: Option<ValueRef>, obligations: Vec<TypeObligation> },
    Inhabitation { producer: ProducerRef, contract: SlotContract },
    ResourceCapacityBound { required: BigUint, limit: usize }
]);
wire_record!(ConnectionFailure { value: Option<ValueRef>, destination: SlotContract, counterexample: CounterexampleCertificate });
wire_record!(AvailableValue { producer: ProducerRef, contract: SlotContract, resource: Option<ResourceLotRef> });
wire_record!(BranchFact { guard: GuardId, inspected: ValueRef, arm: GuardArm, refinement: Option<SlotContract>, assumptions: Vec<ProjectionAssumption>, exact: Option<SlotValue> });
wire_record!(SearchState { available: Vec<AvailableValue>, used_sites: Vec<SiteId>, used_guards: Vec<GuardId>, facts: Vec<BranchFact>, trace: Vec<TraceStep>, pending_failure: Option<FailureOrigin> });
wire_enum!(ChoiceSkeleton; units []; tuples []; records [Invoke { invocation: InvocationPlan, outcomes: Vec<OutcomeId>, empty_outcomes: Vec<OutcomeId> }, Guard { guard: GuardId, inspected: ValueRef, arms: Vec<GuardArm> }]);
wire_record!(MissingSupply { site: Option<SiteId>, port: String, contract: SlotContract });
wire_enum!(TerminalAssessment; units []; tuples [Feasible(ResourceTraceCertificate), EmptyValues(Vec<ProducerRef>), Unknown(Vec<UnresolvedObligation>)]; records [
    ResourceUnreachable { trace: BranchTrace, lowering: resource::SolverInput, correspondence: ResourceCorrespondence, closure: resource::ClosureWitness },
    RejectedLowering { trace: BranchTrace, reason: String }
]);
wire_record!(TerminalCoverage {
    terminal: ReturnPlan,
    assessment: TerminalAssessment
});
wire_record!(ChoiceCoverage { choice: ChoiceSkeleton, children: Vec<usize> });
wire_record!(ClosedSearchState { state: SearchState, terminals: Vec<TerminalCoverage>, choices: Vec<ChoiceCoverage>, rejected_connections: Vec<ConnectionFailure>, missing_supply: Vec<MissingSupply> });
wire_record!(CompositionClosureWitness { input_snapshot: CompositionInput, root: usize, states: Vec<ClosedSearchState> });
wire_enum!(SelectionEvidence; units [AnyFeasible]; tuples []; records [Unique { closure: Box<CompositionClosureWitness>, canonical_plan: String }]);

wire_enum!(resource::TokenKind; units [Input, Output, Failure, Effect, Observation, Accepted]; tuples []; records []);
wire_record!(resource::ColoredToken {
    target: String,
    index: BigUint,
    revision: BigUint,
    kind: resource::TokenKind
});
wire_record!(resource::TypedPlace {
    identity: String,
    token_type: String,
    revision: BigUint
});
wire_record!(resource::TypedTransition { identity: String, input_places: Vec<String>, output_places: Vec<String>, failure_places: Vec<String>, revision: BigUint });
wire_record!(resource::InputBinding {
    transition_id: String,
    name: String,
    place: String,
    token_type: String,
    identity: String,
    provenance: String,
    multiplicity: BigUint,
    mode: resource::BindingMode,
    required_revision: BigUint
});
wire_record!(resource::DeclarationGraph { places: Vec<String>, transitions: Vec<String>, edges: Vec<(String, String)>, revision: BigUint });
wire_record!(resource::DomainBound {
    target_identity: String,
    index: BigUint,
    revision: BigUint,
    max_bindings: BigUint,
    max_search_steps: BigUint
});
wire_record!(resource::Marking { places: Vec<(String, Vec<resource::ColoredToken>)> });
wire_enum!(resource::GoalPredicate; units []; tuples [Not(Box<resource::GoalPredicate>)]; records [
    PlaceHasAtLeast { place: String, count: BigUint },
    PlaceHasToken { place: String, target: String, index: BigUint, revision: BigUint }
]; binary [And(Box<resource::GoalPredicate>, Box<resource::GoalPredicate>), Or(Box<resource::GoalPredicate>, Box<resource::GoalPredicate>)]);
wire_record!(resource::SolverInput { places: Vec<resource::TypedPlace>, transitions: Vec<resource::TypedTransition>, bindings: Vec<resource::InputBinding>, goal: resource::GoalPredicate, graph: resource::DeclarationGraph, marking: resource::Marking, bound: resource::DomainBound });
wire_record!(resource::ReachabilityWitness { path: Vec<String>, final_marking: resource::Marking });
wire_record!(resource::ClosureWitness { explored_markings: Vec<resource::Marking>, steps: BigUint, frontier: Vec<resource::Marking> });
wire_record!(resource::AcyclicWitness { explored_markings: Vec<resource::Marking>, steps: BigUint, frontier: Vec<resource::Marking> });
wire_enum!(resource::UnknownReason; units []; tuples [BindingBoundExhausted(BigUint), SearchStepBoundExhausted(BigUint)]; records []);

#[derive(Debug, Clone, PartialEq)]
pub struct GenerationComposition {
    pub problem: CompositionInput,
    pub derivation: RawComposition,
}
#[derive(Debug, Clone, PartialEq)]
pub enum GenerationEntrypoint {
    Definition {
        identity: String,
        definition: DefinitionRef,
    },
    Composition {
        identity: String,
        problem_identity: String,
        problem_revision: String,
        plan_sha256: String,
    },
}
#[derive(Debug, Clone, PartialEq)]
pub struct GenerationContext {
    pub graph: SemanticGraph,
    pub composition: Option<GenerationComposition>,
    pub entrypoints: Vec<GenerationEntrypoint>,
    pub signature_input: SignatureGenerationInput,
}
impl GenerationContext {
    pub fn signature_input(&self) -> &SignatureGenerationInput {
        &self.signature_input
    }
    pub fn graph(&self) -> &SemanticGraph {
        &self.graph
    }
    pub fn problem(&self) -> Option<&CompositionInput> {
        self.composition.as_ref().map(|value| &value.problem)
    }
    pub fn plan(&self) -> Option<&CompositionPlan> {
        self.composition
            .as_ref()
            .map(|value| &value.derivation.plan)
    }
    pub fn entrypoints(&self) -> &[GenerationEntrypoint] {
        &self.entrypoints
    }
    pub fn provider_interfaces(&self) -> impl Iterator<Item = &FunctionSignature> {
        self.problem()
            .into_iter()
            .flat_map(|value| value.signatures.iter())
    }
}
fn composition_wire_value<T: WireEncode + ?Sized>(value: &T) -> Decoded<serde_json::Value> {
    serde_json::to_value(Wire(value))
        .map_err(|failure| GenerationFailure::Encoding(failure.to_string()))
}
fn composition_wire_decode<T: WireDecode>(value: &serde_json::Value, path: &str) -> Decoded<T> {
    let raw = serde_json::from_str::<ExchangeJson>(&value.to_string())
        .map_err(|failure| GenerationFailure::InvalidJson(failure.to_string()))?;
    T::decode_wire(&raw, path)
}
pub fn encode_composition_input(problem: &CompositionInput) -> Decoded<String> {
    serde_json::to_string(&Wire(problem))
        .map_err(|failure| GenerationFailure::Encoding(failure.to_string()))
}
pub fn problem_sha256(problem: &CompositionInput) -> Decoded<String> {
    Ok(utf8_sha256(&encode_composition_input(problem)?))
}
pub fn plan_sha256(plan: &CompositionPlan) -> Decoded<String> {
    let text = serde_json::to_string(&Wire(plan))
        .map_err(|failure| GenerationFailure::Encoding(failure.to_string()))?;
    Ok(utf8_sha256(&text))
}
fn composition_basis_values(
    library: &TypeSignatureLibrary,
) -> Decoded<(serde_json::Value, serde_json::Value)> {
    let graph = crate::signature_admission::check_type_signatures(library)
        .map_err(|failure| GenerationFailure::Encoding(failure.to_string()))?;
    let native = composition_wire_value(&SemanticBasis::of(&graph))?;
    let wire = crate::signature_admission::signature_basis(library, None, &[])
        .map_err(|failure| GenerationFailure::Encoding(failure.to_string()))
        .and_then(|basis| composition_wire_value(&basis))?;
    Ok((native, wire))
}
fn signature_shape(
    library: &TypeSignatureLibrary,
    type_id: &str,
) -> Option<serde_json::Value> {
    library
        .nodes
        .iter()
        .find(|node| node.id == type_id)
        .and_then(|node| composition_wire_value(&node.shape).ok())
}
fn canonical_inclusion_rule(rule: &str) -> Option<&'static str> {
    match rule {
        "EmptySource" => Some("EmptySource"),
        "Boolean" => Some("Boolean"),
        "Integer" => Some("IntegerIntersection"),
        "String" => Some("StringConditions"),
        "Bytes" => Some("BytesLength"),
        "Unit" => Some("Unit"),
        "UnfoldSource" => Some("UnfoldSource"),
        "UnfoldDestination" => Some("UnfoldDestination"),
        "Array" => Some("Array"),
        "Product" => Some("Product"),
        "SourceUnion" => Some("SourceUnion"),
        "DestinationUnion" => Some("DestinationUnion"),
        _ => None,
    }
}
fn native_inclusion_rule(rule: &str) -> Option<&'static str> {
    match rule {
        "IntegerIntersection" => Some("Integer"),
        "StringConditions" => Some("String"),
        "BytesLength" => Some("Bytes"),
        "EmptySource" => Some("EmptySource"),
        "Boolean" => Some("Boolean"),
        "Unit" => Some("Unit"),
        "UnfoldSource" => Some("UnfoldSource"),
        "UnfoldDestination" => Some("UnfoldDestination"),
        "Array" => Some("Array"),
        "Product" => Some("Product"),
        "SourceUnion" => Some("SourceUnion"),
        "DestinationUnion" => Some("DestinationUnion"),
        _ => None,
    }
}



fn composition_to_signature_wire(
    value: &mut serde_json::Value,
    library: &TypeSignatureLibrary,
    native_basis: &serde_json::Value,
    wire_basis: &serde_json::Value,
) {
    if let Some(id) = value
        .as_object()
        .filter(|fields| {
            fields.contains_key("source")
                && fields.contains_key("definition_name")
                && fields.contains_key("pointer")
        })
        .and_then(|fields| fields.get("definition_name"))
        .and_then(serde_json::Value::as_str)
        .map(str::to_owned)
    {
        *value = serde_json::Value::String(id);
        return;
    }
    if let Some(id) = value
        .as_object()
        .filter(|fields| {
            fields.contains_key("source")
                && fields.contains_key("name")
                && fields.len() == 2
        })
        .and_then(|fields| fields.get("name"))
        .and_then(serde_json::Value::as_str)
        .map(str::to_owned)
    {
        *value = serde_json::Value::String(id);
        return;
    }
    match value {
        serde_json::Value::Array(values) => {
            for value in values {
                composition_to_signature_wire(value, library, native_basis, wire_basis);
            }
        }
        serde_json::Value::Object(fields) => {
            if fields.get("basis") == Some(native_basis) {
                fields.insert("basis".into(), wire_basis.clone());
            }
            if fields.get("tag").and_then(serde_json::Value::as_str) == Some("Operation") {
                if let Some(id) = fields
                    .get("value")
                    .and_then(|value| value.get("name"))
                    .and_then(serde_json::Value::as_str)
                {
                    fields.insert("value".into(), serde_json::Value::String(id.into()));
                }
            }
            for value in fields.values_mut() {
                composition_to_signature_wire(value, library, native_basis, wire_basis);
            }
            if fields.contains_key("basis")
                && fields.contains_key("source")
                && fields.contains_key("destination")
                && fields.contains_key("rule")
                && !fields.contains_key("pairs")
            {
                let source = fields.get("source").cloned();
                let destination = fields.get("destination").cloned();
                let source_id = source
                    .as_ref()
                    .and_then(|slot| slot.get("type_id"))
                    .and_then(serde_json::Value::as_str)
                    .map(str::to_owned);
                let destination_id = destination
                    .as_ref()
                    .and_then(|slot| slot.get("type_id"))
                    .and_then(serde_json::Value::as_str)
                    .map(str::to_owned);
                let rule = fields
                    .get("rule")
                    .and_then(|rule| rule.get("tag"))
                    .and_then(serde_json::Value::as_str)
                    .and_then(canonical_inclusion_rule);
                if let (
                    Some(source),
                    Some(destination),
                    Some(source_id),
                    Some(destination_id),
                    Some(rule),
                ) = (source, destination, source_id, destination_id, rule)
                {
                    if let (Some(source_shape), Some(destination_shape)) = (
                        signature_shape(library, &source_id),
                        signature_shape(library, &destination_id),
                    ) {
                        let pair = serde_json::json!({
                            "source": source,
                            "destination": destination,
                            "source_tag": null
                        });
                        fields.remove("rule");
                        fields.insert("empty_types".into(), serde_json::json!([]));
                        fields.insert(
                            "pairs".into(),
                            serde_json::json!([{
                                "pair": pair,
                                "source_shape": source_shape,
                                "destination_shape": destination_shape,
                                "rule": {"tag": rule},
                                "children": []
                            }]),
                        );
                        fields.insert(
                            "root".into(),
                            serde_json::Value::String("0".into()),
                        );
                    }
                }
            }
            if let Some(reference) = fields.remove("type_ref") {
                fields.insert("type_id".into(), reference);
            }
            if fields.contains_key("definition_ref")
                && fields.contains_key("reference_trace")
                && fields.contains_key("observed")
            {
                if let Some(type_id) = fields
                    .get("type_id")
                    .and_then(serde_json::Value::as_str)
                    .map(str::to_owned)
                {
                    let origin = fields.get("origin").cloned().unwrap_or_default();
                    let locator = origin.get("pointer").cloned().unwrap_or_else(|| serde_json::json!([]));
                    let source = serde_json::json!({
                        "repository": "ncoh-type-signatures@1",
                        "revision": library.revision,
                        "path": library.identity,
                        "content_digest": crate::signature_admission::canonical_digest(library)
                    });
                    let observed = fields.get("observed").cloned().unwrap_or_default().to_string();
                    fields.remove("definition_ref");
                    fields.insert("target".into(), serde_json::json!({"tag":"Type","value":type_id}));
                    fields.insert("origin".into(), serde_json::json!({"source":source,"locator":locator}));
                    fields.insert("observed".into(), serde_json::Value::String(observed));
                }
            }
        }
        _ => {}
    }
}
fn composition_add_causes(
    value: &mut serde_json::Value,
    causes: &[(FunctionRef, Vec<(OutcomeId, OutcomeCause)>)],
) -> Decoded<()> {
    match value {
        serde_json::Value::Array(values) => {
            for value in values {
                composition_add_causes(value, causes)?;
            }
        }
        serde_json::Value::Object(fields) => {
            let identity = fields
                .get("reference")
                .and_then(|reference| reference.get("identity"))
                .and_then(serde_json::Value::as_str)
                .map(str::to_owned);
            if let (Some(identity), Some(outcomes)) = (
                identity,
                fields
                    .get_mut("outcomes")
                    .and_then(serde_json::Value::as_array_mut),
            ) {
                if let Some((_, declared)) = causes
                    .iter()
                    .find(|(reference, _)| reference.identity == identity)
                {
                    for outcome in outcomes {
                        let id = outcome
                            .get("id")
                            .and_then(serde_json::Value::as_str)
                            .map(str::to_owned);
                        if let Some((_, cause)) = id.and_then(|id| {
                            declared.iter().find(|(declared, _)| declared.0 == id)
                        }) {
                            outcome
                                .as_object_mut()
                                .ok_or_else(|| shape("$.signature.outcome", "record"))?
                                .insert("cause".into(), composition_wire_value(cause)?);
                        }
                    }
                }
            }
            for value in fields.values_mut() {
                composition_add_causes(value, causes)?;
            }
        }
        _ => {}
    }
    Ok(())
}
fn composition_check_causes(
    fields: &mut serde_json::Map<String, serde_json::Value>,
    library: &TypeSignatureLibrary,
) -> Decoded<()> {
    if !fields.contains_key("form") || !fields.contains_key("outcomes") {
        return Ok(());
    }
    let operation_id = fields
        .get("form")
        .filter(|form| form.get("tag").and_then(serde_json::Value::as_str) == Some("Operation"))
        .and_then(|form| form.get("value"))
        .and_then(serde_json::Value::as_str);
    let operation = operation_id
        .map(|operation_id| {
            library
                .definitions
                .iter()
                .find(|definition| definition.id == operation_id)
                .and_then(|definition| match &definition.shape {
                    SignatureDefinitionShape::Operation(operation) => Some(operation),
                    _ => None,
                })
                .ok_or_else(|| shape("$.signature.form.value", "declared operation"))
        })
        .transpose()?;
    let outcomes = fields
        .get_mut("outcomes")
        .and_then(serde_json::Value::as_array_mut)
        .ok_or_else(|| shape("$.signature.outcomes", "function outcomes"))?;
    if let Some(operation) = operation {
        for expected in &operation.outcomes {
            let actual = outcomes
                .iter()
                .find(|outcome| {
                    outcome.get("id").and_then(serde_json::Value::as_str)
                        == Some(expected.id.as_str())
                })
                .ok_or_else(|| {
                    shape("$.signature.outcomes", "every declared operation outcome")
                })?;
            if actual.get("cause") != Some(&composition_wire_value(&expected.cause)?) {
                return Err(shape(
                    "$.signature.outcome.cause",
                    "unchanged declared outcome cause",
                ));
            }
        }
    }
    for outcome in outcomes {
        let id = outcome
            .get("id")
            .and_then(serde_json::Value::as_str)
            .unwrap_or_default()
            .to_owned();
        let cause = outcome
            .as_object_mut()
            .and_then(|outcome| outcome.remove("cause"))
            .ok_or_else(|| shape("$.signature.outcome.cause", "outcome cause"))?;
        if operation.is_some_and(|operation| {
            !operation.outcomes.iter().any(|expected| expected.id == id)
                && cause.get("tag").and_then(serde_json::Value::as_str)
                    != Some("ExternalCondition")
        }) {
            return Err(shape(
                "$.signature.outcome.cause",
                "external condition supplement",
            ));
        }
    }
    Ok(())
}

fn composition_from_signature_wire(
    value: &mut serde_json::Value,
    library: &TypeSignatureLibrary,
    native_basis: &serde_json::Value,
    wire_basis: &serde_json::Value,
) -> Decoded<()> {
    let library_digest = crate::signature_admission::canonical_digest(library);
    composition_value_from_signature_wire(
        value,
        library,
        &library_digest,
        native_basis,
        wire_basis,
    )
}

fn composition_value_from_signature_wire(
    value: &mut serde_json::Value,
    library: &TypeSignatureLibrary,
    library_digest: &str,
    native_basis: &serde_json::Value,
    wire_basis: &serde_json::Value,
) -> Decoded<()> {
    match value {
        serde_json::Value::Array(values) => {
            for value in values {
                composition_value_from_signature_wire(
                    value,
                    library,
                    library_digest,
                    native_basis,
                    wire_basis,
                )?;
            }
        }
        serde_json::Value::Object(fields) => {
            if fields.contains_key("target")
                && fields.contains_key("reference_trace")
                && fields.contains_key("observed")
            {
                let type_id = fields
                    .get("type_id")
                    .and_then(serde_json::Value::as_str)
                    .ok_or_else(|| shape("$.composition.value_failure.type_id", "type identifier"))?
                    .to_owned();
                let reference = crate::signature_admission::signature_type_ref(
                    library,
                    library_digest,
                    &type_id,
                );
                let pointer = fields
                    .get("origin")
                    .and_then(|origin| origin.get("locator"))
                    .and_then(serde_json::Value::as_array)
                    .map(|items| {
                        items
                            .iter()
                            .filter_map(serde_json::Value::as_str)
                            .map(str::to_owned)
                            .collect::<Vec<_>>()
                    })
                    .unwrap_or_default();
                let observed = fields
                    .get("observed")
                    .and_then(serde_json::Value::as_str)
                    .and_then(|text| serde_json::from_str(text).ok())
                    .ok_or_else(|| shape("$.composition.value_failure.observed", "encoded slot value"))?;
                let trace = fields
                    .get("reference_trace")
                    .and_then(serde_json::Value::as_array)
                    .cloned()
                    .unwrap_or_default()
                    .into_iter()
                    .filter_map(|value| value.as_str().map(str::to_owned))
                    .map(|id| {
                        composition_wire_value(&crate::signature_admission::signature_type_ref(
                            library,
                            library_digest,
                            &id,
                        ))
                    })
                    .collect::<Decoded<Vec<_>>>()?;
                fields.remove("target");
                fields.insert(
                    "definition_ref".into(),
                    composition_wire_value(&DefinitionRef {
                        source: reference.source.clone(),
                        name: reference.definition_name.clone(),
                    })?,
                );
                fields.insert(
                    "origin".into(),
                    composition_wire_value(&OccurrenceRef {
                        source: reference.source.clone(),
                        pointer: pointer.into(),
                    })?,
                );
                fields.insert("observed".into(), observed);
                fields.insert("reference_trace".into(), serde_json::Value::Array(trace));
            }
            if fields.contains_key("pairs")
                && fields.contains_key("root")
                && fields.contains_key("empty_types")
                && fields.contains_key("source")
                && fields.contains_key("destination")
            {
                let rule = fields
                    .get("pairs")
                    .and_then(serde_json::Value::as_array)
                    .and_then(|pairs| pairs.first())
                    .and_then(|pair| pair.get("rule"))
                    .and_then(|rule| rule.get("tag"))
                    .and_then(serde_json::Value::as_str)
                    .and_then(native_inclusion_rule)
                    .ok_or_else(|| {
                        shape("$.composition.inclusion.rule", "known rule")
                    })?;
                fields.remove("pairs");
                fields.remove("root");
                fields.remove("empty_types");
                fields.insert("rule".into(), serde_json::json!({"tag": rule}));
            }
            if let Some(type_id) = fields
                .remove("type_id")
                .and_then(|value| value.as_str().map(str::to_owned))
            {
                let reference = crate::signature_admission::signature_type_ref(
                    library,
                    library_digest,
                    &type_id,
                );
                fields.insert("type_ref".into(), composition_wire_value(&reference)?);
            }
            if let Some(type_id) = fields
                .get("source_type")
                .and_then(serde_json::Value::as_str)
            {
                let reference = crate::signature_admission::signature_type_ref(
                    library,
                    library_digest,
                    type_id,
                );
                fields.insert("source_type".into(), composition_wire_value(&reference)?);
            }
            if fields.contains_key("id") {
                if let Some(type_id) = fields
                    .get("token_type")
                    .and_then(serde_json::Value::as_str)
                    .map(str::to_owned)
                {
                    let reference = crate::signature_admission::signature_type_ref(
                        library,
                        library_digest,
                        &type_id,
                    );
                    fields.insert(
                        "token_type".into(),
                        composition_wire_value(&reference)?,
                    );
                }
            }
            composition_check_causes(fields, library)?;
            if fields.contains_key("basis") {
                if fields.get("basis") != Some(wire_basis) {
                    return Err(shape("$.composition.basis", "checked signature basis"));
                }
                fields.insert("basis".into(), native_basis.clone());
            }
            if fields.get("tag").and_then(serde_json::Value::as_str) == Some("Operation") {
                if let Some(id) = fields.get("value").and_then(serde_json::Value::as_str) {
                    let reference = crate::signature_admission::signature_definition_ref(
                        library,
                        library_digest,
                        id,
                    );
                    fields.insert("value".into(), composition_wire_value(&reference)?);
                }
            }
            for value in fields.values_mut() {
                composition_value_from_signature_wire(
                    value,
                    library,
                    library_digest,
                    native_basis,
                    wire_basis,
                )?;
            }
        }
        _ => {}
    }
    Ok(())
}
fn decode_signature_composition_value<T: WireDecode>(
    library: &TypeSignatureLibrary,
    value: &serde_json::Value,
    path: &str,
) -> Decoded<T> {
    let (native_basis, wire_basis) = composition_basis_values(library)?;
    let mut native = value.clone();
    composition_from_signature_wire(
        &mut native,
        library,
        &native_basis,
        &wire_basis,
    )?;
    composition_wire_decode(&native, path)
}

pub fn signature_composition_from_native(
    library: &TypeSignatureLibrary,
    problem: &CompositionInput,
    derivation: &RawComposition,
    causes: &[(FunctionRef, Vec<(OutcomeId, OutcomeCause)>)],
) -> Decoded<SignatureComposition> {
    let (native_basis, wire_basis) = composition_basis_values(library)?;
    let mut problem = composition_wire_value(problem)?;
    let mut derivation = composition_wire_value(derivation)?;
    composition_add_causes(&mut problem, causes)?;
    composition_add_causes(&mut derivation, causes)?;
    composition_to_signature_wire(&mut problem, library, &native_basis, &wire_basis);
    composition_to_signature_wire(&mut derivation, library, &native_basis, &wire_basis);
    Ok(SignatureComposition {
        problem,
        derivation,
    })
}
pub fn decode_signature_problem(
    library: &TypeSignatureLibrary,
    value: &serde_json::Value,
) -> Decoded<CompositionInput> {
    let problem = decode_signature_composition_value::<CompositionInput>(
        library,
        value,
        "$.composition.problem",
    )?;
    let graph = crate::signature_admission::check_type_signatures(library)
        .map_err(|failure| GenerationFailure::Encoding(failure.to_string()))?;
    prepare_composition(&graph, problem.clone())
        .map_err(|failure| GenerationFailure::Encoding(format!("{failure:?}")))?;
    Ok(problem)
}
pub(crate) fn decode_signature_composition(
    input: &SignatureGenerationInput,
    graph: &SemanticGraph,
) -> Decoded<Option<GenerationComposition>> {
    let Some(value) = &input.composition else {
        return Ok(None);
    };
    let problem = decode_signature_composition_value::<CompositionInput>(
        &input.signatures,
        &value.problem,
        "$.composition.problem",
    )?;
    let derivation = decode_signature_composition_value::<RawComposition>(
        &input.signatures,
        &value.derivation,
        "$.composition.derivation",
    )?;
    let prepared = prepare_composition(graph, problem.clone())
        .map_err(|failure| GenerationFailure::Encoding(format!("{failure:?}")))?;
    verify_composition(&prepared, &derivation)
        .map_err(|failure| GenerationFailure::Encoding(format!("{failure:?}")))?;
    Ok(Some(GenerationComposition {
        problem,
        derivation,
    }))
}
pub fn signature_render_context(
    checked: crate::signature_admission::CheckedSignatureGeneration,
) -> Decoded<GenerationContext> {
    let input = checked.input().clone();
    let graph = checked.graph().clone();
    let composition = decode_signature_composition(&input, &graph)?;
    let mut entrypoints = input
        .entrypoints
        .iter()
        .map(|value| GenerationEntrypoint::Definition {
            identity: value.identity.clone(),
            definition: crate::signature_admission::signature_definition_ref(
                &input.signatures,
                &input.basis.graph_sha256,
                &value.definition,
            ),
        })
        .collect::<Vec<_>>();
    if let Some(value) = &composition {
        entrypoints.push(GenerationEntrypoint::Composition {
            identity: value.problem.identity.clone(),
            problem_identity: value.problem.identity.clone(),
            problem_revision: value.problem.revision.clone(),
            plan_sha256: plan_sha256(&value.derivation.plan)?,
        });
    }
    Ok(GenerationContext {
        graph,
        composition,
        entrypoints,
        signature_input: input,
    })
}
pub fn signature_generation_context(
    expected: &SignatureGenerationBasis,
    text: &str,
) -> Decoded<GenerationContext> {
    let input = decode_signature_generation(text)?;
    let checked = crate::signature_admission::admit_signature_generation(expected, input)
        .map_err(|failure| GenerationFailure::Encoding(failure.to_string()))?;
    signature_render_context(checked)
}
pub fn verify_generation(context: &GenerationContext) -> Decoded<&SignatureGenerationInput> {
    if let Some(value) = &context.composition {
        let prepared = prepare_composition(&context.graph, value.problem.clone())
            .map_err(|failure| GenerationFailure::Encoding(format!("{failure:?}")))?;
        verify_composition(&prepared, &value.derivation)
            .map_err(|failure| GenerationFailure::Encoding(format!("{failure:?}")))?;
    }
    Ok(&context.signature_input)
}
