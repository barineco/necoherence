// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

import gleam/list
import gleam/option.{type Option}
import necoherence/exact_json as kdl

pub type JsonValue =
  kdl.JsonValue

pub type SourceIdentity {
  SourceIdentity(
    repository: String,
    revision: String,
    path: String,
    content_digest: String,
  )
}

pub type Origin {
  Origin(source: SourceIdentity, locator: List(String))
}

pub type SourceRef {
  SourceRef(
    repository: String,
    revision: String,
    path: String,
    content_digest: String,
    document_id: String,
    declared_revision: Option(Int),
  )
}

pub type ProfileRef {
  ProfileRef(identity: String, revision: String, content_digest: String)
}

pub type TypeRef {
  TypeRef(source: SourceRef, definition_name: String, pointer: List(String))
}

pub type DefinitionRef {
  DefinitionRef(source: SourceRef, name: String)
}

pub type OccurrenceRef {
  OccurrenceRef(source: SourceRef, pointer: List(String))
}

pub type IntegerDomain {
  Unbounded
  IntegerInterval(minimum: Int, maximum: Int)
}

pub type StringLengthUnit {
  Utf8Bytes
  UnicodeScalars
  Graphemes
}

pub type GraphemeProperty {
  Other
  Cr
  Lf
  Control
  Extend
  Zwj
  RegionalIndicator
  Prepend
  SpacingMark
  L
  V
  T
  Lv
  Lvt
}

pub type IndicProperty {
  IndicOther
  Consonant
  IndicExtend
  Linker
}

pub type CodepointRange {
  CodepointRange(first: Int, last: Int)
}

pub type GraphemeRange {
  GraphemeRange(first: Int, last: Int, property: GraphemeProperty)
}

pub type IndicRange {
  IndicRange(first: Int, last: Int, property: IndicProperty)
}

pub type GraphemeComponent {
  GraphemeComponent(
    unicode_version: String,
    uax29_revision: String,
    cluster_profile: String,
  )
}

pub type GraphemeSource {
  GraphemeSource(role: String, origin: Origin)
}

pub type GraphemeRules {
  GraphemeRules(
    reference: ProfileRef,
    properties: List(GraphemeRange),
    extended_pictographic: List(CodepointRange),
    indic_conjunct: List(IndicRange),
    component: GraphemeComponent,
    table_sha256: String,
    sources: List(GraphemeSource),
  )
}

pub type CalendarRule {
  CalendarRule(
    allow_second_60: Bool,
    minimum_year: Int,
    maximum_year: Int,
    reject_utc_year_outside_range: Bool,
  )
}

pub type DfaTransition {
  DfaTransition(from_state: Int, first: Int, last: Int, to_state: Int)
}

pub type DfaSpec {
  DfaSpec(
    state_count: Int,
    initial_state: Int,
    accepting_states: List(Int),
    transitions: List(DfaTransition),
  )
}

pub type FormatRule {
  Literal(value: String)
  Sequence(parts: List(FormatRule))
  Optional(rule: FormatRule)
  Labels(
    separator: String,
    min_count: Int,
    max_count: Option(Int),
    total_max: Option(Int),
    rule: FormatRule,
  )
  Bounded(unit: StringLengthUnit, maximum: Int, rule: FormatRule)
  AsciiDfa(spec: DfaSpec)
  Identifier(
    first_alphabet: String,
    rest_alphabet: String,
    exact_length: Option(Int),
    min_length: Int,
    max_length: Option(Int),
    forbidden: List(String),
  )
  Text
  Not(rule: FormatRule)
  Timestamp(rule: CalendarRule)
  AbsoluteUri(max_bytes: Int)
  LanguageTag(grandfathered: List(String))
  Choice(rules: List(FormatRule))
}

pub type FormatBinding {
  FormatBinding(name: String, reference: ProfileRef, rule: FormatRule)
}

pub type IntegerForm {
  Number
  IntegralDecimal
  DecimalString
}

pub type IntegerDomainBinding {
  IntegerDomainBinding(
    name: String,
    reference: ProfileRef,
    range: IntegerDomain,
    forms: List(IntegerForm),
  )
}

pub type NumberModel {
  NumberModel(decimals: Bool)
}

pub type BytesAlphabet {
  Standard
  UrlSafe
  Either
}

pub type WrapperPayload {
  WrapperBytes
  WrapperText(format: Option(String))
}

pub type Wrapper {
  Wrapper(name: String, key: String, payload: WrapperPayload)
}

pub type LengthBound {
  LengthBound(
    unit: StringLengthUnit,
    minimum: Option(Int),
    maximum: Option(Int),
  )
}

pub type FormatUse {
  NamedFormat(name: String)
  InlineFormat(rule: FormatRule)
}

pub type SealedLeaf {
  SealedString(spec: StringSpec)
  SealedInteger(spec: IntegerSpec)
}

pub type SealedField {
  SealedField(key: String, required: Bool, leaf: SealedLeaf)
}

pub type SealedExtras {
  SealedReject
  SealedAny
}

pub type SealedForm {
  SealedForm(tag: String, fields: List(SealedField), extras: SealedExtras)
}

pub type TagModel {
  TagModel(key: String, format: Option(String), sealed: List(SealedForm))
}

pub type BytesPolicy {
  BytesPolicy(
    reference: ProfileRef,
    padding_optional: Bool,
    alphabet: BytesAlphabet,
    strict_pad_bits: Bool,
    wrapper: Option(String),
  )
}

pub type SemanticProfile {
  SemanticProfile(
    reference: ProfileRef,
    source_refs: List(SourceIdentity),
    integer_domains: List(IntegerDomainBinding),
    default_integer_domain: String,
    numbers: NumberModel,
    grapheme_rules: Option(GraphemeRules),
    format_bindings: List(FormatBinding),
    bytes_policy: Option(BytesPolicy),
    wrappers: List(Wrapper),
    tag: Option(TagModel),
  )
}

pub type ProfilePredicate {
  Pr01
  Pr02
  Pr03
  Pr04
  Pr05
  Pr06
  Pr07
  Pr08
  Pr09
  Pr10
  Pr11
  Pr12
  Pr13
  Pr14
  Pr15
  Pr16
}

pub type ProfileFailure {
  ProfileFailure(
    reference: ProfileRef,
    predicate: ProfilePredicate,
    location: List(String),
  )
}

pub opaque type CheckedProfile {
  CheckedProfile(profile: SemanticProfile)
}

pub fn checked_profile_value(checked: CheckedProfile) -> SemanticProfile {
  checked.profile
}

pub fn checked_profile(profile: SemanticProfile) -> CheckedProfile {
  CheckedProfile(profile)
}

pub type IntegerSpec {
  IntegerSpec(
    domain: Option(String),
    minimum: Option(Int),
    maximum: Option(Int),
    const_value: Option(Int),
    enum_values: Option(List(Int)),
    default_value: Option(Int),
  )
}

pub type DecimalBound {
  DecimalBound(mantissa: Int, scale: Int, exclusive: Bool)
}

pub type DecimalSpec {
  DecimalSpec(minimum: Option(DecimalBound), maximum: Option(DecimalBound))
}

pub type StringSpec {
  StringSpec(
    format: Option(FormatUse),
    lengths: List(LengthBound),
    wrapper: Option(String),
    const_value: Option(String),
    enum_values: Option(List(String)),
    examples: List(String),
    default_value: Option(String),
  )
}

pub type ElementContract {
  ElementContract(type_ref: TypeRef, nullable: Bool)
}

pub type ExtraMembers {
  RejectExtras
  AllowExtras(key_format: Option(FormatUse), value: ElementContract)
}

pub type ValueKind {
  NullKind
  BooleanKind
  NumberKind
  StringKind
  ArrayKind
  ObjectKind
}

pub type MemberTest {
  AbsentMember
  FormatMember(name: String)
}

pub type BranchSelector {
  InternalTag
  MemberShape(tests: List(#(String, MemberTest)))
  Kind(kind: ValueKind)
  Otherwise
}

pub type UnknownKind {
  AnyValue
  OrdinaryObject
}

pub type FieldSpec {
  FieldSpec(wire_name: String, slot: SlotContract, origin: OccurrenceRef)
}

pub type ProductSpec {
  ProductSpec(fields: List(FieldSpec), extras: ExtraMembers)
}

pub type UnionBranch {
  UnionBranch(
    target: TypeRef,
    wire_tag: String,
    selector: BranchSelector,
    origin: OccurrenceRef,
  )
}

pub type UnionSpec {
  UnionSpec(branches: List(UnionBranch))
}

pub type SealedRefinement {
  SealedRefinement(key: String, leaf: SealedLeaf)
}

pub type TypeShape {
  BooleanShape(spec: BooleanSpec)
  IntegerShape(spec: IntegerSpec)
  DecimalShape(spec: DecimalSpec)
  StringShape(spec: StringSpec)
  BytesShape(spec: LengthSpec)
  ProductShape(spec: ProductSpec)
  ArrayShape(spec: ArraySpec)
  AliasShape(target: TypeRef, reference_text: String)
  TaggedUnionShape(spec: UnionSpec)
  SealedShape(tag: String, refinements: List(SealedRefinement))
  Never
  UnknownShape(kind: UnknownKind)
  UnitShape
  RawBodyShape(encoding: String)
  OpaqueShape(type_name: String)
}

pub type TypeNode {
  TypeNode(
    reference: TypeRef,
    shape: TypeShape,
    description: Option(String),
    attributes: List(OccurrenceRef),
    extensions: List(OccurrenceRef),
  )
}

pub type SemanticGraph {
  SemanticGraph(
    profile: SemanticProfile,
    nodes: List(TypeNode),
    source_refs: List(SourceRef),
  )
}

pub type MeaningObligation {
  Mo01
  Mo02
  Mo03
  Mo04
  Mo05
  Mo06
  Mo07
  Mo08
  Mo09
  Mo10
  Mo11
}

pub type SemanticReason {
  UnknownFormatReason(name: String)
  MissingGraphemeRulesReason
  MissingBytesPolicyReason
  UnknownIntegerDomainReason(name: String)
  UnknownWrapperReason(name: String)
  WrapperPayloadReason(name: String)
  UnknownSealedTagReason(tag: String)
  DecimalNotAdmittedReason
  IntegerBoundReason
  OpaqueTypeReason(name: String)
  MissingTagModelReason
  UnresolvedTypeReason
  MembershipBoundReason
}

pub type SemanticObligation {
  SemanticObligation(
    type_ref: TypeRef,
    value_path: ValuePath,
    reason: SemanticReason,
  )
}

pub type MeaningFailure {
  MeaningFailure(
    type_ref: TypeRef,
    predicate: MeaningObligation,
    location: List(String),
  )
}

pub type ObjectClass {
  SealedObject(form: SealedForm)
  WrapperObject(wrapper: Wrapper)
  OrdinaryObjectClass
}

pub type SlotContract {
  SlotContract(type_ref: TypeRef, required: Bool, nullable: Bool)
}

pub type SlotValue(a) {
  Absent
  Null
  Present(a)
}

pub type ValuePath =
  List(PathStep)

pub type PathStep {
  Field(name: String)
  Index(index: Int)
  Variant(tag: String)
}

pub type LengthSpec {
  LengthSpec(minimum: Option(Int), maximum: Option(Int))
}

pub type BooleanSpec {
  BooleanSpec(const_value: Option(Bool), default_value: Option(Bool))
}

pub type ArraySpec {
  ArraySpec(
    item: ElementContract,
    min_length: Option(Int),
    max_length: Option(Int),
  )
}

pub type EffectPoint {
  HttpRequestResponse
  DataOnly
}

pub type ValueCondition {
  MissingRequiredCondition
  NullNotAllowedCondition
  WrongValueKindCondition(expected: String)
  ConstMismatchCondition
  EnumMismatchCondition
  BelowMinimumCondition
  AboveMaximumCondition
  IntegerDomainCondition
  StringLengthCondition
  ArrayLengthCondition
  BytesLengthCondition
  FormatFailureCondition(name: String)
  InvalidBytesCondition
  InvalidWrapperCondition(name: String)
  InvalidTagCondition
  ReservedFormCondition
  NoBranchSelectedCondition
  KeyFormatCondition(name: String)
  UninhabitedCondition
  DuplicateFieldCondition(name: String)
  UnexpectedFieldCondition(name: String)
  InvalidDataModelCondition
  ReferenceCycleCondition
}

pub type ValueFailure {
  ValueFailure(
    type_ref: TypeRef,
    definition_ref: DefinitionRef,
    origin: OccurrenceRef,
    value_path: ValuePath,
    condition: ValueCondition,
    observed: SlotValue(kdl.JsonValue),
    reference_trace: List(TypeRef),
  )
}

pub type ValueDecision {
  AcceptedValue
  RejectedValue(failure: ValueFailure)
  UnresolvedValue(obligations: List(SemanticObligation))
  CertificateMismatchValue(condition: String)
}

pub fn child(reference: TypeRef, segments: List(String)) -> TypeRef {
  TypeRef(
    reference.source,
    reference.definition_name,
    list.append(reference.pointer, segments),
  )
}

pub fn occurrence(reference: TypeRef) -> OccurrenceRef {
  OccurrenceRef(reference.source, reference.pointer)
}

pub fn occurrence_at(reference: TypeRef, name: String) -> OccurrenceRef {
  occurrence(child(reference, [name]))
}
