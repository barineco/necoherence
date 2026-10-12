// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

use crate::semantic_types::*;
use num_bigint::BigUint;
use std::collections::HashSet;
use std::sync::Arc;

pub type TypeId = String;
pub type DefinitionId = String;
pub type GroupId = String;
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum AnnotationTarget {
    Library,
    Group(String),
    Definition(String),
    Type(String),
    Outcome { definition: String, outcome: String },
}
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ProvenanceBinding {
    pub target: AnnotationTarget,
    pub origins: Vec<Origin>,
}
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DefinitionGroup {
    pub id: String,
    pub members: Vec<String>,
}
#[derive(Debug, Clone, PartialEq)]
pub struct Annotation {
    pub target: AnnotationTarget,
    pub key: String,
    pub value: JsonValue,
}
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ValueSemanticProfile {
    pub reference: ProfileRef,
    pub source_refs: Vec<SourceIdentity>,
    pub integer_domains: Vec<IntegerDomainBinding>,
    pub default_integer_domain: String,
    pub numbers: NumberModel,
    pub grapheme_rules: Option<GraphemeRules>,
    pub format_bindings: Vec<FormatBinding>,
    pub wrappers: Vec<Wrapper>,
    pub tag: Option<TagModel>,
    pub bytes_policy: Option<BytesPolicy>,
}
impl ValueSemanticProfile {
    pub fn semantic_profile(&self) -> VersionedSemanticProfile {
        VersionedSemanticProfile {
            reference: self.reference.clone(),
            source_refs: self.source_refs.clone(),
            integer_domains: self.integer_domains.clone(),
            default_integer_domain: self.default_integer_domain.clone(),
            numbers: self.numbers,
            grapheme_rules: self.grapheme_rules.clone(),
            format_bindings: self.format_bindings.clone(),
            bytes_policy: self.bytes_policy.clone(),
            wrappers: self.wrappers.clone(),
            tag: self.tag.clone(),
        }
    }
    pub fn from_profile(p: &VersionedSemanticProfile) -> Self {
        Self {
            reference: p.reference.clone(),
            source_refs: p.source_refs.clone(),
            integer_domains: p.integer_domains.clone(),
            default_integer_domain: p.default_integer_domain.clone(),
            numbers: p.numbers,
            grapheme_rules: p.grapheme_rules.clone(),
            format_bindings: p.format_bindings.clone(),
            wrappers: p.wrappers.clone(),
            tag: p.tag.clone(),
            bytes_policy: p.bytes_policy.clone(),
        }
    }
}
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SignatureSlot {
    pub type_id: String,
    pub required: bool,
    pub nullable: bool,
}
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SignatureField {
    pub wire_name: String,
    pub slot: SignatureSlot,
}
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SignatureElementContract {
    pub type_id: String,
    pub nullable: bool,
}
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SignatureExtraMembers {
    Reject,
    Allow {
        key_format: Option<FormatUse>,
        value: SignatureElementContract,
    },
}
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SignatureProduct {
    pub fields: Vec<SignatureField>,
    pub extras: SignatureExtraMembers,
}
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SignatureArray {
    pub item: SignatureElementContract,
    pub minimum: Option<BigUint>,
    pub maximum: Option<BigUint>,
}
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SignatureUnionBranch {
    pub target: String,
    pub wire_tag: String,
    pub selector: BranchSelector,
}
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SignatureUnion {
    pub branches: Vec<SignatureUnionBranch>,
}
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Shape {
    Unknown(UnknownKind),
    Unit,
    Boolean(BooleanSpec),
    Integer(IntegerSpec),
    Decimal(DecimalSpec),
    String(StringSpec),
    Bytes(LengthSpec),
    Product(SignatureProduct),
    Array(SignatureArray),
    TaggedUnion(SignatureUnion),
    Sealed {
        tag: String,
        refinements: Vec<SealedRefinement>,
    },
    Never,
    Alias {
        target: String,
    },
    RawBody {
        encoding: String,
    },
    Opaque {
        type_name: String,
    },
}
impl Shape {
    pub fn references(&self) -> Vec<&str> {
        match self {
            Self::Product(p) => p
                .fields
                .iter()
                .map(|f| f.slot.type_id.as_str())
                .chain(match &p.extras {
                    SignatureExtraMembers::Allow { value, .. } => Some(value.type_id.as_str()),
                    _ => None,
                })
                .collect(),
            Self::Array(a) => vec![a.item.type_id.as_str()],
            Self::TaggedUnion(u) => u.branches.iter().map(|b| b.target.as_str()).collect(),
            Self::Alias { target } => vec![target],
            _ => vec![],
        }
    }
}
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TypeNodeInput {
    pub id: String,
    pub shape: Shape,
}
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum OutcomeCause {
    ValueContract { origin: Origin },
    ExternalCondition { specification: Origin },
}
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SignaturePort {
    pub id: String,
    pub contract: SignatureSlot,
}
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum OutcomeForm {
    Success,
    DeclaredFailure,
}
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SignatureResourceProduction {
    pub id: String,
    pub token_type: String,
    pub revision: BigUint,
    pub quantity: BigUint,
    pub provenance: String,
}
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SignatureOutcome {
    pub id: String,
    pub form: OutcomeForm,
    pub cause: OutcomeCause,
    pub value_ports: Vec<SignaturePort>,
    pub produced_resources: Vec<SignatureResourceProduction>,
}
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct OperationContract {
    pub effect: EffectPoint,
    pub inputs: Vec<SignaturePort>,
    pub outcomes: Vec<SignatureOutcome>,
}
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SignatureDefinitionShape {
    Value(String),
    Symbol(String),
    Operation(OperationContract),
    Message(String),
}
impl SignatureDefinitionShape {
    fn references(&self) -> Vec<&str> {
        match self {
            Self::Value(v) | Self::Message(v) => vec![v],
            Self::Operation(o) => o
                .inputs
                .iter()
                .map(|p| p.contract.type_id.as_str())
                .chain(o.outcomes.iter().flat_map(|x| {
                    x.value_ports
                        .iter()
                        .map(|p| p.contract.type_id.as_str())
                        .chain(x.produced_resources.iter().map(|p| p.token_type.as_str()))
                }))
                .collect(),
            Self::Symbol(_) => vec![],
        }
    }
}
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DefinitionInput {
    pub id: String,
    pub wire_identity: String,
    pub shape: SignatureDefinitionShape,
}
#[derive(Debug, Clone, PartialEq)]
pub struct TypeSignatureLibrary {
    pub schema: String,
    pub identity: String,
    pub revision: String,
    pub profile: ValueSemanticProfile,
    pub sources: Vec<SourceIdentity>,
    pub provenance: Vec<ProvenanceBinding>,
    pub groups: Vec<DefinitionGroup>,
    pub annotations: Vec<Annotation>,
    pub nodes: Vec<TypeNodeInput>,
    pub definitions: Vec<DefinitionInput>,
}
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LibraryPredicate {
    Lb01,
    Lb02,
    Lb03,
    Lb04,
    Lb05,
    Lb06,
    Lb07,
    Lb08,
    Lb09,
    Lb10,
    Lb11,
    Lb12,
    Lb13,
    Lb14,
    Lb15,
    Lb16,
    Lb17,
    Lb18,
    Lb19,
}
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LibraryFailure {
    pub reference: String,
    pub predicate: LibraryPredicate,
    pub location: Vec<String>,
}
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum LibraryCheckFailure {
    Profile(ProfileFailure),
    Library(LibraryFailure),
}
#[derive(Debug, Clone, PartialEq)]
pub struct CheckedLibrary {
    pub library: TypeSignatureLibrary,
    pub profile: CheckedProfile,
}
fn unique<'a>(mut values: impl Iterator<Item = &'a str>) -> bool {
    let mut seen = HashSet::new();
    values.all(|v| !v.is_empty() && seen.insert(v))
}
fn digest(v: &str) -> bool {
    v.len() == 64
        && v.bytes()
            .all(|c| c.is_ascii_digit() || (b'a'..=b'f').contains(&c))
}
fn bounds<T: Ord>(a: &Option<T>, b: &Option<T>) -> bool {
    match (a, b) {
        (Some(a), Some(b)) => a <= b,
        _ => true,
    }
}
fn format_use<'a>(p: &'a ValueSemanticProfile, u: &'a FormatUse) -> Option<&'a FormatRule> {
    match u {
        FormatUse::Named(n) => p
            .format_bindings
            .iter()
            .find(|b| b.name == *n)
            .map(|b| &b.rule),
        FormatUse::Inline(r) => Some(r),
    }
}
fn target_valid(l: &TypeSignatureLibrary, t: &AnnotationTarget) -> bool {
    match t{AnnotationTarget::Library=>true,AnnotationTarget::Group(x)=>l.groups.iter().any(|v|v.id==*x),AnnotationTarget::Definition(x)=>l.definitions.iter().any(|v|v.id==*x),AnnotationTarget::Type(x)=>l.nodes.iter().any(|v|v.id==*x),AnnotationTarget::Outcome{definition,outcome}=>l.definitions.iter().any(|d|d.id==*definition&&matches!(&d.shape,SignatureDefinitionShape::Operation(o) if o.outcomes.iter().any(|x|x.id==*outcome)))}
}
fn origin_valid(l: &TypeSignatureLibrary, o: &Origin) -> bool {
    l.sources.contains(&o.source)
}
fn outcome_valid(library: &TypeSignatureLibrary, outcome: &SignatureOutcome) -> bool {
    unique(outcome.value_ports.iter().map(|port| port.id.as_str()))
        && match &outcome.cause {
            OutcomeCause::ValueContract { origin } => origin_valid(library, origin),
            OutcomeCause::ExternalCondition { specification } => {
                origin_valid(library, specification)
                    && !outcome.value_ports.is_empty()
                    && outcome.form == OutcomeForm::DeclaredFailure
            }
        }
}
fn sources_unique(sources: &[SourceIdentity]) -> bool {
    let mut seen = HashSet::new();
    sources.iter().all(|source| seen.insert(source))
}
fn declaration_valid(l: &TypeSignatureLibrary) -> bool {
    l.schema == "ncoh-type-signatures@1"
        && !l.identity.is_empty()
        && !l.revision.is_empty()
        && digest(&l.profile.reference.content_digest)
        && l.sources.iter().all(|s| digest(&s.content_digest))
        && sources_unique(&l.sources)
        && unique(l.nodes.iter().map(|n| n.id.as_str()))
        && unique(l.definitions.iter().map(|n| n.id.as_str()))
        && unique(l.groups.iter().map(|n| n.id.as_str()))
        && l.nodes.iter().all(|n| {
            n.shape
                .references()
                .iter()
                .all(|r| l.nodes.iter().any(|x| x.id == *r))
        })
        && l.definitions.iter().all(|definition| {
            definition
                .shape
                .references()
                .iter()
                .all(|reference| l.nodes.iter().any(|node| node.id == *reference))
                && match &definition.shape {
                    SignatureDefinitionShape::Operation(operation) => {
                        unique(operation.inputs.iter().map(|port| port.id.as_str()))
                            && unique(operation.outcomes.iter().map(|outcome| outcome.id.as_str()))
                            && !operation.outcomes.is_empty()
                            && operation
                                .outcomes
                                .iter()
                                .all(|outcome| outcome_valid(l, outcome))
                    }
                    _ => true,
                }
        })
        && l.groups.iter().all(|g| {
            g.members
                .iter()
                .all(|m| l.definitions.iter().any(|d| d.id == *m))
        })
        && l.provenance
            .iter()
            .all(|p| target_valid(l, &p.target) && p.origins.iter().all(|o| origin_valid(l, o)))
        && l.annotations.iter().all(|a| target_valid(l, &a.target))
}
fn predicate(l: &TypeSignatureLibrary) -> Option<LibraryPredicate> {
    if !declaration_valid(l) {
        return Some(LibraryPredicate::Lb01);
    }
    if l.nodes.iter().any(|n|matches!(&n.shape,Shape::Product(p) if !unique(p.fields.iter().map(|f|f.wire_name.as_str())))){return Some(LibraryPredicate::Lb02)}
    if l.nodes.iter().any(|n|matches!(&n.shape,Shape::Product(p) if p.fields.iter().any(|f|l.profile.wrappers.iter().any(|w|w.key==f.wire_name)))){return Some(LibraryPredicate::Lb03)}
    if l.nodes.iter().any(|node| {
        matches!(&node.shape, Shape::TaggedUnion(union) if {
            let mut seen = HashSet::new();
            union
                .branches
                .iter()
                .any(|branch| !seen.insert(branch.wire_tag.as_str()))
        })
    }) {
        return Some(LibraryPredicate::Lb04);
    }
    if l.nodes.iter().any(|n|matches!(&n.shape,Shape::TaggedUnion(u) if u.branches.iter().enumerate().any(|(i,b)|b.selector==BranchSelector::Otherwise&&i+1!=u.branches.len()))){return Some(LibraryPredicate::Lb05)}
    if l.nodes.iter().any(|n|matches!(&n.shape,Shape::TaggedUnion(u) if u.branches.iter().any(|b|b.wire_tag.is_empty()||matches!(&b.selector,BranchSelector::MemberShape(t) if t.iter().any(|x|x.0.is_empty()))))){return Some(LibraryPredicate::Lb06)}
    if l.nodes.iter().any(|n|matches!((&n.shape,&l.profile.tag),(Shape::TaggedUnion(u),Some(t)) if u.branches.iter().any(|b|b.selector==BranchSelector::InternalTag&&t.format.as_ref().is_some_and(|f|l.profile.format_bindings.iter().find(|x|x.name==*f).is_none_or(|x|!crate::semantic_validation::recognize_format(&x.rule,&b.wire_tag)))))){return Some(LibraryPredicate::Lb07)}
    if l.nodes.iter().any(|n|matches!((&n.shape,&l.profile.tag),(Shape::TaggedUnion(u),Some(t)) if u.branches.iter().any(|b|b.selector==BranchSelector::InternalTag&&(t.sealed.iter().any(|x|x.tag==b.wire_tag)!=l.nodes.iter().any(|x|x.id==b.target&&matches!(&x.shape,Shape::Sealed{tag,..} if tag==&b.wire_tag)))))){return Some(LibraryPredicate::Lb08)}
    if l.nodes.iter().any(|n|matches!(&n.shape,Shape::TaggedUnion(u) if u.branches.iter().any(|b|matches!(&b.selector,BranchSelector::MemberShape(t) if !unique(t.iter().map(|x|x.0.as_str()))||t.iter().any(|x|matches!(&x.1,MemberTest::Format(f) if !l.profile.format_bindings.iter().any(|b|b.name==*f))))))){return Some(LibraryPredicate::Lb09)}
    if l.nodes
        .iter()
        .any(|node| match (&node.shape, &l.profile.tag) {
            (Shape::Sealed { .. }, None) => true,
            (Shape::Sealed { tag, refinements }, Some(model)) => model
                .sealed
                .iter()
                .find(|form| form.tag == *tag)
                .is_none_or(|form| {
                    !unique(refinements.iter().map(|refinement| refinement.key.as_str()))
                        || refinements.iter().any(|refinement| {
                            !form.fields.iter().any(|field| {
                                field.key == refinement.key
                                    && matches!(
                                        (&field.leaf, &refinement.leaf),
                                        (SealedLeaf::String(_), SealedLeaf::String(_))
                                            | (SealedLeaf::Integer(_), SealedLeaf::Integer(_))
                                    )
                            })
                        })
                }),
            _ => false,
        })
    {
        return Some(LibraryPredicate::Lb10);
    }
    if l.nodes.iter().any(|n|matches!(&n.shape,Shape::TaggedUnion(u) if u.branches.iter().any(|b|b.selector==BranchSelector::InternalTag&&!l.nodes.iter().any(|x|x.id==b.target&&matches!(x.shape,Shape::Product(_)|Shape::Sealed{..}))))){return Some(LibraryPredicate::Lb11)}
    if l.nodes.iter().any(|n|matches!(&n.shape,Shape::Product(p) if matches!(&p.extras,SignatureExtraMembers::Allow{key_format:Some(f),..} if format_use(&l.profile,f).is_none()))){return Some(LibraryPredicate::Lb12)}
    if l.nodes.iter().any(|n|matches!(&n.shape,Shape::String(s) if s.wrapper.as_ref().is_some_and(|x|!l.profile.wrappers.iter().any(|w|w.name==*x&&matches!(w.payload,WrapperPayload::Text{..})))||s.format.as_ref().is_some_and(|f|format_use(&l.profile,f).is_none_or(|r|!crate::semantic_validation::format_rule_well_formed(r)))||s.lengths.iter().any(|b|!bounds(&b.minimum,&b.maximum)))){return Some(LibraryPredicate::Lb13)}
    if l.nodes.iter().any(|n|matches!(&n.shape,Shape::Integer(s) if !bounds(&s.minimum,&s.maximum)||s.domain.as_ref().is_some_and(|d|!l.profile.integer_domains.iter().any(|x|x.name==*d)))){return Some(LibraryPredicate::Lb14)}
    if l.nodes.iter().any(|n|matches!(&n.shape,Shape::Decimal(s) if matches!((&s.minimum,&s.maximum),(Some(a),Some(b)) if a.scale!=b.scale||b.mantissa<a.mantissa))){return Some(LibraryPredicate::Lb15)}
    if l.nodes.iter().any(|n| {
        matches!(&n.shape,Shape::Array(a) if !bounds(&a.minimum,&a.maximum))
            || matches!(&n.shape,Shape::Bytes(a) if !bounds(&a.minimum,&a.maximum))
    }) {
        return Some(LibraryPredicate::Lb16);
    }
    if l.nodes.iter().any(|n|matches!((&n.shape,&l.profile.tag),(Shape::TaggedUnion(u),Some(t)) if u.branches.iter().any(|b|b.selector==BranchSelector::InternalTag&&l.nodes.iter().any(|x|x.id==b.target&&matches!(&x.shape,Shape::Product(p) if p.fields.iter().find(|f|f.wire_name==t.key).is_none_or(|f|l.nodes.iter().find(|x|x.id==f.slot.type_id).is_none_or(|x|!matches!(&x.shape,Shape::String(s) if crate::semantic_validation::string_condition(&l.profile.semantic_profile(),s,&b.wire_tag).is_none())))))))){return Some(LibraryPredicate::Lb17)}
    if l.nodes.iter().any(|n|matches!(&n.shape,Shape::TaggedUnion(u) if {let mut s:Vec<&BranchSelector>=Vec::new();u.branches.iter().any(|b|if s.contains(&&b.selector){true}else{s.push(&b.selector);false})})){return Some(LibraryPredicate::Lb18)}
    if l.nodes.iter().any(|n| match &n.shape {
        Shape::String(s) => s
            .const_value
            .iter()
            .chain(s.enum_values.iter().flatten())
            .chain(s.default_value.iter())
            .any(|v| {
                crate::semantic_validation::string_condition(&l.profile.semantic_profile(), s, v)
                    .is_some()
            }),
        Shape::Integer(s) => s
            .const_value
            .iter()
            .chain(s.enum_values.iter().flatten())
            .chain(s.default_value.iter())
            .any(|v| {
                crate::semantic_validation::integer_condition(
                    &l.profile.semantic_profile(),
                    s,
                    &JsonValue::Num(v.clone()),
                )
                .is_some()
            }),
        _ => false,
    }) {
        return Some(LibraryPredicate::Lb19);
    }
    None
}
pub fn check_library(l: &TypeSignatureLibrary) -> Result<CheckedLibrary, LibraryCheckFailure> {
    let profile = crate::semantic_validation::check_profile(&l.profile.semantic_profile())
        .map_err(LibraryCheckFailure::Profile)?;
    if let Some(p) = predicate(l) {
        return Err(LibraryCheckFailure::Library(LibraryFailure {
            reference: l.identity.clone(),
            predicate: p,
            location: vec!["library".into()],
        }));
    }
    Ok(CheckedLibrary {
        library: l.clone(),
        profile,
    })
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SignatureGenerationBasis {
    pub signature_schema: String,
    pub library_identity: String,
    pub library_revision: String,
    pub profile: ProfileRef,
    pub graph_sha256: String,
    pub provenance_sha256: String,
    pub metadata_sha256: String,
    pub problem_sha256: Option<String>,
    pub entrypoints_sha256: String,
}
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SignatureEntrypoint {
    pub identity: String,
    pub definition: String,
}
#[derive(Debug, Clone, PartialEq)]
pub struct SignatureComposition {
    pub problem: serde_json::Value,
    pub derivation: serde_json::Value,
}
#[derive(Debug, Clone, PartialEq)]
pub struct SignatureGenerationInput {
    pub schema: String,
    pub basis: SignatureGenerationBasis,
    pub signatures: Arc<TypeSignatureLibrary>,
    pub composition: Option<SignatureComposition>,
    pub entrypoints: Vec<SignatureEntrypoint>,
}
