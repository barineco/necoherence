// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT
wire_record!(SourceIdentity {
    repository: String,
    revision: String,
    path: String,
    content_digest: String
});
wire_record!(Origin { source:SourceIdentity, locator:Vec<String> });
wire_record!(SourceRef { repository:String, revision:String, path:String, content_digest:String, document_id:String, declared_revision:Option<BigInt> });
wire_record!(ProfileRef {
    identity: String,
    revision: String,
    content_digest: String
});
wire_record!(TypeRef { source:Arc<SourceRef>, definition_name:Arc<str>, pointer:Arc<[String]> });
wire_record!(DefinitionRef { source:Arc<SourceRef>, name:Arc<str> });
wire_record!(OccurrenceRef { source:Arc<SourceRef>, pointer:Arc<[String]> });
wire_enum!(IntegerDomain; units [Unbounded]; tuples []; records [Inclusive { minimum:BigInt, maximum:BigInt }]);
wire_enum!(IntegerForm; units [Number,IntegralDecimal,DecimalString]; tuples []; records []);
wire_record!(IntegerDomainBinding { name:String, reference:ProfileRef, range:IntegerDomain, forms:Vec<IntegerForm> });
wire_record!(NumberModel { decimals: bool });
wire_enum!(BytesAlphabet; units [Standard,UrlSafe,Either]; tuples []; records []);
wire_enum!(StringLengthUnit; units [Utf8Bytes,UnicodeScalars,Graphemes]; tuples []; records []);
wire_record!(LengthBound { unit:StringLengthUnit, minimum:Option<BigUint>, maximum:Option<BigUint> });
wire_enum!(FormatUse; units []; tuples [Named(String),Inline(FormatRule)]; records []);
wire_enum!(GraphemeProperty; units [Other,Cr,Lf,Control,Extend,Zwj,RegionalIndicator,Prepend,SpacingMark,L,V,T,Lv,Lvt]; tuples []; records []);
wire_enum!(IndicProperty; units [Other,Consonant,Extend,Linker]; tuples []; records []);
wire_record!(CodepointRange {
    first: BigUint,
    last: BigUint
});
wire_record!(GraphemeRange {
    first: BigUint,
    last: BigUint,
    property: GraphemeProperty
});
wire_record!(IndicRange {
    first: BigUint,
    last: BigUint,
    property: IndicProperty
});
wire_record!(GraphemeComponent {
    unicode_version: String,
    uax29_revision: String,
    cluster_profile: String
});
wire_record!(GraphemeSource {
    role: String,
    origin: Origin
});
wire_record!(GraphemeRules { reference:ProfileRef,component:GraphemeComponent,table_sha256:String,sources:Vec<GraphemeSource>,properties:Vec<GraphemeRange>,extended_pictographic:Vec<CodepointRange>,indic_conjunct:Vec<IndicRange> });
wire_record!(BytesPolicy { reference:ProfileRef,padding_optional:bool,alphabet:BytesAlphabet,strict_pad_bits:bool,wrapper:Option<String> });
wire_record!(CalendarRule {
    allow_second_60: bool,
    minimum_year: BigUint,
    maximum_year: BigUint,
    reject_utc_year_outside_range: bool => "rejectUtcYearOutsideRange"
});
wire_record!(DfaTransition {
    from_state: BigUint,
    first: BigUint,
    last: BigUint,
    to_state: BigUint
});
wire_record!(DfaSpec { state_count:BigUint,initial_state:BigUint,accepting_states:Vec<BigUint>,transitions:Vec<DfaTransition> });
wire_enum!(FormatRule; units [Text]; tuples [Literal(String),Sequence(Vec<FormatRule>),Optional(Box<FormatRule>),AsciiDfa(DfaSpec),Timestamp(CalendarRule),Choice(Vec<FormatRule>),Not(Box<FormatRule>)]; records [Labels { separator:String,min_count:BigUint,max_count:Option<BigUint>,total_max:Option<BigUint>,rule:Box<FormatRule> },Bounded { unit:StringLengthUnit,maximum:BigUint,rule:Box<FormatRule> },Identifier { first_alphabet:String,rest_alphabet:String,exact_length:Option<BigUint>,min_length:BigUint,max_length:Option<BigUint>,forbidden:Vec<String> },AbsoluteUri { max_bytes:Option<BigUint> },LanguageTag { grandfathered:Vec<String> }]);
wire_record!(FormatBinding {
    name: String,
    reference: ProfileRef,
    rule: FormatRule
});
wire_record!(Wrapper {
    name: String,
    key: String,
    payload: WrapperPayload
});
wire_record!(BooleanSpec { const_value:Option<bool>,default_value:Option<bool> });
wire_record!(IntegerSpec { domain:Option<String>,minimum:Option<BigInt>,maximum:Option<BigInt>,const_value:Option<BigInt>,enum_values:Option<Vec<BigInt>>,default_value:Option<BigInt> });
wire_record!(DecimalBound {
    mantissa: BigInt,
    scale: BigUint,
    exclusive: bool
});
wire_record!(DecimalSpec { minimum:Option<DecimalBound>,maximum:Option<DecimalBound> });
wire_record!(StringSpec { format:Option<FormatUse>,lengths:Vec<LengthBound>,wrapper:Option<String>,const_value:Option<String>,enum_values:Option<Vec<String>>,examples:Vec<String>,default_value:Option<String> });
wire_enum!(SealedLeaf; units []; tuples [String(StringSpec),Integer(IntegerSpec)]; records []);
wire_record!(SealedField {
    key: String,
    required: bool,
    leaf: SealedLeaf
});
wire_enum!(SealedExtras; units [Reject,Any]; tuples []; records []);
wire_record!(SealedForm { tag:String,fields:Vec<SealedField>,extras:SealedExtras });
wire_record!(TagModel { key:String,format:Option<String>,sealed:Vec<SealedForm> });
wire_record!(SealedRefinement {
    key: String,
    leaf: SealedLeaf
});
wire_record!(VersionedSemanticProfile { reference:ProfileRef,source_refs:Vec<SourceIdentity>,integer_domains:Vec<IntegerDomainBinding>,default_integer_domain:String,numbers:NumberModel,grapheme_rules:Option<GraphemeRules>,format_bindings:Vec<FormatBinding>,bytes_policy:Option<BytesPolicy>,wrappers:Vec<Wrapper>,tag:Option<TagModel> });
wire_record!(SemanticGraph { profile:VersionedSemanticProfile,nodes:Vec<TypeNode>,source_refs:Vec<SourceRef> });
wire_record!(DefaultApplication {
    value_path: ValuePath,
    type_ref: TypeRef,
    origin: OccurrenceRef,
    value: JsonValue
});
wire_record!(LengthSpec { minimum:Option<BigUint>,maximum:Option<BigUint> });
wire_enum!(UnknownKind; units [Any,OrdinaryObject]; tuples []; records []);
wire_enum!(ValueKind; units [Null,Boolean,Number,String,Array,Object]; tuples []; records []);
wire_enum!(MemberTest; units [Absent]; tuples [Format(String)]; records []);
wire_record!(ValueSemanticProfile { reference:ProfileRef,source_refs:Vec<SourceIdentity>,integer_domains:Vec<IntegerDomainBinding>,default_integer_domain:String,numbers:NumberModel,grapheme_rules:Option<GraphemeRules>,format_bindings:Vec<FormatBinding>,bytes_policy:Option<BytesPolicy>,wrappers:Vec<Wrapper>,tag:Option<TagModel> });
wire_enum!(AnnotationTarget; units [Library]; tuples [Group(String),Definition(String),Type(String)]; records [Outcome { definition:String,outcome:String }]);
wire_record!(ProvenanceBinding { target:AnnotationTarget,origins:Vec<Origin> });
wire_record!(DefinitionGroup { id:String,members:Vec<String> });
wire_record!(Annotation {
    target: AnnotationTarget,
    key: String,
    value: JsonValue
});
wire_record!(SignatureSlot {
    type_id: String,
    required: bool,
    nullable: bool
});
wire_record!(SignatureField {
    wire_name: String,
    slot: SignatureSlot
});
wire_record!(SignatureElementContract {
    type_id: String,
    nullable: bool
});
wire_enum!(SignatureExtraMembers; units [Reject]; tuples []; records [Allow { key_format:Option<FormatUse>,value:SignatureElementContract }]);
wire_record!(SignatureProduct { fields:Vec<SignatureField>,extras:SignatureExtraMembers });
wire_record!(SignatureArray { item:SignatureElementContract,minimum:Option<BigUint> => "min_length",maximum:Option<BigUint> => "max_length" });
wire_record!(SignatureUnionBranch {
    target: String,
    wire_tag: String,
    selector: BranchSelector
});
wire_record!(SignatureUnion { branches:Vec<SignatureUnionBranch> });
wire_enum!(Shape; units [Unit,Never]; tuples [Unknown(UnknownKind),Boolean(BooleanSpec),Integer(IntegerSpec),Decimal(DecimalSpec),String(StringSpec),Bytes(LengthSpec),Product(SignatureProduct),Array(SignatureArray),TaggedUnion(SignatureUnion)]; records [Sealed { tag:String,refinements:Vec<SealedRefinement> },Alias { target:String },RawBody { encoding:String },Opaque { type_name:String }]);
wire_record!(TypeNodeInput {
    id: String,
    shape: Shape
});
wire_enum!(EffectPoint; units [HttpRequestResponse,DataOnly]; tuples []; records []);
wire_enum!(necoherence::type_signatures::OutcomeForm; units [Success,DeclaredFailure]; tuples []; records []);
wire_enum!(OutcomeCause; units []; tuples []; records [ValueContract { origin:Origin },ExternalCondition { specification:Origin }]);
wire_record!(SignaturePort {
    id: String,
    contract: SignatureSlot
});
wire_record!(SignatureResourceProduction {
    id: String,
    token_type: String,
    revision: BigUint,
    quantity: BigUint,
    provenance: String
});
wire_record!(SignatureOutcome { id:String,form:necoherence::type_signatures::OutcomeForm,cause:OutcomeCause,value_ports:Vec<SignaturePort>,produced_resources:Vec<SignatureResourceProduction> });
wire_record!(OperationContract { effect:EffectPoint,inputs:Vec<SignaturePort>,outcomes:Vec<SignatureOutcome> });
wire_enum!(SignatureDefinitionShape; units []; tuples [Value(String),Symbol(String),Operation(OperationContract),Message(String)]; records []);
wire_record!(DefinitionInput {
    id: String,
    wire_identity: String,
    shape: SignatureDefinitionShape
});
wire_record!(TypeSignatureLibrary { schema:String,identity:String,revision:String,profile:ValueSemanticProfile,sources:Vec<SourceIdentity>,provenance:Vec<ProvenanceBinding>,groups:Vec<DefinitionGroup>,annotations:Vec<Annotation>,nodes:Vec<TypeNodeInput>,definitions:Vec<DefinitionInput> });
wire_record!(SignatureGenerationBasis { signature_schema:String,library_identity:String,library_revision:String,profile:ProfileRef,graph_sha256:String,provenance_sha256:String,metadata_sha256:String,problem_sha256:Option<String>,observations_sha256:Option<String>,entrypoints_sha256:String });
wire_record!(ExpectedSignatureBasis { basis:SignatureGenerationBasis,observations:Option<GoalObservations> });
wire_record!(SignatureEntrypoint {
    identity: String,
    definition: String
});
wire_enum!(PathStep; units []; tuples [Field(String),Index(BigUint),Variant(String)]; records []);
wire_enum!(SlotValue; units [Absent,Null]; tuples [Present(JsonValue)]; records []);
wire_enum!(ValueCondition; units [MissingRequired,NullNotAllowed,ConstMismatch,EnumMismatch,BelowMinimum,AboveMaximum,IntegerDomain,StringLength,ArrayLength,BytesLength,InvalidBytes,InvalidTag,ReservedForm,NoBranchSelected,Uninhabited,InvalidDataModel,ReferenceCycle]; tuples [WrongValueKind(String),Format(String),InvalidWrapper(String),KeyFormat(String),DuplicateField(String),UnexpectedField(String)]; records []);
wire_record!(ValueFailure { type_ref:TypeRef,definition_ref:DefinitionRef,origin:OccurrenceRef,value_path:ValuePath,condition:ValueCondition,observed:SlotValue,reference_trace:Vec<TypeRef> });
wire_enum!(ProfilePredicate; units [Pr01,Pr02,Pr03,Pr04,Pr05,Pr06,Pr07,Pr08,Pr09,Pr10,Pr11,Pr12,Pr13,Pr14,Pr15,Pr16]; tuples []; records []);
wire_record!(ProfileFailure { reference:ProfileRef,predicate:ProfilePredicate,location:Vec<String> });
wire_record!(SignatureGenerationInput { schema:String,basis:SignatureGenerationBasis,signatures:Arc<TypeSignatureLibrary>,composition:Option<serde_json::Value>,entrypoints:Vec<SignatureEntrypoint> });
wire_record!(SlotContract {
    type_ref: TypeRef,
    required: bool,
    nullable: bool
});
wire_record!(ElementContract {
    type_ref: TypeRef,
    nullable: bool
});
wire_enum_prefixed!(ExtraMembers; units [Reject]; tuples []; records [Allow { key_format:Option<FormatUse>, value:ElementContract }]);
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
wire_enum_prefixed!(TypeShape; units [Unit,Never]; tuples [Unknown(UnknownKind),Boolean(BooleanSpec),Integer(IntegerSpec),Decimal(DecimalSpec),String(StringSpec),Bytes(LengthSpec),Product(ProductSpec),Array(ArraySpec),TaggedUnion(UnionSpec)]; records [Sealed { tag:String,refinements:Vec<SealedRefinement> },Alias { target:TypeRef,reference_text:String },RawBody { encoding:String },Opaque { type_name:String }]);
wire_record!(TypeNode { reference:TypeRef, shape:TypeShape, description:Option<String>, attributes:Vec<OccurrenceRef>, extensions:Vec<OccurrenceRef> });
wire_enum_prefixed!(SemanticReason; units [MissingGraphemeRules,MissingBytesPolicy,DecimalNotAdmitted,IntegerBound,MissingTagModel,UnresolvedType,MembershipBound]; tuples [UnknownFormat(String),UnknownIntegerDomain(String),UnknownWrapper(String),WrapperPayload(String),UnknownSealedTag(String),OpaqueType(String),UninterpretedExtension(String),InvalidProfile(String),CertificateMismatch(String),ProjectionUnavailable(String)]; records []);
wire_record!(SemanticObligation {
    type_ref: TypeRef,
    origin: OccurrenceRef,
    value_path: ValuePath,
    profile: ProfileRef,
    reason: SemanticReason
});
wire_record!(EvaluationProvenance {
    operation: String,
    type_ref: TypeRef,
    value_path: ValuePath
});
wire_record!(CompositionProvenance {
    operation: String,
    input_identity: String,
    input_revision: String
});
wire_enum!(ReasonDisposition; units [Residual,Stopped,Failed]; tuples []; records []);
wire_enum!(ProjectionAssumption; units []; tuples [Present(ValuePath),NonNull(ValuePath)]; records [Variant { path:ValuePath,tag:String },IndexPresent { path:ValuePath,index:BigUint }]);
wire_record!(ProjectionCertificate { profile:ProfileRef,source_refs:Vec<SourceRef>,source:SlotContract,path:ValuePath,assumptions:Vec<ProjectionAssumption>,destination:SlotContract });
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
wire_record!(SemanticBasis { profile: VersionedSemanticProfile, sources: Vec<SourceRef> });
wire_record!(FunctionRef {
    identity: String,
    revision: String,
    content_digest: String
});
wire_record!(TypePair { source: SlotContract, destination: SlotContract, source_tag: Option<String> });
wire_enum!(InclusionRule; units [SameDefinedType,EmptySource,Boolean,IntegerIntersection,FiniteStrings,StringConditions,BytesLength,Unit,UnfoldSource,UnfoldDestination,Array,Product,SourceUnion,DestinationUnion]; tuples []; records []);
wire_record!(PairEntry { pair: TypePair, source_shape: TypeShape, destination_shape: TypeShape, rule: InclusionRule, children: Vec<BigUint> });
wire_record!(InclusionCertificate {
    basis: SemanticBasis,
    source: SlotContract,
    destination: SlotContract,
    empty_types: Vec<TypeRef>,
    pairs: Vec<PairEntry>,
    root: BigUint
});
wire_enum_prefixed!(TypeObligationReason; units [ConstraintImplication,Presence,UnionRemainder,Inhabitation,ObligationBoundExhausted]; tuples [Meaning(Vec<SemanticObligation>),ExtraField(String)]; records []);
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
wire_enum!(necoherence::semantic_composition::OutcomeForm; units [Success, DeclaredFailure]; tuples []; records []);
wire_record!(OutcomeContract { id: OutcomeId, form: necoherence::semantic_composition::OutcomeForm, value_ports: Vec<OutputPort>, produced_resources: Vec<ResourceProduction> });
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
    max_tokens: BigUint
});
wire_record!(SearchBounds { max_expanded_states: BigUint, max_binding_candidates: BigUint, max_type_obligations: BigUint, max_branch_nodes: BigUint, resource_bounds: Option<ResourceBounds>, max_sample_length: BigUint });
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
    rank: BigUint,
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
wire_enum_prefixed!(UnresolvedObligation; units [BranchInhabitation, StateBoundExhausted, BindingBoundExhausted, BranchBoundExhausted, UnresolvedUniqueness]; tuples [Meaning(Vec<SemanticObligation>), ResourceSolverUnknown(resource::UnknownReason)]; records [
    Type { value: Option<ValueRef>, obligations: Vec<TypeObligation> },
    Inhabitation { producer: ProducerRef, contract: SlotContract },
    ResourceCapacityBound { required: BigUint, limit: BigUint }
]);
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
wire_enum_prefixed!(resource::UnknownReason; units []; tuples [BindingBoundExhausted(BigUint), SearchStepBoundExhausted(BigUint)]; records []);
