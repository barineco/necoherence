// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

pub use crate::exact_json::JsonValue;
use num_bigint::{BigInt, BigUint};
use std::sync::Arc;

#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct SourceIdentity {
    pub repository: String,
    pub revision: String,
    pub path: String,
    pub content_digest: String,
}
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Origin {
    pub source: SourceIdentity,
    pub locator: Vec<String>,
}
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct SourceRef {
    pub repository: String,
    pub revision: String,
    pub path: String,
    pub content_digest: String,
    pub document_id: String,
    pub declared_revision: Option<BigInt>,
}
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct ProfileRef {
    pub identity: String,
    pub revision: String,
    pub content_digest: String,
}
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct TypeRef {
    pub source: Arc<SourceRef>,
    pub definition_name: Arc<str>,
    pub pointer: Arc<[String]>,
}
impl TypeRef {
    pub fn new(
        source: Arc<SourceRef>,
        definition_name: impl Into<Arc<str>>,
        pointer: impl Into<Arc<[String]>>,
    ) -> Self {
        Self {
            source,
            definition_name: definition_name.into(),
            pointer: pointer.into(),
        }
    }
}
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct DefinitionRef {
    pub source: Arc<SourceRef>,
    pub name: Arc<str>,
}
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct OccurrenceRef {
    pub source: Arc<SourceRef>,
    pub pointer: Arc<[String]>,
}
impl From<&TypeRef> for OccurrenceRef {
    fn from(value: &TypeRef) -> Self {
        Self {
            source: value.source.clone(),
            pointer: value.pointer.clone(),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum IntegerDomain {
    Unbounded,
    Inclusive { minimum: BigInt, maximum: BigInt },
}
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum IntegerForm {
    Number,
    IntegralDecimal,
    DecimalString,
}
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct IntegerDomainBinding {
    pub name: String,
    pub reference: ProfileRef,
    pub range: IntegerDomain,
    pub forms: Vec<IntegerForm>,
}
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct NumberModel {
    pub decimals: bool,
}
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BytesAlphabet {
    Standard,
    UrlSafe,
    Either,
}
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum StringLengthUnit {
    Utf8Bytes,
    UnicodeScalars,
    Graphemes,
}
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LengthBound {
    pub unit: StringLengthUnit,
    pub minimum: Option<BigUint>,
    pub maximum: Option<BigUint>,
}
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum FormatUse {
    Named(String),
    Inline(FormatRule),
}
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum GraphemeProperty {
    Other,
    Cr,
    Lf,
    Control,
    Extend,
    Zwj,
    RegionalIndicator,
    Prepend,
    SpacingMark,
    L,
    V,
    T,
    Lv,
    Lvt,
}
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum IndicProperty {
    Other,
    Consonant,
    Extend,
    Linker,
}
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CodepointRange {
    pub first: u32,
    pub last: u32,
}
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct GraphemeRange {
    pub first: u32,
    pub last: u32,
    pub property: GraphemeProperty,
}
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct IndicRange {
    pub first: u32,
    pub last: u32,
    pub property: IndicProperty,
}
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct GraphemeComponent {
    pub unicode_version: String,
    pub uax29_revision: String,
    pub cluster_profile: String,
}
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct GraphemeSource {
    pub role: String,
    pub origin: Origin,
}
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct GraphemeRules {
    pub reference: ProfileRef,
    pub properties: Vec<GraphemeRange>,
    pub extended_pictographic: Vec<CodepointRange>,
    pub indic_conjunct: Vec<IndicRange>,
    pub component: GraphemeComponent,
    pub table_sha256: String,
    pub sources: Vec<GraphemeSource>,
}
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BytesPolicy {
    pub reference: ProfileRef,
    pub padding_optional: bool,
    pub alphabet: BytesAlphabet,
    pub strict_pad_bits: bool,
    pub wrapper: Option<String>,
}
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CalendarRule {
    pub allow_second_60: bool,
    pub minimum_year: BigUint,
    pub maximum_year: BigUint,
    pub reject_utc_year_outside_range: bool,
}
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DfaTransition {
    pub from_state: BigUint,
    pub first: u8,
    pub last: u8,
    pub to_state: BigUint,
}
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DfaSpec {
    pub state_count: BigUint,
    pub initial_state: BigUint,
    pub accepting_states: Vec<BigUint>,
    pub transitions: Vec<DfaTransition>,
}
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum FormatRule {
    Literal(String),
    Sequence(Vec<FormatRule>),
    Optional(Box<FormatRule>),
    Labels {
        separator: String,
        min_count: BigUint,
        max_count: Option<BigUint>,
        total_max: Option<BigUint>,
        rule: Box<FormatRule>,
    },
    Bounded {
        unit: StringLengthUnit,
        maximum: BigUint,
        rule: Box<FormatRule>,
    },
    AsciiDfa(DfaSpec),
    Identifier {
        first_alphabet: String,
        rest_alphabet: String,
        exact_length: Option<BigUint>,
        min_length: BigUint,
        max_length: Option<BigUint>,
        forbidden: Vec<String>,
    },
    Timestamp(CalendarRule),
    AbsoluteUri {
        max_bytes: Option<BigUint>,
    },
    LanguageTag {
        grandfathered: Vec<String>,
    },
    Choice(Vec<FormatRule>),
    Text,
    Not(Box<FormatRule>),
}
impl FormatRule {
    pub fn depth(&self) -> usize {
        match self {
            Self::Sequence(v) | Self::Choice(v) => 1 + v.iter().map(Self::depth).max().unwrap_or(0),
            Self::Optional(v)
            | Self::Labels { rule: v, .. }
            | Self::Bounded { rule: v, .. }
            | Self::Not(v) => 1 + v.depth(),
            _ => 1,
        }
    }
}
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FormatBinding {
    pub name: String,
    pub reference: ProfileRef,
    pub rule: FormatRule,
}
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum WrapperPayload {
    Bytes,
    Text { format: Option<String> },
}
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Wrapper {
    pub name: String,
    pub key: String,
    pub payload: WrapperPayload,
}
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BooleanSpec {
    pub const_value: Option<bool>,
    pub default_value: Option<bool>,
}
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct IntegerSpec {
    pub domain: Option<String>,
    pub minimum: Option<BigInt>,
    pub maximum: Option<BigInt>,
    pub const_value: Option<BigInt>,
    pub enum_values: Option<Vec<BigInt>>,
    pub default_value: Option<BigInt>,
}
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DecimalBound {
    pub mantissa: BigInt,
    pub scale: BigUint,
    pub exclusive: bool,
}
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DecimalSpec {
    pub minimum: Option<DecimalBound>,
    pub maximum: Option<DecimalBound>,
}
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct StringSpec {
    pub format: Option<FormatUse>,
    pub lengths: Vec<LengthBound>,
    pub wrapper: Option<String>,
    pub const_value: Option<String>,
    pub enum_values: Option<Vec<String>>,
    pub examples: Vec<String>,
    pub default_value: Option<String>,
}
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SealedLeaf {
    String(StringSpec),
    Integer(IntegerSpec),
}
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SealedField {
    pub key: String,
    pub required: bool,
    pub leaf: SealedLeaf,
}
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SealedExtras {
    Reject,
    Any,
}
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SealedForm {
    pub tag: String,
    pub fields: Vec<SealedField>,
    pub extras: SealedExtras,
}
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TagModel {
    pub key: String,
    pub format: Option<String>,
    pub sealed: Vec<SealedForm>,
}
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SealedRefinement {
    pub key: String,
    pub leaf: SealedLeaf,
}
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ObjectClass {
    Sealed(SealedForm),
    Wrapper(Wrapper),
    Ordinary,
}
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct VersionedSemanticProfile {
    pub reference: ProfileRef,
    pub source_refs: Vec<SourceIdentity>,
    pub integer_domains: Vec<IntegerDomainBinding>,
    pub default_integer_domain: String,
    pub numbers: NumberModel,
    pub grapheme_rules: Option<GraphemeRules>,
    pub format_bindings: Vec<FormatBinding>,
    pub bytes_policy: Option<BytesPolicy>,
    pub wrappers: Vec<Wrapper>,
    pub tag: Option<TagModel>,
}
impl VersionedSemanticProfile {
    pub fn format(&self, name: &str) -> Option<&FormatBinding> {
        self.format_bindings.iter().find(|v| v.name == name)
    }
    pub fn integer_domain(&self, name: Option<&str>) -> Option<&IntegerDomainBinding> {
        let n = name.unwrap_or(&self.default_integer_domain);
        self.integer_domains.iter().find(|v| v.name == n)
    }
}
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ProfilePredicate {
    Pr01,
    Pr02,
    Pr03,
    Pr04,
    Pr05,
    Pr06,
    Pr07,
    Pr08,
    Pr09,
    Pr10,
    Pr11,
    Pr12,
    Pr13,
    Pr14,
    Pr15,
    Pr16,
}
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ProfileFailure {
    pub reference: ProfileRef,
    pub predicate: ProfilePredicate,
    pub location: Vec<String>,
}
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CheckedProfile {
    pub profile: VersionedSemanticProfile,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SlotContract {
    pub type_ref: TypeRef,
    pub required: bool,
    pub nullable: bool,
}
#[derive(Debug, Clone, PartialEq)]
pub enum SlotValue<T = JsonValue> {
    Absent,
    Null,
    Present(T),
}
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum PathStep {
    Field(String),
    Index(BigUint),
    Variant(String),
}
pub type ValuePath = Vec<PathStep>;
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LengthSpec {
    pub minimum: Option<BigUint>,
    pub maximum: Option<BigUint>,
}
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FieldSpec {
    pub wire_name: String,
    pub slot: SlotContract,
    pub origin: OccurrenceRef,
}
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ElementContract {
    pub type_ref: TypeRef,
    pub nullable: bool,
}
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ExtraMembers {
    Reject,
    Allow {
        key_format: Option<FormatUse>,
        value: ElementContract,
    },
}
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ProductSpec {
    pub fields: Vec<FieldSpec>,
    pub extras: ExtraMembers,
}
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ArraySpec {
    pub item: ElementContract,
    pub min_length: Option<BigUint>,
    pub max_length: Option<BigUint>,
}
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ValueKind {
    Null,
    Boolean,
    Number,
    String,
    Array,
    Object,
}
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum MemberTest {
    Absent,
    Format(String),
}
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum BranchSelector {
    InternalTag,
    MemberShape(Vec<(String, MemberTest)>),
    Kind(ValueKind),
    Otherwise,
}
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct UnionBranch {
    pub target: TypeRef,
    pub wire_tag: String,
    pub selector: BranchSelector,
    pub origin: OccurrenceRef,
}
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct UnionSpec {
    pub branches: Vec<UnionBranch>,
}
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum UnknownKind {
    Any,
    OrdinaryObject,
}
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum TypeShape {
    Boolean(BooleanSpec),
    Integer(IntegerSpec),
    Decimal(DecimalSpec),
    String(StringSpec),
    Bytes(LengthSpec),
    Product(ProductSpec),
    Array(ArraySpec),
    Alias {
        target: TypeRef,
        reference_text: String,
    },
    TaggedUnion(UnionSpec),
    Sealed {
        tag: String,
        refinements: Vec<SealedRefinement>,
    },
    Never,
    Unknown(UnknownKind),
    Unit,
    RawBody {
        encoding: String,
    },
    Opaque {
        type_name: String,
    },
}
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TypeNode {
    pub reference: TypeRef,
    pub shape: TypeShape,
    pub description: Option<String>,
    pub attributes: Vec<OccurrenceRef>,
    pub extensions: Vec<OccurrenceRef>,
}
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum EffectPoint {
    HttpRequestResponse,
    DataOnly,
}
#[derive(Debug, Clone, PartialEq)]
pub struct SemanticGraph {
    pub profile: VersionedSemanticProfile,
    pub nodes: Vec<TypeNode>,
    pub source_refs: Vec<SourceRef>,
}
impl SemanticGraph {
    pub fn profile(&self) -> &VersionedSemanticProfile {
        &self.profile
    }
    pub fn find_type(&self, r: &TypeRef) -> Option<&TypeNode> {
        self.nodes.iter().find(|n| &n.reference == r)
    }
}
pub fn type_children(shape: &TypeShape) -> Vec<&TypeRef> {
    match shape {
        TypeShape::Product(s) => s
            .fields
            .iter()
            .map(|f| &f.slot.type_ref)
            .chain(match &s.extras {
                ExtraMembers::Allow { value, .. } => Some(&value.type_ref),
                _ => None,
            })
            .collect(),
        TypeShape::Array(s) => vec![&s.item.type_ref],
        TypeShape::Alias { target, .. } => vec![target],
        TypeShape::TaggedUnion(s) => s.branches.iter().map(|b| &b.target).collect(),
        _ => vec![],
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MeaningObligation {
    Mo01,
    Mo02,
    Mo03,
    Mo04,
    Mo05,
    Mo06,
    Mo07,
    Mo08,
    Mo09,
    Mo10,
    Mo11,
}
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MeaningFailure {
    pub type_ref: TypeRef,
    pub predicate: MeaningObligation,
    pub location: Vec<String>,
}
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SemanticReason {
    UnknownFormat(String),
    MissingGraphemeRules,
    MissingBytesPolicy,
    UnknownIntegerDomain(String),
    UnknownWrapper(String),
    WrapperPayload(String),
    UnknownSealedTag(String),
    DecimalNotAdmitted,
    IntegerBound,
    OpaqueType(String),
    MissingTagModel,
    UninterpretedExtension(String),
    UnresolvedType,
    InvalidProfile(String),
    MembershipBound,
    CertificateMismatch(String),
    ProjectionUnavailable(String),
}
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SemanticObligation {
    pub type_ref: TypeRef,
    pub origin: OccurrenceRef,
    pub value_path: ValuePath,
    pub profile: ProfileRef,
    pub reason: SemanticReason,
}
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ValueCondition {
    MissingRequired,
    NullNotAllowed,
    WrongValueKind(String),
    ConstMismatch,
    EnumMismatch,
    BelowMinimum,
    AboveMaximum,
    IntegerDomain,
    StringLength,
    ArrayLength,
    BytesLength,
    Format(String),
    InvalidBytes,
    InvalidWrapper(String),
    InvalidTag,
    ReservedForm,
    NoBranchSelected,
    KeyFormat(String),
    Uninhabited,
    DuplicateField(String),
    UnexpectedField(String),
    InvalidDataModel,
    ReferenceCycle,
}
#[derive(Debug, Clone, PartialEq)]
pub struct ValueFailure {
    pub type_ref: TypeRef,
    pub definition_ref: DefinitionRef,
    pub origin: OccurrenceRef,
    pub value_path: ValuePath,
    pub condition: ValueCondition,
    pub observed: SlotValue,
    pub reference_trace: Vec<TypeRef>,
}
#[derive(Debug, Clone, PartialEq)]
pub enum ValueDecision {
    Accepted,
    Rejected(ValueFailure),
    Unresolved(Vec<SemanticObligation>),
}
