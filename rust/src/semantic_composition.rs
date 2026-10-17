// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

use crate::core::Nat;
use crate::semantic_types::*;
use crate::semantic_validation::{
    self as validation, accepts_slot, accepts_value, recognize_format,
};
use crate::typed_mapping as resource;
use num_bigint::BigInt;
use num_traits::{One, ToPrimitive, Zero};
use std::collections::HashSet;
use std::sync::Arc;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SemanticBasis {
    pub profile: VersionedSemanticProfile,
    pub sources: Vec<SourceIdentity>,
}
impl SemanticBasis {
    pub fn of(graph: &SemanticGraph) -> Self {
        Self {
            profile: graph.profile().clone(),
            sources: graph.profile().source_refs.clone(),
        }
    }
    fn matches(&self, graph: &SemanticGraph) -> bool {
        self.profile == *graph.profile() && self.sources == graph.profile().source_refs
    }
}
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct FunctionRef {
    pub identity: String,
    pub revision: String,
    pub content_digest: String,
}
macro_rules! identifier {
    ($($name:ident),+ $(,)?) => { $(
        #[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord, Hash)]
        pub struct $name(pub String);
    )+ };
}
identifier!(
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

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum InclusionRule {
    EmptySource,
    Presence,
    Unknown,
    Boolean,
    Integer,
    String,
    Bytes,
    Unit,
    Never,
    UnfoldSource,
    UnfoldDestination,
    Array,
    Product,
    SourceUnion,
    DestinationUnion,
    Sealed,
}
#[derive(Debug, Clone, PartialEq)]
pub struct CounterexampleCertificate {
    pub basis: SemanticBasis,
    pub source: SlotContract,
    pub destination: SlotContract,
    pub value: SlotValue,
    pub destination_failure: ValueFailure,
}
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum TypeObligationReason {
    ConstraintImplication,
    Presence,
    UnionRemainder,
    Inhabitation,
    ObligationBoundExhausted,
    Meaning(Vec<SemanticObligation>),
    ExtraField(String),
}
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TypeObligation {
    pub source: TypeRef,
    pub destination: TypeRef,
    pub reason: TypeObligationReason,
}
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct InclusionCertificate {
    pub basis: SemanticBasis,
    pub source: SlotContract,
    pub destination: SlotContract,
    pub rule: InclusionRule,
}
#[derive(Debug, Clone, PartialEq)]
pub enum CompatibilityDecision {
    Compatible(InclusionCertificate),
    Incompatible(CounterexampleCertificate),
    Unknown(Vec<TypeObligation>),
}
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SampleObligation {
    SampleBound,
}
#[derive(Debug, Clone, PartialEq)]
pub struct SampleResult<T> {
    pub values: Vec<T>,
    pub obligations: Vec<SampleObligation>,
}
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SearchBounds {
    pub max_expanded_states: usize,
    pub max_binding_candidates: usize,
    pub max_type_obligations: usize,
    pub max_branch_nodes: usize,
    pub resource_bounds: Option<ResourceBounds>,
    pub max_sample_length: usize,
}
impl Default for SearchBounds {
    fn default() -> Self {
        Self {
            max_expanded_states: 10_000,
            max_binding_candidates: 100_000,
            max_type_obligations: 10_000,
            max_branch_nodes: 100_000,
            resource_bounds: None,
            max_sample_length: 32,
        }
    }
}
pub fn present_contract(reference: TypeRef) -> SlotContract {
    SlotContract {
        type_ref: reference,
        required: true,
        nullable: false,
    }
}
pub fn borrowed_slot(value: &SlotValue) -> SlotValue<&JsonValue> {
    match value {
        SlotValue::Absent => SlotValue::Absent,
        SlotValue::Null => SlotValue::Null,
        SlotValue::Present(value) => SlotValue::Present(value),
    }
}
fn owned_slot(value: SlotValue<&JsonValue>) -> SlotValue {
    match value {
        SlotValue::Absent => SlotValue::Absent,
        SlotValue::Null => SlotValue::Null,
        SlotValue::Present(value) => SlotValue::Present(value.clone()),
    }
}
pub fn resolved_shape<'g>(
    graph: &'g SemanticGraph,
    reference: &'g TypeRef,
) -> Option<&'g TypeShape> {
    let mut current = reference;
    let mut seen = HashSet::new();
    loop {
        if !seen.insert(current) {
            return None;
        }
        let shape = &graph.find_type(current)?.shape;
        match shape {
            TypeShape::Alias { target, .. } => current = target,
            _ => return Some(shape),
        }
    }
}
fn empty_types(graph: &SemanticGraph) -> Vec<TypeRef> {
    let mut empty = Vec::new();
    loop {
        let before = empty.len();
        for node in &graph.nodes {
            let is_empty = match &node.shape {
                TypeShape::Never => true,
                TypeShape::Alias { target, .. } => empty.contains(target),
                TypeShape::TaggedUnion(union) => union
                    .branches
                    .iter()
                    .all(|branch| empty.contains(&branch.target)),
                _ => false,
            };
            if is_empty && !empty.contains(&node.reference) {
                empty.push(node.reference.clone());
            }
        }
        if empty.len() == before {
            return empty;
        }
    }
}
pub fn slot_empty(slot: &SlotContract, empty: &[TypeRef]) -> bool {
    slot.required && !slot.nullable && empty.contains(&slot.type_ref)
}
#[derive(Debug, Clone, PartialEq)]
pub enum InclusionFailure {
    BasisMismatch,
    ContractMismatch,
    UndefinedMeaning(Vec<MeaningFailure>),
    CounterexampleMismatch,
    Unresolved(TypeObligation),
}
pub fn verify_inclusion(
    graph: &SemanticGraph,
    source: &SlotContract,
    destination: &SlotContract,
    certificate: &InclusionCertificate,
) -> Result<(), InclusionFailure> {
    if !certificate.basis.matches(graph) {
        return Err(InclusionFailure::BasisMismatch);
    }
    if certificate.source != *source || certificate.destination != *destination {
        return Err(InclusionFailure::ContractMismatch);
    }
    match check_assignable(graph, source, destination, usize::MAX) {
        CompatibilityDecision::Compatible(actual) if actual.rule == certificate.rule => Ok(()),
        CompatibilityDecision::Unknown(mut obligations) => {
            Err(InclusionFailure::Unresolved(obligations.remove(0)))
        }
        _ => Err(InclusionFailure::ContractMismatch),
    }
}
pub fn verify_counterexample(
    graph: &SemanticGraph,
    certificate: &CounterexampleCertificate,
) -> Result<(), InclusionFailure> {
    if !certificate.basis.matches(graph) {
        return Err(InclusionFailure::BasisMismatch);
    }
    let source = accepts_slot(
        graph,
        &certificate.source,
        borrowed_slot(&certificate.value),
    );
    let destination = accepts_slot(
        graph,
        &certificate.destination,
        borrowed_slot(&certificate.value),
    );
    if matches!(source, ValueDecision::Accepted)
        && matches!(destination, ValueDecision::Rejected(_))
    {
        Ok(())
    } else {
        Err(InclusionFailure::CounterexampleMismatch)
    }
}
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ProjectionAssumption {
    Present(ValuePath),
    NonNull(ValuePath),
    Variant {
        path: ValuePath,
        tag: String,
    },
    IndexPresent {
        path: ValuePath,
        index: num_bigint::BigUint,
    },
}
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ProjectionCertificate {
    pub profile: ProfileRef,
    pub source_refs: Vec<SourceIdentity>,
    pub source: SlotContract,
    pub path: ValuePath,
    pub assumptions: Vec<ProjectionAssumption>,
    pub destination: SlotContract,
}
#[derive(Debug, Clone, PartialEq)]
pub enum ProjectionFailure {
    WrongShape { type_ref: TypeRef, path: ValuePath },
    MissingField { type_ref: TypeRef, name: String },
    MissingVariant { type_ref: TypeRef, tag: String },
    BranchAssumptionRequired { path: ValuePath, tag: String },
    UndefinedMeaning(MeaningFailure),
    CertificateMismatch(String),
}
fn strengthen_projection(
    slot: &mut SlotContract,
    path: &[PathStep],
    assumptions: &[ProjectionAssumption],
) {
    if assumptions.iter().any(|a| match a {
        ProjectionAssumption::Present(at)
        | ProjectionAssumption::Variant { path: at, .. }
        | ProjectionAssumption::IndexPresent { path: at, .. } => at == path,
        _ => false,
    }) {
        slot.required = true;
        slot.nullable = false;
    } else if assumptions
        .iter()
        .any(|a| matches!(a, ProjectionAssumption::NonNull(at) if at == path))
    {
        slot.nullable = false;
    }
}
pub fn project_slot(
    graph: &SemanticGraph,
    source: &SlotContract,
    path: &[PathStep],
    assumptions: &[ProjectionAssumption],
) -> Result<ProjectionCertificate, ProjectionFailure> {
    validation::check_meaning_defined(graph, std::slice::from_ref(&source.type_ref))
        .map_err(ProjectionFailure::UndefinedMeaning)?;
    let mut slot = source.clone();
    let mut position = 0usize;
    let mut visited = HashSet::new();
    loop {
        let traversed = path
            .get(..position)
            .ok_or_else(|| ProjectionFailure::WrongShape {
                type_ref: slot.type_ref.clone(),
                path: path.to_vec(),
            })?;
        strengthen_projection(&mut slot, traversed, assumptions);
        let Some(step) = path.get(position) else {
            break;
        };
        if !visited.insert((slot.type_ref.clone(), position)) {
            return Err(ProjectionFailure::WrongShape {
                type_ref: slot.type_ref,
                path: traversed.to_vec(),
            });
        }
        let shape = graph
            .find_type(&slot.type_ref)
            .map(|node| &node.shape)
            .ok_or_else(|| ProjectionFailure::WrongShape {
                type_ref: slot.type_ref.clone(),
                path: traversed.to_vec(),
            })?;
        match (shape, step) {
            (TypeShape::Alias { target, .. }, _) => {
                slot.type_ref = target.clone();
                continue;
            }
            (TypeShape::Product(spec), PathStep::Field(name)) => {
                let field = spec
                    .fields
                    .iter()
                    .find(|field| field.wire_name == *name)
                    .ok_or_else(|| ProjectionFailure::MissingField {
                        type_ref: slot.type_ref.clone(),
                        name: name.clone(),
                    })?;
                slot.type_ref = field.slot.type_ref.clone();
                slot.required &= field.slot.required;
                slot.nullable |= field.slot.nullable;
            }
            (TypeShape::Array(spec), PathStep::Index(index)) => {
                let present = spec.min_length.as_ref().is_some_and(|minimum| index < minimum) || assumptions.iter().any(|a| matches!(a, ProjectionAssumption::IndexPresent{path:at,index:actual} if at == traversed && actual == index));
                slot.type_ref = spec.item.type_ref.clone();
                slot.required &= present;
                slot.nullable |= element_allows_null(graph, &spec.item);
            }
            (TypeShape::TaggedUnion(spec), PathStep::Variant(tag)) => {
                if !assumptions.iter().any(|a| matches!(a, ProjectionAssumption::Variant{path:at,tag:actual} if at == traversed && actual == tag)) { return Err(ProjectionFailure::BranchAssumptionRequired { path: traversed.to_vec(), tag: tag.clone() }); }
                slot.type_ref = spec
                    .branches
                    .iter()
                    .find(|branch| branch.wire_tag == *tag)
                    .ok_or_else(|| ProjectionFailure::MissingVariant {
                        type_ref: slot.type_ref.clone(),
                        tag: tag.clone(),
                    })?
                    .target
                    .clone();
            }
            _ => {
                return Err(ProjectionFailure::WrongShape {
                    type_ref: slot.type_ref,
                    path: traversed.to_vec(),
                })
            }
        }
        position += 1;
    }
    Ok(ProjectionCertificate {
        profile: graph.profile.reference.clone(),
        source_refs: graph.profile.source_refs.clone(),
        source: source.clone(),
        path: path.to_vec(),
        assumptions: assumptions.to_vec(),
        destination: slot,
    })
}
pub fn check_projection_certificate(
    graph: &SemanticGraph,
    certificate: &ProjectionCertificate,
) -> Result<(), ProjectionFailure> {
    if certificate.profile != graph.profile.reference
        || certificate.source_refs != graph.profile.source_refs
    {
        return Err(ProjectionFailure::CertificateMismatch(
            "profile or source revisions".into(),
        ));
    }
    if project_slot(
        graph,
        &certificate.source,
        &certificate.path,
        &certificate.assumptions,
    )? == *certificate
    {
        Ok(())
    } else {
        Err(ProjectionFailure::CertificateMismatch(
            "projection contract or guards".into(),
        ))
    }
}
fn value_at_path<'a>(mut value: &'a JsonValue, path: &[PathStep]) -> SlotValue<&'a JsonValue> {
    for step in path {
        match (step, value) {
            (PathStep::Field(name), JsonValue::Obj(members)) => {
                match members.iter().find(|(key, _)| key == name) {
                    Some((_, v)) => value = v,
                    None => return SlotValue::Absent,
                }
            }
            (PathStep::Index(index), JsonValue::Arr(items)) => {
                match index.to_usize().and_then(|i| items.get(i)) {
                    Some(v) => value = v,
                    None => return SlotValue::Absent,
                }
            }
            (PathStep::Variant(_), _) => {}
            _ => return SlotValue::Absent,
        }
    }
    if matches!(value, JsonValue::Null) {
        SlotValue::Null
    } else {
        SlotValue::Present(value)
    }
}
fn member<'a>(members: &'a [(String, JsonValue)], key: &str) -> Option<&'a JsonValue> {
    members
        .iter()
        .find(|(name, _)| name == key)
        .map(|(_, value)| value)
}

pub fn sample_bound<T>(mut values: Vec<T>, limit: usize) -> SampleResult<T> {
    let bounded = values.len() > limit;
    values.truncate(limit);
    SampleResult {
        values,
        obligations: if bounded {
            vec![SampleObligation::SampleBound]
        } else {
            vec![]
        },
    }
}
pub fn max_sample_length(value: &JsonValue) -> usize {
    match value {
        JsonValue::Str(text) | JsonValue::Dec(text) => text.chars().count(),
        JsonValue::Arr(items) => items.len(),
        JsonValue::Obj(members) => members.len(),
        _ => 0,
    }
}
fn included_format(s: &FormatRule, d: &FormatRule) -> bool {
    s == d
        || matches!(d, FormatRule::Text)
        || matches!(d,FormatRule::Choice(v)if v.iter().any(|x|included_format(s,x)))
}
fn bounds<T: Ord>(smin: &Option<T>, smax: &Option<T>, dmin: &Option<T>, dmax: &Option<T>) -> bool {
    dmin.as_ref()
        .is_none_or(|d| smin.as_ref().is_some_and(|s| d <= s))
        && dmax
            .as_ref()
            .is_none_or(|d| smax.as_ref().is_some_and(|s| s <= d))
}
fn shape<'a>(g: &'a SemanticGraph, r: &TypeRef) -> Option<&'a TypeShape> {
    let mut r = r;
    let mut seen = HashSet::new();
    loop {
        if !seen.insert(r) {
            return None;
        }
        let s = &g.find_type(r)?.shape;
        if let TypeShape::Alias { target, .. } = s {
            r = target
        } else {
            return Some(s);
        }
    }
}
fn sealed_leaf_sample(profile: &VersionedSemanticProfile, leaf: &SealedLeaf) -> Option<JsonValue> {
    match leaf {
        SealedLeaf::String(spec) => spec
            .const_value
            .clone()
            .or_else(|| {
                spec.enum_values
                    .as_ref()
                    .and_then(|values| values.first().cloned())
            })
            .or_else(|| spec.examples.first().cloned())
            .or_else(|| match &spec.format {
                None => Some("x".into()),
                Some(format) => format_use_rule(profile, format)
                    .and_then(|rule| format_samples(rule, 1).into_iter().next()),
            })
            .map(JsonValue::Str),
        SealedLeaf::Integer(spec) => spec
            .const_value
            .clone()
            .or_else(|| {
                spec.enum_values
                    .as_ref()
                    .and_then(|values| values.first().cloned())
            })
            .or_else(|| spec.minimum.clone())
            .or_else(|| spec.maximum.clone())
            .map(JsonValue::Num),
    }
}
fn sealed_sample(
    profile: &VersionedSemanticProfile,
    tag: &str,
    refinements: &[SealedRefinement],
) -> Option<JsonValue> {
    let tag_model = profile.tag.as_ref()?;
    let form = tag_model.sealed.iter().find(|form| form.tag == tag)?;
    let fields = form
        .fields
        .iter()
        .filter(|field| field.required)
        .map(|field| {
            let leaf = refinements
                .iter()
                .find(|refinement| refinement.key == field.key)
                .map_or(&field.leaf, |refinement| &refinement.leaf);
            sealed_leaf_sample(profile, leaf).map(|value| (field.key.clone(), value))
        })
        .collect::<Option<Vec<_>>>()?;
    Some(JsonValue::Obj(
        std::iter::once((tag_model.key.clone(), JsonValue::Str(tag.to_owned())))
            .chain(fields)
            .collect(),
    ))
}
fn format_use_rule<'a>(
    profile: &'a VersionedSemanticProfile,
    format: &'a FormatUse,
) -> Option<&'a FormatRule> {
    match format {
        FormatUse::Named(name) => profile.format(name).map(|binding| &binding.rule),
        FormatUse::Inline(rule) => Some(rule),
    }
}
fn format_use_included(
    profile: &VersionedSemanticProfile,
    source: &Option<FormatUse>,
    destination: &Option<FormatUse>,
) -> bool {
    match destination {
        None => true,
        Some(destination) => source.as_ref().is_some_and(|source| {
            format_use_rule(profile, source)
                .zip(format_use_rule(profile, destination))
                .is_some_and(|(source, destination)| included_format(source, destination))
        }),
    }
}
fn format_use_accepts(
    profile: &VersionedSemanticProfile,
    format: &Option<FormatUse>,
    text: &str,
) -> bool {
    format.as_ref().is_none_or(|format| {
        format_use_rule(profile, format).is_some_and(|rule| recognize_format(rule, text))
    })
}
fn selector_disjoint(left: &UnionBranch, right: &UnionBranch) -> bool {
    match (&left.selector, &right.selector) {
        (BranchSelector::InternalTag, BranchSelector::InternalTag) => {
            left.wire_tag != right.wire_tag
        }
        (BranchSelector::Kind(left), BranchSelector::Kind(right)) => left != right,
        (BranchSelector::InternalTag, BranchSelector::Kind(right))
        | (BranchSelector::Kind(right), BranchSelector::InternalTag) => *right != ValueKind::Object,
        _ => false,
    }
}
fn selectors_equal(source: &UnionBranch, destination: &UnionBranch) -> bool {
    match (&source.selector, &destination.selector) {
        (BranchSelector::InternalTag, BranchSelector::InternalTag) => {
            source.wire_tag == destination.wire_tag
        }
        (BranchSelector::MemberShape(_), BranchSelector::MemberShape(_)) => source == destination,
        (BranchSelector::Kind(source), BranchSelector::Kind(destination)) => source == destination,
        (BranchSelector::Otherwise, BranchSelector::Otherwise) => true,
        _ => false,
    }
}
fn union_pairs<'a>(
    source: &'a [UnionBranch],
    destination: &'a [UnionBranch],
) -> Option<Vec<(&'a TypeRef, &'a TypeRef)>> {
    match (source.split_first(), destination.split_first()) {
        (None, _) => Some(vec![]),
        (Some(_), None) => None,
        (Some((source_head, source_rest)), Some((destination_head, destination_rest))) => {
            if selectors_equal(source_head, destination_head) {
                let mut pairs = union_pairs(source_rest, destination_rest)?;
                pairs.insert(0, (&source_head.target, &destination_head.target));
                Some(pairs)
            } else if source
                .iter()
                .all(|source| selector_disjoint(destination_head, source))
            {
                union_pairs(source, destination_rest)
            } else {
                None
            }
        }
    }
}
fn element_allows_null(g: &SemanticGraph, contract: &ElementContract) -> bool {
    contract.nullable
        || matches!(
            accepts_value(g, &contract.type_ref, &JsonValue::Null),
            ValueDecision::Accepted
        )
}

fn element_included(
    g: &SemanticGraph,
    source: &ElementContract,
    destination: &ElementContract,
) -> bool {
    (!element_allows_null(g, source) || element_allows_null(g, destination))
        && local(g, &source.type_ref, &destination.type_ref).is_some_and(|result| result.0)
}

fn local(g: &SemanticGraph, s: &TypeRef, d: &TypeRef) -> Option<(bool, InclusionRule)> {
    let (ss, ds) = (shape(g, s)?, shape(g, d)?);
    if matches!(ss, TypeShape::Never) {
        return Some((true, InclusionRule::EmptySource));
    }
    if ss == ds {
        return Some((
            true,
            match ss {
                TypeShape::Boolean(_) => InclusionRule::Boolean,
                TypeShape::Integer(_) => InclusionRule::Integer,
                TypeShape::String(_) => InclusionRule::String,
                TypeShape::Bytes(_) => InclusionRule::Bytes,
                TypeShape::Unit => InclusionRule::Unit,
                _ => InclusionRule::Unknown,
            },
        ));
    }
    match (ss, ds) {
        (_, TypeShape::Unknown(UnknownKind::Any)) => Some((true, InclusionRule::Unknown)),
        (TypeShape::Product(_), TypeShape::Unknown(UnknownKind::OrdinaryObject)) => {
            Some((true, InclusionRule::Unknown))
        }
        (TypeShape::Boolean(a), TypeShape::Boolean(b)) => Some((
            b.const_value.is_none() || a.const_value == b.const_value,
            InclusionRule::Boolean,
        )),
        (TypeShape::Integer(a), TypeShape::Integer(b)) => Some((
            a.domain == b.domain
                && bounds(&a.minimum, &a.maximum, &b.minimum, &b.maximum)
                && b.const_value
                    .as_ref()
                    .is_none_or(|x| a.const_value.as_ref() == Some(x))
                && b.enum_values.as_ref().is_none_or(|x| {
                    a.enum_values
                        .as_ref()
                        .is_some_and(|a| a.iter().all(|v| x.contains(v)))
                }),
            InclusionRule::Integer,
        )),
        (TypeShape::String(source), TypeShape::String(destination)) => Some((
            destination.wrapper == source.wrapper
                && destination
                    .const_value
                    .as_ref()
                    .is_none_or(|value| source.const_value.as_ref() == Some(value))
                && destination.enum_values.as_ref().is_none_or(|values| {
                    source
                        .enum_values
                        .as_ref()
                        .is_some_and(|source| source.iter().all(|value| values.contains(value)))
                })
                && destination.lengths.iter().all(|destination| {
                    source
                        .lengths
                        .iter()
                        .find(|source| source.unit == destination.unit)
                        .is_some_and(|source| {
                            bounds(
                                &source.minimum,
                                &source.maximum,
                                &destination.minimum,
                                &destination.maximum,
                            )
                        })
                })
                && format_use_included(&g.profile, &source.format, &destination.format),
            InclusionRule::String,
        )),
        (TypeShape::Bytes(a), TypeShape::Bytes(b)) => Some((
            bounds(&a.minimum, &a.maximum, &b.minimum, &b.maximum),
            InclusionRule::Bytes,
        )),
        (TypeShape::Array(a), TypeShape::Array(b)) => Some((
            bounds(&a.min_length, &a.max_length, &b.min_length, &b.max_length)
                && element_included(g, &a.item, &b.item),
            InclusionRule::Array,
        )),
        (TypeShape::Product(source), TypeShape::Product(destination)) => {
            let tag_key = g.profile.tag.as_ref().map(|tag| tag.key.as_str());
            let destination_fields = destination.fields.iter().all(|target| {
                match source
                    .fields
                    .iter()
                    .find(|field| field.wire_name == target.wire_name)
                {
                    Some(origin) => {
                        (!target.slot.required || origin.slot.required)
                            && (!origin.slot.nullable || target.slot.nullable)
                            && local(g, &origin.slot.type_ref, &target.slot.type_ref)
                                .is_some_and(|result| result.0)
                    }
                    None => {
                        !target.slot.required
                            && tag_key != Some(target.wire_name.as_str())
                            && matches!(&source.extras,
                                ExtraMembers::Allow { value, .. }
                                    if (!element_allows_null(g, value) || target.slot.nullable)
                                        && local(g, &value.type_ref, &target.slot.type_ref)
                                            .is_some_and(|result| result.0))
                    }
                }
            });
            let source_fields = source.fields.iter().all(|origin| {
                destination
                    .fields
                    .iter()
                    .any(|field| field.wire_name == origin.wire_name)
                    || tag_key == Some(origin.wire_name.as_str())
                    || matches!(&destination.extras,
                        ExtraMembers::Allow { key_format, value }
                            if format_use_accepts(&g.profile, key_format, &origin.wire_name)
                                && (!origin.slot.nullable || element_allows_null(g, value))
                                && local(g, &origin.slot.type_ref, &value.type_ref)
                                    .is_some_and(|result| result.0))
            });
            let extras = match (&source.extras, &destination.extras) {
                (ExtraMembers::Reject, _) => true,
                (ExtraMembers::Allow { .. }, ExtraMembers::Reject) => false,
                (
                    ExtraMembers::Allow {
                        key_format: source_key,
                        value: source_value,
                    },
                    ExtraMembers::Allow {
                        key_format: destination_key,
                        value: destination_value,
                    },
                ) => {
                    format_use_included(&g.profile, source_key, destination_key)
                        && element_included(g, source_value, destination_value)
                }
            };
            Some((
                destination_fields && source_fields && extras,
                InclusionRule::Product,
            ))
        }
        (TypeShape::TaggedUnion(source), TypeShape::TaggedUnion(destination)) => {
            let covered = if source
                .branches
                .iter()
                .any(|branch| branch.selector == BranchSelector::Otherwise)
            {
                source == destination
            } else {
                union_pairs(&source.branches, &destination.branches).is_some_and(|pairs| {
                    pairs.iter().all(|(source, destination)| {
                        local(g, source, destination).is_some_and(|result| result.0)
                    })
                })
            };
            Some((covered, InclusionRule::SourceUnion))
        }
        (TypeShape::Sealed { tag: a, .. }, TypeShape::Sealed { tag: b, .. }) => {
            Some((a == b, InclusionRule::Sealed))
        }
        _ => Some((false, InclusionRule::Unknown)),
    }
}
pub fn check_assignable(
    g: &SemanticGraph,
    s: &SlotContract,
    d: &SlotContract,
    max: usize,
) -> CompatibilityDecision {
    check_assignable_bounded(
        g,
        s,
        d,
        &SearchBounds {
            max_type_obligations: max,
            max_sample_length: 32,
            ..SearchBounds::default()
        },
    )
}

pub fn check_assignable_bounded(
    g: &SemanticGraph,
    s: &SlotContract,
    d: &SlotContract,
    bounds: &SearchBounds,
) -> CompatibilityDecision {
    if (!s.required && d.required) || (s.nullable && !d.nullable) {
        let value = if !s.required {
            SlotValue::Absent
        } else {
            SlotValue::Null
        };
        let ValueDecision::Rejected(destination_failure) =
            accepts_slot(g, d, borrowed_slot(&value))
        else {
            return CompatibilityDecision::Unknown(vec![]);
        };
        return CompatibilityDecision::Incompatible(CounterexampleCertificate {
            basis: SemanticBasis::of(g),
            source: s.clone(),
            destination: d.clone(),
            value,
            destination_failure,
        });
    }
    if let Some((true, rule)) = local(g, &s.type_ref, &d.type_ref) {
        return CompatibilityDecision::Compatible(InclusionCertificate {
            basis: SemanticBasis::of(g),
            source: s.clone(),
            destination: d.clone(),
            rule,
        });
    }
    let samples = inclusion_samples_bounded(g, &s.type_ref, &d.type_ref, bounds);
    for value in samples.values {
        if matches!(
            accepts_value(g, &s.type_ref, &value),
            ValueDecision::Accepted
        ) {
            if let ValueDecision::Rejected(destination_failure) =
                accepts_value(g, &d.type_ref, &value)
            {
                return CompatibilityDecision::Incompatible(CounterexampleCertificate {
                    basis: SemanticBasis::of(g),
                    source: s.clone(),
                    destination: d.clone(),
                    value: SlotValue::Present(value),
                    destination_failure,
                });
            }
        }
    }
    CompatibilityDecision::Unknown(vec![TypeObligation {
        source: s.type_ref.clone(),
        destination: d.type_ref.clone(),
        reason: TypeObligationReason::ConstraintImplication,
    }])
}
fn format_samples(r: &FormatRule, limit: usize) -> Vec<String> {
    let mut out = match r {
        FormatRule::Literal(x) => vec![x.clone()],
        FormatRule::Text => vec![String::new(), "a".into()],
        FormatRule::Not(x) => ["", "x", "0", "-", "a.b"]
            .into_iter()
            .filter(|s| !recognize_format(x, s))
            .map(str::to_owned)
            .collect(),
        FormatRule::Optional(x) => std::iter::once(String::new())
            .chain(format_samples(x, limit))
            .collect(),
        FormatRule::Choice(v) => v.iter().flat_map(|x| format_samples(x, limit)).collect(),
        FormatRule::Sequence(v) => {
            let mut a = vec![String::new()];
            for x in v {
                let b = format_samples(x, limit);
                a = a
                    .into_iter()
                    .flat_map(|p| b.iter().map(move |q| format!("{p}{q}")))
                    .take(limit)
                    .collect()
            }
            a
        }
        FormatRule::Labels {
            separator,
            min_count,
            rule,
            ..
        } => {
            let s = format_samples(rule, limit)
                .into_iter()
                .next()
                .unwrap_or_default();
            vec![vec![s; min_count.to_usize().unwrap_or(0)].join(separator)]
        }
        FormatRule::Identifier {
            first_alphabet,
            rest_alphabet,
            min_length,
            ..
        } => {
            let n = min_length.to_usize().unwrap_or(1);
            vec![format!(
                "{}{}",
                first_alphabet.chars().next().unwrap_or('a'),
                rest_alphabet
                    .chars()
                    .next()
                    .unwrap_or('a')
                    .to_string()
                    .repeat(n.saturating_sub(1))
            )]
        }
        FormatRule::Timestamp(_) => vec!["2000-01-01T00:00:00Z".into()],
        FormatRule::AbsoluteUri { .. } => vec!["x:y".into()],
        FormatRule::LanguageTag { grandfathered } => grandfathered
            .first()
            .cloned()
            .into_iter()
            .chain(Some("en".into()))
            .collect(),
        FormatRule::Bounded { rule, .. } => format_samples(rule, limit),
        FormatRule::AsciiDfa(_) => vec![String::new()],
    };
    out.retain(|x| recognize_format(r, x));
    out.truncate(limit);
    out
}
#[derive(Clone, Copy, PartialEq, Eq)]
enum CandidateOrder {
    Collection,
    FirstWitness,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SlotCandidateControl {
    Accept,
    Continue,
    StopNoEvidence,
}

#[derive(Debug, Clone, PartialEq)]
pub enum SlotCandidateSearch {
    AcceptedWithinBound(SlotValue),
    AcceptedBeyondSampleBound(SlotValue),
    NoEvidence,
}

fn visit_product_field_options(
    g: &SemanticGraph,
    field: &FieldSpec,
    fuel: usize,
    seen: &mut Vec<TypeRef>,
    order: CandidateOrder,
    emit: &mut impl FnMut(Option<JsonValue>) -> bool,
    obligations: &mut Vec<SampleObligation>,
) -> bool {
    if !field.slot.required && emit(None) {
        return true;
    }
    if order == CandidateOrder::FirstWitness && field.slot.nullable && emit(Some(JsonValue::Null)) {
        return true;
    }
    if visit_value_candidates(
        g,
        &field.slot.type_ref,
        fuel.saturating_sub(1),
        seen,
        order,
        &mut |value| {
            if matches!(
                accepts_value(g, &field.slot.type_ref, &value),
                ValueDecision::Accepted
            ) {
                emit(Some(value))
            } else {
                false
            }
        },
        obligations,
    ) {
        return true;
    }
    order == CandidateOrder::Collection && field.slot.nullable && emit(Some(JsonValue::Null))
}

#[allow(clippy::too_many_arguments)]
fn visit_product_prefix(
    g: &SemanticGraph,
    fields: &mut [(&FieldSpec, usize)],
    members: Vec<(String, JsonValue)>,
    fuel: usize,
    seen: &mut Vec<TypeRef>,
    order: CandidateOrder,
    stage_exhausted: &mut bool,
    callback_stopped: &mut bool,
    first_product: &mut Option<Vec<(String, JsonValue)>>,
    emit: &mut dyn FnMut(JsonValue) -> bool,
    obligations: &mut Vec<SampleObligation>,
) {
    if *stage_exhausted || *callback_stopped {
        return;
    }
    let Some(((field, count), remaining_fields)) = fields.split_first_mut() else {
        if first_product.is_none() {
            *first_product = Some(members.clone());
        }
        if emit(JsonValue::Obj(members)) {
            *callback_stopped = true;
        }
        return;
    };
    let field = *field;
    let mut field_seen = seen.clone();
    let mut field_obligations = Vec::new();
    let mut emit_option = |value: Option<JsonValue>| {
        if *stage_exhausted || *callback_stopped {
            return true;
        }
        if *count >= fuel {
            *stage_exhausted = true;
            return true;
        }
        *count += 1;
        let mut next = members.clone();
        if let Some(value) = value {
            next.push((field.wire_name.clone(), value));
        }
        visit_product_prefix(
            g,
            remaining_fields,
            next,
            fuel,
            seen,
            order,
            stage_exhausted,
            callback_stopped,
            first_product,
            emit,
            obligations,
        );
        if *stage_exhausted || *callback_stopped {
            return true;
        }
        if *count >= fuel {
            *stage_exhausted = true;
            return true;
        }
        false
    };
    visit_product_field_options(
        g,
        field,
        fuel,
        &mut field_seen,
        order,
        &mut emit_option,
        &mut field_obligations,
    );
    obligations.extend(field_obligations);
}

fn visit_product_candidates(
    g: &SemanticGraph,
    product: &ProductSpec,
    fuel: usize,
    seen: &mut Vec<TypeRef>,
    order: CandidateOrder,
    emit: &mut dyn FnMut(JsonValue) -> bool,
    obligations: &mut Vec<SampleObligation>,
) -> bool {
    let mut fields: Vec<_> = product.fields.iter().map(|field| (field, 0)).collect();
    let mut stage_exhausted = false;
    let mut callback_stopped = false;
    let mut first_product = None;
    visit_product_prefix(
        g,
        &mut fields,
        Vec::new(),
        fuel,
        seen,
        order,
        &mut stage_exhausted,
        &mut callback_stopped,
        &mut first_product,
        emit,
        obligations,
    );
    if callback_stopped {
        return true;
    }
    if let ExtraMembers::Allow { key_format, value } = &product.extras {
        let key = match key_format {
            Some(FormatUse::Inline(rule)) => format_samples(rule, fuel).into_iter().next(),
            Some(FormatUse::Named(name)) => g
                .profile
                .format(name)
                .and_then(|binding| format_samples(&binding.rule, fuel).into_iter().next()),
            None => Some("x".into()),
        };
        if let Some(key) = key {
            if order == CandidateOrder::FirstWitness {
                let base = first_product.unwrap_or_default();
                let mut emitted = 0;
                let mut stopped = false;
                let mut emit_extra = |extra| {
                    emitted += 1;
                    let mut members = base.clone();
                    members.push((key.clone(), extra));
                    stopped = emit(JsonValue::Obj(members));
                    stopped || emitted >= 2
                };
                if value.nullable && emit_extra(JsonValue::Null) {
                    return stopped;
                }
                visit_value_candidates(
                    g,
                    &value.type_ref,
                    fuel.saturating_sub(1),
                    seen,
                    order,
                    &mut |candidate| {
                        if value.nullable && candidate == JsonValue::Null {
                            return false;
                        }
                        matches!(
                            accepts_value(g, &value.type_ref, &candidate),
                            ValueDecision::Accepted
                        ) && emit_extra(candidate)
                    },
                    obligations,
                );
                return stopped;
            }
            let mut extras = Vec::new();
            let mut contains_null = false;
            let mut child_obligations = Vec::new();
            visit_value_candidates(
                g,
                &value.type_ref,
                fuel.saturating_sub(1),
                seen,
                order,
                &mut |candidate| {
                    if matches!(
                        accepts_value(g, &value.type_ref, &candidate),
                        ValueDecision::Accepted
                    ) {
                        contains_null |= candidate == JsonValue::Null;
                        if extras.len() < 2 {
                            extras.push(candidate);
                        }
                    }
                    false
                },
                &mut child_obligations,
            );
            obligations.extend(child_obligations);
            if value.nullable && !contains_null {
                extras.insert(0, JsonValue::Null);
            }
            let base = first_product.unwrap_or_default();
            for extra in extras.into_iter().take(2) {
                let mut members = base.clone();
                members.push((key.clone(), extra));
                if emit(JsonValue::Obj(members)) {
                    return true;
                }
            }
        }
    }
    false
}

fn visit_array_candidates(
    g: &SemanticGraph,
    array: &ArraySpec,
    fuel: usize,
    seen: &mut Vec<TypeRef>,
    order: CandidateOrder,
    emit: &mut dyn FnMut(JsonValue) -> bool,
    obligations: &mut Vec<SampleObligation>,
) -> bool {
    if order == CandidateOrder::Collection {
        let mut child = value_samples(g, &array.item.type_ref, fuel.saturating_sub(1), seen);
        obligations.extend(child.obligations);
        if array.item.nullable && !child.values.contains(&JsonValue::Null) {
            child.values.push(JsonValue::Null);
        }
        let items = child.values.into_iter().take(2).collect::<Vec<_>>();
        return [
            array.min_length.as_ref().and_then(ToPrimitive::to_usize),
            array.max_length.as_ref().and_then(ToPrimitive::to_usize),
            Some(0),
            Some(1),
        ]
        .into_iter()
        .flatten()
        .flat_map(|length| {
            items
                .iter()
                .map(move |item| JsonValue::Arr(vec![item.clone(); length]))
        })
        .any(&mut *emit);
    }
    if array
        .min_length
        .as_ref()
        .is_some_and(|minimum| minimum.to_usize().is_none())
    {
        return false;
    }
    let mut lengths = Vec::new();
    for length in [
        array.min_length.as_ref().and_then(ToPrimitive::to_usize),
        array.max_length.as_ref().and_then(ToPrimitive::to_usize),
        Some(0),
        Some(1),
    ]
    .into_iter()
    .flatten()
    {
        if !lengths.contains(&length) {
            lengths.push(length);
        }
    }
    if array
        .min_length
        .as_ref()
        .and_then(ToPrimitive::to_usize)
        .unwrap_or(0)
        == 0
    {
        if let Some(zero_index) = lengths.iter().position(|length| *length == 0) {
            lengths.remove(zero_index);
            lengths.insert(0, 0);
        }
    }
    for length in lengths {
        if length == 0 {
            if emit(JsonValue::Arr(vec![])) {
                return true;
            }
            continue;
        }
        let mut emitted = 0;
        let mut stopped = false;
        let mut emit_item = |item| {
            emitted += 1;
            stopped = emit(JsonValue::Arr(vec![item; length]));
            stopped || emitted >= 2
        };
        if array.item.nullable && emit_item(JsonValue::Null) {
            if stopped {
                return true;
            }
            continue;
        }
        visit_value_candidates(
            g,
            &array.item.type_ref,
            fuel.saturating_sub(1),
            seen,
            order,
            &mut |candidate| {
                if array.item.nullable && candidate == JsonValue::Null {
                    return false;
                }
                matches!(
                    accepts_value(g, &array.item.type_ref, &candidate),
                    ValueDecision::Accepted
                ) && emit_item(candidate)
            },
            obligations,
        );
        if stopped {
            return true;
        }
    }
    false
}
fn visit_value_candidates(
    g: &SemanticGraph,
    reference: &TypeRef,
    fuel: usize,
    seen: &mut Vec<TypeRef>,
    order: CandidateOrder,
    emit: &mut dyn FnMut(JsonValue) -> bool,
    obligations: &mut Vec<SampleObligation>,
) -> bool {
    if fuel == 0 || seen.contains(reference) {
        return false;
    }
    let Some(shape) = shape(g, reference) else {
        return false;
    };
    seen.push(reference.clone());
    let stopped = match shape {
        TypeShape::Boolean(spec) => spec
            .const_value
            .map(JsonValue::Bool)
            .into_iter()
            .chain([JsonValue::Bool(false), JsonValue::Bool(true)])
            .any(&mut *emit),
        TypeShape::Integer(spec) => spec
            .const_value
            .iter()
            .chain(spec.enum_values.iter().flatten())
            .chain(spec.minimum.iter())
            .chain(spec.maximum.iter())
            .cloned()
            .chain([BigInt::zero(), BigInt::one()])
            .map(JsonValue::Num)
            .any(&mut *emit),
        TypeShape::Decimal(_) => [JsonValue::Dec("0.0".into()), JsonValue::Dec("1.0".into())]
            .into_iter()
            .any(&mut *emit),
        TypeShape::String(spec) => {
            let mut values = spec
                .const_value
                .iter()
                .chain(spec.enum_values.iter().flatten())
                .chain(spec.examples.iter())
                .cloned()
                .chain(
                    spec.format
                        .iter()
                        .filter_map(|format_use| match format_use {
                            FormatUse::Inline(rule) => Some(rule),
                            FormatUse::Named(name) => {
                                g.profile.format(name).map(|binding| &binding.rule)
                            }
                        })
                        .flat_map(|rule| format_samples(rule, fuel)),
                )
                .chain(spec.lengths.iter().flat_map(|bound| {
                    bound
                        .minimum
                        .iter()
                        .chain(bound.maximum.iter())
                        .filter_map(ToPrimitive::to_usize)
                        .map(|length| "a".repeat(length))
                }))
                .peekable();
            let mut emit_text = |text| match &spec.wrapper {
                None => emit(JsonValue::Str(text)),
                Some(name) => g
                    .profile
                    .wrappers
                    .iter()
                    .find(|wrapper| wrapper.name == *name)
                    .is_some_and(|wrapper| {
                        emit(JsonValue::Obj(vec![(
                            wrapper.key.clone(),
                            JsonValue::Str(text),
                        )]))
                    }),
            };
            if values.peek().is_none() {
                emit_text(String::new())
            } else {
                values.any(&mut emit_text)
            }
        }
        TypeShape::Bytes(_) | TypeShape::RawBody { .. } => {
            let value = match g
                .profile
                .bytes_policy
                .as_ref()
                .and_then(|policy| policy.wrapper.as_ref())
            {
                Some(name) => g
                    .profile
                    .wrappers
                    .iter()
                    .find(|wrapper| wrapper.name == *name)
                    .map(|wrapper| {
                        JsonValue::Obj(vec![(wrapper.key.clone(), JsonValue::Str(String::new()))])
                    }),
                None if g.profile.bytes_policy.is_some() => Some(JsonValue::Str(String::new())),
                None => None,
            };
            value.is_some_and(&mut *emit)
        }
        TypeShape::Product(product) => {
            visit_product_candidates(g, product, fuel, seen, order, emit, obligations)
        }
        TypeShape::Array(array) => {
            visit_array_candidates(g, array, fuel, seen, order, emit, obligations)
        }
        TypeShape::TaggedUnion(union) => {
            let mut stopped = false;
            for branch in &union.branches {
                let mut branch_obligations = Vec::new();
                let branch_stopped = visit_value_candidates(
                    g,
                    &branch.target,
                    fuel.saturating_sub(1),
                    seen,
                    order,
                    &mut |candidate| {
                        matches!(
                            accepts_value(g, &branch.target, &candidate),
                            ValueDecision::Accepted
                        ) && emit(candidate)
                    },
                    &mut branch_obligations,
                );
                if order == CandidateOrder::FirstWitness {
                    obligations.extend(branch_obligations);
                }
                if branch_stopped {
                    stopped = true;
                    break;
                }
            }
            stopped
        }
        TypeShape::Sealed { tag, refinements } => {
            sealed_sample(&g.profile, tag, refinements).is_some_and(&mut *emit)
        }
        TypeShape::Never | TypeShape::Opaque { .. } => false,
        TypeShape::Unknown(UnknownKind::Any) => [
            JsonValue::Null,
            JsonValue::Bool(false),
            JsonValue::Num(BigInt::zero()),
            JsonValue::Str(String::new()),
            JsonValue::Arr(vec![]),
            JsonValue::Obj(vec![]),
        ]
        .into_iter()
        .any(&mut *emit),
        TypeShape::Unknown(UnknownKind::OrdinaryObject) => emit(JsonValue::Obj(vec![])),
        TypeShape::Unit => emit(JsonValue::Null),
        TypeShape::Alias { .. } => unreachable!(),
    };
    seen.pop();
    stopped
}

fn value_samples(
    g: &SemanticGraph,
    reference: &TypeRef,
    fuel: usize,
    seen: &mut Vec<TypeRef>,
) -> SampleResult<JsonValue> {
    let mut values = Vec::new();
    let mut obligations = Vec::new();
    visit_value_candidates(
        g,
        reference,
        fuel,
        seen,
        CandidateOrder::Collection,
        &mut |value| {
            values.push(value);
            false
        },
        &mut obligations,
    );
    values.retain(|value| matches!(accepts_value(g, reference, value), ValueDecision::Accepted));
    SampleResult {
        values,
        obligations,
    }
}

pub fn find_accepted_slot_candidate(
    g: &SemanticGraph,
    bounds: &SearchBounds,
    contract: &SlotContract,
    mut inspect: impl FnMut(&SlotValue, bool) -> SlotCandidateControl,
) -> SlotCandidateSearch {
    for value in [
        (!contract.required).then_some(SlotValue::Absent),
        contract.nullable.then_some(SlotValue::Null),
    ]
    .into_iter()
    .flatten()
    {
        if !matches!(
            validation::accepts_slot(g, contract, borrowed_slot(&value)),
            ValueDecision::Accepted
        ) {
            continue;
        }
        match inspect(&value, true) {
            SlotCandidateControl::Accept => return SlotCandidateSearch::AcceptedWithinBound(value),
            SlotCandidateControl::Continue => {}
            SlotCandidateControl::StopNoEvidence => return SlotCandidateSearch::NoEvidence,
        }
    }
    let mut seen = Vec::new();
    let mut result = None;
    let mut stopped = false;
    let mut obligations = Vec::new();
    visit_value_candidates(
        g,
        &contract.type_ref,
        bounds.max_type_obligations.min(g.nodes.len() + 1),
        &mut seen,
        CandidateOrder::FirstWitness,
        &mut |candidate| {
            let value = SlotValue::Present(candidate);
            if !matches!(
                validation::accepts_slot(g, contract, borrowed_slot(&value)),
                ValueDecision::Accepted
            ) {
                return false;
            }
            let within_bound = match &value {
                SlotValue::Present(value) => max_sample_length(value) <= bounds.max_sample_length,
                _ => true,
            };
            match inspect(&value, within_bound) {
                SlotCandidateControl::Accept => {
                    result = Some(if within_bound {
                        SlotCandidateSearch::AcceptedWithinBound(value)
                    } else {
                        SlotCandidateSearch::AcceptedBeyondSampleBound(value)
                    });
                    true
                }
                SlotCandidateControl::Continue => false,
                SlotCandidateControl::StopNoEvidence => {
                    stopped = true;
                    true
                }
            }
        },
        &mut obligations,
    );
    if stopped {
        SlotCandidateSearch::NoEvidence
    } else {
        result.unwrap_or(SlotCandidateSearch::NoEvidence)
    }
}
pub fn sample_value_fuel(
    g: &SemanticGraph,
    b: &SearchBounds,
    fuel: usize,
    seen: &[TypeRef],
    r: &TypeRef,
) -> SampleResult<JsonValue> {
    let mut seen = seen.to_vec();
    let mut result = value_samples(g, r, fuel, &mut seen);
    let before = result.values.len();
    result
        .values
        .retain(|value| max_sample_length(value) <= b.max_sample_length);
    if result.values.len() != before {
        result.obligations.push(SampleObligation::SampleBound);
    }
    result
}
pub fn slot_samples(
    g: &SemanticGraph,
    b: &SearchBounds,
    s: &SlotContract,
) -> SampleResult<SlotValue> {
    let x = sample_value_fuel(
        g,
        b,
        b.max_type_obligations.min(g.nodes.len() + 1),
        &[],
        &s.type_ref,
    );
    SampleResult {
        values: (!s.required)
            .then_some(SlotValue::Absent)
            .into_iter()
            .chain(s.nullable.then_some(SlotValue::Null))
            .chain(x.values.into_iter().map(SlotValue::Present))
            .collect(),
        obligations: x.obligations,
    }
}
pub fn inclusion_samples(
    graph: &SemanticGraph,
    source: &TypeRef,
    destination: &TypeRef,
    maximum: usize,
) -> SampleResult<JsonValue> {
    inclusion_samples_bounded(
        graph,
        source,
        destination,
        &SearchBounds {
            max_type_obligations: maximum,
            max_sample_length: 32,
            ..SearchBounds::default()
        },
    )
}

pub fn inclusion_samples_bounded(
    graph: &SemanticGraph,
    source: &TypeRef,
    destination: &TypeRef,
    bounds: &SearchBounds,
) -> SampleResult<JsonValue> {
    let fuel = bounds.max_type_obligations.min(graph.nodes.len() + 1);
    let mut generated = sample_value_fuel(graph, bounds, fuel, &[], source);
    let mut candidates = Vec::new();
    if let (Some(TypeShape::Product(source_spec)), Some(TypeShape::Product(destination_spec))) = (
        resolved_shape(graph, source),
        resolved_shape(graph, destination),
    ) {
        for field in &destination_spec.fields {
            if source_spec
                .fields
                .iter()
                .any(|declared| declared.wire_name == field.wire_name)
            {
                continue;
            }
            let Some(JsonValue::Obj(members)) = generated.values.first() else {
                continue;
            };
            for value in [
                JsonValue::Null,
                JsonValue::Bool(true),
                JsonValue::Str("x".into()),
                JsonValue::Str("y".into()),
                JsonValue::Num(BigInt::zero()),
            ] {
                let mut candidate_members = vec![(field.wire_name.clone(), value)];
                candidate_members.extend(members.clone());
                candidates.push(JsonValue::Obj(candidate_members));
            }
        }
        if let ExtraMembers::Allow { key_format, value } = &source_spec.extras {
            let keys = match key_format {
                Some(FormatUse::Inline(rule)) => format_samples(rule, 1),
                Some(FormatUse::Named(name)) => graph
                    .profile
                    .format(name)
                    .map(|binding| format_samples(&binding.rule, 1))
                    .unwrap_or_default(),
                None => vec!["x".into()],
            };
            let mut values = sample_value_fuel(graph, bounds, fuel, &[], &value.type_ref).values;
            if value.nullable && !values.contains(&JsonValue::Null) {
                values.push(JsonValue::Null);
            }
            for key in keys {
                for value in &values {
                    candidates.push(JsonValue::Obj(vec![(key.clone(), value.clone())]));
                }
            }
        }
    }
    let candidate_count = candidates.len();
    let additional: Vec<_> = candidates
        .into_iter()
        .filter(|value| {
            max_sample_length(value) <= bounds.max_sample_length
                && matches!(accepts_value(graph, source, value), ValueDecision::Accepted)
        })
        .collect();
    if additional.len() != candidate_count {
        generated.obligations.push(SampleObligation::SampleBound);
    }
    generated.values.extend(additional);
    generated
}

#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub enum ProducerRef {
    Initial(InputId),
    InvocationOutcome {
        site: SiteId,
        outcome: OutcomeId,
        port: PortId,
    },
}
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ValueRef {
    pub producer: ProducerRef,
    pub path: ValuePath,
}
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SourceConstraint {
    AnyCompatible,
    InitialOnly {
        input: InputId,
        path: ValuePath,
    },
    ProducedBy {
        site: SiteId,
        outcome: OutcomeId,
        port: PortId,
        path: ValuePath,
    },
}
impl SourceConstraint {
    fn accepts(&self, producer: &ProducerRef, value_path: &[PathStep]) -> bool {
        match (self, producer) {
            (Self::AnyCompatible, _) => true,
            (Self::InitialOnly { input, path }, ProducerRef::Initial(actual)) => {
                input == actual && path == value_path
            }
            (
                Self::ProducedBy {
                    site,
                    outcome,
                    port,
                    path,
                },
                ProducerRef::InvocationOutcome {
                    site: s,
                    outcome: o,
                    port: p,
                },
            ) => site == s && outcome == o && port == p && path == value_path,
            _ => false,
        }
    }
}
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub enum ResourceLotRef {
    Initial(LotId),
    Produced {
        site: SiteId,
        outcome: OutcomeId,
        production: ProductionId,
    },
}
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ResourceProducer {
    Initial { identity: String, revision: String },
    InvocationOutcome { site: SiteId, outcome: OutcomeId },
}
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ResourceIdentityConstraint {
    Any,
    Exactly(ResourceProducer),
}
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ResourceLot {
    pub id: LotId,
    pub token_type: TypeRef,
    pub producer: ResourceProducer,
    pub revision: Nat,
    pub quantity: Nat,
    pub provenance: String,
}
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ResourceRequirement {
    pub id: RequirementId,
    pub token_type: TypeRef,
    pub mode: resource::BindingMode,
    pub multiplicity: Nat,
    pub required_revision: Nat,
    pub identity: ResourceIdentityConstraint,
}
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ResourceProduction {
    pub id: ProductionId,
    pub token_type: TypeRef,
    pub revision: Nat,
    pub quantity: Nat,
    pub provenance: String,
}
#[derive(Debug, Clone, PartialEq)]
pub enum InitialSource {
    Argument,
    SuppliedValue(SlotValue),
}
#[derive(Debug, Clone, PartialEq)]
pub struct InitialInput {
    pub id: InputId,
    pub contract: SlotContract,
    pub source: InitialSource,
    pub resource: Option<LotId>,
}
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct InputPort {
    pub id: PortId,
    pub contract: SlotContract,
    pub source_constraint: SourceConstraint,
    pub resource_requirement: Option<RequirementId>,
}
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct OutputPort {
    pub id: PortId,
    pub contract: SlotContract,
    pub resource_production: Option<ProductionId>,
}
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum OutcomeForm {
    Success,
    DeclaredFailure,
}
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct OutcomeContract {
    pub id: OutcomeId,
    pub form: OutcomeForm,
    pub value_ports: Vec<OutputPort>,
    pub produced_resources: Vec<ResourceProduction>,
}
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum FunctionForm {
    Pure,
    Operation(DefinitionRef),
    DeclaredTransform,
}
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CompositionEffect {
    PureFunction,
    HttpRequestResponse,
    DataOnly,
}
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum GuardArm {
    Present,
    Absent,
    Null,
    Variant(String),
    UnknownVariant,
    Accepted,
    Rejected,
}
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum FailureOrigin {
    Function {
        function: FunctionRef,
        outcome: OutcomeId,
    },
    Guard {
        guard: GuardId,
        arm: GuardArm,
    },
}
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FunctionSignature {
    pub reference: FunctionRef,
    pub form: FunctionForm,
    pub effect: CompositionEffect,
    pub inputs: Vec<InputPort>,
    pub outcomes: Vec<OutcomeContract>,
    pub resource_inputs: Vec<ResourceRequirement>,
    pub assumption_ref: String,
    pub handles_failure: Option<FailureOrigin>,
}
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct InvocationSite {
    pub id: SiteId,
    pub function: FunctionRef,
}
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PermittedProjection {
    pub source_type: TypeRef,
    pub path: ValuePath,
}
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum GuardKind {
    Presence,
    Variants,
    Validate(SlotContract),
}
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DeclaredGuard {
    pub id: GuardId,
    pub source_type: TypeRef,
    pub path: ValuePath,
    pub kind: GuardKind,
}
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum FieldPresence {
    Required,
    Optional,
}
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FieldConstraint {
    pub field: String,
    pub source: SourceConstraint,
    pub presence: FieldPresence,
}
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ConstructionRule {
    pub identity: String,
    pub type_ref: TypeRef,
    pub nested_fields: Vec<(String, String)>,
    pub field_constraints: Vec<FieldConstraint>,
}
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct InvocationDomain {
    pub identity: String,
    pub revision: String,
    pub sites: Vec<InvocationSite>,
    pub permitted_projections: Vec<PermittedProjection>,
    pub permitted_constructions: Vec<ConstructionRule>,
    pub permitted_transforms: Vec<FunctionRef>,
    pub guards: Vec<DeclaredGuard>,
}
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ResourceGoal {
    pub lot: ResourceLotRef,
    pub multiplicity: Nat,
    pub revision: Nat,
}
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct GoalPort {
    pub id: GoalPortId,
    pub contract: SlotContract,
    pub source_constraint: SourceConstraint,
}
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FailureEmbedding {
    pub id: FailureEmbeddingId,
    pub origin: FailureOrigin,
    pub contract: SlotContract,
    pub final_resources: Vec<ResourceGoal>,
}
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct GoalSpec {
    pub outputs: Vec<GoalPort>,
    pub failures: Vec<FailureEmbedding>,
    pub final_resources: Vec<ResourceGoal>,
}
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SelectionPolicy {
    RequireUnique,
    AnyFeasible,
}
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ResourceBounds {
    pub max_bindings: Nat,
    pub max_search_steps: Nat,
    pub max_tokens: usize,
}
#[derive(Debug, Clone, PartialEq)]
pub struct CompositionInput {
    pub identity: String,
    pub revision: String,
    pub basis: SemanticBasis,
    pub signatures: Vec<FunctionSignature>,
    pub initial_inputs: Vec<InitialInput>,
    pub initial_resources: Vec<ResourceLot>,
    pub goal: GoalSpec,
    pub invocation_domain: InvocationDomain,
    pub allowed_effects: Vec<CompositionEffect>,
    pub explicit_order: Vec<(SiteId, SiteId)>,
    pub selection_policy: Option<SelectionPolicy>,
    pub bounds: SearchBounds,
}
#[derive(Debug, Clone, PartialEq)]
pub enum CompositionInputFailure {
    BasisMismatch,
    DuplicateIdentity {
        kind: String,
        identity: String,
    },
    UnresolvedType(TypeRef),
    UnresolvedFunction(FunctionRef),
    InvalidSignature {
        function: FunctionRef,
        reason: String,
    },
    InvalidInitialValue {
        input: InputId,
        failure: ValueFailure,
    },
    InvalidInvocationDomain(String),
    InvalidResourceDeclaration(String),
    OperationEffectMismatch {
        operation: DefinitionRef,
        expected: CompositionEffect,
        supplied: CompositionEffect,
    },
}
#[derive(Debug)]
pub struct PreparedCompositionInput<'g> {
    graph: &'g SemanticGraph,
    input: CompositionInput,
    empty: Vec<TypeRef>,
    initial_obligations: Vec<SemanticObligation>,
}
impl<'g> PreparedCompositionInput<'g> {
    pub fn graph(&self) -> &'g SemanticGraph {
        self.graph
    }
    pub fn input(&self) -> &CompositionInput {
        &self.input
    }
    pub fn empty(&self) -> &[TypeRef] {
        &self.empty
    }
    pub fn initial_obligations(&self) -> &[SemanticObligation] {
        &self.initial_obligations
    }
}
fn unique_ids<'a>(
    kind: &str,
    values: impl IntoIterator<Item = &'a str>,
) -> Result<(), CompositionInputFailure> {
    let mut seen = HashSet::new();
    for identity in values {
        if identity.is_empty() || !seen.insert(identity) {
            return Err(CompositionInputFailure::DuplicateIdentity {
                kind: kind.to_owned(),
                identity: identity.to_owned(),
            });
        }
    }
    Ok(())
}
fn check_type(graph: &SemanticGraph, reference: &TypeRef) -> Result<(), CompositionInputFailure> {
    if graph.find_type(reference).is_some() {
        Ok(())
    } else {
        Err(CompositionInputFailure::UnresolvedType(reference.clone()))
    }
}
fn signature<'a>(
    input: &'a CompositionInput,
    reference: &FunctionRef,
) -> Option<&'a FunctionSignature> {
    input
        .signatures
        .iter()
        .find(|signature| signature.reference == *reference)
}
fn site_signature<'a>(input: &'a CompositionInput, site: &SiteId) -> Option<&'a FunctionSignature> {
    signature(
        input,
        &input
            .invocation_domain
            .sites
            .iter()
            .find(|candidate| candidate.id == *site)?
            .function,
    )
}
fn source_path_valid(graph: &SemanticGraph, reference: &TypeRef, path: &[PathStep]) -> bool {
    let mut reference = reference;
    let mut position = 0;
    let mut seen = HashSet::new();
    loop {
        let Some(node) = graph.find_type(reference) else {
            return false;
        };
        let Some(step) = path.get(position) else {
            return true;
        };
        if !seen.insert((reference, position)) {
            return false;
        }
        match (&node.shape, step) {
            (TypeShape::Alias { target, .. }, _) => {
                reference = target;
                continue;
            }
            (TypeShape::Product(spec), PathStep::Field(name)) => {
                let Some(field) = spec.fields.iter().find(|field| field.wire_name == *name) else {
                    return false;
                };
                reference = &field.slot.type_ref;
            }
            (TypeShape::Array(spec), PathStep::Index(_)) => reference = &spec.item.type_ref,
            (TypeShape::TaggedUnion(spec), PathStep::Variant(tag)) => {
                let Some(branch) = spec.branches.iter().find(|branch| branch.wire_tag == *tag)
                else {
                    return false;
                };
                reference = &branch.target;
            }
            _ => return false,
        }
        position += 1;
    }
}

fn check_source_constraint(
    graph: &SemanticGraph,
    input: &CompositionInput,
    constraint: &SourceConstraint,
) -> Result<(), CompositionInputFailure> {
    let source = match constraint {
        SourceConstraint::AnyCompatible => return Ok(()),
        SourceConstraint::InitialOnly { input: id, path } => input
            .initial_inputs
            .iter()
            .find(|initial| initial.id == *id)
            .map(|initial| (&initial.contract, path)),
        SourceConstraint::ProducedBy {
            site,
            outcome,
            port,
            path,
        } => site_signature(input, site)
            .and_then(|signature| {
                signature
                    .outcomes
                    .iter()
                    .find(|candidate| candidate.id == *outcome)
            })
            .and_then(|outcome| {
                outcome
                    .value_ports
                    .iter()
                    .find(|candidate| candidate.id == *port)
            })
            .map(|port| (&port.contract, path)),
    };
    let valid =
        source.is_some_and(|(contract, path)| source_path_valid(graph, &contract.type_ref, path));
    if valid {
        Ok(())
    } else {
        Err(CompositionInputFailure::InvalidInvocationDomain(format!(
            "unresolved source constraint {:?}",
            constraint
        )))
    }
}
fn check_operation_signature(
    graph: &SemanticGraph,
    signature: &FunctionSignature,
    reference: &DefinitionRef,
) -> Result<(), CompositionInputFailure> {
    let source_known = graph
        .nodes
        .iter()
        .any(|node| node.reference.source == reference.source);
    if source_known {
        Ok(())
    } else {
        Err(CompositionInputFailure::InvalidSignature {
            function: signature.reference.clone(),
            reason: "operation source is absent from the graph".into(),
        })
    }
}
pub fn prepare_composition(
    graph: &SemanticGraph,
    input: CompositionInput,
) -> Result<PreparedCompositionInput<'_>, CompositionInputFailure> {
    if !input.basis.matches(graph) {
        return Err(CompositionInputFailure::BasisMismatch);
    }
    unique_ids(
        "input",
        input.initial_inputs.iter().map(|value| value.id.0.as_str()),
    )?;
    unique_ids(
        "site",
        input
            .invocation_domain
            .sites
            .iter()
            .map(|value| value.id.0.as_str()),
    )?;
    unique_ids(
        "lot",
        input
            .initial_resources
            .iter()
            .map(|value| value.id.0.as_str()),
    )?;
    unique_ids(
        "goal",
        input.goal.outputs.iter().map(|value| value.id.0.as_str()),
    )?;
    unique_ids(
        "failure embedding",
        input.goal.failures.iter().map(|value| value.id.0.as_str()),
    )?;
    unique_ids(
        "guard",
        input
            .invocation_domain
            .guards
            .iter()
            .map(|value| value.id.0.as_str()),
    )?;
    let mut functions = HashSet::new();
    for function in &input.signatures {
        let fail = |reason: &str| CompositionInputFailure::InvalidSignature {
            function: function.reference.clone(),
            reason: reason.to_owned(),
        };
        if !functions.insert(&function.reference) {
            return Err(fail("duplicate function revision"));
        }
        if function.reference.identity.is_empty()
            || function.reference.revision.is_empty()
            || function.reference.content_digest.is_empty()
            || function.assumption_ref.is_empty()
        {
            return Err(fail(
                "function provenance or signature assumption is absent",
            ));
        }
        if function.outcomes.is_empty() {
            return Err(fail("no declared outcome"));
        }
        unique_ids(
            "input port",
            function.inputs.iter().map(|port| port.id.0.as_str()),
        )?;
        unique_ids(
            "outcome",
            function
                .outcomes
                .iter()
                .map(|outcome| outcome.id.0.as_str()),
        )?;
        unique_ids(
            "resource requirement",
            function
                .resource_inputs
                .iter()
                .map(|requirement| requirement.id.0.as_str()),
        )?;
        match &function.form {
            FunctionForm::Pure | FunctionForm::DeclaredTransform
                if function.effect != CompositionEffect::PureFunction =>
            {
                return Err(fail("pure/transform declaration has a non-pure effect"))
            }
            FunctionForm::Operation(reference) => {
                check_operation_signature(graph, function, reference)?
            }
            _ => {}
        }
        for port in &function.inputs {
            check_type(graph, &port.contract.type_ref)?;
            if port.resource_requirement.as_ref().is_some_and(|id| {
                !function
                    .resource_inputs
                    .iter()
                    .any(|requirement| requirement.id == *id)
            }) {
                return Err(fail("input port names an absent resource requirement"));
            }
        }
        for requirement in &function.resource_inputs {
            check_type(graph, &requirement.token_type)?;
            if requirement.multiplicity.is_zero() {
                return Err(fail("resource multiplicity is zero"));
            }
        }
        for outcome in &function.outcomes {
            unique_ids(
                "output port",
                outcome.value_ports.iter().map(|port| port.id.0.as_str()),
            )?;
            unique_ids(
                "resource production",
                outcome
                    .produced_resources
                    .iter()
                    .map(|production| production.id.0.as_str()),
            )?;
            for port in &outcome.value_ports {
                check_type(graph, &port.contract.type_ref)?;
                if port.resource_production.as_ref().is_some_and(|id| {
                    !outcome
                        .produced_resources
                        .iter()
                        .any(|production| production.id == *id)
                }) {
                    return Err(fail("output resource backing is unresolved"));
                }
            }
            for production in &outcome.produced_resources {
                check_type(graph, &production.token_type)?;
            }
        }
    }
    for site in &input.invocation_domain.sites {
        let function = signature(&input, &site.function)
            .ok_or_else(|| CompositionInputFailure::UnresolvedFunction(site.function.clone()))?;
        if !input.allowed_effects.contains(&function.effect) {
            return Err(CompositionInputFailure::InvalidInvocationDomain(format!(
                "effect not allowed at {:?}",
                site.id
            )));
        }
        if function.form == FunctionForm::DeclaredTransform
            && !input
                .invocation_domain
                .permitted_transforms
                .contains(&function.reference)
        {
            return Err(CompositionInputFailure::InvalidInvocationDomain(format!(
                "transform not permitted at {:?}",
                site.id
            )));
        }
    }
    let mut initial_obligations = Vec::new();
    for initial in &input.initial_inputs {
        check_type(graph, &initial.contract.type_ref)?;
        if let InitialSource::SuppliedValue(value) = &initial.source {
            match validation::accepts_slot(graph, &initial.contract, borrowed_slot(value)) {
                ValueDecision::Rejected(failure) => {
                    return Err(CompositionInputFailure::InvalidInitialValue {
                        input: initial.id.clone(),
                        failure,
                    })
                }
                ValueDecision::Unresolved(reasons) => initial_obligations.extend(reasons),
                ValueDecision::Accepted => {}
            }
        }
        if initial
            .resource
            .as_ref()
            .is_some_and(|id| !input.initial_resources.iter().any(|lot| lot.id == *id))
        {
            return Err(CompositionInputFailure::InvalidResourceDeclaration(
                format!("initial backing lot unresolved at {:?}", initial.id),
            ));
        }
    }
    for lot in &input.initial_resources {
        check_type(graph, &lot.token_type)?;
        if !matches!(&lot.producer, ResourceProducer::Initial { identity, revision } if !identity.is_empty() && !revision.is_empty())
            || lot.provenance.is_empty()
        {
            return Err(CompositionInputFailure::InvalidResourceDeclaration(
                format!("initial producer/provenance invalid at {:?}", lot.id),
            ));
        }
    }
    if input.goal.outputs.is_empty() {
        return Err(CompositionInputFailure::InvalidInvocationDomain(
            "goal has no output ports".to_owned(),
        ));
    }
    for goal in &input.goal.outputs {
        check_type(graph, &goal.contract.type_ref)?;
        check_source_constraint(graph, &input, &goal.source_constraint)?;
    }
    for function in &input.signatures {
        for port in &function.inputs {
            check_source_constraint(graph, &input, &port.source_constraint)?;
        }
    }
    for embedding in &input.goal.failures {
        check_type(graph, &embedding.contract.type_ref)?;
        check_failure_origin(&input, &embedding.origin)?;
    }
    for function in &input.signatures {
        if let Some(origin) = &function.handles_failure {
            check_failure_origin(&input, origin)?;
        }
    }
    for projection in &input.invocation_domain.permitted_projections {
        check_type(graph, &projection.source_type)?;
    }
    unique_ids(
        "construction",
        input
            .invocation_domain
            .permitted_constructions
            .iter()
            .map(|rule| rule.identity.as_str()),
    )?;
    for construction in &input.invocation_domain.permitted_constructions {
        check_type(graph, &construction.type_ref)?;
        let Some(TypeShape::Product(product)) = resolved_shape(graph, &construction.type_ref)
        else {
            return Err(CompositionInputFailure::InvalidInvocationDomain(
                "construction must name a resolved product".to_owned(),
            ));
        };
        unique_ids(
            "nested construction field",
            construction
                .nested_fields
                .iter()
                .map(|(field, _)| field.as_str()),
        )?;
        unique_ids(
            "constrained construction field",
            construction
                .field_constraints
                .iter()
                .map(|constraint| constraint.field.as_str()),
        )?;
        for constraint in &construction.field_constraints {
            if !product
                .fields
                .iter()
                .any(|candidate| candidate.wire_name == constraint.field)
            {
                return Err(CompositionInputFailure::InvalidInvocationDomain(
                    "constrained construction field unresolved".to_owned(),
                ));
            }
            if construction
                .nested_fields
                .iter()
                .any(|(nested, _)| nested == &constraint.field)
            {
                return Err(CompositionInputFailure::InvalidInvocationDomain(
                    "construction field has both nested rule and source constraint".to_owned(),
                ));
            }
            check_source_constraint(graph, &input, &constraint.source)?;
        }
        for (field, nested) in &construction.nested_fields {
            let Some(field) = product
                .fields
                .iter()
                .find(|candidate| candidate.wire_name == *field)
            else {
                return Err(CompositionInputFailure::InvalidInvocationDomain(
                    "nested construction field unresolved".to_owned(),
                ));
            };
            if !input
                .invocation_domain
                .permitted_constructions
                .iter()
                .any(|rule| &rule.identity == nested && rule.type_ref == field.slot.type_ref)
            {
                return Err(CompositionInputFailure::InvalidInvocationDomain(
                    "nested construction rule/type unresolved".to_owned(),
                ));
            }
        }
        let mut pending = vec![construction.identity.as_str()];
        let mut seen = HashSet::new();
        while let Some(identity) = pending.pop() {
            if !seen.insert(identity) {
                continue;
            }
            let Some(rule) = input
                .invocation_domain
                .permitted_constructions
                .iter()
                .find(|rule| rule.identity == identity)
            else {
                return Err(CompositionInputFailure::InvalidInvocationDomain(
                    "nested construction rule unresolved".to_owned(),
                ));
            };
            for (_, child) in &rule.nested_fields {
                if child == &construction.identity {
                    return Err(CompositionInputFailure::InvalidInvocationDomain(
                        "construction rules must form a finite acyclic expansion".to_owned(),
                    ));
                }
                pending.push(child);
            }
        }
    }
    for guard in &input.invocation_domain.guards {
        check_type(graph, &guard.source_type)?;
        if let GuardKind::Validate(contract) = &guard.kind {
            check_type(graph, &contract.type_ref)?;
        }
    }
    for (before, after) in &input.explicit_order {
        if before == after
            || site_signature(&input, before).is_none()
            || site_signature(&input, after).is_none()
        {
            return Err(CompositionInputFailure::InvalidInvocationDomain(
                "invalid explicit site order".to_owned(),
            ));
        }
    }
    for goal in input.goal.final_resources.iter().chain(
        input
            .goal
            .failures
            .iter()
            .flat_map(|embedding| &embedding.final_resources),
    ) {
        if declared_lot(&input, &goal.lot).is_none() {
            return Err(CompositionInputFailure::InvalidResourceDeclaration(
                format!("goal lot unresolved: {:?}", goal.lot),
            ));
        }
    }
    let empty = empty_types(graph);
    Ok(PreparedCompositionInput {
        graph,
        input,
        empty,
        initial_obligations,
    })
}
fn check_failure_origin(
    input: &CompositionInput,
    origin: &FailureOrigin,
) -> Result<(), CompositionInputFailure> {
    let valid = match origin {
        FailureOrigin::Function { function, outcome } => {
            signature(input, function).is_some_and(|signature| {
                signature.outcomes.iter().any(|candidate| {
                    candidate.id == *outcome && candidate.form == OutcomeForm::DeclaredFailure
                })
            })
        }
        FailureOrigin::Guard { guard, .. } => input
            .invocation_domain
            .guards
            .iter()
            .any(|candidate| candidate.id == *guard),
    };
    if valid {
        Ok(())
    } else {
        Err(CompositionInputFailure::InvalidInvocationDomain(format!(
            "failure origin unresolved: {:?}",
            origin
        )))
    }
}
#[derive(Debug, Clone, PartialEq, Eq)]
struct LotDeclaration {
    token_type: TypeRef,
    producer: ResourceProducer,
    revision: Nat,
    quantity: Nat,
    provenance: String,
}
fn declared_lot(input: &CompositionInput, reference: &ResourceLotRef) -> Option<LotDeclaration> {
    match reference {
        ResourceLotRef::Initial(id) => input
            .initial_resources
            .iter()
            .find(|lot| lot.id == *id)
            .map(|lot| LotDeclaration {
                token_type: lot.token_type.clone(),
                producer: lot.producer.clone(),
                revision: lot.revision.clone(),
                quantity: lot.quantity.clone(),
                provenance: lot.provenance.clone(),
            }),
        ResourceLotRef::Produced {
            site,
            outcome,
            production,
        } => {
            let production = site_signature(input, site)?
                .outcomes
                .iter()
                .find(|candidate| candidate.id == *outcome)?
                .produced_resources
                .iter()
                .find(|candidate| candidate.id == *production)?;
            Some(LotDeclaration {
                token_type: production.token_type.clone(),
                producer: ResourceProducer::InvocationOutcome {
                    site: site.clone(),
                    outcome: outcome.clone(),
                },
                revision: production.revision.clone(),
                quantity: production.quantity.clone(),
                provenance: production.provenance.clone(),
            })
        }
    }
}

#[derive(Debug, Clone, PartialEq)]
pub enum BindingCompatibility {
    Inclusion(Arc<InclusionCertificate>),
    SuppliedValue { value: SlotValue },
}
#[derive(Debug, Clone, PartialEq)]
pub enum BindingExpr {
    Source {
        value: ValueRef,
        projection: ProjectionCertificate,
        compatibility: BindingCompatibility,
    },
    Product {
        construction: String,
        type_ref: TypeRef,
        fields: Vec<(String, BindingExpr)>,
    },
}
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ResourceBinding {
    pub requirement: RequirementId,
    pub lot: ResourceLotRef,
    pub inclusion: Arc<InclusionCertificate>,
}
#[derive(Debug, Clone, PartialEq)]
pub struct InvocationPlan {
    pub site: SiteId,
    pub function: FunctionRef,
    pub bindings: Vec<(PortId, BindingExpr)>,
    pub resources: Vec<ResourceBinding>,
}
#[derive(Debug, Clone, PartialEq)]
pub enum ReturnPlan {
    Success(Vec<(GoalPortId, BindingExpr)>),
    Failure {
        embedding: FailureEmbeddingId,
        value: BindingExpr,
    },
}
#[derive(Debug, Clone, PartialEq)]
pub struct PlanTree {
    pub rank: usize,
    pub node: PlanNode,
}
#[derive(Debug, Clone, PartialEq)]
pub enum PlanNode {
    Invoke {
        invocation: InvocationPlan,
        arms: Vec<(OutcomeId, PlanTree)>,
        empty_outcomes: Vec<OutcomeId>,
    },
    Guard {
        guard: GuardId,
        inspected: ValueRef,
        arms: Vec<(GuardArm, PlanTree)>,
    },
    Return(ReturnPlan),
}
#[derive(Debug, Clone, PartialEq)]
pub struct CompositionPlan {
    pub input_identity: String,
    pub input_revision: String,
    pub root: PlanTree,
}
#[derive(Debug, Clone, PartialEq)]
pub enum TraceStep {
    Invocation {
        invocation: InvocationPlan,
        outcome: OutcomeId,
    },
    Guard {
        guard: GuardId,
        inspected: ValueRef,
        arm: GuardArm,
    },
}
#[derive(Debug, Clone, PartialEq)]
pub struct BranchTrace {
    pub steps: Vec<TraceStep>,
    pub terminal: ReturnPlan,
}
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ResourceLotCorrespondence {
    pub lot: ResourceLotRef,
    pub place: String,
    pub producer: ResourceProducer,
    pub token_target: String,
    pub token_type: String,
    pub revision: Nat,
    pub quantity: Nat,
    pub provenance: String,
}
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ValueCorrespondence {
    pub producer: ProducerRef,
    pub place: String,
    pub token_target: String,
    pub revision: Nat,
}
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct NormalizedResourceBinding {
    pub transition: String,
    pub lot: ResourceLotRef,
    pub read: Nat,
    pub consume: Nat,
    pub required_revision: Nat,
}
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ResourceCorrespondence {
    pub lots: Vec<ResourceLotCorrespondence>,
    pub values: Vec<ValueCorrespondence>,
    pub normalized_bindings: Vec<NormalizedResourceBinding>,
    pub execution_order: Vec<String>,
}
#[derive(Debug, Clone, PartialEq)]
pub struct ResourceTraceCertificate {
    pub trace: BranchTrace,
    pub lowering: resource::SolverInput,
    pub correspondence: ResourceCorrespondence,
    pub reachability: resource::ReachabilityWitness,
    pub acyclicity: resource::AcyclicWitness,
    pub value_sources: Vec<(ProducerRef, SlotValue)>,
}
#[derive(Debug, Clone, PartialEq)]
pub struct CompositionWitness {
    pub input_snapshot: CompositionInput,
    pub initial_membership: Vec<(InputId, SlotValue)>,
    pub resource_traces: Vec<ResourceTraceCertificate>,
}
#[derive(Debug, Clone, PartialEq)]
pub struct RawComposition {
    pub plan: CompositionPlan,
    pub witness: CompositionWitness,
    pub selection: Arc<SelectionEvidence>,
}
#[derive(Debug)]
pub struct CheckedComposition<'p, 'g> {
    prepared: &'p PreparedCompositionInput<'g>,
    raw: RawComposition,
}
impl<'p, 'g> CheckedComposition<'p, 'g> {
    pub fn prepared(&self) -> &'p PreparedCompositionInput<'g> {
        self.prepared
    }
    pub fn plan(&self) -> &CompositionPlan {
        &self.raw.plan
    }
    pub fn witness(&self) -> &CompositionWitness {
        &self.raw.witness
    }
    pub fn raw(&self) -> &RawComposition {
        &self.raw
    }
}
#[derive(Debug, Clone, PartialEq)]
pub enum WitnessFailure {
    InputRevisionMismatch,
    InitialMembership(InputId),
    ProducerMismatch(ValueRef),
    ProjectionMismatch(ProjectionFailure),
    SourceConstraintMismatch(ValueRef),
    Inclusion(InclusionFailure),
    SuppliedValueMismatch(ValueRef),
    ConstructionMismatch(TypeRef),
    MissingBinding(String),
    SignatureMismatch(SiteId),
    GuardNotDominating(ValueRef),
    IncompleteBranchCoverage(String),
    FailureEmbeddingMismatch(FailureEmbeddingId),
    GoalMismatch,
    RankViolation,
    ResourceLoweringMismatch(String),
    ResourceReplayMismatch(String),
    ForgedClosure(String),
    ForgedAcyclicity(String),
    MissingEvidence(String),
}
#[derive(Debug, Clone, PartialEq)]
pub enum UnresolvedObligation {
    Type {
        value: Option<ValueRef>,
        obligations: Vec<TypeObligation>,
    },
    Meaning(Vec<MeaningFailure>),
    SemanticMeaning(Vec<SemanticObligation>),
    Inhabitation {
        producer: ProducerRef,
        contract: SlotContract,
    },
    BranchInhabitation,
    StateBoundExhausted,
    BindingBoundExhausted,
    BranchBoundExhausted,
    ResourceSolverUnknown(resource::UnknownReason),
    ResourceCapacityBound {
        required: Nat,
        limit: usize,
    },
    UnresolvedUniqueness,
}
#[derive(Debug, Clone, PartialEq)]
pub struct ConnectionFailure {
    pub value: Option<ValueRef>,
    pub destination: SlotContract,
    pub counterexample: CounterexampleCertificate,
}
#[derive(Debug, Clone, PartialEq)]
pub enum CompositionEngineFailure {
    ContractViolation(String),
    Resource(resource::SolverFailure),
    Witness(WitnessFailure),
}
#[derive(Debug, Clone, PartialEq)]
pub enum LoweringFailure {
    Invalid(String),
    Unknown(UnresolvedObligation),
}
#[derive(Debug)]
pub struct CheckedReachability<'a> {
    input: &'a resource::SolverInput,
    witness: &'a resource::ReachabilityWitness,
}
impl CheckedReachability<'_> {
    pub fn input(&self) -> &resource::SolverInput {
        self.input
    }
    pub fn witness(&self) -> &resource::ReachabilityWitness {
        self.witness
    }
}
#[derive(Debug)]
pub struct CheckedClosure<'a> {
    input: &'a resource::SolverInput,
    witness: &'a resource::ClosureWitness,
}
impl CheckedClosure<'_> {
    pub fn input(&self) -> &resource::SolverInput {
        self.input
    }
    pub fn witness(&self) -> &resource::ClosureWitness {
        self.witness
    }
}
#[derive(Debug)]
pub struct CheckedAcyclic<'a> {
    input: &'a resource::SolverInput,
    witness: &'a resource::AcyclicWitness,
}
impl CheckedAcyclic<'_> {
    pub fn input(&self) -> &resource::SolverInput {
        self.input
    }
    pub fn witness(&self) -> &resource::AcyclicWitness {
        self.witness
    }
}

fn resource_neighbors(
    input: &resource::SolverInput,
    marking: &resource::Marking,
) -> Vec<resource::Marking> {
    input
        .transitions
        .iter()
        .filter_map(|transition| {
            let bindings = resource::bindings_for(input, &transition.identity);
            resource::transition_enabled_at(&bindings, marking)
                .then(|| resource::apply_branch_at(marking, transition, &bindings))
        })
        .collect()
}
fn resource_input_valid(input: &resource::SolverInput) -> Result<(), WitnessFailure> {
    if let Some(reason) = resource::validate(input) {
        return Err(WitnessFailure::ResourceReplayMismatch(format!(
            "invalid solver input: {:?}",
            reason
        )));
    }
    if resource::binding_bound_exceeded(input) {
        return Err(WitnessFailure::ResourceReplayMismatch(
            "binding bound exhausted".to_owned(),
        ));
    }
    Ok(())
}
pub fn verify_reachability_witness<'a>(
    input: &'a resource::SolverInput,
    witness: &'a resource::ReachabilityWitness,
) -> Result<CheckedReachability<'a>, WitnessFailure> {
    resource_input_valid(input)?;
    if Nat::from(witness.path.len()) > input.bound.max_search_steps {
        return Err(WitnessFailure::ResourceReplayMismatch(
            "path exceeds bound".to_owned(),
        ));
    }
    let mut marking = input.marking.clone();
    for identity in &witness.path {
        let transition = input
            .transitions
            .iter()
            .find(|transition| transition.identity == *identity)
            .ok_or_else(|| {
                WitnessFailure::ResourceReplayMismatch(format!("unknown transition {}", identity))
            })?;
        let bindings = resource::bindings_for(input, identity);
        if !resource::transition_enabled_at(&bindings, &marking) {
            return Err(WitnessFailure::ResourceReplayMismatch(format!(
                "disabled transition {}",
                identity
            )));
        }
        marking = resource::apply_branch_at(&marking, transition, &bindings);
    }
    if marking != witness.final_marking || !resource::eval_goal(&marking, &input.goal) {
        return Err(WitnessFailure::ResourceReplayMismatch(
            "final marking or resource goal differs".to_owned(),
        ));
    }
    Ok(CheckedReachability { input, witness })
}
fn verify_finite_closure(
    input: &resource::SolverInput,
    markings: &[resource::Marking],
    steps: &Nat,
    frontier: &[resource::Marking],
) -> Result<Vec<Vec<usize>>, WitnessFailure> {
    resource_input_valid(input)?;
    if !frontier.is_empty()
        || *steps != Nat::from(markings.len())
        || steps > &input.bound.max_search_steps
        || !markings.contains(&input.marking)
    {
        return Err(WitnessFailure::ForgedClosure(
            "initial marking, frontier, steps or bound".to_owned(),
        ));
    }
    let mut edges = Vec::with_capacity(markings.len());
    for (index, marking) in markings.iter().enumerate() {
        if markings
            .iter()
            .take(index)
            .any(|earlier| earlier == marking)
        {
            return Err(WitnessFailure::ForgedClosure(
                "duplicate marking".to_owned(),
            ));
        }
        let mut successors = Vec::new();
        for successor in resource_neighbors(input, marking) {
            let Some(index) = markings.iter().position(|marking| marking == &successor) else {
                return Err(WitnessFailure::ForgedClosure(
                    "enabled successor is omitted".to_owned(),
                ));
            };
            if !successors.contains(&index) {
                successors.push(index);
            }
        }
        edges.push(successors);
    }
    let root = markings
        .iter()
        .position(|marking| marking == &input.marking)
        .ok_or_else(|| WitnessFailure::ForgedClosure("initial marking omitted".to_owned()))?;
    let mut reached = HashSet::new();
    let mut pending = vec![root];
    while let Some(index) = pending.pop() {
        if reached.insert(index) {
            pending.extend(edges.get(index).into_iter().flatten());
        }
    }
    if reached.len() != markings.len() {
        return Err(WitnessFailure::ForgedClosure(
            "unreachable marking injected".to_owned(),
        ));
    }
    Ok(edges)
}
pub fn verify_closure_witness<'a>(
    input: &'a resource::SolverInput,
    witness: &'a resource::ClosureWitness,
) -> Result<CheckedClosure<'a>, WitnessFailure> {
    verify_finite_closure(
        input,
        &witness.explored_markings,
        &witness.steps,
        &witness.frontier,
    )?;
    if witness
        .explored_markings
        .iter()
        .any(|marking| resource::eval_goal(marking, &input.goal))
    {
        return Err(WitnessFailure::ForgedClosure(
            "closure contains a resource goal".to_owned(),
        ));
    }
    Ok(CheckedClosure { input, witness })
}
pub fn verify_acyclic_witness<'a>(
    input: &'a resource::SolverInput,
    witness: &'a resource::AcyclicWitness,
) -> Result<CheckedAcyclic<'a>, WitnessFailure> {
    let edges = verify_finite_closure(
        input,
        &witness.explored_markings,
        &witness.steps,
        &witness.frontier,
    )?;
    let mut indegrees = vec![0usize; edges.len()];
    for successors in &edges {
        for index in successors {
            if let Some(degree) = indegrees.get_mut(*index) {
                *degree += 1;
            }
        }
    }
    let mut pending: Vec<_> = indegrees
        .iter()
        .enumerate()
        .filter_map(|(index, degree)| (*degree == 0).then_some(index))
        .collect();
    let mut removed = 0usize;
    while let Some(index) = pending.pop() {
        removed += 1;
        for successor in edges.get(index).into_iter().flatten() {
            if let Some(degree) = indegrees.get_mut(*successor) {
                *degree -= 1;
                if *degree == 0 {
                    pending.push(*successor);
                }
            }
        }
    }
    if removed != edges.len() {
        return Err(WitnessFailure::ForgedAcyclicity(
            "closed marking graph contains a cycle".to_owned(),
        ));
    }
    Ok(CheckedAcyclic { input, witness })
}

fn encode_tuple(parts: &[&str]) -> String {
    let mut result = String::new();
    for part in parts {
        result.push_str(&part.len().to_string());
        result.push(':');
        result.push_str(part);
    }
    result
}
pub(crate) fn type_identity(reference: &TypeRef) -> String {
    let declared = reference
        .source
        .declared_revision
        .as_ref()
        .map(ToString::to_string)
        .unwrap_or_default();
    let has_revision = if reference.source.declared_revision.is_some() {
        "some"
    } else {
        "none"
    };
    let pointer: Vec<_> = reference.pointer.iter().map(String::as_str).collect();
    let pointer = encode_tuple(&pointer);
    encode_tuple(&[
        "type",
        &reference.source.repository,
        &reference.source.revision,
        &reference.source.path,
        &reference.source.content_digest,
        &reference.source.document_id,
        has_revision,
        &declared,
        &reference.definition_name,
        &pointer,
    ])
}
fn function_identity(reference: &FunctionRef) -> String {
    encode_tuple(&[
        &reference.identity,
        &reference.revision,
        &reference.content_digest,
    ])
}
fn producer_identity(producer: &ProducerRef) -> String {
    match producer {
        ProducerRef::Initial(id) => encode_tuple(&["initial-value", &id.0]),
        ProducerRef::InvocationOutcome {
            site,
            outcome,
            port,
        } => encode_tuple(&["outcome-value", &site.0, &outcome.0, &port.0]),
    }
}
fn lot_identity(lot: &ResourceLotRef) -> String {
    match lot {
        ResourceLotRef::Initial(id) => encode_tuple(&["initial-lot", &id.0]),
        ResourceLotRef::Produced {
            site,
            outcome,
            production,
        } => encode_tuple(&["produced-lot", &site.0, &outcome.0, &production.0]),
    }
}
fn invocation_identity(invocation: &InvocationPlan, outcome: &OutcomeId) -> String {
    encode_tuple(&[
        "invocation",
        &invocation.site.0,
        &function_identity(&invocation.function),
        &outcome.0,
    ])
}
fn production_identity(site: &SiteId, outcome: &OutcomeId, production: &ProductionId) -> String {
    encode_tuple(&["resource-production", &site.0, &outcome.0, &production.0])
}
fn declared_value(
    input: &CompositionInput,
    producer: &ProducerRef,
) -> Option<(SlotContract, Option<ResourceLotRef>)> {
    match producer {
        ProducerRef::Initial(id) => input
            .initial_inputs
            .iter()
            .find(|initial| initial.id == *id)
            .map(|initial| {
                (
                    initial.contract.clone(),
                    initial.resource.clone().map(ResourceLotRef::Initial),
                )
            }),
        ProducerRef::InvocationOutcome {
            site,
            outcome,
            port,
        } => {
            let output = site_signature(input, site)?
                .outcomes
                .iter()
                .find(|candidate| candidate.id == *outcome)?
                .value_ports
                .iter()
                .find(|candidate| candidate.id == *port)?;
            Some((
                output.contract.clone(),
                output
                    .resource_production
                    .clone()
                    .map(|production| ResourceLotRef::Produced {
                        site: site.clone(),
                        outcome: outcome.clone(),
                        production,
                    }),
            ))
        }
    }
}
fn binding_sources<'a>(binding: &'a BindingExpr, result: &mut Vec<&'a ValueRef>) {
    match binding {
        BindingExpr::Source { value, .. } => result.push(value),
        BindingExpr::Product { fields, .. } => {
            for (_, binding) in fields {
                binding_sources(binding, result);
            }
        }
    }
}
struct LoweredPhase {
    identity: String,
    revision: Nat,
    value_reads: Vec<ProducerRef>,
    reads: Vec<(ResourceLotRef, Nat)>,
    consumes: Vec<(ResourceLotRef, Nat)>,
    outputs: Vec<String>,
}
fn add_requirement(
    requirements: &mut Vec<(ResourceLotRef, Nat)>,
    lot: ResourceLotRef,
    count: Nat,
    consume: bool,
) {
    if let Some((_, previous)) = requirements
        .iter_mut()
        .find(|(reference, _)| *reference == lot)
    {
        if consume {
            *previous += count;
        } else if *previous < count {
            *previous = count;
        }
    } else {
        requirements.push((lot, count));
    }
}

pub fn lower_resource_trace(
    prepared: &PreparedCompositionInput<'_>,
    trace: &BranchTrace,
) -> Result<(resource::SolverInput, ResourceCorrespondence), LoweringFailure> {
    let input = prepared.input();
    let invalid = |reason: String| LoweringFailure::Invalid(reason);
    let mut lots = Vec::new();
    let mut values = Vec::new();
    let mut marking = resource::Marking { places: Vec::new() };
    let mut places = Vec::new();
    let mut phases = Vec::new();
    let mut available = HashSet::new();
    let mut used_sites = HashSet::new();
    let mut used_guards = HashSet::new();
    for lot in &input.initial_resources {
        let reference = ResourceLotRef::Initial(lot.id.clone());
        let place = lot_identity(&reference);
        let target = match &lot.producer {
            ResourceProducer::Initial { identity, revision } => {
                encode_tuple(&["initial-resource", identity, revision, &lot.id.0])
            }
            _ => return Err(invalid("initial lot has a produced identity".to_owned())),
        };
        let quantity = lot.quantity.to_usize().ok_or_else(|| {
            LoweringFailure::Unknown(UnresolvedObligation::ResourceCapacityBound {
                required: lot.quantity.clone(),
                limit: usize::MAX,
            })
        })?;
        let cap = input
            .bounds
            .resource_bounds
            .as_ref()
            .map(|bound| bound.max_tokens)
            .unwrap_or(DEFAULT_RESOURCE_TOKEN_BOUND);
        if quantity > cap {
            return Err(LoweringFailure::Unknown(
                UnresolvedObligation::ResourceCapacityBound {
                    required: lot.quantity.clone(),
                    limit: cap,
                },
            ));
        }
        let token_type = type_identity(&lot.token_type);
        places.push(resource::TypedPlace {
            identity: place.clone(),
            token_type: token_type.clone(),
            revision: lot.revision.clone(),
        });
        marking.places.push((
            place.clone(),
            vec![
                resource::ColoredToken {
                    target: target.clone(),
                    index: Nat::zero(),
                    revision: lot.revision.clone(),
                    kind: resource::TokenKind::Input
                };
                quantity
            ],
        ));
        lots.push(ResourceLotCorrespondence {
            lot: reference,
            place,
            producer: lot.producer.clone(),
            token_target: target,
            token_type,
            revision: lot.revision.clone(),
            quantity: lot.quantity.clone(),
            provenance: lot.provenance.clone(),
        });
    }
    for initial in &input.initial_inputs {
        let producer = ProducerRef::Initial(initial.id.clone());
        let place = producer_identity(&producer);
        let target = place.clone();
        places.push(resource::TypedPlace {
            identity: place.clone(),
            token_type: type_identity(&initial.contract.type_ref),
            revision: Nat::zero(),
        });
        marking.places.push((
            place.clone(),
            vec![resource::ColoredToken {
                target: target.clone(),
                index: Nat::zero(),
                revision: Nat::zero(),
                kind: resource::TokenKind::Input,
            }],
        ));
        available.insert(producer.clone());
        values.push(ValueCorrespondence {
            producer,
            place,
            token_target: target,
            revision: Nat::zero(),
        });
    }
    for step in &trace.steps {
        match step {
            TraceStep::Guard {
                guard, inspected, ..
            } => {
                if !used_guards.insert(guard.clone())
                    || !input
                        .invocation_domain
                        .guards
                        .iter()
                        .any(|declaration| declaration.id == *guard)
                    || !available.contains(&inspected.producer)
                {
                    return Err(invalid(
                        "guard declaration/producer is unavailable".to_owned(),
                    ));
                }
                phases.push(LoweredPhase {
                    identity: encode_tuple(&[
                        "guard",
                        &guard.0,
                        &producer_identity(&inspected.producer),
                    ]),
                    revision: Nat::zero(),
                    value_reads: vec![inspected.producer.clone()],
                    reads: Vec::new(),
                    consumes: Vec::new(),
                    outputs: Vec::new(),
                });
            }
            TraceStep::Invocation {
                invocation,
                outcome,
            } => {
                if !used_sites.insert(invocation.site.clone()) {
                    return Err(invalid("site fired twice on one branch".to_owned()));
                }
                let function = site_signature(input, &invocation.site)
                    .ok_or_else(|| invalid("unresolved site".to_owned()))?;
                if function.reference != invocation.function {
                    return Err(invalid("function revision differs at site".to_owned()));
                }
                let outcome_contract = function
                    .outcomes
                    .iter()
                    .find(|candidate| candidate.id == *outcome)
                    .ok_or_else(|| invalid("unresolved outcome".to_owned()))?;
                if invocation.bindings.len() != function.inputs.len()
                    || invocation.resources.len() != function.resource_inputs.len()
                {
                    return Err(invalid(
                        "binding coverage differs from signature".to_owned(),
                    ));
                }
                let mut reads = Vec::new();
                let mut consumes = Vec::new();
                let mut value_reads = Vec::new();
                for port in &function.inputs {
                    let bindings: Vec<_> = invocation
                        .bindings
                        .iter()
                        .filter(|(id, _)| *id == port.id)
                        .collect();
                    let [(_, binding)] = bindings.as_slice() else {
                        return Err(invalid("input binding missing or duplicated".to_owned()));
                    };
                    let mut sources = Vec::new();
                    binding_sources(binding, &mut sources);
                    for source in &sources {
                        if !available.contains(&source.producer) {
                            return Err(invalid(
                                "value producer is not earlier on this branch".to_owned(),
                            ));
                        }
                        if !value_reads.contains(&source.producer) {
                            value_reads.push(source.producer.clone());
                        }
                        if let Some((_, Some(lot))) = declared_value(input, &source.producer) {
                            add_requirement(&mut reads, lot, Nat::one(), false);
                        }
                    }
                    if let Some(requirement) = &port.resource_requirement {
                        let resource_binding = invocation
                            .resources
                            .iter()
                            .find(|binding| binding.requirement == *requirement)
                            .ok_or_else(|| {
                                invalid("backing resource binding missing".to_owned())
                            })?;
                        let backed = matches!(
                            sources.as_slice(),
                            [source] if declared_value(input, &source.producer)
                                .and_then(|(_, lot)| lot)
                                .as_ref()
                                == Some(&resource_binding.lot)
                        );
                        if !backed {
                            return Err(invalid(
                                "port backing differs from selected resource lot".to_owned(),
                            ));
                        }
                    }
                }
                for requirement in &function.resource_inputs {
                    let bindings: Vec<_> = invocation
                        .resources
                        .iter()
                        .filter(|binding| binding.requirement == requirement.id)
                        .collect();
                    let [binding] = bindings.as_slice() else {
                        return Err(invalid("resource binding missing or duplicated".to_owned()));
                    };
                    let binding = *binding;
                    let lot = lots
                        .iter()
                        .find(|lot| lot.lot == binding.lot)
                        .ok_or_else(|| invalid("resource producer unavailable".to_owned()))?;
                    let declaration = declared_lot(input, &binding.lot)
                        .ok_or_else(|| invalid("unresolved resource lot".to_owned()))?;
                    if declaration.revision != requirement.required_revision
                        || !matches!(&requirement.identity, ResourceIdentityConstraint::Any)
                            && requirement.identity
                                != ResourceIdentityConstraint::Exactly(declaration.producer.clone())
                    {
                        return Err(invalid(
                            "resource identity or required revision differs".to_owned(),
                        ));
                    }
                    verify_inclusion(
                        prepared.graph(),
                        &present_contract(declaration.token_type),
                        &present_contract(requirement.token_type.clone()),
                        &binding.inclusion,
                    )
                    .map_err(|failure| invalid(format!("resource type proof: {:?}", failure)))?;
                    match requirement.mode {
                        resource::BindingMode::Read => add_requirement(
                            &mut reads,
                            lot.lot.clone(),
                            requirement.multiplicity.clone(),
                            false,
                        ),
                        resource::BindingMode::Consume => add_requirement(
                            &mut consumes,
                            lot.lot.clone(),
                            requirement.multiplicity.clone(),
                            true,
                        ),
                    }
                }
                let identity = invocation_identity(invocation, outcome);
                let mut outputs = Vec::new();
                for port in &outcome_contract.value_ports {
                    let producer = ProducerRef::InvocationOutcome {
                        site: invocation.site.clone(),
                        outcome: outcome.clone(),
                        port: port.id.clone(),
                    };
                    let place = producer_identity(&producer);
                    places.push(resource::TypedPlace {
                        identity: place.clone(),
                        token_type: type_identity(&port.contract.type_ref),
                        revision: Nat::zero(),
                    });
                    values.push(ValueCorrespondence {
                        producer: producer.clone(),
                        place: place.clone(),
                        token_target: identity.clone(),
                        revision: Nat::zero(),
                    });
                    available.insert(producer);
                    outputs.push(place);
                }
                phases.push(LoweredPhase {
                    identity,
                    revision: Nat::zero(),
                    value_reads,
                    reads,
                    consumes,
                    outputs,
                });
                for production in &outcome_contract.produced_resources {
                    let reference = ResourceLotRef::Produced {
                        site: invocation.site.clone(),
                        outcome: outcome.clone(),
                        production: production.id.clone(),
                    };
                    let place = lot_identity(&reference);
                    let target = production_identity(&invocation.site, outcome, &production.id);
                    let token_type = type_identity(&production.token_type);
                    let quantity = production.quantity.to_usize().ok_or_else(|| {
                        LoweringFailure::Unknown(UnresolvedObligation::ResourceCapacityBound {
                            required: production.quantity.clone(),
                            limit: usize::MAX,
                        })
                    })?;
                    let cap = input
                        .bounds
                        .resource_bounds
                        .as_ref()
                        .map(|bound| bound.max_tokens)
                        .unwrap_or(DEFAULT_RESOURCE_TOKEN_BOUND);
                    if quantity > cap {
                        return Err(LoweringFailure::Unknown(
                            UnresolvedObligation::ResourceCapacityBound {
                                required: production.quantity.clone(),
                                limit: cap,
                            },
                        ));
                    }
                    places.push(resource::TypedPlace {
                        identity: place.clone(),
                        token_type: token_type.clone(),
                        revision: production.revision.clone(),
                    });
                    lots.push(ResourceLotCorrespondence {
                        lot: reference,
                        place: place.clone(),
                        producer: ResourceProducer::InvocationOutcome {
                            site: invocation.site.clone(),
                            outcome: outcome.clone(),
                        },
                        token_target: target.clone(),
                        token_type,
                        revision: production.revision.clone(),
                        quantity: production.quantity.clone(),
                        provenance: production.provenance.clone(),
                    });
                    phases.push(LoweredPhase {
                        identity: target,
                        revision: production.revision.clone(),
                        value_reads: Vec::new(),
                        reads: Vec::new(),
                        consumes: Vec::new(),
                        outputs: vec![place; quantity],
                    });
                }
            }
        }
    }
    let root_control = encode_tuple(&["control", "0"]);
    places.push(resource::TypedPlace {
        identity: root_control.clone(),
        token_type: "control".to_owned(),
        revision: Nat::zero(),
    });
    marking.places.push((
        root_control.clone(),
        vec![resource::ColoredToken {
            target: "control-root".to_owned(),
            index: Nat::zero(),
            revision: Nat::zero(),
            kind: resource::TokenKind::Input,
        }],
    ));
    let mut previous_control = root_control;
    let mut previous_target = "control-root".to_owned();
    let mut previous_revision = Nat::zero();
    let mut transitions = Vec::new();
    let mut bindings = Vec::new();
    let mut normalized_bindings = Vec::new();
    let mut execution_order = Vec::new();
    let mut maximum_tokens = Nat::from(
        marking
            .places
            .iter()
            .map(|(_, tokens)| tokens.len())
            .sum::<usize>(),
    );
    for (index, phase) in phases.into_iter().enumerate() {
        let permit = encode_tuple(&["permit", &phase.identity]);
        places.push(resource::TypedPlace {
            identity: permit.clone(),
            token_type: "control".to_owned(),
            revision: Nat::zero(),
        });
        marking.places.push((
            permit.clone(),
            vec![resource::ColoredToken {
                target: permit.clone(),
                index: Nat::zero(),
                revision: Nat::zero(),
                kind: resource::TokenKind::Input,
            }],
        ));
        let next_control = encode_tuple(&["control", &(index + 1).to_string()]);
        places.push(resource::TypedPlace {
            identity: next_control.clone(),
            token_type: "control".to_owned(),
            revision: phase.revision.clone(),
        });
        let mut input_places = vec![previous_control.clone(), permit.clone()];
        let mut transition_bindings = vec![
            resource::InputBinding {
                transition_id: phase.identity.clone(),
                name: "order".to_owned(),
                place: previous_control.clone(),
                token_type: "control".to_owned(),
                identity: previous_target.clone(),
                provenance: "selected branch order".to_owned(),
                multiplicity: Nat::one(),
                mode: resource::BindingMode::Consume,
                required_revision: previous_revision.clone(),
            },
            resource::InputBinding {
                transition_id: phase.identity.clone(),
                name: "permit".to_owned(),
                place: permit.clone(),
                token_type: "control".to_owned(),
                identity: permit,
                provenance: "finite site permit".to_owned(),
                multiplicity: Nat::one(),
                mode: resource::BindingMode::Consume,
                required_revision: Nat::zero(),
            },
        ];
        for producer in &phase.value_reads {
            let value = values
                .iter()
                .find(|value| &value.producer == producer)
                .ok_or_else(|| invalid("input value correspondence unavailable".to_owned()))?;
            let declaration = declared_value(input, producer)
                .ok_or_else(|| invalid("input value declaration unavailable".to_owned()))?;
            input_places.push(value.place.clone());
            transition_bindings.push(resource::InputBinding {
                transition_id: phase.identity.clone(),
                name: encode_tuple(&["value-read", &value.place]),
                place: value.place.clone(),
                token_type: type_identity(&declaration.0.type_ref),
                identity: value.token_target.clone(),
                provenance: producer_identity(producer),
                multiplicity: Nat::one(),
                mode: resource::BindingMode::Read,
                required_revision: value.revision.clone(),
            });
        }
        let lot_refs: Vec<_> = phase
            .reads
            .iter()
            .chain(&phase.consumes)
            .map(|(lot, _)| lot)
            .collect();
        let mut seen = HashSet::new();
        for reference in lot_refs {
            if !seen.insert(reference) {
                continue;
            }
            let lot = lots
                .iter()
                .find(|lot| &lot.lot == reference)
                .ok_or_else(|| invalid("normalization names an unavailable lot".to_owned()))?;
            let read = phase
                .reads
                .iter()
                .find(|(lot, _)| lot == reference)
                .map(|(_, count)| count.clone())
                .unwrap_or_else(Nat::zero);
            let consume = phase
                .consumes
                .iter()
                .find(|(lot, _)| lot == reference)
                .map(|(_, count)| count.clone())
                .unwrap_or_else(Nat::zero);
            input_places.push(lot.place.clone());
            for (mode_name, mode, count) in [
                ("read", resource::BindingMode::Read, &read),
                ("consume", resource::BindingMode::Consume, &consume),
            ] {
                if count.is_zero() {
                    continue;
                }
                transition_bindings.push(resource::InputBinding {
                    transition_id: phase.identity.clone(),
                    name: encode_tuple(&[mode_name, &lot.place]),
                    place: lot.place.clone(),
                    token_type: lot.token_type.clone(),
                    identity: lot.token_target.clone(),
                    provenance: lot.provenance.clone(),
                    multiplicity: count.clone(),
                    mode,
                    required_revision: lot.revision.clone(),
                });
            }
            normalized_bindings.push(NormalizedResourceBinding {
                transition: phase.identity.clone(),
                lot: reference.clone(),
                read,
                consume,
                required_revision: lot.revision.clone(),
            });
        }
        let mut output_places = phase.outputs;
        output_places.push(next_control.clone());
        maximum_tokens += Nat::from(output_places.len() + 1);
        transitions.push(resource::TypedTransition {
            identity: phase.identity.clone(),
            input_places,
            output_places,
            failure_places: Vec::new(),
            revision: phase.revision.clone(),
        });
        bindings.extend(transition_bindings);
        execution_order.push(phase.identity.clone());
        previous_control = next_control;
        previous_target = phase.identity;
        previous_revision = phase.revision;
    }
    let cap = input
        .bounds
        .resource_bounds
        .as_ref()
        .map(|bound| bound.max_tokens)
        .unwrap_or(DEFAULT_RESOURCE_TOKEN_BOUND);
    if maximum_tokens > Nat::from(cap) {
        return Err(LoweringFailure::Unknown(
            UnresolvedObligation::ResourceCapacityBound {
                required: maximum_tokens,
                limit: cap,
            },
        ));
    }
    let mut goal = resource::GoalPredicate::PlaceHasToken {
        place: previous_control,
        target: previous_target,
        index: Nat::zero(),
        revision: previous_revision,
    };
    let (return_bindings, final_resources): (Vec<&BindingExpr>, &[ResourceGoal]) =
        match &trace.terminal {
            ReturnPlan::Success(outputs) => (
                outputs.iter().map(|(_, binding)| binding).collect(),
                &input.goal.final_resources,
            ),
            ReturnPlan::Failure { embedding, value } => {
                let embedding = input
                    .goal
                    .failures
                    .iter()
                    .find(|candidate| candidate.id == *embedding)
                    .ok_or_else(|| invalid("unresolved failure embedding".to_owned()))?;
                (vec![value], &embedding.final_resources)
            }
        };
    for binding in return_bindings {
        let mut sources = Vec::new();
        binding_sources(binding, &mut sources);
        for source in sources {
            let correspondence = values
                .iter()
                .find(|value| value.producer == source.producer)
                .ok_or_else(|| invalid("return value producer unavailable".to_owned()))?;
            goal = resource::GoalPredicate::And(
                Box::new(goal),
                Box::new(resource::GoalPredicate::PlaceHasToken {
                    place: correspondence.place.clone(),
                    target: correspondence.token_target.clone(),
                    index: Nat::zero(),
                    revision: correspondence.revision.clone(),
                }),
            );
            if let Some((_, Some(reference))) = declared_value(input, &source.producer) {
                let lot = lots
                    .iter()
                    .find(|lot| lot.lot == reference)
                    .ok_or_else(|| invalid("return resource backing unavailable".to_owned()))?;
                goal = resource::GoalPredicate::And(
                    Box::new(goal),
                    Box::new(resource::GoalPredicate::PlaceHasAtLeast {
                        place: lot.place.clone(),
                        count: Nat::one(),
                    }),
                );
            }
        }
    }
    for requirement in final_resources {
        let lot = lots
            .iter()
            .find(|lot| lot.lot == requirement.lot)
            .ok_or_else(|| invalid("terminal resource producer unavailable".to_owned()))?;
        if lot.revision != requirement.revision {
            return Err(invalid("terminal resource revision".to_owned()));
        }
        goal = resource::GoalPredicate::And(
            Box::new(goal),
            Box::new(resource::GoalPredicate::PlaceHasAtLeast {
                place: lot.place.clone(),
                count: requirement.multiplicity.clone(),
            }),
        );
    }
    let graph = resource::DeclarationGraph {
        places: places.iter().map(|place| place.identity.clone()).collect(),
        transitions: transitions
            .iter()
            .map(|transition| transition.identity.clone())
            .collect(),
        edges: transitions
            .iter()
            .flat_map(|transition| {
                transition
                    .input_places
                    .iter()
                    .map(|place| (place.clone(), transition.identity.clone()))
                    .chain(
                        transition
                            .output_places
                            .iter()
                            .map(|place| (transition.identity.clone(), place.clone())),
                    )
            })
            .collect(),
        revision: Nat::zero(),
    };
    let max_bindings = input
        .bounds
        .resource_bounds
        .as_ref()
        .map(|bound| bound.max_bindings.clone())
        .unwrap_or_else(|| Nat::from(bindings.len()));
    let max_search_steps = input
        .bounds
        .resource_bounds
        .as_ref()
        .map(|bound| bound.max_search_steps.clone())
        .unwrap_or_else(|| Nat::from(transitions.len() + 1));
    let bound = resource::DomainBound {
        target_identity: input.identity.clone(),
        index: Nat::zero(),
        revision: Nat::zero(),
        max_bindings,
        max_search_steps,
    };
    let lowered = resource::SolverInput {
        places,
        transitions,
        bindings,
        goal,
        graph,
        marking,
        bound,
    };
    if let Some(reason) = resource::validate(&lowered) {
        return Err(invalid(format!(
            "lowered declaration rejected: {:?}",
            reason
        )));
    }
    Ok((
        lowered,
        ResourceCorrespondence {
            lots,
            values,
            normalized_bindings,
            execution_order,
        },
    ))
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AvailableValue {
    pub producer: ProducerRef,
    pub contract: SlotContract,
    pub resource: Option<ResourceLotRef>,
}
#[derive(Debug, Clone, PartialEq)]
pub struct BranchFact {
    pub guard: GuardId,
    pub inspected: ValueRef,
    pub arm: GuardArm,
    pub refinement: Option<SlotContract>,
    pub assumptions: Vec<ProjectionAssumption>,
    pub exact: Option<SlotValue>,
}
#[derive(Debug, Clone, PartialEq)]
pub struct SearchState {
    pub available: Vec<AvailableValue>,
    pub used_sites: Vec<SiteId>,
    pub used_guards: Vec<GuardId>,
    pub facts: Vec<BranchFact>,
    pub trace: Vec<TraceStep>,
    pub pending_failure: Option<FailureOrigin>,
}
pub fn initial_state(prepared: &PreparedCompositionInput<'_>) -> SearchState {
    SearchState {
        available: prepared
            .input
            .initial_inputs
            .iter()
            .map(|initial| AvailableValue {
                producer: ProducerRef::Initial(initial.id.clone()),
                contract: initial.contract.clone(),
                resource: initial.resource.clone().map(ResourceLotRef::Initial),
            })
            .collect(),
        used_sites: Vec::new(),
        used_guards: Vec::new(),
        facts: Vec::new(),
        trace: Vec::new(),
        pending_failure: None,
    }
}
fn relative_assumption(
    assumption: &ProjectionAssumption,
    prefix: &[PathStep],
) -> Option<ProjectionAssumption> {
    let trim = |path: &[PathStep]| path.strip_prefix(prefix).map(<[PathStep]>::to_vec);
    match assumption {
        ProjectionAssumption::Present(path) => trim(path).map(ProjectionAssumption::Present),
        ProjectionAssumption::NonNull(path) => trim(path).map(ProjectionAssumption::NonNull),
        ProjectionAssumption::Variant { path, tag } => {
            trim(path).map(|path| ProjectionAssumption::Variant {
                path,
                tag: tag.clone(),
            })
        }
        ProjectionAssumption::IndexPresent { path, index } => {
            trim(path).map(|path| ProjectionAssumption::IndexPresent {
                path,
                index: index.clone(),
            })
        }
    }
}
pub fn effective_projection(
    prepared: &PreparedCompositionInput<'_>,
    state: &SearchState,
    value: &ValueRef,
) -> Result<ProjectionCertificate, WitnessFailure> {
    let source = state
        .available
        .iter()
        .find(|source| source.producer == value.producer)
        .ok_or_else(|| WitnessFailure::ProducerMismatch(value.clone()))?;
    let refinement = state.facts.iter().rev().find(|fact| {
        fact.inspected.producer == value.producer
            && fact.refinement.is_some()
            && value.path.starts_with(&fact.inspected.path)
    });
    let (contract, prefix) = match refinement {
        Some(fact) => (
            fact.refinement
                .as_ref()
                .ok_or_else(|| WitnessFailure::GuardNotDominating(value.clone()))?,
            fact.inspected.path.as_slice(),
        ),
        None => (&source.contract, &[][..]),
    };
    let assumptions = state
        .facts
        .iter()
        .filter(|fact| fact.inspected.producer == value.producer)
        .flat_map(|fact| &fact.assumptions)
        .filter_map(|assumption| relative_assumption(assumption, prefix))
        .collect::<Vec<_>>();
    let path = value
        .path
        .strip_prefix(prefix)
        .ok_or_else(|| WitnessFailure::GuardNotDominating(value.clone()))?;
    project_slot(prepared.graph(), contract, path, &assumptions)
        .map_err(WitnessFailure::ProjectionMismatch)
}
pub fn project_owned(value: &SlotValue, path: &[PathStep], _representation: &()) -> SlotValue {
    if path.is_empty() {
        return value.clone();
    }
    match value {
        SlotValue::Absent => SlotValue::Absent,
        SlotValue::Null => SlotValue::Null,
        SlotValue::Present(value) => owned_slot(value_at_path(value, path)),
    }
}
fn exact_value(
    input: &CompositionInput,
    state: &SearchState,
    value: &ValueRef,
    _representation: &(),
) -> Option<SlotValue> {
    if let Some(fact) = state.facts.iter().rev().find(|fact| {
        fact.inspected.producer == value.producer
            && fact.exact.is_some()
            && value.path.starts_with(&fact.inspected.path)
    }) {
        return Some(project_owned(
            fact.exact.as_ref()?,
            value.path.strip_prefix(fact.inspected.path.as_slice())?,
            _representation,
        ));
    }
    match &value.producer {
        ProducerRef::Initial(id) => match &input
            .initial_inputs
            .iter()
            .find(|initial| initial.id == *id)?
            .source
        {
            InitialSource::SuppliedValue(supplied) => {
                Some(project_owned(supplied, &value.path, _representation))
            }
            InitialSource::Argument => None,
        },
        _ => None,
    }
}
fn path_permitted(input: &CompositionInput, source: &SlotContract, path: &[PathStep]) -> bool {
    path.is_empty()
        || input
            .invocation_domain
            .permitted_projections
            .iter()
            .any(|projection| projection.source_type == source.type_ref && projection.path == path)
        || input
            .invocation_domain
            .guards
            .iter()
            .any(|guard| guard.source_type == source.type_ref && guard.path == path)
}
fn ensure_possible(
    prepared: &PreparedCompositionInput<'_>,
    state: &SearchState,
    value: &ValueRef,
    contract: &SlotContract,
) -> Result<(), WitnessFailure> {
    if let Some(exact) = exact_value(prepared.input(), state, value, &()) {
        if matches!(
            validation::accepts_slot(prepared.graph(), contract, borrowed_slot(&exact)),
            ValueDecision::Accepted
        ) {
            return Ok(());
        }
    } else if !slot_empty(contract, &prepared.empty)
        && matches!(
            find_accepted_slot_candidate(
                prepared.graph(),
                &prepared.input.bounds,
                contract,
                |_, _| SlotCandidateControl::Accept,
            ),
            SlotCandidateSearch::AcceptedWithinBound(_)
                | SlotCandidateSearch::AcceptedBeyondSampleBound(_)
        )
    {
        return Ok(());
    }
    Err(WitnessFailure::MissingEvidence(format!(
        "no accepted value from {:?}",
        value
    )))
}
fn check_binding(
    prepared: &PreparedCompositionInput<'_>,
    state: &SearchState,
    binding: &BindingExpr,
    destination: &SlotContract,
    constraint: &SourceConstraint,
) -> Result<(), WitnessFailure> {
    match binding {
        BindingExpr::Source {
            value,
            projection,
            compatibility,
        } => {
            if !constraint.accepts(&value.producer, &value.path) {
                return Err(WitnessFailure::SourceConstraintMismatch(value.clone()));
            }
            let source = state
                .available
                .iter()
                .find(|source| source.producer == value.producer)
                .ok_or_else(|| WitnessFailure::ProducerMismatch(value.clone()))?;
            if !path_permitted(prepared.input(), &source.contract, &value.path) {
                return Err(WitnessFailure::ProjectionMismatch(
                    ProjectionFailure::CertificateMismatch(
                        "projection is outside the finite domain".to_owned(),
                    ),
                ));
            }
            let computed = effective_projection(prepared, state, value)?;
            if computed != *projection {
                return Err(WitnessFailure::ProjectionMismatch(
                    ProjectionFailure::CertificateMismatch(
                        "source, path or dominating guard differs".to_owned(),
                    ),
                ));
            }
            check_projection_certificate(prepared.graph(), projection)
                .map_err(WitnessFailure::ProjectionMismatch)?;
            ensure_possible(prepared, state, value, &projection.destination)?;
            match compatibility {
                BindingCompatibility::Inclusion(certificate) => {
                    verify_inclusion(
                        prepared.graph(),
                        &projection.destination,
                        destination,
                        certificate,
                    )
                    .map_err(WitnessFailure::Inclusion)?;
                }
                BindingCompatibility::SuppliedValue { value: supplied } => {
                    if exact_value(prepared.input(), state, value, &()).as_ref() != Some(supplied)
                        || !matches!(
                            validation::accepts_slot(
                                prepared.graph(),
                                &projection.destination,
                                borrowed_slot(supplied)
                            ),
                            ValueDecision::Accepted
                        )
                        || !matches!(
                            validation::accepts_slot(
                                prepared.graph(),
                                destination,
                                borrowed_slot(supplied)
                            ),
                            ValueDecision::Accepted
                        )
                    {
                        return Err(WitnessFailure::SuppliedValueMismatch(value.clone()));
                    }
                }
            }
            Ok(())
        }
        BindingExpr::Product {
            construction,
            type_ref,
            fields,
        } => {
            let rule = prepared
                .input
                .invocation_domain
                .permitted_constructions
                .iter()
                .find(|rule| &rule.identity == construction && &rule.type_ref == type_ref)
                .ok_or_else(|| WitnessFailure::ConstructionMismatch(type_ref.clone()))?;
            if !matches!(constraint, SourceConstraint::AnyCompatible)
                || *type_ref != destination.type_ref
            {
                return Err(WitnessFailure::ConstructionMismatch(type_ref.clone()));
            }
            let Some(TypeShape::Product(spec)) = resolved_shape(prepared.graph(), type_ref) else {
                return Err(WitnessFailure::ConstructionMismatch(type_ref.clone()));
            };
            let mut seen = HashSet::new();
            for (name, binding) in fields {
                if !seen.insert(name) {
                    return Err(WitnessFailure::ConstructionMismatch(type_ref.clone()));
                }
                let field = spec
                    .fields
                    .iter()
                    .find(|field| field.wire_name == *name)
                    .ok_or_else(|| WitnessFailure::ConstructionMismatch(type_ref.clone()))?;
                if let BindingExpr::Product {
                    construction: child,
                    ..
                } = binding
                {
                    if !rule
                        .nested_fields
                        .iter()
                        .any(|(field, nested)| field == name && nested == child)
                    {
                        return Err(WitnessFailure::ConstructionMismatch(type_ref.clone()));
                    }
                }
                if !field.slot.nullable && binding_may_have_present_null(prepared, state, binding) {
                    return Err(WitnessFailure::ConstructionMismatch(type_ref.clone()));
                }
                let constraint = rule
                    .field_constraints
                    .iter()
                    .find(|constraint| &constraint.field == name)
                    .map_or(&SourceConstraint::AnyCompatible, |constraint| {
                        &constraint.source
                    });
                check_binding(prepared, state, binding, &field.slot, constraint)?;
            }
            if spec.fields.iter().any(|field| {
                field.slot.required && !fields.iter().any(|(name, _)| name == &field.wire_name)
            }) {
                return Err(WitnessFailure::ConstructionMismatch(type_ref.clone()));
            }
            if rule.field_constraints.iter().any(|constraint| {
                constraint.presence == FieldPresence::Required
                    && !fields.iter().any(|(name, _)| name == &constraint.field)
            }) {
                return Err(WitnessFailure::ConstructionMismatch(type_ref.clone()));
            }
            if let Err(reason) =
                validation::check_meaning_defined(prepared.graph(), std::slice::from_ref(type_ref))
            {
                let reasons = vec![reason];
                return Err(WitnessFailure::Inclusion(
                    InclusionFailure::UndefinedMeaning(reasons),
                ));
            }
            Ok(())
        }
    }
}
fn outcome_empty(prepared: &PreparedCompositionInput<'_>, outcome: &OutcomeContract) -> bool {
    outcome.value_ports.iter().all(|port| {
        validation::check_meaning_defined(
            prepared.graph(),
            std::slice::from_ref(&port.contract.type_ref),
        )
        .is_ok()
    }) && outcome
        .value_ports
        .iter()
        .any(|port| slot_empty(&port.contract, &prepared.empty))
}
fn check_invocation(
    prepared: &PreparedCompositionInput<'_>,
    state: &SearchState,
    invocation: &InvocationPlan,
) -> Result<(), WitnessFailure> {
    let input = prepared.input();
    let function = site_signature(input, &invocation.site)
        .ok_or_else(|| WitnessFailure::SignatureMismatch(invocation.site.clone()))?;
    let handles = function.handles_failure == state.pending_failure
        || function.handles_failure.is_none()
            && !state
                .pending_failure
                .as_ref()
                .is_some_and(must_handle_failure);
    if function.reference != invocation.function
        || state.used_sites.contains(&invocation.site)
        || !handles
    {
        return Err(WitnessFailure::SignatureMismatch(invocation.site.clone()));
    }
    if input
        .explicit_order
        .iter()
        .any(|(before, after)| after == &invocation.site && !state.used_sites.contains(before))
    {
        return Err(WitnessFailure::RankViolation);
    }
    if invocation.bindings.len() != function.inputs.len()
        || invocation.resources.len() != function.resource_inputs.len()
    {
        return Err(WitnessFailure::MissingBinding(invocation.site.0.clone()));
    }
    for port in &function.inputs {
        let bindings: Vec<_> = invocation
            .bindings
            .iter()
            .filter(|(id, _)| *id == port.id)
            .collect();
        let [(_, port_binding)] = bindings.as_slice() else {
            return Err(WitnessFailure::MissingBinding(port.id.0.clone()));
        };
        check_binding(
            prepared,
            state,
            port_binding,
            &port.contract,
            &port.source_constraint,
        )?;
        if let Some(requirement) = &port.resource_requirement {
            let resource = invocation
                .resources
                .iter()
                .find(|resource| resource.requirement == *requirement)
                .ok_or_else(|| WitnessFailure::MissingBinding(requirement.0.clone()))?;
            let mut sources = Vec::new();
            binding_sources(port_binding, &mut sources);
            let backed = matches!(
                sources.as_slice(),
                [source] if declared_value(input, &source.producer)
                    .and_then(|(_, lot)| lot)
                    .as_ref()
                    == Some(&resource.lot)
            );
            if !backed {
                return Err(WitnessFailure::ResourceLoweringMismatch(
                    "input backing lot differs".to_owned(),
                ));
            }
        }
    }
    let available_lots = state_lots(input, state);
    for requirement in &function.resource_inputs {
        let bindings: Vec<_> = invocation
            .resources
            .iter()
            .filter(|binding| binding.requirement == requirement.id)
            .collect();
        let binding = match bindings.as_slice() {
            [binding] if available_lots.contains(&binding.lot) => *binding,
            _ => return Err(WitnessFailure::MissingBinding(requirement.id.0.clone())),
        };
        let lot = declared_lot(input, &binding.lot).ok_or_else(|| {
            WitnessFailure::ResourceLoweringMismatch("resource lot unresolved".to_owned())
        })?;
        if lot.revision != requirement.required_revision
            || !matches!(&requirement.identity, ResourceIdentityConstraint::Any)
                && requirement.identity != ResourceIdentityConstraint::Exactly(lot.producer)
        {
            return Err(WitnessFailure::ResourceLoweringMismatch(
                "resource revision/identity differs".to_owned(),
            ));
        }
        verify_inclusion(
            prepared.graph(),
            &present_contract(lot.token_type),
            &present_contract(requirement.token_type.clone()),
            &binding.inclusion,
        )
        .map_err(WitnessFailure::Inclusion)?;
    }
    if let Some(origin) = function.handles_failure.as_ref() {
        let actual = state.trace.iter().rev().find_map(|step| match step {
            TraceStep::Invocation { invocation, outcome } if matches!(origin, FailureOrigin::Function { function, outcome: expected } if function == &invocation.function && expected == outcome) => Some(invocation.site.clone()),
            _ => None,
        });
        let mut sources = Vec::new();
        for (_, binding) in &invocation.bindings {
            binding_sources(binding, &mut sources);
        }
        let uses_failure = match origin {
            FailureOrigin::Function { outcome, .. } => actual.is_some_and(|site| sources.iter().any(|source| matches!(&source.producer, ProducerRef::InvocationOutcome { site: actual, outcome: actual_outcome, .. } if actual == &site && actual_outcome == outcome))),
            FailureOrigin::Guard { guard, .. } => state.facts.iter().rev().find(|fact| &fact.guard == guard).is_some_and(|fact| sources.iter().any(|source| source.producer == fact.inspected.producer && source.path.starts_with(&fact.inspected.path))),
        };
        if !uses_failure {
            return Err(WitnessFailure::MissingEvidence(
                "handler does not receive the actual failure value".to_owned(),
            ));
        }
    }
    Ok(())
}
fn after_invocation(
    state: &SearchState,
    invocation: &InvocationPlan,
    outcome: &OutcomeContract,
) -> SearchState {
    let mut next = state.clone();
    next.used_sites.push(invocation.site.clone());
    for port in &outcome.value_ports {
        next.available.push(AvailableValue {
            producer: ProducerRef::InvocationOutcome {
                site: invocation.site.clone(),
                outcome: outcome.id.clone(),
                port: port.id.clone(),
            },
            contract: port.contract.clone(),
            resource: port
                .resource_production
                .clone()
                .map(|production| ResourceLotRef::Produced {
                    site: invocation.site.clone(),
                    outcome: outcome.id.clone(),
                    production,
                }),
        });
    }
    next.trace.push(TraceStep::Invocation {
        invocation: invocation.clone(),
        outcome: outcome.id.clone(),
    });
    next.pending_failure = match outcome.form {
        OutcomeForm::Success => None,
        OutcomeForm::DeclaredFailure => Some(FailureOrigin::Function {
            function: invocation.function.clone(),
            outcome: outcome.id.clone(),
        }),
    };
    next
}
fn state_lots(input: &CompositionInput, state: &SearchState) -> Vec<ResourceLotRef> {
    let mut result: Vec<_> = input
        .initial_resources
        .iter()
        .map(|lot| ResourceLotRef::Initial(lot.id.clone()))
        .collect();
    for step in &state.trace {
        if let TraceStep::Invocation {
            invocation,
            outcome,
        } = step
        {
            if let Some(outcome_contract) =
                site_signature(input, &invocation.site).and_then(|function| {
                    function
                        .outcomes
                        .iter()
                        .find(|candidate| candidate.id == *outcome)
                })
            {
                result.extend(
                    outcome_contract
                        .produced_resources
                        .iter()
                        .map(|production| ResourceLotRef::Produced {
                            site: invocation.site.clone(),
                            outcome: outcome.clone(),
                            production: production.id.clone(),
                        }),
                );
            }
        }
    }
    result
}
pub fn guard_declaration<'a>(
    input: &'a CompositionInput,
    id: &GuardId,
) -> Option<&'a DeclaredGuard> {
    input
        .invocation_domain
        .guards
        .iter()
        .find(|guard| guard.id == *id)
}
fn guard_arms(
    prepared: &PreparedCompositionInput<'_>,
    state: &SearchState,
    guard: &DeclaredGuard,
    inspected: &ValueRef,
) -> Result<Vec<GuardArm>, WitnessFailure> {
    if state.used_guards.contains(&guard.id) {
        return Err(WitnessFailure::GuardNotDominating(inspected.clone()));
    }
    let source = state
        .available
        .iter()
        .find(|source| source.producer == inspected.producer)
        .ok_or_else(|| WitnessFailure::ProducerMismatch(inspected.clone()))?;
    if source.contract.type_ref != guard.source_type || inspected.path != guard.path {
        return Err(WitnessFailure::GuardNotDominating(inspected.clone()));
    }
    let projected = effective_projection(prepared, state, inspected)?;
    if let GuardKind::Validate(destination) = &guard.kind {
        if let Err(reason) = validation::check_meaning_defined(
            prepared.graph(),
            std::slice::from_ref(&destination.type_ref),
        ) {
            return Err(WitnessFailure::Inclusion(
                InclusionFailure::UndefinedMeaning(vec![reason]),
            ));
        }
    }
    if let Some(value) = exact_value(prepared.input(), state, inspected, &()) {
        return Ok(vec![evaluate_guard_arm(
            prepared.graph(),
            guard,
            borrowed_slot(&value),
        )
        .map_err(|failure| {
            WitnessFailure::MissingEvidence(format!("guard value: {:?}", failure))
        })?]);
    }
    let mut arms = Vec::new();
    match &guard.kind {
        GuardKind::Validate(destination) => {
            if slots_disjoint(
                prepared.graph(),
                &projected.destination,
                destination,
                &prepared.empty,
            ) {
                arms.push(GuardArm::Rejected);
            } else if matches!(
                check_assignable_bounded(
                    prepared.graph(),
                    &projected.destination,
                    destination,
                    &prepared.input.bounds
                ),
                CompatibilityDecision::Compatible(_)
            ) {
                arms.push(GuardArm::Accepted);
            } else {
                arms.push(GuardArm::Accepted);
                arms.push(GuardArm::Rejected);
            }
        }
        GuardKind::Presence | GuardKind::Variants => {
            if !projected.destination.required {
                arms.push(GuardArm::Absent);
            }
            if projected.destination.nullable {
                arms.push(GuardArm::Null);
            }
            if !prepared.empty.contains(&projected.destination.type_ref) {
                if guard.kind == GuardKind::Presence {
                    arms.push(GuardArm::Present);
                } else {
                    let Some(TypeShape::TaggedUnion(spec)) =
                        resolved_shape(prepared.graph(), &projected.destination.type_ref)
                    else {
                        return Err(WitnessFailure::GuardNotDominating(inspected.clone()));
                    };
                    arms.extend(
                        spec.branches
                            .iter()
                            .filter(|branch| !prepared.empty.contains(&branch.target))
                            .map(|branch| GuardArm::Variant(branch.wire_tag.clone())),
                    );
                    if spec
                        .branches
                        .iter()
                        .any(|branch| branch.selector == BranchSelector::Otherwise)
                    {
                        arms.push(GuardArm::UnknownVariant);
                    }
                }
            }
        }
    }
    Ok(arms)
}
pub fn evaluate_guard_arm(
    graph: &SemanticGraph,
    guard: &DeclaredGuard,
    inspected: SlotValue<&JsonValue>,
) -> Result<GuardArm, ValueDecision> {
    match &guard.kind {
        GuardKind::Validate(contract) => match validation::accepts_slot(graph, contract, inspected)
        {
            ValueDecision::Accepted => Ok(GuardArm::Accepted),
            ValueDecision::Rejected(_) => Ok(GuardArm::Rejected),
            unresolved => Err(unresolved),
        },
        GuardKind::Presence => Ok(match inspected {
            SlotValue::Absent => GuardArm::Absent,
            SlotValue::Null => GuardArm::Null,
            SlotValue::Present(_) => GuardArm::Present,
        }),
        GuardKind::Variants => {
            match inspected {
                SlotValue::Absent => Ok(GuardArm::Absent),
                SlotValue::Null => Ok(GuardArm::Null),
                SlotValue::Present(JsonValue::Obj(members)) => {
                    let Some(JsonValue::Str(tag)) = graph
                        .profile()
                        .tag
                        .as_ref()
                        .and_then(|model| member(members, &model.key))
                    else {
                        return Err(ValueDecision::Rejected(guard_value_failure(
                            &guard.source_type,
                            ValueCondition::InvalidTag,
                        )));
                    };
                    let source = present_contract(guard.source_type.clone());
                    let assumptions = guard
                        .path
                        .iter()
                        .enumerate()
                        .filter_map(
                            |(position, step)| match (step, guard.path.get(..position)) {
                                (PathStep::Variant(tag), Some(prefix)) => {
                                    Some(ProjectionAssumption::Variant {
                                        path: prefix.to_vec(),
                                        tag: tag.clone(),
                                    })
                                }
                                _ => None,
                            },
                        )
                        .collect::<Vec<_>>();
                    let projection = project_slot(graph, &source, &guard.path, &assumptions)
                        .map_err(|failure| match failure {
                            ProjectionFailure::UndefinedMeaning(_) => {
                                ValueDecision::Rejected(guard_value_failure(
                                    &guard.source_type,
                                    ValueCondition::InvalidDataModel,
                                ))
                            }
                            _ => ValueDecision::Rejected(guard_value_failure(
                                &guard.source_type,
                                ValueCondition::InvalidDataModel,
                            )),
                        })?;
                    let Some(TypeShape::TaggedUnion(spec)) =
                        resolved_shape(graph, &projection.destination.type_ref)
                    else {
                        return Err(ValueDecision::Rejected(guard_value_failure(
                            &guard.source_type,
                            ValueCondition::InvalidDataModel,
                        )));
                    };
                    if spec.branches.iter().any(|branch| branch.wire_tag == *tag) {
                        Ok(GuardArm::Variant(tag.clone()))
                    } else if spec
                        .branches
                        .iter()
                        .any(|branch| branch.selector == BranchSelector::Otherwise)
                    {
                        Ok(GuardArm::UnknownVariant)
                    } else {
                        Err(ValueDecision::Rejected(guard_value_failure(
                            &guard.source_type,
                            ValueCondition::NoBranchSelected,
                        )))
                    }
                }
                _ => Err(ValueDecision::Rejected(guard_value_failure(
                    &guard.source_type,
                    ValueCondition::WrongValueKind("tagged object".to_owned()),
                ))),
            }
        }
    }
}
fn guard_value_failure(reference: &TypeRef, condition: ValueCondition) -> ValueFailure {
    ValueFailure {
        type_ref: reference.clone(),
        definition_ref: DefinitionRef {
            source: Arc::clone(&reference.source),
            name: Arc::clone(&reference.definition_name),
        },
        origin: reference.into(),
        value_path: Vec::new(),
        condition,
        observed: SlotValue::Absent,
        reference_trace: Vec::new(),
    }
}
fn after_guard(
    prepared: &PreparedCompositionInput<'_>,
    state: &SearchState,
    guard: &DeclaredGuard,
    inspected: &ValueRef,
    arm: &GuardArm,
) -> Result<SearchState, WitnessFailure> {
    let projected = effective_projection(prepared, state, inspected)?;
    let mut fact = BranchFact {
        guard: guard.id.clone(),
        inspected: inspected.clone(),
        arm: arm.clone(),
        refinement: None,
        assumptions: Vec::new(),
        exact: None,
    };
    match arm {
        GuardArm::Present | GuardArm::UnknownVariant => {
            let mut contract = projected.destination.clone();
            contract.required = true;
            contract.nullable = false;
            fact.refinement = Some(contract);
        }
        GuardArm::Variant(tag) => fact.assumptions.push(ProjectionAssumption::Variant {
            path: inspected.path.clone(),
            tag: tag.clone(),
        }),
        GuardArm::Absent => fact.exact = Some(SlotValue::Absent),
        GuardArm::Null => fact.exact = Some(SlotValue::Null),
        GuardArm::Accepted => {
            let GuardKind::Validate(contract) = &guard.kind else {
                return Err(WitnessFailure::GuardNotDominating(inspected.clone()));
            };
            fact.refinement = Some(contract.clone());
        }
        GuardArm::Rejected => {}
    }
    if let Some(exact) = exact_value(prepared.input(), state, inspected, &()) {
        fact.exact = Some(exact);
    }
    let mut next = state.clone();
    next.used_guards.push(guard.id.clone());
    next.facts.push(fact);
    next.trace.push(TraceStep::Guard {
        guard: guard.id.clone(),
        inspected: inspected.clone(),
        arm: arm.clone(),
    });
    if !state
        .pending_failure
        .as_ref()
        .is_some_and(must_handle_failure)
        && matches!(
            arm,
            GuardArm::Absent | GuardArm::Null | GuardArm::UnknownVariant | GuardArm::Rejected
        )
    {
        next.pending_failure = Some(FailureOrigin::Guard {
            guard: guard.id.clone(),
            arm: arm.clone(),
        });
    }
    Ok(next)
}
pub fn check_return(
    prepared: &PreparedCompositionInput<'_>,
    state: &SearchState,
    terminal: &ReturnPlan,
) -> Result<bool, WitnessFailure> {
    match terminal {
        ReturnPlan::Success(outputs) => {
            if state
                .pending_failure
                .as_ref()
                .is_some_and(must_handle_failure)
                || outputs.len() != prepared.input.goal.outputs.len()
            {
                return Err(WitnessFailure::GoalMismatch);
            }
            for goal in &prepared.input.goal.outputs {
                let bindings: Vec<_> = outputs.iter().filter(|(id, _)| *id == goal.id).collect();
                let [(_, output_binding)] = bindings.as_slice() else {
                    return Err(WitnessFailure::GoalMismatch);
                };
                check_binding(
                    prepared,
                    state,
                    output_binding,
                    &goal.contract,
                    &goal.source_constraint,
                )?;
            }
            Ok(true)
        }
        ReturnPlan::Failure { embedding, value } => {
            let embedding_contract = prepared
                .input
                .goal
                .failures
                .iter()
                .find(|candidate| candidate.id == *embedding)
                .ok_or_else(|| WitnessFailure::FailureEmbeddingMismatch(embedding.clone()))?;
            if state.pending_failure.as_ref() != Some(&embedding_contract.origin) {
                return Err(WitnessFailure::FailureEmbeddingMismatch(embedding.clone()));
            }
            check_binding(
                prepared,
                state,
                value,
                &embedding_contract.contract,
                &SourceConstraint::AnyCompatible,
            )?;
            let mut sources = Vec::new();
            binding_sources(value, &mut sources);
            let actual = match &embedding_contract.origin {
                FailureOrigin::Function { function, outcome } => {
                    let site = state.trace.iter().rev().find_map(|step| match step {
                        TraceStep::Invocation {
                            invocation,
                            outcome: actual,
                        } if &invocation.function == function && actual == outcome => {
                            Some(&invocation.site)
                        }
                        _ => None,
                    });
                    site.is_some_and(|site| sources.iter().any(|source| matches!(&source.producer, ProducerRef::InvocationOutcome { site: actual, outcome: actual_outcome, .. } if actual == site && actual_outcome == outcome)))
                }
                FailureOrigin::Guard { guard, arm } => state
                    .facts
                    .iter()
                    .rev()
                    .find(|fact| &fact.guard == guard && &fact.arm == arm)
                    .is_some_and(|fact| {
                        sources.iter().any(|source| {
                            source.producer == fact.inspected.producer
                                && source.path.starts_with(&fact.inspected.path)
                        })
                    }),
            };
            if !actual {
                return Err(WitnessFailure::FailureEmbeddingMismatch(embedding.clone()));
            }
            Ok(false)
        }
    }
}

fn must_handle_failure(origin: &FailureOrigin) -> bool {
    matches!(
        origin,
        FailureOrigin::Function { .. }
            | FailureOrigin::Guard {
                arm: GuardArm::Rejected,
                ..
            }
    )
}
fn binding_may_have_present_null(
    prepared: &PreparedCompositionInput<'_>,
    state: &SearchState,
    binding: &BindingExpr,
) -> bool {
    match binding {
        BindingExpr::Source {
            value, projection, ..
        } => match exact_value(prepared.input(), state, value, &()) {
            Some(SlotValue::Present(JsonValue::Null)) => true,
            Some(_) => false,
            None => matches!(
                validation::accepts_value(
                    prepared.graph(),
                    &projection.destination.type_ref,
                    &JsonValue::Null
                ),
                ValueDecision::Accepted
            ),
        },
        BindingExpr::Product { .. } => false,
    }
}

fn evaluated_binding(
    binding: &BindingExpr,
    values: &[(ProducerRef, SlotValue)],
    _representation: &(),
) -> Option<SlotValue> {
    match binding {
        BindingExpr::Source { value, .. } => values
            .iter()
            .find(|(producer, _)| producer == &value.producer)
            .map(|(_, source)| project_owned(source, &value.path, _representation)),
        BindingExpr::Product { fields, .. } => {
            let mut members = Vec::new();
            for (name, binding) in fields {
                match evaluated_binding(binding, values, _representation)? {
                    SlotValue::Absent => {}
                    SlotValue::Null => members.push((name.clone(), JsonValue::Null)),
                    SlotValue::Present(value) => members.push((name.clone(), value)),
                }
            }
            Some(SlotValue::Present(JsonValue::Obj(members)))
        }
    }
}
pub fn verify_value_models(
    prepared: &PreparedCompositionInput<'_>,
    state: &SearchState,
    values: &[(ProducerRef, SlotValue)],
) -> Result<(), WitnessFailure> {
    if values.len() != state.available.len() {
        return Err(WitnessFailure::MissingEvidence(
            "producer value coverage".to_owned(),
        ));
    }
    for source in &state.available {
        let models: Vec<_> = values
            .iter()
            .filter(|(producer, _)| producer == &source.producer)
            .collect();
        let model = match models.as_slice() {
            [(_, model)]
                if matches!(
                    validation::accepts_slot(
                        prepared.graph(),
                        &source.contract,
                        borrowed_slot(model)
                    ),
                    ValueDecision::Accepted
                ) =>
            {
                model
            }
            _ => {
                return Err(WitnessFailure::ProducerMismatch(ValueRef {
                    producer: source.producer.clone(),
                    path: Vec::new(),
                }))
            }
        };
        if let ProducerRef::Initial(id) = &source.producer {
            if let Some(InitialInput {
                source: InitialSource::SuppliedValue(expected),
                ..
            }) = prepared
                .input
                .initial_inputs
                .iter()
                .find(|initial| &initial.id == id)
            {
                if expected != model {
                    return Err(WitnessFailure::SuppliedValueMismatch(ValueRef {
                        producer: source.producer.clone(),
                        path: Vec::new(),
                    }));
                }
            }
        }
    }
    for step in &state.trace {
        match step {
            TraceStep::Guard {
                guard,
                inspected,
                arm,
            } => {
                let declaration = guard_declaration(prepared.input(), guard)
                    .ok_or_else(|| WitnessFailure::GuardNotDominating(inspected.clone()))?;
                let value = values
                    .iter()
                    .find(|(producer, _)| producer == &inspected.producer)
                    .map(|(_, value)| project_owned(value, &inspected.path, &()))
                    .ok_or_else(|| WitnessFailure::ProducerMismatch(inspected.clone()))?;
                if evaluate_guard_arm(prepared.graph(), declaration, borrowed_slot(&value))
                    .ok()
                    .as_ref()
                    != Some(arm)
                {
                    return Err(WitnessFailure::GuardNotDominating(inspected.clone()));
                }
            }
            TraceStep::Invocation { invocation, .. } => {
                let function = site_signature(prepared.input(), &invocation.site)
                    .ok_or_else(|| WitnessFailure::SignatureMismatch(invocation.site.clone()))?;
                for port in &function.inputs {
                    let binding = invocation
                        .bindings
                        .iter()
                        .find(|(id, _)| *id == port.id)
                        .ok_or_else(|| WitnessFailure::MissingBinding(port.id.0.clone()))?;
                    let value = evaluated_binding(&binding.1, values, &())
                        .ok_or_else(|| WitnessFailure::MissingBinding(port.id.0.clone()))?;
                    if !matches!(
                        validation::accepts_slot(
                            prepared.graph(),
                            &port.contract,
                            borrowed_slot(&value)
                        ),
                        ValueDecision::Accepted
                    ) {
                        return Err(WitnessFailure::MissingEvidence(format!(
                            "no accepted actual input at {:?}",
                            port.id
                        )));
                    }
                }
            }
        }
    }
    Ok(())
}
pub fn verify_return_values(
    prepared: &PreparedCompositionInput<'_>,
    terminal: &ReturnPlan,
    values: &[(ProducerRef, SlotValue)],
) -> Result<(), WitnessFailure> {
    match terminal {
        ReturnPlan::Success(outputs) => {
            for goal in &prepared.input.goal.outputs {
                let binding = outputs
                    .iter()
                    .find(|(id, _)| *id == goal.id)
                    .ok_or(WitnessFailure::GoalMismatch)?;
                let value = evaluated_binding(&binding.1, values, &())
                    .ok_or(WitnessFailure::GoalMismatch)?;
                if !matches!(
                    validation::accepts_slot(
                        prepared.graph(),
                        &goal.contract,
                        borrowed_slot(&value)
                    ),
                    ValueDecision::Accepted
                ) {
                    return Err(WitnessFailure::GoalMismatch);
                }
            }
        }
        ReturnPlan::Failure { embedding, value } => {
            let embedding = prepared
                .input
                .goal
                .failures
                .iter()
                .find(|candidate| candidate.id == *embedding)
                .ok_or(WitnessFailure::GoalMismatch)?;
            let value =
                evaluated_binding(value, values, &()).ok_or(WitnessFailure::GoalMismatch)?;
            if !matches!(
                validation::accepts_slot(
                    prepared.graph(),
                    &embedding.contract,
                    borrowed_slot(&value)
                ),
                ValueDecision::Accepted
            ) {
                return Err(WitnessFailure::GoalMismatch);
            }
        }
    }
    Ok(())
}

#[derive(Debug, Clone, PartialEq)]
pub enum ChoiceSkeleton {
    Invoke {
        invocation: InvocationPlan,
        outcomes: Vec<OutcomeId>,
        empty_outcomes: Vec<OutcomeId>,
    },
    Guard {
        guard: GuardId,
        inspected: ValueRef,
        arms: Vec<GuardArm>,
    },
}
#[derive(Debug, Clone, PartialEq)]
pub struct MissingSupply {
    pub site: Option<SiteId>,
    pub port: String,
    pub contract: SlotContract,
}
pub struct Enumeration {
    pub terminals: Vec<ReturnPlan>,
    pub choices: Vec<ChoiceSkeleton>,
    pub unknown: Vec<UnresolvedObligation>,
    pub failures: Vec<ConnectionFailure>,
    pub missing: Vec<MissingSupply>,
}
pub struct CandidateBudget {
    bindings: usize,
    branch_nodes: usize,
    exhausted_bindings: bool,
    pub exhausted_branches: bool,
}
impl Default for CandidateBudget {
    fn default() -> Self {
        Self::new()
    }
}
impl CandidateBudget {
    pub fn new() -> Self {
        Self {
            bindings: 0,
            branch_nodes: 0,
            exhausted_bindings: false,
            exhausted_branches: false,
        }
    }
    fn binding(&mut self, input: &CompositionInput) -> bool {
        if self.bindings >= input.bounds.max_binding_candidates {
            self.exhausted_bindings = true;
            false
        } else {
            self.bindings += 1;
            true
        }
    }
}
struct LocalEnumerator<'a, 'g, 'b> {
    prepared: &'a PreparedCompositionInput<'g>,
    state: &'a SearchState,
    budget: &'b mut CandidateBudget,
    unknown: Vec<UnresolvedObligation>,
    failures: Vec<ConnectionFailure>,
    missing: Vec<MissingSupply>,
}
impl LocalEnumerator<'_, '_, '_> {
    fn compatibility(
        &mut self,
        source: &SlotContract,
        destination: &SlotContract,
        value: Option<ValueRef>,
    ) -> Option<Arc<InclusionCertificate>> {
        match check_assignable_bounded(
            self.prepared.graph(),
            source,
            destination,
            &self.prepared.input.bounds,
        ) {
            CompatibilityDecision::Compatible(certificate) => Some(Arc::new(certificate)),
            CompatibilityDecision::Incompatible(counterexample) => {
                self.failures.push(ConnectionFailure {
                    value,
                    destination: destination.clone(),
                    counterexample,
                });
                None
            }
            CompatibilityDecision::Unknown(obligations) => {
                self.unknown
                    .push(UnresolvedObligation::Type { value, obligations });
                None
            }
        }
    }
    fn source_bindings(
        &mut self,
        destination: &SlotContract,
        constraint: &SourceConstraint,
    ) -> Vec<BindingExpr> {
        let mut result = Vec::new();
        for source in &self.state.available {
            if slot_empty(&source.contract, &self.prepared.empty) {
                continue;
            }
            let mut paths = vec![Vec::new()];
            paths.extend(
                self.prepared
                    .input
                    .invocation_domain
                    .permitted_projections
                    .iter()
                    .filter(|projection| projection.source_type == source.contract.type_ref)
                    .map(|projection| projection.path.clone()),
            );
            paths.extend(
                self.state
                    .facts
                    .iter()
                    .filter(|fact| fact.inspected.producer == source.producer)
                    .map(|fact| fact.inspected.path.clone()),
            );
            let mut distinct = Vec::new();
            for path in paths {
                if !distinct.contains(&path) {
                    distinct.push(path);
                }
            }
            for path in distinct {
                if !constraint.accepts(&source.producer, &path) {
                    continue;
                }
                if !self.budget.binding(self.prepared.input()) {
                    return result;
                }
                let value = ValueRef {
                    producer: source.producer.clone(),
                    path,
                };
                let projection = match effective_projection(self.prepared, self.state, &value) {
                    Ok(projection) => projection,
                    Err(WitnessFailure::ProjectionMismatch(
                        ProjectionFailure::UndefinedMeaning(reason),
                    )) => {
                        self.unknown
                            .push(UnresolvedObligation::Meaning(vec![reason]));
                        continue;
                    }
                    Err(_) => continue,
                };
                if let Some(supplied) = exact_value(self.prepared.input(), self.state, &value, &())
                {
                    match validation::accepts_slot(
                        self.prepared.graph(),
                        &projection.destination,
                        borrowed_slot(&supplied),
                    ) {
                        ValueDecision::Accepted => {}
                        ValueDecision::Unresolved(reasons) => {
                            self.unknown
                                .push(UnresolvedObligation::SemanticMeaning(reasons));
                            continue;
                        }
                        ValueDecision::Rejected(_) => continue,
                    }
                    match validation::accepts_slot(
                        self.prepared.graph(),
                        destination,
                        borrowed_slot(&supplied),
                    ) {
                        ValueDecision::Accepted => {
                            let binding = BindingExpr::Source {
                                value,
                                projection,
                                compatibility: BindingCompatibility::SuppliedValue {
                                    value: supplied,
                                },
                            };
                            if check_binding(
                                self.prepared,
                                self.state,
                                &binding,
                                destination,
                                constraint,
                            )
                            .is_ok()
                            {
                                result.push(binding);
                            }
                        }
                        ValueDecision::Rejected(destination_failure) => {
                            if matches!(
                                validation::accepts_slot(
                                    self.prepared.graph(),
                                    &projection.destination,
                                    borrowed_slot(&supplied)
                                ),
                                ValueDecision::Accepted
                            ) {
                                self.failures.push(ConnectionFailure {
                                    value: Some(value),
                                    destination: destination.clone(),
                                    counterexample: CounterexampleCertificate {
                                        basis: SemanticBasis::of(self.prepared.graph()),
                                        source: projection.destination,
                                        destination: destination.clone(),
                                        value: supplied,
                                        destination_failure,
                                    },
                                });
                            }
                        }
                        ValueDecision::Unresolved(reasons) => self
                            .unknown
                            .push(UnresolvedObligation::SemanticMeaning(reasons)),
                    }
                    continue;
                }
                if slot_empty(&projection.destination, &self.prepared.empty) {
                    continue;
                }
                match find_accepted_slot_candidate(
                    self.prepared.graph(),
                    &self.prepared.input.bounds,
                    &projection.destination,
                    |_, _| SlotCandidateControl::Accept,
                ) {
                    SlotCandidateSearch::AcceptedWithinBound(_)
                    | SlotCandidateSearch::AcceptedBeyondSampleBound(_) => {}
                    SlotCandidateSearch::NoEvidence => {
                        self.unknown.push(UnresolvedObligation::Inhabitation {
                            producer: value.producer.clone(),
                            contract: projection.destination.clone(),
                        });
                        continue;
                    }
                }
                if let Some(certificate) =
                    self.compatibility(&projection.destination, destination, Some(value.clone()))
                {
                    let binding = BindingExpr::Source {
                        value,
                        projection,
                        compatibility: BindingCompatibility::Inclusion(certificate),
                    };
                    if check_binding(self.prepared, self.state, &binding, destination, constraint)
                        .is_ok()
                    {
                        result.push(binding);
                    }
                }
            }
        }
        result
    }
    fn construction_bindings(
        &mut self,
        destination: &SlotContract,
        rule_id: &str,
    ) -> Vec<BindingExpr> {
        let Some(rule) = self
            .prepared
            .input
            .invocation_domain
            .permitted_constructions
            .iter()
            .find(|rule| rule.identity == rule_id && rule.type_ref == destination.type_ref)
        else {
            return Vec::new();
        };
        let Some(TypeShape::Product(spec)) = resolved_shape(self.prepared.graph(), &rule.type_ref)
        else {
            return Vec::new();
        };
        let mut products: Vec<Vec<(String, BindingExpr)>> = vec![Vec::new()];
        for field in &spec.fields {
            let field_constraint = rule
                .field_constraints
                .iter()
                .find(|constraint| constraint.field == field.wire_name);
            let constraint = field_constraint
                .map_or(&SourceConstraint::AnyCompatible, |constraint| {
                    &constraint.source
                });
            let mut choices = self.source_bindings(&field.slot, constraint);
            if let Some((_, nested)) = rule
                .nested_fields
                .iter()
                .find(|(name, _)| name == &field.wire_name)
            {
                choices.extend(self.construction_bindings(&field.slot, nested));
            }
            let mut next = Vec::new();
            for fields in products {
                if !field.slot.required
                    && !field_constraint
                        .is_some_and(|constraint| constraint.presence == FieldPresence::Required)
                {
                    next.push(fields.clone());
                }
                for binding in &choices {
                    if !self.budget.binding(self.prepared.input()) {
                        break;
                    }
                    let mut fields = fields.clone();
                    fields.push((field.wire_name.clone(), binding.clone()));
                    next.push(fields);
                }
            }
            products = next;
            if products.is_empty() || self.budget.exhausted_bindings {
                break;
            }
        }
        products
            .into_iter()
            .map(|fields| BindingExpr::Product {
                construction: rule.identity.clone(),
                type_ref: rule.type_ref.clone(),
                fields,
            })
            .filter(|binding| {
                check_binding(
                    self.prepared,
                    self.state,
                    binding,
                    destination,
                    &SourceConstraint::AnyCompatible,
                )
                .is_ok()
            })
            .collect()
    }
    fn bindings(
        &mut self,
        destination: &SlotContract,
        constraint: &SourceConstraint,
    ) -> Vec<BindingExpr> {
        let mut bindings = self.source_bindings(destination, constraint);
        if matches!(constraint, SourceConstraint::AnyCompatible) {
            for rule in self
                .prepared
                .input
                .invocation_domain
                .permitted_constructions
                .iter()
                .filter(|rule| rule.type_ref == destination.type_ref)
            {
                bindings.extend(self.construction_bindings(destination, &rule.identity));
            }
        }
        bindings
    }
    fn resource_bindings(&mut self, function: &FunctionSignature) -> Vec<Vec<ResourceBinding>> {
        let lots = state_lots(self.prepared.input(), self.state);
        let mut bindings = vec![Vec::new()];
        for requirement in &function.resource_inputs {
            let mut options = Vec::new();
            for reference in &lots {
                if !self.budget.binding(self.prepared.input()) {
                    break;
                }
                let Some(lot) = declared_lot(self.prepared.input(), reference) else {
                    continue;
                };
                if lot.revision != requirement.required_revision
                    || !matches!(&requirement.identity, ResourceIdentityConstraint::Any)
                        && requirement.identity != ResourceIdentityConstraint::Exactly(lot.producer)
                {
                    continue;
                }
                if let Some(inclusion) = self.compatibility(
                    &present_contract(lot.token_type),
                    &present_contract(requirement.token_type.clone()),
                    None,
                ) {
                    options.push(ResourceBinding {
                        requirement: requirement.id.clone(),
                        lot: reference.clone(),
                        inclusion,
                    });
                }
            }
            let mut next = Vec::new();
            for bindings in bindings {
                for option in &options {
                    if !self.budget.binding(self.prepared.input()) {
                        break;
                    }
                    let mut bindings = bindings.clone();
                    bindings.push(option.clone());
                    next.push(bindings);
                }
            }
            bindings = next;
        }
        bindings
    }
    fn enumerate(mut self) -> Enumeration {
        let input = self.prepared.input();
        let mut terminals = Vec::new();
        if !self
            .state
            .pending_failure
            .as_ref()
            .is_some_and(must_handle_failure)
        {
            let mut goals = vec![Vec::new()];
            for goal in &input.goal.outputs {
                let bindings = self.bindings(&goal.contract, &goal.source_constraint);
                if bindings.is_empty() {
                    self.missing.push(MissingSupply {
                        site: None,
                        port: goal.id.0.clone(),
                        contract: goal.contract.clone(),
                    });
                }
                let mut next = Vec::new();
                for goals in goals {
                    for binding in &bindings {
                        if !self.budget.binding(input) {
                            break;
                        }
                        let mut goals = goals.clone();
                        goals.push((goal.id.clone(), binding.clone()));
                        next.push(goals);
                    }
                }
                goals = next;
            }
            terminals.extend(goals.into_iter().map(ReturnPlan::Success));
        }
        if let Some(origin) = &self.state.pending_failure {
            for embedding in input
                .goal
                .failures
                .iter()
                .filter(|embedding| &embedding.origin == origin)
            {
                for value in self.bindings(&embedding.contract, &SourceConstraint::AnyCompatible) {
                    let terminal = ReturnPlan::Failure {
                        embedding: embedding.id.clone(),
                        value,
                    };
                    if check_return(self.prepared, self.state, &terminal).is_ok() {
                        terminals.push(terminal);
                    }
                }
            }
        }
        let mut choices = Vec::new();
        for site in &input.invocation_domain.sites {
            if self.state.used_sites.contains(&site.id)
                || input.explicit_order.iter().any(|(before, after)| {
                    after == &site.id && !self.state.used_sites.contains(before)
                })
            {
                continue;
            }
            let Some(function) = signature(input, &site.function) else {
                continue;
            };
            if function.handles_failure != self.state.pending_failure
                && !(function.handles_failure.is_none()
                    && !self
                        .state
                        .pending_failure
                        .as_ref()
                        .is_some_and(must_handle_failure))
            {
                continue;
            }
            let mut bindings = vec![Vec::new()];
            for port in &function.inputs {
                let options = self.bindings(&port.contract, &port.source_constraint);
                if options.is_empty() {
                    self.missing.push(MissingSupply {
                        site: Some(site.id.clone()),
                        port: port.id.0.clone(),
                        contract: port.contract.clone(),
                    });
                }
                let mut next = Vec::new();
                for bindings in bindings {
                    for option in &options {
                        if !self.budget.binding(input) {
                            break;
                        }
                        let mut bindings = bindings.clone();
                        bindings.push((port.id.clone(), option.clone()));
                        next.push(bindings);
                    }
                }
                bindings = next;
            }
            if bindings.is_empty() {
                continue;
            }
            let resources = self.resource_bindings(function);
            let outcomes: Vec<_> = function
                .outcomes
                .iter()
                .filter(|outcome| !outcome_empty(self.prepared, outcome))
                .map(|outcome| outcome.id.clone())
                .collect();
            let empty_outcomes = function
                .outcomes
                .iter()
                .filter(|outcome| outcome_empty(self.prepared, outcome))
                .map(|outcome| outcome.id.clone())
                .collect::<Vec<_>>();
            if outcomes.is_empty() {
                continue;
            }
            for bindings in bindings {
                for resources in &resources {
                    if !self.budget.binding(input) {
                        break;
                    }
                    let invocation = InvocationPlan {
                        site: site.id.clone(),
                        function: function.reference.clone(),
                        bindings: bindings.clone(),
                        resources: resources.clone(),
                    };
                    match check_invocation(self.prepared, self.state, &invocation) {
                        Ok(()) => choices.push(ChoiceSkeleton::Invoke {
                            invocation,
                            outcomes: outcomes.clone(),
                            empty_outcomes: empty_outcomes.clone(),
                        }),
                        Err(WitnessFailure::Inclusion(InclusionFailure::UndefinedMeaning(
                            reasons,
                        ))) => self.unknown.push(UnresolvedObligation::Meaning(reasons)),
                        _ => {}
                    }
                }
            }
        }
        for guard in &input.invocation_domain.guards {
            if self.state.used_guards.contains(&guard.id) {
                continue;
            }
            for source in self
                .state
                .available
                .iter()
                .filter(|source| source.contract.type_ref == guard.source_type)
            {
                if !self.budget.binding(input) {
                    break;
                }
                let inspected = ValueRef {
                    producer: source.producer.clone(),
                    path: guard.path.clone(),
                };
                match guard_arms(self.prepared, self.state, guard, &inspected) {
                    Ok(arms) if !arms.is_empty() => choices.push(ChoiceSkeleton::Guard {
                        guard: guard.id.clone(),
                        inspected,
                        arms,
                    }),
                    Err(WitnessFailure::ProjectionMismatch(
                        ProjectionFailure::UndefinedMeaning(reason),
                    )) => self
                        .unknown
                        .push(UnresolvedObligation::Meaning(vec![reason])),
                    Err(WitnessFailure::Inclusion(InclusionFailure::UndefinedMeaning(reasons))) => {
                        self.unknown.push(UnresolvedObligation::Meaning(reasons))
                    }
                    _ => {}
                }
            }
        }
        if self.budget.exhausted_bindings {
            self.unknown
                .push(UnresolvedObligation::BindingBoundExhausted);
        }
        Enumeration {
            terminals,
            choices,
            unknown: self.unknown,
            failures: self.failures,
            missing: self.missing,
        }
    }
}
pub fn enumerate_state(
    prepared: &PreparedCompositionInput<'_>,
    state: &SearchState,
    budget: &mut CandidateBudget,
) -> Enumeration {
    LocalEnumerator {
        prepared,
        state,
        budget,
        unknown: Vec::new(),
        failures: Vec::new(),
        missing: Vec::new(),
    }
    .enumerate()
}
pub fn choice_states(
    prepared: &PreparedCompositionInput<'_>,
    state: &SearchState,
    choice: &ChoiceSkeleton,
) -> Result<Vec<SearchState>, WitnessFailure> {
    match choice {
        ChoiceSkeleton::Invoke {
            invocation,
            outcomes,
            ..
        } => {
            check_invocation(prepared, state, invocation)?;
            let function = site_signature(prepared.input(), &invocation.site)
                .ok_or_else(|| WitnessFailure::SignatureMismatch(invocation.site.clone()))?;
            outcomes
                .iter()
                .map(|id| {
                    function
                        .outcomes
                        .iter()
                        .find(|outcome| outcome.id == *id)
                        .map(|outcome| after_invocation(state, invocation, outcome))
                        .ok_or_else(|| WitnessFailure::IncompleteBranchCoverage(id.0.clone()))
                })
                .collect()
        }
        ChoiceSkeleton::Guard {
            guard,
            inspected,
            arms,
        } => {
            let declaration = guard_declaration(prepared.input(), guard)
                .ok_or_else(|| WitnessFailure::GuardNotDominating(inspected.clone()))?;
            arms.iter()
                .map(|arm| after_guard(prepared, state, declaration, inspected, arm))
                .collect()
        }
    }
}

#[derive(Debug, Clone, PartialEq)]
pub enum TerminalAssessment {
    Feasible(ResourceTraceCertificate),
    ResourceUnreachable {
        trace: BranchTrace,
        lowering: resource::SolverInput,
        correspondence: ResourceCorrespondence,
        closure: resource::ClosureWitness,
    },
    RejectedLowering {
        trace: BranchTrace,
        reason: String,
    },
    EmptyValues(Vec<ProducerRef>),
    Unknown(Vec<UnresolvedObligation>),
}
#[derive(Debug, Clone, PartialEq)]
pub struct TerminalCoverage {
    pub terminal: ReturnPlan,
    pub assessment: TerminalAssessment,
}
#[derive(Debug, Clone, PartialEq)]
pub struct ChoiceCoverage {
    pub choice: ChoiceSkeleton,
    pub children: Vec<usize>,
}
#[derive(Debug, Clone, PartialEq)]
pub struct ClosedSearchState {
    pub state: SearchState,
    pub terminals: Vec<TerminalCoverage>,
    pub choices: Vec<ChoiceCoverage>,
    pub rejected_connections: Vec<ConnectionFailure>,
    pub missing_supply: Vec<MissingSupply>,
}
#[derive(Debug, Clone, PartialEq)]
pub struct CompositionClosureWitness {
    pub input_snapshot: CompositionInput,
    pub root: usize,
    pub states: Vec<ClosedSearchState>,
}
#[derive(Debug, Clone, PartialEq)]
pub enum SelectionEvidence {
    AnyFeasible,
    Unique {
        closure: Box<CompositionClosureWitness>,
        canonical_plan: String,
    },
}
#[derive(Debug)]
pub enum CompositionDecision<'p, 'g> {
    Solved(CheckedComposition<'p, 'g>, Arc<SelectionEvidence>),
    Unreachable(CompositionClosureWitness),
    Unknown {
        obligations: Vec<UnresolvedObligation>,
        frontier: Vec<SearchState>,
        rejected_connections: Vec<ConnectionFailure>,
    },
    Ambiguous {
        candidates: Vec<VerifiedCompositionCandidate<'p, 'g>>,
        canonical_plans: Vec<String>,
    },
}
impl<'p, 'g> CompositionDecision<'p, 'g> {
    pub fn decide_unreachable(
        prepared: &PreparedCompositionInput<'_>,
        closure: CompositionClosureWitness,
    ) -> Result<Self, CompositionEngineFailure> {
        verify_unreachable_composition(prepared, &closure)
            .map_err(CompositionEngineFailure::Witness)?;
        Ok(Self::Unreachable(closure))
    }
    pub fn decide_ambiguous(
        prepared: &'p PreparedCompositionInput<'g>,
        first: CandidateTree,
        second: CandidateTree,
    ) -> Result<Self, CompositionEngineFailure> {
        let membership = initial_membership(prepared)?;
        let mut candidates = Vec::new();
        let mut canonical_plans = Vec::new();
        for candidate in [first, second] {
            let key = candidate_key(prepared.input(), &candidate);
            let plan = CompositionPlan {
                input_identity: prepared.input().identity.clone(),
                input_revision: prepared.input().revision.clone(),
                root: candidate.tree,
            };
            let witness = CompositionWitness {
                input_snapshot: prepared.input().clone(),
                initial_membership: membership.clone(),
                resource_traces: candidate.certificates,
            };
            candidates.push(
                VerifiedCompositionCandidate::verify(prepared, plan, witness)
                    .map_err(CompositionEngineFailure::Witness)?,
            );
            canonical_plans.push(key);
        }
        if canonical_plans
            .windows(2)
            .any(|pair| pair.first() == pair.last())
        {
            return Err(CompositionEngineFailure::ContractViolation(
                "ambiguous candidates have the same canonical plan".to_owned(),
            ));
        }
        Ok(Self::Ambiguous {
            candidates,
            canonical_plans,
        })
    }
}
#[derive(Debug, Clone)]
pub struct CandidateTree {
    pub tree: PlanTree,
    pub node_count: usize,
    pub success: bool,
    pub certificates: Vec<ResourceTraceCertificate>,
}

pub fn resource_trace_meaning(
    prepared: &PreparedCompositionInput<'_>,
    correspondence: &ResourceCorrespondence,
) -> Result<(), UnresolvedObligation> {
    for lot in &correspondence.lots {
        let Some(declaration) = declared_lot(prepared.input(), &lot.lot) else {
            continue;
        };
        if let Err(reason) = validation::check_meaning_defined(
            prepared.graph(),
            std::slice::from_ref(&declaration.token_type),
        ) {
            let reasons = vec![reason];
            return Err(UnresolvedObligation::Meaning(reasons));
        }
        if lot.quantity.is_zero() {
            continue;
        }
        if sample_value_fuel(
            prepared.graph(),
            &prepared.input.bounds,
            prepared.input.bounds.max_type_obligations,
            &[],
            &declaration.token_type,
        )
        .values
        .is_empty()
        {
            return Err(UnresolvedObligation::Type {
                value: None,
                obligations: vec![TypeObligation {
                    source: declaration.token_type.clone(),
                    destination: declaration.token_type,
                    reason: TypeObligationReason::Inhabitation,
                }],
            });
        }
    }
    Ok(())
}
fn verify_trace_certificate(
    prepared: &PreparedCompositionInput<'_>,
    state: &SearchState,
    terminal: &ReturnPlan,
    certificate: &ResourceTraceCertificate,
) -> Result<(), WitnessFailure> {
    let trace = BranchTrace {
        steps: state.trace.clone(),
        terminal: terminal.clone(),
    };
    if certificate.trace != trace {
        return Err(WitnessFailure::ResourceLoweringMismatch(
            "branch trace differs".to_owned(),
        ));
    }
    verify_value_models(prepared, state, &certificate.value_sources)?;
    verify_return_values(prepared, terminal, &certificate.value_sources)?;
    let (lowering, correspondence) = lower_resource_trace(prepared, &trace)
        .map_err(|failure| WitnessFailure::ResourceLoweringMismatch(format!("{:?}", failure)))?;
    if certificate.lowering != lowering || certificate.correspondence != correspondence {
        return Err(WitnessFailure::ResourceLoweringMismatch(
            "solver input/correspondence differs".to_owned(),
        ));
    }
    resource_trace_meaning(prepared, &correspondence).map_err(|failure| {
        WitnessFailure::MissingEvidence(format!("resource meaning: {:?}", failure))
    })?;
    if certificate.reachability.path != correspondence.execution_order {
        return Err(WitnessFailure::ResourceReplayMismatch(
            "path does not execute the exact selected trace".to_owned(),
        ));
    }
    verify_reachability_witness(&lowering, &certificate.reachability)?;
    verify_acyclic_witness(&lowering, &certificate.acyclicity)?;
    Ok(())
}
fn verify_terminal_assessment(
    prepared: &PreparedCompositionInput<'_>,
    state: &SearchState,
    terminal: &ReturnPlan,
    assessment: &TerminalAssessment,
) -> Result<(), WitnessFailure> {
    check_return(prepared, state, terminal)?;
    let trace = BranchTrace {
        steps: state.trace.clone(),
        terminal: terminal.clone(),
    };
    match assessment {
        TerminalAssessment::Feasible(certificate) => {
            verify_trace_certificate(prepared, state, terminal, certificate)
        }
        TerminalAssessment::ResourceUnreachable {
            trace: supplied,
            lowering,
            correspondence,
            closure,
        } => {
            if *supplied != trace {
                return Err(WitnessFailure::ResourceLoweringMismatch(
                    "unreachable trace differs".to_owned(),
                ));
            }
            let computed = lower_resource_trace(prepared, &trace).map_err(|failure| {
                WitnessFailure::ResourceLoweringMismatch(format!("{:?}", failure))
            })?;
            if computed.0 != *lowering || computed.1 != *correspondence {
                return Err(WitnessFailure::ResourceLoweringMismatch(
                    "unreachable lowering differs".to_owned(),
                ));
            }
            verify_closure_witness(lowering, closure)?;
            Ok(())
        }
        TerminalAssessment::RejectedLowering {
            trace: supplied,
            reason,
        } => {
            if *supplied != trace {
                return Err(WitnessFailure::ResourceLoweringMismatch(
                    "rejected trace differs".to_owned(),
                ));
            }
            match lower_resource_trace(prepared, &trace) {
                Err(LoweringFailure::Invalid(actual)) if actual == *reason => Ok(()),
                _ => Err(WitnessFailure::ResourceLoweringMismatch(
                    "lowering rejection is forged".to_owned(),
                )),
            }
        }
        TerminalAssessment::EmptyValues(producers) => {
            let actual: Vec<_> = state
                .available
                .iter()
                .filter(|source| slot_empty(&source.contract, &prepared.empty))
                .map(|source| source.producer.clone())
                .collect();
            if actual.is_empty() || actual != *producers {
                return Err(WitnessFailure::MissingEvidence(
                    "empty source proof is forged".to_owned(),
                ));
            }
            Ok(())
        }
        TerminalAssessment::Unknown(_) => Err(WitnessFailure::ForgedClosure(
            "unresolved terminal in a closed witness".to_owned(),
        )),
    }
}
fn binding_key(binding: &BindingExpr) -> String {
    match binding {
        BindingExpr::Source { value, .. } => encode_tuple(&[
            "source",
            &producer_identity(&value.producer),
            &path_identity(&value.path),
        ]),
        BindingExpr::Product {
            construction,
            type_ref,
            fields,
        } => {
            let mut fields = fields
                .iter()
                .map(|(name, binding)| encode_tuple(&[name, &binding_key(binding)]))
                .collect::<Vec<_>>();
            fields.sort();
            encode_tuple(&[
                "construct",
                construction,
                &type_identity(type_ref),
                &encode_tuple(&fields.iter().map(String::as_str).collect::<Vec<_>>()),
            ])
        }
    }
}
fn invocation_key(invocation: &InvocationPlan) -> String {
    let mut bindings = invocation
        .bindings
        .iter()
        .map(|(port, binding)| encode_tuple(&[&port.0, &binding_key(binding)]))
        .collect::<Vec<_>>();
    bindings.sort();
    let mut resources = invocation
        .resources
        .iter()
        .map(|binding| encode_tuple(&[&binding.requirement.0, &lot_identity(&binding.lot)]))
        .collect::<Vec<_>>();
    resources.sort();
    encode_tuple(&[
        "invoke",
        &invocation.site.0,
        &function_identity(&invocation.function),
        &encode_tuple(&bindings.iter().map(String::as_str).collect::<Vec<_>>()),
        &encode_tuple(&resources.iter().map(String::as_str).collect::<Vec<_>>()),
    ])
}
fn return_key(terminal: &ReturnPlan) -> String {
    match terminal {
        ReturnPlan::Success(outputs) => {
            let mut outputs = outputs
                .iter()
                .map(|(id, binding)| encode_tuple(&[&id.0, &binding_key(binding)]))
                .collect::<Vec<_>>();
            outputs.sort();
            encode_tuple(&[
                "success",
                &encode_tuple(&outputs.iter().map(String::as_str).collect::<Vec<_>>()),
            ])
        }
        ReturnPlan::Failure { embedding, value } => {
            encode_tuple(&["failure", &embedding.0, &binding_key(value)])
        }
    }
}
fn order_free(input: &CompositionInput, invocation: &InvocationPlan) -> bool {
    signature(input, &invocation.function).is_some_and(|function| {
        function.effect == CompositionEffect::PureFunction
            && function
                .resource_inputs
                .iter()
                .all(|requirement| requirement.mode == resource::BindingMode::Read)
            && matches!(
                function.outcomes.as_slice(),
                [outcome]
                    if outcome.form == OutcomeForm::Success
                        && outcome.produced_resources.is_empty()
            )
    })
}
fn canonical_trace(input: &CompositionInput, trace: &BranchTrace) -> String {
    let mut parts = Vec::new();
    let mut unordered = Vec::new();
    fn flush(unordered: &mut Vec<String>, parts: &mut Vec<String>) {
        unordered.sort();
        parts.append(unordered);
    }
    for step in &trace.steps {
        match step {
            TraceStep::Invocation {
                invocation,
                outcome,
            } if order_free(input, invocation) => {
                unordered.push(encode_tuple(&[&invocation_key(invocation), &outcome.0]))
            }
            TraceStep::Invocation {
                invocation,
                outcome,
            } => {
                flush(&mut unordered, &mut parts);
                parts.push(encode_tuple(&[&invocation_key(invocation), &outcome.0]));
            }
            TraceStep::Guard {
                guard,
                inspected,
                arm,
            } => {
                flush(&mut unordered, &mut parts);
                parts.push(encode_tuple(&[
                    "guard",
                    &guard.0,
                    &producer_identity(&inspected.producer),
                    &path_identity(&inspected.path),
                    &guard_arm_identity(arm),
                ]));
            }
        }
    }
    flush(&mut unordered, &mut parts);
    parts.push(return_key(&trace.terminal));
    encode_tuple(&parts.iter().map(String::as_str).collect::<Vec<_>>())
}
pub fn candidate_key(input: &CompositionInput, candidate: &CandidateTree) -> String {
    let mut branches = candidate
        .certificates
        .iter()
        .map(|certificate| canonical_trace(input, &certificate.trace))
        .collect::<Vec<_>>();
    branches.sort();
    encode_tuple(&branches.iter().map(String::as_str).collect::<Vec<_>>())
}
pub fn merge_choice(
    input: &CompositionInput,
    state: &SearchState,
    choice: &ChoiceSkeleton,
    children: &[Vec<CandidateTree>],
    budget: &mut CandidateBudget,
) -> Vec<CandidateTree> {
    if children.is_empty() || children.iter().any(Vec::is_empty) {
        return Vec::new();
    }
    let mut products: Vec<(usize, Vec<CandidateTree>)> = vec![(1, Vec::new())];
    for candidates in children {
        let mut next = Vec::new();
        for (node_count, prefix) in products {
            for candidate in candidates {
                let Some(node_count) = node_count
                    .checked_add(candidate.node_count)
                    .filter(|count| *count <= input.bounds.max_branch_nodes)
                else {
                    budget.exhausted_branches = true;
                    continue;
                };
                if budget.branch_nodes >= input.bounds.max_branch_nodes {
                    budget.exhausted_branches = true;
                    break;
                }
                budget.branch_nodes += 1;
                let mut product = prefix.clone();
                product.push(candidate.clone());
                next.push((node_count, product));
            }
        }
        products = next;
        if products.is_empty() {
            break;
        }
    }
    let mut result = Vec::new();
    let mut seen = HashSet::new();
    for (node_count, product) in products {
        let success = product.iter().any(|candidate| candidate.success);
        let certificates = product
            .iter()
            .flat_map(|candidate| candidate.certificates.iter().cloned())
            .collect();
        let node = match choice {
            ChoiceSkeleton::Invoke {
                invocation,
                outcomes,
                empty_outcomes,
            } => PlanNode::Invoke {
                invocation: invocation.clone(),
                arms: outcomes
                    .iter()
                    .cloned()
                    .zip(product.into_iter().map(|candidate| candidate.tree))
                    .collect(),
                empty_outcomes: empty_outcomes.clone(),
            },
            ChoiceSkeleton::Guard {
                guard,
                inspected,
                arms,
            } => PlanNode::Guard {
                guard: guard.clone(),
                inspected: inspected.clone(),
                arms: arms
                    .iter()
                    .cloned()
                    .zip(product.into_iter().map(|candidate| candidate.tree))
                    .collect(),
            },
        };
        let candidate = CandidateTree {
            tree: PlanTree {
                rank: state.trace.len(),
                node,
            },
            node_count,
            success,
            certificates,
        };
        if seen.insert(candidate_key(input, &candidate)) {
            result.push(candidate);
        }
    }
    result
}
#[derive(Debug)]
pub struct VerifiedCompositionCandidate<'p, 'g> {
    prepared: &'p PreparedCompositionInput<'g>,
    plan: CompositionPlan,
    witness: CompositionWitness,
}
impl<'p, 'g> VerifiedCompositionCandidate<'p, 'g> {
    pub fn verify(
        prepared: &'p PreparedCompositionInput<'g>,
        plan: CompositionPlan,
        witness: CompositionWitness,
    ) -> Result<Self, WitnessFailure> {
        check_candidate(prepared, &plan, &witness)?;
        Ok(Self {
            prepared,
            plan,
            witness,
        })
    }
    pub fn prepared(&self) -> &'p PreparedCompositionInput<'g> {
        self.prepared
    }
    pub fn plan(&self) -> &CompositionPlan {
        &self.plan
    }
    pub fn witness(&self) -> &CompositionWitness {
        &self.witness
    }
}
#[derive(Debug)]
pub struct CheckedCompositionClosure<'a> {
    witness: &'a CompositionClosureWitness,
    canonical_plans: Vec<String>,
}
impl CheckedCompositionClosure<'_> {
    pub fn witness(&self) -> &CompositionClosureWitness {
        self.witness
    }
    pub fn canonical_plans(&self) -> &[String] {
        &self.canonical_plans
    }
    pub fn goal_unreachable(&self) -> bool {
        self.canonical_plans.is_empty()
    }
}
fn replay_closed_candidates(
    prepared: &PreparedCompositionInput<'_>,
    witness: &CompositionClosureWitness,
    index: usize,
    memo: &mut [Option<Vec<CandidateTree>>],
    active: &mut HashSet<usize>,
    budget: &mut CandidateBudget,
) -> Result<Vec<CandidateTree>, WitnessFailure> {
    if let Some(candidates) = memo.get(index).and_then(Option::as_ref) {
        return Ok(candidates.clone());
    }
    if !active.insert(index) {
        return Err(WitnessFailure::ForgedClosure(
            "cyclic finite invocation search graph".to_owned(),
        ));
    }
    let record = witness
        .states
        .get(index)
        .ok_or_else(|| WitnessFailure::ForgedClosure("missing search state".to_owned()))?;
    let mut candidates = Vec::new();
    for terminal in &record.terminals {
        if let TerminalAssessment::Feasible(certificate) = &terminal.assessment {
            if prepared.input.bounds.max_branch_nodes == 0 {
                return Err(WitnessFailure::ForgedClosure(
                    "terminal evidence exceeds branch-node bound".to_owned(),
                ));
            }
            candidates.push(CandidateTree {
                tree: PlanTree {
                    rank: record.state.trace.len(),
                    node: PlanNode::Return(terminal.terminal.clone()),
                },
                node_count: 1,
                success: matches!(terminal.terminal, ReturnPlan::Success(_)),
                certificates: vec![certificate.clone()],
            });
        }
    }
    for choice in &record.choices {
        let children = choice
            .children
            .iter()
            .map(|index| replay_closed_candidates(prepared, witness, *index, memo, active, budget))
            .collect::<Result<Vec<_>, _>>()?;
        candidates.extend(merge_choice(
            prepared.input(),
            &record.state,
            &choice.choice,
            &children,
            budget,
        ));
        if budget.exhausted_branches {
            return Err(WitnessFailure::ForgedClosure(
                "branch evidence exceeds bound".to_owned(),
            ));
        }
    }
    let mut seen = HashSet::new();
    candidates.retain(|candidate| seen.insert(candidate_key(prepared.input(), candidate)));
    active.remove(&index);
    if let Some(slot) = memo.get_mut(index) {
        *slot = Some(candidates.clone());
    }
    Ok(candidates)
}
pub fn verify_composition_closure<'a>(
    prepared: &PreparedCompositionInput<'_>,
    witness: &'a CompositionClosureWitness,
) -> Result<CheckedCompositionClosure<'a>, WitnessFailure> {
    if witness.input_snapshot != *prepared.input() {
        return Err(WitnessFailure::InputRevisionMismatch);
    }
    if !prepared.initial_obligations.is_empty() {
        return Err(WitnessFailure::ForgedClosure(
            "initial supplied values still have semantic obligations".to_owned(),
        ));
    }
    if witness.states.get(witness.root).map(|record| &record.state)
        != Some(&initial_state(prepared))
    {
        return Err(WitnessFailure::ForgedClosure(
            "initial search state missing".to_owned(),
        ));
    }
    let mut reached = HashSet::new();
    let mut pending = vec![witness.root];
    while let Some(index) = pending.pop() {
        if !reached.insert(index) {
            continue;
        }
        let record = witness
            .states
            .get(index)
            .ok_or_else(|| WitnessFailure::ForgedClosure("search successor missing".to_owned()))?;
        pending.extend(
            record
                .choices
                .iter()
                .flat_map(|choice| &choice.children)
                .copied(),
        );
    }
    if reached.len() != witness.states.len() {
        return Err(WitnessFailure::ForgedClosure(
            "extraneous search state".to_owned(),
        ));
    }
    let mut budget = CandidateBudget::new();
    let mut expanded = 0usize;
    for (index, record) in witness.states.iter().enumerate() {
        if witness
            .states
            .iter()
            .take(index)
            .any(|previous| previous.state == record.state)
        {
            return Err(WitnessFailure::ForgedClosure(
                "duplicate search state".to_owned(),
            ));
        }
        let expected = enumerate_state(prepared, &record.state, &mut budget);
        if !expected.unknown.is_empty() || budget.exhausted_bindings {
            return Err(WitnessFailure::ForgedClosure(
                "unresolved type/binding frontier".to_owned(),
            ));
        }
        if !same_key_multiset(
            record
                .terminals
                .iter()
                .map(|coverage| return_key(&coverage.terminal))
                .collect(),
            expected.terminals.iter().map(return_key).collect(),
        ) || !same_key_multiset(
            record
                .choices
                .iter()
                .map(|coverage| choice_key(&coverage.choice))
                .collect(),
            expected.choices.iter().map(choice_key).collect(),
        ) {
            return Err(WitnessFailure::ForgedClosure(
                "terminal or enabled successor coverage differs".to_owned(),
            ));
        }
        if record.rejected_connections != expected.failures
            || record.missing_supply != expected.missing
        {
            return Err(WitnessFailure::ForgedClosure(
                "source counterexamples or missing supplies differ".to_owned(),
            ));
        }
        for failure in &record.rejected_connections {
            verify_counterexample(prepared.graph(), &failure.counterexample)
                .map_err(WitnessFailure::Inclusion)?;
        }
        for terminal in &record.terminals {
            verify_terminal_assessment(
                prepared,
                &record.state,
                &terminal.terminal,
                &terminal.assessment,
            )?;
        }
        if !record.choices.is_empty() {
            expanded += 1;
        }
        for choice in &record.choices {
            let children = choice_states(prepared, &record.state, &choice.choice)?;
            if children.len() != choice.children.len() {
                return Err(WitnessFailure::ForgedClosure(
                    "outcome/guard successors omitted".to_owned(),
                ));
            }
            for (child, index) in children.iter().zip(&choice.children) {
                if !witness
                    .states
                    .get(*index)
                    .is_some_and(|record| same_search_state(prepared, &record.state, child))
                    || child.trace.len() <= record.state.trace.len()
                {
                    return Err(WitnessFailure::ForgedClosure(
                        "source, branch, rank or resource state differs".to_owned(),
                    ));
                }
            }
        }
    }
    if expanded > prepared.input.bounds.max_expanded_states {
        return Err(WitnessFailure::ForgedClosure(
            "state bound exceeded".to_owned(),
        ));
    }
    let candidates = replay_closed_candidates(
        prepared,
        witness,
        witness.root,
        &mut vec![None; witness.states.len()],
        &mut HashSet::new(),
        &mut budget,
    )?;
    let canonical_plans = candidates
        .iter()
        .filter(|candidate| candidate.success)
        .map(|candidate| candidate_key(prepared.input(), candidate))
        .collect();
    Ok(CheckedCompositionClosure {
        witness,
        canonical_plans,
    })
}
pub fn verify_unreachable_composition(
    prepared: &PreparedCompositionInput<'_>,
    witness: &CompositionClosureWitness,
) -> Result<(), WitnessFailure> {
    let checked = verify_composition_closure(prepared, witness)?;
    if !checked.goal_unreachable() {
        return Err(WitnessFailure::ForgedClosure(
            "closed domain contains a complete success plan".to_owned(),
        ));
    }
    Ok(())
}
fn verify_initial_membership(
    prepared: &PreparedCompositionInput<'_>,
    witness: &CompositionWitness,
) -> Result<(), WitnessFailure> {
    if witness.input_snapshot != *prepared.input() {
        return Err(WitnessFailure::InputRevisionMismatch);
    }
    if witness.initial_membership.len() != prepared.input.initial_inputs.len() {
        return Err(WitnessFailure::MissingEvidence(
            "initial input coverage".to_owned(),
        ));
    }
    for initial in &prepared.input.initial_inputs {
        let values: Vec<_> = witness
            .initial_membership
            .iter()
            .filter(|(id, _)| *id == initial.id)
            .collect();
        let value = match values.as_slice() {
            [(_, value)]
                if matches!(
                    validation::accepts_slot(
                        prepared.graph(),
                        &initial.contract,
                        borrowed_slot(value)
                    ),
                    ValueDecision::Accepted
                ) =>
            {
                value
            }
            _ => return Err(WitnessFailure::InitialMembership(initial.id.clone())),
        };
        if let InitialSource::SuppliedValue(supplied) = &initial.source {
            if supplied != value {
                return Err(WitnessFailure::InitialMembership(initial.id.clone()));
            }
        }
    }
    Ok(())
}
fn verify_plan_tree(
    prepared: &PreparedCompositionInput<'_>,
    state: &SearchState,
    tree: &PlanTree,
    parent_rank: Option<usize>,
    witness: &CompositionWitness,
    used_certificates: &mut HashSet<usize>,
    nodes: &mut usize,
) -> Result<bool, WitnessFailure> {
    *nodes += 1;
    if *nodes > prepared.input.bounds.max_branch_nodes {
        return Err(WitnessFailure::RankViolation);
    }
    if parent_rank.is_some_and(|rank| tree.rank <= rank) {
        return Err(WitnessFailure::RankViolation);
    }
    match &tree.node {
        PlanNode::Return(terminal) => {
            let success = check_return(prepared, state, terminal)?;
            let trace = BranchTrace {
                steps: state.trace.clone(),
                terminal: terminal.clone(),
            };
            let certificates: Vec<_> = witness
                .resource_traces
                .iter()
                .enumerate()
                .filter(|(_, certificate)| certificate.trace == trace)
                .collect();
            let [(index, certificate)] = certificates.as_slice() else {
                return Err(WitnessFailure::MissingEvidence(
                    "exact resource/producer certificate for branch".to_owned(),
                ));
            };
            let (index, certificate) = (*index, *certificate);
            used_certificates.insert(index);
            verify_trace_certificate(prepared, state, terminal, certificate)?;
            Ok(success)
        }
        PlanNode::Invoke {
            invocation,
            arms,
            empty_outcomes,
        } => {
            check_invocation(prepared, state, invocation)?;
            let function = site_signature(prepared.input(), &invocation.site)
                .ok_or_else(|| WitnessFailure::SignatureMismatch(invocation.site.clone()))?;
            let expected = function
                .outcomes
                .iter()
                .filter(|outcome| !outcome_empty(prepared, outcome))
                .map(|outcome| &outcome.id)
                .collect::<Vec<_>>();
            let empty = function
                .outcomes
                .iter()
                .filter(|outcome| outcome_empty(prepared, outcome))
                .map(|outcome| &outcome.id)
                .collect::<Vec<_>>();
            if !same_key_multiset(
                arms.iter().map(|(id, _)| id.0.clone()).collect(),
                expected.iter().map(|id| id.0.clone()).collect(),
            ) || !same_key_multiset(
                empty_outcomes.iter().map(|id| id.0.clone()).collect(),
                empty.iter().map(|id| id.0.clone()).collect(),
            ) || arms.is_empty()
            {
                return Err(WitnessFailure::IncompleteBranchCoverage(
                    invocation.site.0.clone(),
                ));
            }
            let mut success = false;
            for (id, child) in arms {
                let outcome = function
                    .outcomes
                    .iter()
                    .find(|outcome| outcome.id == *id)
                    .ok_or_else(|| WitnessFailure::IncompleteBranchCoverage(id.0.clone()))?;
                let next = after_invocation(state, invocation, outcome);
                success |= verify_plan_tree(
                    prepared,
                    &next,
                    child,
                    Some(tree.rank),
                    witness,
                    used_certificates,
                    nodes,
                )?;
            }
            Ok(success)
        }
        PlanNode::Guard {
            guard,
            inspected,
            arms,
        } => {
            let declaration = guard_declaration(prepared.input(), guard)
                .ok_or_else(|| WitnessFailure::GuardNotDominating(inspected.clone()))?;
            let expected = guard_arms(prepared, state, declaration, inspected)?;
            if !same_key_multiset(
                arms.iter()
                    .map(|(arm, _)| guard_arm_identity(arm))
                    .collect(),
                expected.iter().map(guard_arm_identity).collect(),
            ) || arms.is_empty()
            {
                return Err(WitnessFailure::IncompleteBranchCoverage(guard.0.clone()));
            }
            let mut success = false;
            for (arm, child) in arms {
                let next = after_guard(prepared, state, declaration, inspected, arm)?;
                success |= verify_plan_tree(
                    prepared,
                    &next,
                    child,
                    Some(tree.rank),
                    witness,
                    used_certificates,
                    nodes,
                )?;
            }
            Ok(success)
        }
    }
}
fn check_candidate(
    prepared: &PreparedCompositionInput<'_>,
    plan: &CompositionPlan,
    witness: &CompositionWitness,
) -> Result<(), WitnessFailure> {
    if plan.input_identity != prepared.input.identity
        || plan.input_revision != prepared.input.revision
    {
        return Err(WitnessFailure::InputRevisionMismatch);
    }
    verify_initial_membership(prepared, witness)?;
    let mut used = HashSet::new();
    if !verify_plan_tree(
        prepared,
        &initial_state(prepared),
        &plan.root,
        None,
        witness,
        &mut used,
        &mut 0usize,
    )? {
        return Err(WitnessFailure::GoalMismatch);
    }
    if used.len() != witness.resource_traces.len() {
        return Err(WitnessFailure::MissingEvidence(
            "extraneous resource/producer branch evidence".to_owned(),
        ));
    }
    Ok(())
}
fn raw_candidate_key(input: &CompositionInput, raw: &RawComposition) -> String {
    let mut branches = raw
        .witness
        .resource_traces
        .iter()
        .map(|certificate| canonical_trace(input, &certificate.trace))
        .collect::<Vec<_>>();
    branches.sort();
    encode_tuple(&branches.iter().map(String::as_str).collect::<Vec<_>>())
}
pub fn verify_composition<'p, 'g>(
    prepared: &'p PreparedCompositionInput<'g>,
    raw: &RawComposition,
) -> Result<CheckedComposition<'p, 'g>, WitnessFailure> {
    check_candidate(prepared, &raw.plan, &raw.witness)?;
    let key = raw_candidate_key(prepared.input(), raw);
    match raw.selection.as_ref() {
        SelectionEvidence::AnyFeasible
            if prepared.input.selection_policy == Some(SelectionPolicy::AnyFeasible) => {}
        SelectionEvidence::Unique {
            closure,
            canonical_plan,
        } if prepared.input.selection_policy != Some(SelectionPolicy::AnyFeasible) => {
            let checked = verify_composition_closure(prepared, closure)?;
            if checked.canonical_plans.as_slice() != std::slice::from_ref(&key)
                || *canonical_plan != key
            {
                return Err(WitnessFailure::MissingEvidence(
                    "unique selection is not established by the finite closed domain".to_owned(),
                ));
            }
        }
        _ => {
            return Err(WitnessFailure::MissingEvidence(
                "selection evidence disagrees with caller policy".to_owned(),
            ))
        }
    }
    Ok(CheckedComposition {
        prepared,
        raw: raw.clone(),
    })
}
pub fn initial_membership(
    prepared: &PreparedCompositionInput<'_>,
) -> Result<Vec<(InputId, SlotValue)>, CompositionEngineFailure> {
    let mut result = Vec::new();
    for initial in &prepared.input.initial_inputs {
        let value = match &initial.source {
            InitialSource::SuppliedValue(value) => value.clone(),
            InitialSource::Argument => {
                match find_accepted_slot_candidate(
                    prepared.graph(),
                    &prepared.input.bounds,
                    &initial.contract,
                    |_, _| SlotCandidateControl::Accept,
                ) {
                    SlotCandidateSearch::AcceptedWithinBound(value)
                    | SlotCandidateSearch::AcceptedBeyondSampleBound(value) => value,
                    SlotCandidateSearch::NoEvidence => {
                        return Err(CompositionEngineFailure::ContractViolation(
                            "feasible branch omitted initial inhabitation".to_owned(),
                        ));
                    }
                }
            }
        };
        result.push((initial.id.clone(), value));
    }
    Ok(result)
}
fn slots_disjoint(
    graph: &SemanticGraph,
    source: &SlotContract,
    destination: &SlotContract,
    _empty: &[TypeRef],
) -> bool {
    let bounds = SearchBounds::default();
    let source_samples = slot_samples(graph, &bounds, source);
    let destination_samples = slot_samples(graph, &bounds, destination);
    let source_rejected = source_samples.values.iter().all(|value| {
        matches!(
            accepts_slot(graph, destination, borrowed_slot(value)),
            ValueDecision::Rejected(_)
        )
    });
    let destination_rejected = destination_samples.values.iter().all(|value| {
        matches!(
            accepts_slot(graph, source, borrowed_slot(value)),
            ValueDecision::Rejected(_)
        )
    });
    !source_samples.values.is_empty()
        && !destination_samples.values.is_empty()
        && source_rejected
        && destination_rejected
}

pub const DEFAULT_RESOURCE_TOKEN_BOUND: usize = 100_000;

fn path_identity(path: &[PathStep]) -> String {
    let steps = path
        .iter()
        .map(|step| match step {
            PathStep::Field(name) => encode_tuple(&["field", name]),
            PathStep::Index(index) => encode_tuple(&["index", &index.to_string()]),
            PathStep::Variant(tag) => encode_tuple(&["variant", tag]),
        })
        .collect::<Vec<_>>();
    encode_tuple(&steps.iter().map(String::as_str).collect::<Vec<_>>())
}
fn guard_arm_identity(arm: &GuardArm) -> String {
    match arm {
        GuardArm::Present => encode_tuple(&["present"]),
        GuardArm::Absent => encode_tuple(&["absent"]),
        GuardArm::Null => encode_tuple(&["null"]),
        GuardArm::Variant(tag) => encode_tuple(&["variant", tag]),
        GuardArm::UnknownVariant => encode_tuple(&["unknown-variant"]),
        GuardArm::Accepted => encode_tuple(&["accepted"]),
        GuardArm::Rejected => encode_tuple(&["rejected"]),
    }
}

fn same_key_multiset(mut left: Vec<String>, mut right: Vec<String>) -> bool {
    left.sort();
    right.sort();
    left == right
}
fn choice_key(choice: &ChoiceSkeleton) -> String {
    match choice {
        ChoiceSkeleton::Invoke {
            invocation,
            outcomes,
            empty_outcomes,
        } => {
            let mut outcomes = outcomes.iter().map(|id| id.0.as_str()).collect::<Vec<_>>();
            outcomes.sort();
            let mut empty = empty_outcomes
                .iter()
                .map(|id| id.0.as_str())
                .collect::<Vec<_>>();
            empty.sort();
            encode_tuple(&[
                "invocation-choice",
                &invocation_key(invocation),
                &encode_tuple(&outcomes),
                &encode_tuple(&empty),
            ])
        }
        ChoiceSkeleton::Guard {
            guard,
            inspected,
            arms,
        } => {
            let mut arms = arms.iter().map(guard_arm_identity).collect::<Vec<_>>();
            arms.sort();
            encode_tuple(&[
                "guard-choice",
                &guard.0,
                &producer_identity(&inspected.producer),
                &path_identity(&inspected.path),
                &encode_tuple(&arms.iter().map(String::as_str).collect::<Vec<_>>()),
            ])
        }
    }
}
fn trace_step_key(step: &TraceStep) -> String {
    match step {
        TraceStep::Invocation {
            invocation,
            outcome,
        } => encode_tuple(&["invoke", &invocation_key(invocation), &outcome.0]),
        TraceStep::Guard {
            guard,
            inspected,
            arm,
        } => encode_tuple(&[
            "guard",
            &guard.0,
            &producer_identity(&inspected.producer),
            &path_identity(&inspected.path),
            &guard_arm_identity(arm),
        ]),
    }
}
fn same_search_state(
    prepared: &PreparedCompositionInput<'_>,
    actual: &SearchState,
    expected: &SearchState,
) -> bool {
    if actual == expected {
        return true;
    }
    if actual.available != expected.available
        || actual.used_sites != expected.used_sites
        || actual.used_guards != expected.used_guards
        || actual.facts != expected.facts
        || actual.pending_failure != expected.pending_failure
        || actual.trace.len() != expected.trace.len()
        || !actual
            .trace
            .iter()
            .zip(&expected.trace)
            .all(|(actual, expected)| trace_step_key(actual) == trace_step_key(expected))
    {
        return false;
    }
    let mut replay = initial_state(prepared);
    for step in &actual.trace {
        match step {
            TraceStep::Invocation {
                invocation,
                outcome,
            } => {
                if check_invocation(prepared, &replay, invocation).is_err() {
                    return false;
                }
                let Some(outcome) =
                    site_signature(prepared.input(), &invocation.site).and_then(|signature| {
                        signature
                            .outcomes
                            .iter()
                            .find(|candidate| candidate.id == *outcome)
                    })
                else {
                    return false;
                };
                replay = after_invocation(&replay, invocation, outcome);
            }
            TraceStep::Guard {
                guard,
                inspected,
                arm,
            } => {
                let Some(declaration) = guard_declaration(prepared.input(), guard) else {
                    return false;
                };
                if !guard_arms(prepared, &replay, declaration, inspected)
                    .is_ok_and(|arms| arms.contains(arm))
                {
                    return false;
                }
                let Ok(next) = after_guard(prepared, &replay, declaration, inspected, arm) else {
                    return false;
                };
                replay = next;
            }
        }
    }
    replay == *actual
}
