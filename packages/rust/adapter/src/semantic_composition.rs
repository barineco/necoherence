// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

use crate::core::Nat;
use crate::exact_json_view::JsonValueView;
use crate::inclusion::{
    destination_rejection, integer_rule_check, lower_contained_nat, obligation,
    product_field_pairs, product_rule_shape_check, rule_u_child_pairs, rule_u_coverage,
    string_rule_check, type_pair, upper_contained_nat, verify_counterexample_in,
    verify_inclusion_in,
};
use crate::semantic_expansion::accepts_view_in;
use crate::semantic_prepared_validation::{PreparedMetadata, PreparedProfile};
use crate::semantic_types::*;
use crate::semantic_validation::{
    self as validation, recognize_format, select_union_branch_view, BorrowedValueDecision,
    FormatWorkspace, PreparedValidator,
};
use crate::type_signatures::LibraryCheckFailure;
use crate::typed_mapping as resource;
use num_bigint::{BigInt, BigUint};
use num_traits::{ToPrimitive, Zero};
use std::collections::{HashMap, HashSet, VecDeque};
use std::sync::Arc;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SemanticBasis {
    pub profile: VersionedSemanticProfile,
    pub sources: Vec<SourceRef>,
}
impl SemanticBasis {
    pub fn of(graph: &SemanticGraph) -> Self {
        Self {
            profile: graph.profile().clone(),
            sources: graph.source_refs.clone(),
        }
    }
    pub(crate) fn matches(&self, graph: &SemanticGraph) -> bool {
        self.profile == *graph.profile() && self.sources == graph.source_refs
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
pub struct TypePair {
    pub source: SlotContract,
    pub destination: SlotContract,
    pub source_tag: Option<String>,
}
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum InclusionRule {
    SameDefinedType,
    EmptySource,
    Boolean,
    IntegerIntersection,
    FiniteStrings,
    StringConditions,
    BytesLength,
    Unit,
    UnfoldSource,
    UnfoldDestination,
    Array,
    Product,
    SourceUnion,
    DestinationUnion,
}
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PairEntry {
    pub pair: TypePair,
    pub source_shape: TypeShape,
    pub destination_shape: TypeShape,
    pub rule: InclusionRule,
    pub children: Vec<BigUint>,
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
    pub pair: TypePair,
    pub path: ValuePath,
    pub reason: TypeObligationReason,
}
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct InclusionCertificate {
    pub basis: SemanticBasis,
    pub source: SlotContract,
    pub destination: SlotContract,
    pub empty_types: Vec<TypeRef>,
    pub pairs: Vec<PairEntry>,
    pub root: BigUint,
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
    pub max_expanded_states: BigUint,
    pub max_binding_candidates: BigUint,
    pub max_type_obligations: BigUint,
    pub max_branch_nodes: BigUint,
    pub resource_bounds: Option<ResourceBounds>,
    pub max_sample_length: BigUint,
}
fn limit_of(bound: &BigUint) -> usize {
    bound.to_usize().unwrap_or(usize::MAX)
}
impl SearchBounds {
    pub fn expanded_state_limit(&self) -> usize {
        limit_of(&self.max_expanded_states)
    }
    pub fn binding_candidate_limit(&self) -> usize {
        limit_of(&self.max_binding_candidates)
    }
    pub fn type_obligation_limit(&self) -> usize {
        limit_of(&self.max_type_obligations)
    }
    pub fn branch_node_limit(&self) -> usize {
        limit_of(&self.max_branch_nodes)
    }
    pub fn sample_length_limit(&self) -> usize {
        limit_of(&self.max_sample_length)
    }
}
impl Default for SearchBounds {
    fn default() -> Self {
        Self {
            max_expanded_states: BigUint::from(10_000u32),
            max_binding_candidates: BigUint::from(100_000u32),
            max_type_obligations: BigUint::from(10_000u32),
            max_branch_nodes: BigUint::from(100_000u32),
            resource_bounds: None,
            max_sample_length: BigUint::from(32u8),
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
pub fn resolved_shape<'g>(graph: &'g SemanticGraph, reference: &TypeRef) -> Option<&'g TypeShape> {
    let mut current: &TypeRef = reference;
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
fn string_finite(spec: &StringSpec) -> Option<Vec<String>> {
    spec.const_value
        .as_ref()
        .map(|value| vec![value.clone()])
        .or_else(|| spec.enum_values.clone())
}
fn nat_range_empty(
    minimum: &Option<num_bigint::BigUint>,
    maximum: &Option<num_bigint::BigUint>,
) -> bool {
    minimum
        .as_ref()
        .zip(maximum.as_ref())
        .is_some_and(|(minimum, maximum)| maximum < minimum)
}
fn check_empty_row(
    graph: &SemanticGraph,
    refs: &HashSet<TypeRef>,
    reference: &TypeRef,
) -> Result<(), InclusionFailure> {
    let node = graph
        .find_type(reference)
        .ok_or(InclusionFailure::ForgedEmptiness)?;
    match &node.shape {
        TypeShape::Alias { target, .. } if refs.contains(target) => Ok(()),
        TypeShape::String(spec)
            if spec.wrapper.is_none()
                && string_finite(spec).is_some_and(|values| {
                    values.iter().all(|value| {
                        validation::string_condition(&graph.profile, spec, value).is_some()
                    })
                }) =>
        {
            Ok(())
        }
        TypeShape::Bytes(spec) if nat_range_empty(&spec.minimum, &spec.maximum) => Ok(()),
        TypeShape::Product(spec)
            if spec.fields.iter().any(|field| {
                field.slot.required && !field.slot.nullable && refs.contains(&field.slot.type_ref)
            }) =>
        {
            Ok(())
        }
        TypeShape::Array(spec)
            if nat_range_empty(&spec.min_length, &spec.max_length)
                || spec
                    .min_length
                    .as_ref()
                    .is_some_and(|minimum| !minimum.is_zero())
                    && !spec.item.nullable
                    && refs.contains(&spec.item.type_ref) =>
        {
            Ok(())
        }
        TypeShape::TaggedUnion(spec)
            if spec
                .branches
                .iter()
                .all(|branch| refs.contains(&branch.target)) =>
        {
            Ok(())
        }
        _ => Err(InclusionFailure::ForgedEmptiness),
    }
}
pub fn distinct<T: Clone + Eq + std::hash::Hash>(items: impl IntoIterator<Item = T>) -> Vec<T> {
    let mut seen = HashSet::new();
    items
        .into_iter()
        .filter(|item| seen.insert(item.clone()))
        .collect()
}
fn prune_empty_types(
    graph: &SemanticGraph,
    mut fuel: usize,
    mut refs: Vec<TypeRef>,
) -> Vec<TypeRef> {
    while fuel > 0 {
        fuel -= 1;
        let set = refs.iter().cloned().collect::<HashSet<_>>();
        let retained = refs
            .iter()
            .filter(|reference| check_empty_row(graph, &set, reference).is_ok())
            .cloned()
            .collect::<Vec<_>>();
        if retained.len() == refs.len() {
            return retained;
        }
        refs = retained;
    }
    refs
}
fn empty_types(graph: &SemanticGraph) -> Vec<TypeRef> {
    prune_empty_types(
        graph,
        graph.nodes.len() + 1,
        distinct(graph.nodes.iter().map(|node| node.reference.clone())),
    )
}
pub fn slot_empty(slot: &SlotContract, empty: &[TypeRef]) -> bool {
    slot.required && !slot.nullable && empty.contains(&slot.type_ref)
}
#[derive(Debug, Clone, PartialEq)]
pub enum InclusionFailure {
    BasisMismatch,
    ContractMismatch,
    UndefinedMeaning(Vec<SemanticObligation>),
    MissingPair,
    PairMismatch(usize),
    RuleMismatch(usize),
    ChildCoverage(usize),
    ForgedEmptiness,
    CounterexampleMismatch,
    Unresolved(TypeObligation),
}
#[derive(Debug)]
pub struct CheckedEmptyTypes<'g> {
    graph: &'g SemanticGraph,
    pub(crate) refs: Vec<TypeRef>,
}
impl CheckedEmptyTypes<'_> {
    pub fn graph(&self) -> &SemanticGraph {
        self.graph
    }
    pub fn refs(&self) -> &[TypeRef] {
        &self.refs
    }
}
pub fn verify_empty_types<'g>(
    graph: &'g SemanticGraph,
    refs: &[TypeRef],
) -> Result<CheckedEmptyTypes<'g>, InclusionFailure> {
    let set = refs.iter().cloned().collect::<HashSet<_>>();
    if set.len() != refs.len() {
        return Err(InclusionFailure::ForgedEmptiness);
    }
    for reference in refs {
        check_empty_row(graph, &set, reference)?;
    }
    Ok(CheckedEmptyTypes {
        graph,
        refs: refs.to_vec(),
    })
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
    pub source_refs: Vec<SourceRef>,
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
    VariantSelectionUndetermined { path: ValuePath, tag: String },
    Unresolved(Vec<SemanticObligation>),
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
    metadata: &PreparedMetadata<'_>,
    source: &SlotContract,
    path: &[PathStep],
    assumptions: &[ProjectionAssumption],
) -> Result<ProjectionCertificate, ProjectionFailure> {
    let graph = metadata.graph();
    let obligations = metadata.meaning_obligations(std::slice::from_ref(&source.type_ref));
    if !obligations.is_empty() {
        return Err(ProjectionFailure::Unresolved(obligations));
    }
    let fuel = (path.len() + 1) * (graph.nodes.len() + 1);
    let destination = project_contract(metadata, assumptions, fuel, source.clone(), &[], path)?;
    let destination_obligations =
        metadata.meaning_obligations(std::slice::from_ref(&destination.type_ref));
    if !destination_obligations.is_empty() {
        return Err(ProjectionFailure::Unresolved(destination_obligations));
    }
    Ok(ProjectionCertificate {
        profile: graph.profile.reference.clone(),
        source_refs: graph.source_refs.clone(),
        source: source.clone(),
        path: path.to_vec(),
        assumptions: assumptions.to_vec(),
        destination,
    })
}

fn project_contract(
    metadata: &PreparedMetadata<'_>,
    assumptions: &[ProjectionAssumption],
    fuel: usize,
    mut slot: SlotContract,
    traversed: &[PathStep],
    remaining: &[PathStep],
) -> Result<SlotContract, ProjectionFailure> {
    let graph = metadata.graph();
    let Some(fuel) = fuel.checked_sub(1) else {
        return Err(ProjectionFailure::Unresolved(vec![projection_obligation(
            graph,
            &slot.type_ref,
            traversed,
            SemanticReason::MembershipBound,
        )]));
    };
    strengthen_projection(&mut slot, traversed, assumptions);
    let Some((step, rest)) = remaining.split_first() else {
        return Ok(slot);
    };
    let Some(node) = metadata
        .node_index(&slot.type_ref)
        .and_then(|position| graph.nodes.get(position))
    else {
        return Err(ProjectionFailure::Unresolved(vec![projection_obligation(
            graph,
            &slot.type_ref,
            traversed,
            SemanticReason::UnresolvedType,
        )]));
    };
    if let (TypeShape::Alias { target, .. }, _) = (&node.shape, step) {
        let aliased = SlotContract {
            type_ref: target.clone(),
            ..slot
        };
        return project_contract(metadata, assumptions, fuel, aliased, traversed, remaining);
    }
    let next = match (&node.shape, step) {
        (TypeShape::Product(spec), PathStep::Field(name)) => {
            let field = spec
                .fields
                .iter()
                .find(|field| field.wire_name == *name)
                .ok_or_else(|| ProjectionFailure::MissingField {
                    type_ref: slot.type_ref.clone(),
                    name: name.clone(),
                })?;
            SlotContract {
                type_ref: field.slot.type_ref.clone(),
                required: slot.required && field.slot.required,
                nullable: slot.nullable || field.slot.nullable,
            }
        }
        (TypeShape::Array(spec), PathStep::Index(index)) => {
            let indexed = spec
                .min_length
                .as_ref()
                .is_some_and(|minimum| index < minimum)
                || assumptions.iter().any(|assumption| {
                    matches!(
                        assumption,
                        ProjectionAssumption::IndexPresent { path, index: actual }
                            if path == traversed && actual == index
                    )
                });
            SlotContract {
                type_ref: spec.item.type_ref.clone(),
                required: slot.required && indexed,
                nullable: true,
            }
        }
        (TypeShape::TaggedUnion(spec), PathStep::Variant(tag)) => {
            let assumed = assumptions.iter().any(|assumption| {
                matches!(
                    assumption,
                    ProjectionAssumption::Variant { path, tag: actual }
                        if path == traversed && actual == tag
                )
            });
            if !assumed {
                return Err(ProjectionFailure::BranchAssumptionRequired {
                    path: traversed.to_vec(),
                    tag: tag.clone(),
                });
            }
            let branch = spec
                .branches
                .iter()
                .find(|branch| branch.wire_tag == *tag)
                .ok_or_else(|| ProjectionFailure::MissingVariant {
                    type_ref: slot.type_ref.clone(),
                    tag: tag.clone(),
                })?;
            if graph.profile.tag.is_none()
                || projectable_tag_branch(&spec.branches, tag) != Some(branch)
            {
                return Err(ProjectionFailure::VariantSelectionUndetermined {
                    path: traversed.to_vec(),
                    tag: tag.clone(),
                });
            }
            SlotContract {
                type_ref: branch.target.clone(),
                required: slot.required,
                nullable: slot.nullable,
            }
        }
        _ => {
            return Err(ProjectionFailure::WrongShape {
                type_ref: slot.type_ref.clone(),
                path: traversed.to_vec(),
            })
        }
    };
    let mut next_traversed = traversed.to_vec();
    next_traversed.push(step.clone());
    project_contract(metadata, assumptions, fuel, next, &next_traversed, rest)
}

fn projection_obligation(
    graph: &SemanticGraph,
    reference: &TypeRef,
    path: &[PathStep],
    reason: SemanticReason,
) -> SemanticObligation {
    SemanticObligation {
        type_ref: reference.clone(),
        origin: reference.into(),
        value_path: path.to_vec(),
        profile: graph.profile.reference.clone(),
        reason,
    }
}

fn projectable_tag_branch<'a>(branches: &'a [UnionBranch], tag: &str) -> Option<&'a UnionBranch> {
    for branch in branches {
        if branch.wire_tag == tag {
            return (branch.selector == BranchSelector::InternalTag).then_some(branch);
        }
        if !selector_precedes_internal_tag(branch, tag) {
            return None;
        }
    }
    None
}

fn selector_precedes_internal_tag(branch: &UnionBranch, tag: &str) -> bool {
    match &branch.selector {
        BranchSelector::InternalTag => branch.wire_tag != tag,
        BranchSelector::Kind(kind) => *kind != ValueKind::Object,
        BranchSelector::MemberShape(_) | BranchSelector::Otherwise => false,
    }
}
pub fn check_projection_certificate(
    metadata: &PreparedMetadata<'_>,
    certificate: &ProjectionCertificate,
) -> Result<(), ProjectionFailure> {
    let graph = metadata.graph();
    if certificate.profile != graph.profile.reference
        || certificate.source_refs != graph.source_refs
    {
        return Err(ProjectionFailure::CertificateMismatch(
            "profile or source revisions".into(),
        ));
    }
    if project_slot(
        metadata,
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
pub fn project_value_view<'a>(
    profile: &VersionedSemanticProfile,
    value: SlotValue<JsonValueView<'a>>,
    path: &[PathStep],
) -> SlotValue<JsonValueView<'a>> {
    match value {
        SlotValue::Absent => SlotValue::Absent,
        SlotValue::Null => SlotValue::Null,
        SlotValue::Present(value) => value_at_path(profile, value, path),
    }
}
fn value_at_path<'a>(
    profile: &VersionedSemanticProfile,
    value: JsonValueView<'a>,
    path: &[PathStep],
) -> SlotValue<JsonValueView<'a>> {
    let Some((step, rest)) = path.split_first() else {
        return SlotValue::Present(value);
    };
    if value.kind() == ValueKind::Null {
        return SlotValue::Null;
    }
    let next = match step {
        PathStep::Field(name) => match value.member(name) {
            Some(next) => next,
            None => return SlotValue::Absent,
        },
        PathStep::Index(index) => {
            let Some(items) = value.as_array() else {
                return SlotValue::Absent;
            };
            match index.to_usize().and_then(|i| items.get(i)) {
                Some(item) => JsonValueView::from_json(item),
                None => return SlotValue::Absent,
            }
        }
        PathStep::Variant(tag) => {
            if !variant_tag_matches(profile, value, tag) {
                return SlotValue::Absent;
            }
            return value_at_path(profile, value, rest);
        }
    };
    if next.kind() == ValueKind::Null {
        return SlotValue::Null;
    }
    value_at_path(profile, next, rest)
}
fn variant_tag_matches(
    profile: &VersionedSemanticProfile,
    value: JsonValueView<'_>,
    tag: &str,
) -> bool {
    match profile.tag.as_ref() {
        None => false,
        Some(model) => value
            .member(&model.key)
            .and_then(JsonValueView::as_str)
            .is_some_and(|actual| actual == tag),
    }
}

struct DescribedPair {
    entry: PairEntry,
    children: Vec<(TypeRef, TypeRef)>,
}
fn describe_pair(
    validator: &mut PreparedValidator<'_>,
    graph: &SemanticGraph,
    empty: &HashSet<TypeRef>,
    source: &TypeRef,
    destination: &TypeRef,
) -> Result<DescribedPair, TypeObligation> {
    let source_shape = graph
        .find_type(source)
        .map(|node| node.shape.clone())
        .ok_or_else(|| {
            obligation(
                source.clone(),
                destination.clone(),
                TypeObligationReason::Meaning(
                    validator.meaning_obligations(std::slice::from_ref(source)),
                ),
            )
        })?;
    let destination_shape = graph
        .find_type(destination)
        .map(|node| node.shape.clone())
        .ok_or_else(|| {
            obligation(
                source.clone(),
                destination.clone(),
                TypeObligationReason::Meaning(
                    validator.meaning_obligations(std::slice::from_ref(destination)),
                ),
            )
        })?;
    let row = |rule, children| DescribedPair {
        entry: PairEntry {
            pair: type_pair(source.clone(), destination.clone()),
            source_shape: source_shape.clone(),
            destination_shape: destination_shape.clone(),
            rule,
            children: vec![],
        },
        children,
    };
    if empty.contains(source) {
        return Ok(row(InclusionRule::EmptySource, vec![]));
    }
    if source_shape == destination_shape {
        return Ok(row(InclusionRule::SameDefinedType, vec![]));
    }
    match (&source_shape, &destination_shape) {
        (TypeShape::Alias { target, .. }, _) => Ok(row(
            InclusionRule::UnfoldSource,
            vec![(target.clone(), destination.clone())],
        )),
        (_, TypeShape::Alias { target, .. }) => Ok(row(
            InclusionRule::UnfoldDestination,
            vec![(source.clone(), target.clone())],
        )),
        (TypeShape::Boolean(source_spec), TypeShape::Boolean(destination_spec))
            if destination_spec.const_value.is_none()
                || source_spec.const_value == destination_spec.const_value =>
        {
            Ok(row(InclusionRule::Boolean, vec![]))
        }
        (TypeShape::Integer(source_spec), TypeShape::Integer(destination_spec))
            if integer_rule_check(
                validator,
                graph,
                source,
                destination,
                source_spec,
                destination_spec,
            ) =>
        {
            Ok(row(InclusionRule::IntegerIntersection, vec![]))
        }
        (TypeShape::String(source_spec), TypeShape::String(destination_spec))
            if string_rule_check(source_spec, destination_spec) =>
        {
            Ok(row(InclusionRule::StringConditions, vec![]))
        }
        (TypeShape::Array(source_spec), TypeShape::Array(destination_spec))
            if lower_contained_nat(&source_spec.min_length, &destination_spec.min_length)
                && upper_contained_nat(&source_spec.max_length, &destination_spec.max_length)
                && (!source_spec.item.nullable || destination_spec.item.nullable) =>
        {
            Ok(row(
                InclusionRule::Array,
                vec![(
                    source_spec.item.type_ref.clone(),
                    destination_spec.item.type_ref.clone(),
                )],
            ))
        }
        (TypeShape::Product(source_spec), TypeShape::Product(destination_spec))
            if product_rule_shape_check(validator, graph, source_spec, destination_spec) =>
        {
            Ok(row(
                InclusionRule::Product,
                product_field_pairs(graph, source_spec, destination_spec),
            ))
        }
        (TypeShape::Product(_), TypeShape::Product(_)) => Err(obligation(
            source.clone(),
            destination.clone(),
            TypeObligationReason::Presence,
        )),
        (TypeShape::TaggedUnion(source_spec), TypeShape::TaggedUnion(destination_spec)) => {
            if !rule_u_coverage(source_spec, destination_spec) {
                return Err(obligation(
                    source.clone(),
                    destination.clone(),
                    TypeObligationReason::UnionRemainder,
                ));
            }
            Ok(row(
                InclusionRule::SourceUnion,
                rule_u_child_pairs(source_spec, destination_spec),
            ))
        }
        _ => Err(obligation(
            source.clone(),
            destination.clone(),
            TypeObligationReason::ConstraintImplication,
        )),
    }
}
fn inclusion_table(
    validator: &mut PreparedValidator<'_>,
    graph: &SemanticGraph,
    empty_refs: &[TypeRef],
    maximum: usize,
    source: &TypeRef,
    destination: &TypeRef,
) -> Result<Vec<PairEntry>, TypeObligation> {
    let empty = empty_refs.iter().cloned().collect::<HashSet<_>>();
    let mut pending = VecDeque::from([(source.clone(), destination.clone())]);
    let mut seen = HashSet::new();
    let mut rows = vec![];
    for _ in 0..maximum {
        let Some((source, destination)) = pending.pop_front() else {
            break;
        };
        if !seen.insert((source.clone(), destination.clone())) {
            continue;
        }
        let described = describe_pair(validator, graph, &empty, &source, &destination)?;
        for child in described.children.iter().rev() {
            pending.push_front(child.clone());
        }
        rows.push(described);
    }
    if let Some((source, destination)) = pending.front() {
        return Err(obligation(
            source.clone(),
            destination.clone(),
            TypeObligationReason::ObligationBoundExhausted,
        ));
    }
    let indexes = rows
        .iter()
        .enumerate()
        .map(|(index, row)| {
            (
                (
                    row.entry.pair.source.type_ref.clone(),
                    row.entry.pair.destination.type_ref.clone(),
                ),
                index,
            )
        })
        .collect::<HashMap<_, _>>();
    let mut entries = Vec::with_capacity(rows.len());
    for mut row in rows {
        let mut children = Vec::with_capacity(row.children.len());
        for pair in &row.children {
            let Some(index) = indexes.get(pair) else {
                return Err(obligation(
                    row.entry.pair.source.type_ref.clone(),
                    row.entry.pair.destination.type_ref.clone(),
                    TypeObligationReason::ObligationBoundExhausted,
                ));
            };
            children.push(BigUint::from(*index));
        }
        row.entry.children = children;
        entries.push(row.entry);
    }
    Ok(entries)
}
fn structural_assignable(
    validator: &mut PreparedValidator<'_>,
    graph: &SemanticGraph,
    empty_refs: &[TypeRef],
    source: &SlotContract,
    destination: &SlotContract,
    maximum: usize,
) -> CompatibilityDecision {
    let table = match inclusion_table(
        validator,
        graph,
        empty_refs,
        maximum,
        &source.type_ref,
        &destination.type_ref,
    ) {
        Ok(table) => table,
        Err(obligation) => return CompatibilityDecision::Unknown(vec![obligation]),
    };
    let certificate = InclusionCertificate {
        basis: SemanticBasis::of(graph),
        source: source.clone(),
        destination: destination.clone(),
        empty_types: empty_refs.to_vec(),
        pairs: table,
        root: BigUint::zero(),
    };
    match verify_inclusion_in(validator, graph, source, destination, &certificate).map(|_| ()) {
        Ok(()) => CompatibilityDecision::Compatible(certificate),
        Err(InclusionFailure::UndefinedMeaning(obligations)) => {
            CompatibilityDecision::Unknown(vec![obligation(
                source.type_ref.clone(),
                destination.type_ref.clone(),
                TypeObligationReason::Meaning(obligations),
            )])
        }
        Err(InclusionFailure::Unresolved(obligation)) => {
            CompatibilityDecision::Unknown(vec![obligation])
        }
        Err(_) => CompatibilityDecision::Unknown(vec![obligation(
            source.type_ref.clone(),
            destination.type_ref.clone(),
            TypeObligationReason::ConstraintImplication,
        )]),
    }
}
pub fn check_assignable(
    graph: &SemanticGraph,
    source: &SlotContract,
    destination: &SlotContract,
    max: usize,
) -> CompatibilityDecision {
    check_assignable_bounded(
        graph,
        source,
        destination,
        &SearchBounds {
            max_type_obligations: BigUint::from(max),
            max_sample_length: BigUint::from(32u8),
            ..SearchBounds::default()
        },
    )
}

pub fn check_assignable_bounded(
    graph: &SemanticGraph,
    source: &SlotContract,
    destination: &SlotContract,
    bounds: &SearchBounds,
) -> CompatibilityDecision {
    check_assignable_with_empty(
        &mut PreparedValidator::new(graph, FormatWorkspace::empty()),
        &empty_types(graph),
        source,
        destination,
        bounds,
    )
}
pub fn check_assignable_with_empty(
    validator: &mut PreparedValidator<'_>,
    empty: &[TypeRef],
    source: &SlotContract,
    destination: &SlotContract,
    bounds: &SearchBounds,
) -> CompatibilityDecision {
    let graph = validator.graph();
    let structural = structural_assignable(
        validator,
        graph,
        empty,
        source,
        destination,
        bounds.type_obligation_limit(),
    );
    if !matches!(&structural, CompatibilityDecision::Unknown(_)) {
        return structural;
    }
    let prepared =
        inclusion_samples_with(validator, &source.type_ref, &destination.type_ref, bounds);
    let samples = (!source.required)
        .then_some(SlotValue::Absent)
        .into_iter()
        .chain(source.nullable.then_some(SlotValue::Null))
        .chain(prepared.values.into_iter().map(SlotValue::Present));
    for value in samples {
        let Some(destination_failure) = destination_rejection(validator, destination, &value)
        else {
            continue;
        };
        let certificate = CounterexampleCertificate {
            basis: SemanticBasis::of(graph),
            source: source.clone(),
            destination: destination.clone(),
            value,
            destination_failure,
        };
        if verify_counterexample_in(validator, graph, source, destination, &certificate).is_ok() {
            return CompatibilityDecision::Incompatible(certificate);
        }
    }
    structural
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

pub fn find_accepted_slot_candidate(
    validator: &mut PreparedValidator<'_>,
    bounds: &SearchBounds,
    contract: &SlotContract,
    mut inspect: impl FnMut(&SlotValue, bool) -> SlotCandidateControl,
) -> SlotCandidateSearch {
    let fuel = bounds
        .type_obligation_limit()
        .min(validator.graph().nodes.len() + 1);
    let candidates = sample_candidates_with(validator, fuel, &[], &contract.type_ref);
    for value in slot_values(validator, contract, candidates) {
        let within_bound = match &value {
            SlotValue::Present(sample) => sample_within_bound(bounds.sample_length_limit(), sample),
            SlotValue::Absent | SlotValue::Null => true,
        };
        match inspect(&value, within_bound) {
            SlotCandidateControl::Accept if within_bound => {
                return SlotCandidateSearch::AcceptedWithinBound(value);
            }
            SlotCandidateControl::Accept => {
                return SlotCandidateSearch::AcceptedBeyondSampleBound(value);
            }
            SlotCandidateControl::Continue => {}
            SlotCandidateControl::StopNoEvidence => return SlotCandidateSearch::NoEvidence,
        }
    }
    SlotCandidateSearch::NoEvidence
}
fn format_samples(
    profile: &VersionedSemanticProfile,
    format: Option<&str>,
    limit: usize,
) -> Vec<String> {
    format
        .and_then(|name| profile.format(name))
        .map(|binding| {
            format_rule_samples_fuel(
                limit,
                profile.grapheme_rules.as_ref(),
                binding.rule.depth(),
                &binding.rule,
            )
        })
        .unwrap_or_default()
}
pub fn format_use_samples(
    profile: &VersionedSemanticProfile,
    format: &Option<FormatUse>,
    limit: usize,
) -> Vec<String> {
    match format {
        None => vec!["x".to_owned()],
        Some(FormatUse::Named(name)) => format_samples(profile, Some(name.as_str()), limit),
        Some(FormatUse::Inline(rule)) => {
            format_rule_samples_fuel(limit, profile.grapheme_rules.as_ref(), rule.depth(), rule)
        }
    }
}
fn format_rule_samples_fuel(
    limit: usize,
    graphemes: Option<&GraphemeRules>,
    fuel: usize,
    rule: &FormatRule,
) -> Vec<String> {
    if fuel == 0 {
        return vec![];
    }
    let inner = fuel - 1;
    let candidates = match rule {
        FormatRule::Literal(value) => vec![value.clone()],
        FormatRule::Sequence(parts) => sequence_samples(
            limit,
            parts
                .iter()
                .map(|part| format_rule_samples_fuel(limit, graphemes, inner, part))
                .collect(),
        ),
        FormatRule::Optional(part) => std::iter::once(String::new())
            .chain(format_rule_samples_fuel(limit, graphemes, inner, part))
            .collect(),
        FormatRule::Choice(branches) => branches
            .iter()
            .flat_map(|branch| format_rule_samples_fuel(limit, graphemes, inner, branch))
            .collect(),
        FormatRule::Labels {
            separator,
            min_count,
            rule: part,
            ..
        } => {
            let copies = min_count.to_usize().unwrap_or(0).max(1);
            format_rule_samples_fuel(limit, graphemes, inner, part)
                .into_iter()
                .map(|sample| vec![sample; copies].join(separator.as_str()))
                .collect()
        }
        FormatRule::Bounded { rule: part, .. } => {
            format_rule_samples_fuel(limit, graphemes, inner, part)
        }
        FormatRule::AsciiDfa(spec) => dfa_shortest_word(spec).into_iter().collect(),
        FormatRule::Identifier {
            first_alphabet,
            rest_alphabet,
            exact_length,
            min_length,
            forbidden,
            ..
        } => identifier_sample(
            first_alphabet,
            rest_alphabet,
            exact_length.as_ref(),
            min_length,
            forbidden.len(),
            |text| recognize_format(rule, graphemes, text),
        )
        .into_iter()
        .collect(),
        FormatRule::Timestamp(calendar) => vec![timestamp_sample(calendar)],
        FormatRule::AbsoluteUri { .. } => ["a:", "a:b"]
            .into_iter()
            .find(|text| recognize_format(rule, graphemes, text))
            .map(str::to_owned)
            .into_iter()
            .collect(),
        FormatRule::LanguageTag { .. } => vec!["aa".to_owned()],
        FormatRule::Text => vec![String::new(), "a".to_owned()],
        FormatRule::Not(child) => {
            let excluded = format_rule_samples_fuel(limit, graphemes, inner, child);
            let mut candidates = vec![String::new(), "a".to_owned(), "aa".to_owned()];
            candidates.extend(excluded.iter().cloned());
            candidates.extend(excluded.iter().map(|text| format!("{text}x")));
            candidates
        }
    };
    candidates
        .into_iter()
        .filter(|text| recognize_format(rule, graphemes, text))
        .take(limit)
        .collect()
}
fn sequence_samples(limit: usize, parts: Vec<Vec<String>>) -> Vec<String> {
    let Some(heads) = parts
        .iter()
        .map(|part| part.first().cloned())
        .collect::<Option<Vec<String>>>()
    else {
        return vec![];
    };
    let mut samples = vec![heads.concat()];
    for (index, part) in parts.iter().enumerate() {
        for sample in part.iter().skip(1) {
            let mut varied = heads.clone();
            if let Some(slot) = varied.get_mut(index) {
                *slot = sample.clone();
            }
            samples.push(varied.concat());
        }
    }
    samples.truncate(limit);
    samples
}
fn dfa_shortest_word(spec: &DfaSpec) -> Option<String> {
    let mut fuel = spec
        .state_count
        .to_usize()
        .unwrap_or(usize::MAX)
        .saturating_add(1);
    let mut frontier: Vec<(BigUint, Vec<char>)> = vec![(spec.initial_state.clone(), vec![])];
    let mut visited = vec![spec.initial_state.clone()];
    while fuel > 0 {
        fuel -= 1;
        if let Some((_, path)) = frontier
            .iter()
            .find(|(state, _)| spec.accepting_states.contains(state))
        {
            return Some(path.iter().collect());
        }
        let mut fresh: Vec<(BigUint, Vec<char>)> = Vec::new();
        for (state, path) in &frontier {
            for transition in spec
                .transitions
                .iter()
                .filter(|transition| transition.from_state == *state)
            {
                if visited.contains(&transition.to_state)
                    || fresh.iter().any(|(next, _)| *next == transition.to_state)
                {
                    continue;
                }
                let character = transition
                    .first
                    .to_u32()
                    .and_then(char::from_u32)
                    .unwrap_or('\0');
                let mut next_path = path.clone();
                next_path.push(character);
                fresh.push((transition.to_state.clone(), next_path));
            }
        }
        if fresh.is_empty() {
            return None;
        }
        visited.extend(fresh.iter().map(|(state, _)| state.clone()));
        frontier = fresh;
    }
    None
}
fn identifier_sample(
    first: &str,
    rest: &str,
    exact_length: Option<&BigUint>,
    minimum: &BigUint,
    forbidden: usize,
    accepts: impl Fn(&str) -> bool,
) -> Option<String> {
    let lengths: Vec<usize> = match exact_length {
        Some(length) => vec![length.to_usize()?],
        None => {
            let minimum = minimum.to_usize()?.max(1);
            (0..=forbidden).map(|extra| minimum + extra).collect()
        }
    };
    lengths
        .into_iter()
        .flat_map(|length| {
            first.chars().flat_map(move |head| {
                if length == 1 {
                    vec![head.to_string()]
                } else {
                    rest.chars()
                        .map(move |tail| {
                            std::iter::once(head)
                                .chain(std::iter::repeat_n(tail, length.saturating_sub(1)))
                                .collect()
                        })
                        .collect()
                }
            })
        })
        .find(|text| accepts(text.as_str()))
}
fn timestamp_sample(calendar: &CalendarRule) -> String {
    let year = calendar.minimum_year.to_string();
    format!(
        "{}{year}-01-01T00:00:00Z",
        "0".repeat(4usize.saturating_sub(year.len()))
    )
}
pub fn sample_value_candidates_fuel(
    graph: &SemanticGraph,
    fuel: usize,
    seen: &[TypeRef],
    reference: &TypeRef,
) -> Vec<JsonValue> {
    if fuel == 0 || seen.contains(reference) || graph.find_type(reference).is_none() {
        return vec![];
    }
    sample_candidates_with(
        &PreparedValidator::new(graph, FormatWorkspace::empty()),
        fuel,
        seen,
        reference,
    )
}
fn sample_candidates_with(
    validator: &PreparedValidator<'_>,
    fuel: usize,
    seen: &[TypeRef],
    reference: &TypeRef,
) -> Vec<JsonValue> {
    if fuel == 0 || seen.contains(reference) || validator.graph().find_type(reference).is_none() {
        return vec![];
    }
    sample_candidates_in(
        validator.metadata(),
        fuel,
        &SampleSeen {
            listed: seen,
            visited: None,
        },
        reference,
    )
}
struct SampleSeen<'s> {
    listed: &'s [TypeRef],
    visited: Option<(&'s TypeRef, &'s SampleSeen<'s>)>,
}
impl SampleSeen<'_> {
    fn contains(&self, reference: &TypeRef) -> bool {
        let mut current = self;
        while let Some((visited, rest)) = current.visited {
            if visited == reference {
                return true;
            }
            current = rest;
        }
        current.listed.contains(reference)
    }
}
fn sample_candidates_in(
    metadata: &PreparedMetadata<'_>,
    fuel: usize,
    seen: &SampleSeen<'_>,
    reference: &TypeRef,
) -> Vec<JsonValue> {
    let graph = metadata.graph();
    if fuel == 0 || seen.contains(reference) {
        return vec![];
    }
    let Some(node) = metadata
        .node_index(reference)
        .and_then(|position| graph.nodes.get(position))
    else {
        return vec![];
    };
    let inner = fuel - 1;
    let child_seen = SampleSeen {
        listed: seen.listed,
        visited: Some((reference, seen)),
    };
    let recurse = |target: &TypeRef| sample_candidates_in(metadata, inner, &child_seen, target);
    let candidates = match &node.shape {
        TypeShape::Boolean(spec) => match spec.const_value {
            Some(value) => vec![JsonValue::Bool(value)],
            None => vec![JsonValue::Bool(false), JsonValue::Bool(true)],
        },
        TypeShape::Integer(spec) => integer_candidates(graph, spec),
        TypeShape::Decimal(spec) => decimal_candidates(spec),
        TypeShape::String(spec) => string_candidates(graph, spec, fuel),
        TypeShape::Bytes(spec) => {
            let lengths: Vec<usize> = spec
                .minimum
                .iter()
                .chain(spec.maximum.iter())
                .filter_map(ToPrimitive::to_usize)
                .chain([0, 1])
                .collect();
            bytes_sample_values(graph, &lengths)
        }
        TypeShape::RawBody { .. } => bytes_sample_values(graph, &[0, 1]),
        TypeShape::Sealed { tag, refinements } => sealed_candidates(graph, tag, refinements),
        TypeShape::Never | TypeShape::Opaque { .. } => vec![],
        TypeShape::Unit => vec![JsonValue::Null],
        TypeShape::Unknown(_) => vec![
            JsonValue::Obj(vec![]),
            JsonValue::Null,
            JsonValue::Bool(false),
            JsonValue::Num(BigInt::zero()),
            JsonValue::Str(String::new()),
            JsonValue::Arr(vec![]),
        ],
        TypeShape::Alias { target, .. } => recurse(target),
        TypeShape::Array(spec) => array_candidates(spec, &recurse),
        TypeShape::Product(spec) => product_candidates(graph, spec, fuel, &recurse),
        TypeShape::TaggedUnion(spec) => tagged_union_candidates(graph, spec, &recurse),
    };
    candidates
        .into_iter()
        .filter(|value| accepts_view_in(metadata, reference, JsonValueView::from_json(value)))
        .collect()
}
fn integer_candidates(graph: &SemanticGraph, spec: &IntegerSpec) -> Vec<JsonValue> {
    let Some(binding) = graph.profile.integer_domain(spec.domain.as_deref()) else {
        return vec![];
    };
    let domain = match &binding.range {
        IntegerDomain::Inclusive { minimum, maximum } => vec![minimum.clone(), maximum.clone()],
        IntegerDomain::Unbounded => vec![],
    };
    let values: Vec<BigInt> = spec
        .const_value
        .iter()
        .cloned()
        .chain(spec.enum_values.iter().flatten().cloned())
        .chain(spec.minimum.iter().cloned())
        .chain(spec.maximum.iter().cloned())
        .chain(domain)
        .chain([0, 1, -1].map(BigInt::from))
        .collect();
    binding
        .forms
        .iter()
        .flat_map(|form| values.iter().map(move |value| integer_sample(*form, value)))
        .collect()
}
fn integer_sample(form: IntegerForm, value: &BigInt) -> JsonValue {
    match form {
        IntegerForm::Number => JsonValue::Num(value.clone()),
        IntegerForm::IntegralDecimal => JsonValue::Dec(value.to_string()),
        IntegerForm::DecimalString => JsonValue::Str(value.to_string()),
    }
}
fn decimal_candidates(spec: &DecimalSpec) -> Vec<JsonValue> {
    spec.minimum
        .iter()
        .chain(spec.maximum.iter())
        .map(|bound| JsonValue::Dec(format!("{}e-{}", bound.mantissa, bound.scale)))
        .chain([
            JsonValue::Dec("0.0".into()),
            JsonValue::Dec("1.0".into()),
            JsonValue::Dec("-1.0".into()),
        ])
        .collect()
}
fn string_candidates(graph: &SemanticGraph, spec: &StringSpec, limit: usize) -> Vec<JsonValue> {
    let lengths: Vec<usize> = spec
        .lengths
        .iter()
        .flat_map(|bound| bound.minimum.iter().chain(bound.maximum.iter()))
        .filter_map(ToPrimitive::to_usize)
        .collect();
    let texts: Vec<String> = spec
        .const_value
        .iter()
        .cloned()
        .chain(spec.enum_values.iter().flatten().cloned())
        .chain(spec.examples.iter().cloned())
        .chain(format_use_samples(&graph.profile, &spec.format, limit))
        .chain(["".to_owned(), "a".to_owned()])
        .chain(lengths.into_iter().map(|length| "a".repeat(length)))
        .collect();
    match &spec.wrapper {
        None => texts.into_iter().map(JsonValue::Str).collect(),
        Some(name) => match graph
            .profile
            .wrappers
            .iter()
            .find(|wrapper| wrapper.name == *name)
        {
            None => vec![],
            Some(wrapper) => texts
                .into_iter()
                .map(|text| JsonValue::Obj(vec![(wrapper.key.clone(), JsonValue::Str(text))]))
                .collect(),
        },
    }
}
fn bytes_sample_values(graph: &SemanticGraph, lengths: &[usize]) -> Vec<JsonValue> {
    let Some(policy) = graph.profile.bytes_policy.as_ref() else {
        return vec![];
    };
    let (quad, one, two) = match policy.alphabet {
        BytesAlphabet::UrlSafe => ("____", "_w==", "__8="),
        BytesAlphabet::Standard | BytesAlphabet::Either => ("////", "/w==", "//8="),
    };
    let wire = |length: usize| {
        format!(
            "{}{}",
            quad.repeat(length / 3),
            match length % 3 {
                1 => one,
                2 => two,
                _ => "",
            }
        )
    };
    match &policy.wrapper {
        None => lengths
            .iter()
            .map(|&length| JsonValue::Str(wire(length)))
            .collect(),
        Some(name) => match graph
            .profile
            .wrappers
            .iter()
            .find(|wrapper| wrapper.name == *name)
        {
            None => vec![],
            Some(wrapper) => lengths
                .iter()
                .map(|&length| {
                    JsonValue::Obj(vec![(wrapper.key.clone(), JsonValue::Str(wire(length)))])
                })
                .collect(),
        },
    }
}
fn sealed_candidates(
    graph: &SemanticGraph,
    tag: &str,
    refinements: &[SealedRefinement],
) -> Vec<JsonValue> {
    let Some(model) = graph.profile.tag.as_ref() else {
        return vec![];
    };
    let Some(form) = model.sealed.iter().find(|form| form.tag == tag) else {
        return vec![];
    };
    let fields: Option<Vec<(String, JsonValue)>> = form
        .fields
        .iter()
        .filter(|field| field.required)
        .map(|field| {
            let leaf = refinements
                .iter()
                .find(|refinement| refinement.key == field.key)
                .map_or(&field.leaf, |refinement| &refinement.leaf);
            sealed_field_sample(graph, leaf).map(|value| (field.key.clone(), value))
        })
        .collect();
    match fields {
        None => vec![],
        Some(fields) => vec![JsonValue::Obj(
            std::iter::once((model.key.clone(), JsonValue::Str(form.tag.clone())))
                .chain(fields)
                .collect(),
        )],
    }
}
fn sealed_field_sample(graph: &SemanticGraph, leaf: &SealedLeaf) -> Option<JsonValue> {
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
            .or_else(|| {
                format_use_samples(&graph.profile, &spec.format, 1)
                    .into_iter()
                    .next()
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
fn array_candidates(
    spec: &ArraySpec,
    recurse: &dyn Fn(&TypeRef) -> Vec<JsonValue>,
) -> Vec<JsonValue> {
    let lengths: Vec<usize> = spec
        .min_length
        .iter()
        .chain(spec.max_length.iter())
        .filter_map(ToPrimitive::to_usize)
        .chain([0, 1])
        .collect();
    let items: Vec<JsonValue> = spec
        .item
        .nullable
        .then_some(JsonValue::Null)
        .into_iter()
        .chain(recurse(&spec.item.type_ref))
        .collect();
    lengths
        .into_iter()
        .flat_map(|length| {
            if length == 0 {
                vec![JsonValue::Arr(vec![])]
            } else {
                items
                    .iter()
                    .map(|item| JsonValue::Arr(vec![item.clone(); length]))
                    .collect()
            }
        })
        .collect()
}
fn product_candidates(
    graph: &SemanticGraph,
    spec: &ProductSpec,
    limit: usize,
    recurse: &dyn Fn(&TypeRef) -> Vec<JsonValue>,
) -> Vec<JsonValue> {
    let mut candidates: Vec<JsonValue> = product_members(&spec.fields, limit, recurse)
        .into_iter()
        .map(JsonValue::Obj)
        .collect();
    if let ExtraMembers::Allow { key_format, value } = &spec.extras {
        let first_values: Vec<JsonValue> = recurse(&value.type_ref).into_iter().take(1).collect();
        for key in format_use_samples(&graph.profile, key_format, 1) {
            for extra in &first_values {
                candidates.push(JsonValue::Obj(vec![(key.clone(), extra.clone())]));
            }
        }
    }
    candidates
}
fn product_members(
    fields: &[FieldSpec],
    limit: usize,
    recurse: &dyn Fn(&TypeRef) -> Vec<JsonValue>,
) -> Vec<Vec<(String, JsonValue)>> {
    let Some((field, rest)) = fields.split_first() else {
        return vec![vec![]];
    };
    let remaining = product_members(rest, limit, recurse);
    let mut here: Vec<Option<JsonValue>> = Vec::new();
    if !field.slot.required {
        here.push(None);
    }
    if field.slot.nullable {
        here.push(Some(JsonValue::Null));
    }
    here.extend(recurse(&field.slot.type_ref).into_iter().map(Some));
    here.iter()
        .flat_map(|value| {
            remaining.iter().map(move |members| match value {
                None => members.clone(),
                Some(value) => std::iter::once((field.wire_name.clone(), value.clone()))
                    .chain(members.iter().cloned())
                    .collect(),
            })
        })
        .take(limit)
        .collect()
}
fn tagged_union_candidates(
    graph: &SemanticGraph,
    spec: &UnionSpec,
    recurse: &dyn Fn(&TypeRef) -> Vec<JsonValue>,
) -> Vec<JsonValue> {
    let tag_key = graph
        .profile
        .tag
        .as_ref()
        .map(|model| model.key.clone())
        .unwrap_or_default();
    spec.branches
        .iter()
        .flat_map(|branch| {
            recurse(&branch.target)
                .into_iter()
                .filter_map(|value| union_branch_sample(&graph.profile, &tag_key, branch, value))
        })
        .collect()
}
fn union_branch_sample(
    profile: &VersionedSemanticProfile,
    tag_key: &str,
    branch: &UnionBranch,
    mut value: JsonValue,
) -> Option<JsonValue> {
    match (&branch.selector, &mut value) {
        (BranchSelector::InternalTag, JsonValue::Obj(members)) => Some(JsonValue::Obj(
            std::iter::once((tag_key.to_owned(), JsonValue::Str(branch.wire_tag.clone())))
                .chain(
                    std::mem::take(members)
                        .into_iter()
                        .filter(|(key, _)| key != tag_key),
                )
                .collect(),
        )),
        (BranchSelector::MemberShape(tests), JsonValue::Obj(members)) => Some(JsonValue::Obj(
            tests
                .iter()
                .fold(std::mem::take(members), |current, (key, test)| match test {
                    MemberTest::Absent => current
                        .into_iter()
                        .filter(|(name, _)| name != key)
                        .collect(),
                    MemberTest::Format(name) => {
                        match format_samples(profile, Some(name.as_str()), 1)
                            .into_iter()
                            .next()
                        {
                            None => current,
                            Some(text) => std::iter::once((key.clone(), JsonValue::Str(text)))
                                .chain(current.into_iter().filter(|(name, _)| name != key))
                                .collect(),
                        }
                    }
                }),
        )),
        (BranchSelector::Kind(_) | BranchSelector::Otherwise, _) => Some(value),
        _ => None,
    }
}
pub fn sample_within_bound(maximum: usize, value: &JsonValue) -> bool {
    match value {
        JsonValue::Str(text) | JsonValue::Dec(text) => text.chars().count() <= maximum,
        JsonValue::Arr(items) => items.len() <= maximum,
        JsonValue::Obj(members) => members.len() <= maximum,
        _ => true,
    }
}
pub fn sample_value_fuel(
    graph: &SemanticGraph,
    bounds: &SearchBounds,
    fuel: usize,
    seen: &[TypeRef],
    reference: &TypeRef,
) -> SampleResult<JsonValue> {
    sample_values_with(
        &PreparedValidator::new(graph, FormatWorkspace::empty()),
        bounds,
        fuel,
        seen,
        reference,
    )
}
fn sample_values_with(
    validator: &PreparedValidator<'_>,
    bounds: &SearchBounds,
    fuel: usize,
    seen: &[TypeRef],
    reference: &TypeRef,
) -> SampleResult<JsonValue> {
    let candidates = sample_candidates_with(validator, fuel, seen, reference);
    let candidate_count = candidates.len();
    let values: Vec<JsonValue> = candidates
        .into_iter()
        .filter(|value| sample_within_bound(bounds.sample_length_limit(), value))
        .collect();
    let obligations = if values.len() == candidate_count {
        vec![]
    } else {
        vec![SampleObligation::SampleBound]
    };
    SampleResult {
        values,
        obligations,
    }
}
fn slot_values(
    validator: &mut PreparedValidator<'_>,
    contract: &SlotContract,
    values: impl IntoIterator<Item = JsonValue>,
) -> Vec<SlotValue> {
    (!contract.required)
        .then_some(SlotValue::Absent)
        .into_iter()
        .chain(contract.nullable.then_some(SlotValue::Null))
        .chain(values.into_iter().map(SlotValue::Present))
        .filter(|value| {
            matches!(
                validator.accepts_slot(contract, borrowed_slot(value)),
                ValueDecision::Accepted
            )
        })
        .collect()
}
pub fn slot_samples(
    graph: &SemanticGraph,
    bounds: &SearchBounds,
    contract: &SlotContract,
) -> SampleResult<SlotValue> {
    let mut validator = PreparedValidator::new(graph, FormatWorkspace::empty());
    let generated = sample_values_with(
        &validator,
        bounds,
        bounds.type_obligation_limit().min(graph.nodes.len() + 1),
        &[],
        &contract.type_ref,
    );
    SampleResult {
        values: slot_values(&mut validator, contract, generated.values),
        obligations: generated.obligations,
    }
}
pub fn inclusion_samples_bounded(
    graph: &SemanticGraph,
    source: &TypeRef,
    destination: &TypeRef,
    bounds: &SearchBounds,
) -> SampleResult<JsonValue> {
    inclusion_samples_with(
        &mut PreparedValidator::new(graph, FormatWorkspace::empty()),
        source,
        destination,
        bounds,
    )
}
fn inclusion_samples_with(
    validator: &mut PreparedValidator<'_>,
    source: &TypeRef,
    destination: &TypeRef,
    bounds: &SearchBounds,
) -> SampleResult<JsonValue> {
    let graph = validator.graph();
    let fuel = bounds.type_obligation_limit().min(graph.nodes.len() + 1);
    let generated = sample_values_with(validator, bounds, fuel, &[], source);
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
            for sample in generated.values.iter().take(1) {
                let JsonValue::Obj(members) = sample else {
                    continue;
                };
                for value in [
                    JsonValue::Null,
                    JsonValue::Bool(true),
                    JsonValue::Str("x".into()),
                    JsonValue::Str("y".into()),
                    JsonValue::Num(BigInt::zero()),
                ] {
                    candidates.push(JsonValue::Obj(
                        std::iter::once((field.wire_name.clone(), value))
                            .chain(members.iter().cloned())
                            .collect(),
                    ));
                }
            }
        }
        if let ExtraMembers::Allow { key_format, value } = &source_spec.extras {
            let extra_values =
                sample_values_with(validator, bounds, fuel, &[], &value.type_ref).values;
            for key in format_use_samples(&graph.profile, key_format, 1) {
                for extra in &extra_values {
                    candidates.push(JsonValue::Obj(vec![(key.clone(), extra.clone())]));
                }
            }
        }
    }
    let candidate_count = candidates.len();
    let additional: Vec<JsonValue> = candidates
        .into_iter()
        .filter(|value| {
            sample_within_bound(bounds.sample_length_limit(), value)
                && matches!(
                    validator.accepts_value(source, value),
                    ValueDecision::Accepted
                )
        })
        .collect();
    let mut obligations = generated.obligations;
    if additional.len() != candidate_count {
        obligations.push(SampleObligation::SampleBound);
    }
    let mut values = generated.values;
    values.extend(additional);
    SampleResult {
        values,
        obligations,
    }
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
    pub fn accepts(&self, producer: &ProducerRef, value_path: &[PathStep]) -> bool {
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
impl ConstructionRule {
    pub fn field_constraint(&self, name: &str) -> &SourceConstraint {
        self.field_constraints
            .iter()
            .find(|constraint| constraint.field == name)
            .map_or(&SourceConstraint::AnyCompatible, |constraint| {
                &constraint.source
            })
    }

    pub fn field_required(&self, name: &str) -> bool {
        self.field_constraints.iter().any(|constraint| {
            constraint.field == name && constraint.presence == FieldPresence::Required
        })
    }
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
    pub max_tokens: Nat,
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
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SignatureContractFailure {
    MissingOutcomeCause {
        function: FunctionRef,
        outcome: OutcomeId,
    },
}
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum InvalidSignatureReason {
    Contract(SignatureContractFailure),
    IdentityRevisionDigestAssumptionsOrOutcomes,
    PureFunctionEffect,
    InputSourceConstraint,
    InputResourceRequirement,
    ZeroResourceMultiplicity,
    OutputResourceProduction,
    FailureHandlerOrigin,
    OutcomeCauseOrExternalFailureValue,
    UnresolvedOperationIdentity,
    DefinitionIsNotAnOperation,
    OperationIdentityBasis,
    OperationEffect,
    BaseOutcomePreservationOrExternalSupplement,
}
impl InvalidSignatureReason {
    pub fn text(&self) -> &'static str {
        match self {
            Self::Contract(SignatureContractFailure::MissingOutcomeCause { .. }) => {
                "missing outcome cause"
            }
            Self::IdentityRevisionDigestAssumptionsOrOutcomes => {
                "identity, revision, digest, assumptions, or outcomes"
            }
            Self::PureFunctionEffect => "pure function effect",
            Self::InputSourceConstraint => "input source constraint",
            Self::InputResourceRequirement => "input resource requirement",
            Self::ZeroResourceMultiplicity => "zero resource multiplicity",
            Self::OutputResourceProduction => "output resource production",
            Self::FailureHandlerOrigin => "failure handler origin",
            Self::OutcomeCauseOrExternalFailureValue => "outcome cause or external failure value",
            Self::UnresolvedOperationIdentity => "unresolved operation identity",
            Self::DefinitionIsNotAnOperation => "definition is not an operation",
            Self::OperationIdentityBasis => "operation identity basis",
            Self::OperationEffect => "operation effect",
            Self::BaseOutcomePreservationOrExternalSupplement => {
                "base outcome preservation or external supplement"
            }
        }
    }
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
        reason: InvalidSignatureReason,
    },
    InvalidInitialValue {
        input: InputId,
        failure: ValueFailure,
    },
    SiteEffectNotPermitted {
        site: SiteId,
        effect: CompositionEffect,
    },
    TransformNotPermitted(FunctionRef),
    EmptyGoal,
    GoalSourceConstraintUndefined {
        port: GoalPortId,
        constraint: SourceConstraint,
    },
    FailureEmbeddingOriginUndefined {
        embedding: FailureEmbeddingId,
        origin: FailureOrigin,
    },
    ConstructionNotProduct {
        identity: String,
        type_ref: TypeRef,
    },
    FieldConstraintUnknownField {
        identity: String,
        field: String,
    },
    ConstrainedNestedField {
        identity: String,
        field: String,
    },
    ConstructionFieldSourceUndefined {
        identity: String,
        constraint: FieldConstraint,
    },
    NestedFieldUndeclared {
        identity: String,
        field: String,
    },
    NestedConstructionMismatch {
        identity: String,
        field: String,
        nested: String,
        type_ref: TypeRef,
    },
    CyclicConstruction {
        identity: String,
    },
    ExplicitSiteOrderInvalid {
        before: SiteId,
        after: SiteId,
    },
    InvalidEmptyTypeClosure(InclusionFailure),
    InvalidResourceDeclaration(String),
    InvalidLibrary(LibraryCheckFailure),
}
pub type OperationChecker<'g> =
    Arc<dyn Fn(&FunctionSignature, &DefinitionRef) -> Result<(), CompositionInputFailure> + 'g>;
pub type OperationMeaning<'g> =
    Arc<dyn Fn(&FunctionSignature, &DefinitionRef) -> Vec<SemanticObligation> + 'g>;
pub struct PreparedCompositionInput<'g> {
    graph: &'g SemanticGraph,
    pub input: CompositionInput,
    operation_checker: OperationChecker<'g>,
    operation_meaning: OperationMeaning<'g>,
    pub empty_refs: Vec<TypeRef>,
    validator: PreparedValidator<'g>,
}
impl Clone for PreparedCompositionInput<'_> {
    fn clone(&self) -> Self {
        Self {
            graph: self.graph,
            input: self.input.clone(),
            operation_checker: self.operation_checker.clone(),
            operation_meaning: self.operation_meaning.clone(),
            empty_refs: self.empty_refs.clone(),
            validator: self.validator.with_empty_workspace(),
        }
    }
}
impl<'g> PreparedCompositionInput<'g> {
    pub fn validator(&self) -> PreparedValidator<'g> {
        self.validator.with_empty_workspace()
    }
    pub fn graph(&self) -> &'g SemanticGraph {
        self.graph
    }
    pub fn input(&self) -> &CompositionInput {
        &self.input
    }
    pub fn operation_checker(&self) -> &OperationChecker<'g> {
        &self.operation_checker
    }
    pub fn operation_meaning(&self) -> &OperationMeaning<'g> {
        &self.operation_meaning
    }
    pub fn empty_refs(&self) -> &[TypeRef] {
        &self.empty_refs
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
pub fn site_signature<'a>(
    input: &'a CompositionInput,
    site: &SiteId,
) -> Option<&'a FunctionSignature> {
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
fn constraint_path_defined(
    metadata: &PreparedMetadata<'_>,
    contract: &SlotContract,
    path: &[PathStep],
) -> bool {
    let assumptions: Vec<ProjectionAssumption> = path
        .iter()
        .enumerate()
        .filter_map(|(index, step)| match step {
            PathStep::Variant(tag) => Some(ProjectionAssumption::Variant {
                path: path.iter().take(index).cloned().collect(),
                tag: tag.clone(),
            }),
            _ => None,
        })
        .collect();
    project_slot(metadata, contract, path, &assumptions).is_ok()
}

fn source_constraint_defined(
    metadata: &PreparedMetadata<'_>,
    input: &CompositionInput,
    constraint: &SourceConstraint,
) -> bool {
    let source = match constraint {
        SourceConstraint::AnyCompatible => return true,
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
    source.is_some_and(|(contract, path)| constraint_path_defined(metadata, contract, path))
}
pub fn operation_checker_without_library<'g>() -> OperationChecker<'g> {
    Arc::new(
        |_: &FunctionSignature, _: &DefinitionRef| -> Result<(), CompositionInputFailure> {
            Ok(())
        },
    )
}
pub fn operation_meaning_of<'g>(graph: &'g SemanticGraph) -> OperationMeaning<'g> {
    Arc::new(move |function: &FunctionSignature, _: &DefinitionRef| {
        let references = function
            .inputs
            .iter()
            .map(|port| port.contract.type_ref.clone())
            .chain(
                function
                    .resource_inputs
                    .iter()
                    .map(|requirement| requirement.token_type.clone()),
            )
            .chain(function.outcomes.iter().flat_map(|outcome| {
                outcome
                    .value_ports
                    .iter()
                    .map(|port| port.contract.type_ref.clone())
                    .chain(
                        outcome
                            .produced_resources
                            .iter()
                            .map(|production| production.token_type.clone()),
                    )
            }))
            .collect::<Vec<_>>();
        validation::meaning_obligations(graph, &references)
    })
}
fn construction_reachable<'a>(rules: &'a [ConstructionRule], start: &'a str) -> HashSet<&'a str> {
    let mut reached = HashSet::new();
    let mut pending = vec![start];
    while let Some(identity) = pending.pop() {
        if !reached.insert(identity) {
            continue;
        }
        if let Some(rule) = rules.iter().find(|rule| rule.identity == identity) {
            pending.extend(rule.nested_fields.iter().map(|(_, child)| child.as_str()));
        }
    }
    reached
}
fn validate_composition_input(
    graph: &SemanticGraph,
    input: &CompositionInput,
    operation_checker: &OperationChecker<'_>,
) -> Result<(), CompositionInputFailure> {
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
    let function_ids = input
        .signatures
        .iter()
        .map(|function| function_identity(&function.reference))
        .collect::<Vec<_>>();
    unique_ids("function", function_ids.iter().map(String::as_str))?;
    unique_ids(
        "guard",
        input
            .invocation_domain
            .guards
            .iter()
            .map(|value| value.id.0.as_str()),
    )?;
    let mut validator = PreparedValidator::new(graph, FormatWorkspace::empty());
    for function in &input.signatures {
        let fail = |reason: InvalidSignatureReason| CompositionInputFailure::InvalidSignature {
            function: function.reference.clone(),
            reason,
        };
        if function.reference.identity.is_empty()
            || function.reference.revision.is_empty()
            || function.reference.content_digest.is_empty()
            || function.assumption_ref.is_empty()
            || function.outcomes.is_empty()
        {
            return Err(fail(
                InvalidSignatureReason::IdentityRevisionDigestAssumptionsOrOutcomes,
            ));
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
                return Err(fail(InvalidSignatureReason::PureFunctionEffect))
            }
            FunctionForm::Operation(reference) => operation_checker(function, reference)?,
            _ => {}
        }
        for port in &function.inputs {
            check_type(graph, &port.contract.type_ref)?;
            if !source_constraint_defined(validator.metadata(), input, &port.source_constraint) {
                return Err(fail(InvalidSignatureReason::InputSourceConstraint));
            }
            if port.resource_requirement.as_ref().is_some_and(|id| {
                !function
                    .resource_inputs
                    .iter()
                    .any(|requirement| requirement.id == *id)
            }) {
                return Err(fail(InvalidSignatureReason::InputResourceRequirement));
            }
        }
        for requirement in &function.resource_inputs {
            check_type(graph, &requirement.token_type)?;
            if requirement.multiplicity.is_zero() {
                return Err(fail(InvalidSignatureReason::ZeroResourceMultiplicity));
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
                    return Err(fail(InvalidSignatureReason::OutputResourceProduction));
                }
            }
            for production in &outcome.produced_resources {
                check_type(graph, &production.token_type)?;
            }
        }
        if function
            .handles_failure
            .as_ref()
            .is_some_and(|origin| !failure_origin_defined(input, origin))
        {
            return Err(fail(InvalidSignatureReason::FailureHandlerOrigin));
        }
    }
    for site in &input.invocation_domain.sites {
        let function = signature(input, &site.function)
            .ok_or_else(|| CompositionInputFailure::UnresolvedFunction(site.function.clone()))?;
        if !input.allowed_effects.contains(&function.effect) {
            return Err(CompositionInputFailure::SiteEffectNotPermitted {
                site: site.id.clone(),
                effect: function.effect,
            });
        }
        if function.form == FunctionForm::DeclaredTransform
            && !input
                .invocation_domain
                .permitted_transforms
                .contains(&function.reference)
        {
            return Err(CompositionInputFailure::TransformNotPermitted(
                function.reference.clone(),
            ));
        }
    }
    for initial in &input.initial_inputs {
        check_type(graph, &initial.contract.type_ref)?;
        if let InitialSource::SuppliedValue(value) = &initial.source {
            match validator.accepts_slot(&initial.contract, borrowed_slot(value)) {
                ValueDecision::Rejected(failure) => {
                    return Err(CompositionInputFailure::InvalidInitialValue {
                        input: initial.id.clone(),
                        failure,
                    })
                }
                ValueDecision::Unresolved(_) | ValueDecision::Accepted => {}
            }
        }
        if initial
            .resource
            .as_ref()
            .is_some_and(|id| !input.initial_resources.iter().any(|lot| lot.id == *id))
        {
            return Err(CompositionInputFailure::InvalidResourceDeclaration(
                "initial backing lot".into(),
            ));
        }
    }
    for lot in &input.initial_resources {
        check_type(graph, &lot.token_type)?;
        match &lot.producer {
            ResourceProducer::Initial { identity, revision } => {
                if identity.is_empty() || revision.is_empty() || lot.provenance.is_empty() {
                    return Err(CompositionInputFailure::InvalidResourceDeclaration(
                        "initial producer or provenance".into(),
                    ));
                }
            }
            ResourceProducer::InvocationOutcome { .. } => {
                return Err(CompositionInputFailure::InvalidResourceDeclaration(
                    "initial lot has an invocation producer".into(),
                ));
            }
        }
    }
    if input.goal.outputs.is_empty() {
        return Err(CompositionInputFailure::EmptyGoal);
    }
    for goal in &input.goal.outputs {
        check_type(graph, &goal.contract.type_ref)?;
        if !source_constraint_defined(validator.metadata(), input, &goal.source_constraint) {
            return Err(CompositionInputFailure::GoalSourceConstraintUndefined {
                port: goal.id.clone(),
                constraint: goal.source_constraint.clone(),
            });
        }
    }
    for embedding in &input.goal.failures {
        check_type(graph, &embedding.contract.type_ref)?;
        if !failure_origin_defined(input, &embedding.origin) {
            return Err(CompositionInputFailure::FailureEmbeddingOriginUndefined {
                embedding: embedding.id.clone(),
                origin: embedding.origin.clone(),
            });
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
            return Err(CompositionInputFailure::ConstructionNotProduct {
                identity: construction.identity.clone(),
                type_ref: construction.type_ref.clone(),
            });
        };
        unique_ids(
            "nested field",
            construction
                .nested_fields
                .iter()
                .map(|(field, _)| field.as_str()),
        )?;
        unique_ids(
            "field constraint",
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
                return Err(CompositionInputFailure::FieldConstraintUnknownField {
                    identity: construction.identity.clone(),
                    field: constraint.field.clone(),
                });
            }
            if construction
                .nested_fields
                .iter()
                .any(|(nested, _)| nested == &constraint.field)
            {
                return Err(CompositionInputFailure::ConstrainedNestedField {
                    identity: construction.identity.clone(),
                    field: constraint.field.clone(),
                });
            }
            if !source_constraint_defined(validator.metadata(), input, &constraint.source) {
                return Err(CompositionInputFailure::ConstructionFieldSourceUndefined {
                    identity: construction.identity.clone(),
                    constraint: constraint.clone(),
                });
            }
        }
        for (field, nested) in &construction.nested_fields {
            let Some(field) = product
                .fields
                .iter()
                .find(|candidate| candidate.wire_name == *field)
            else {
                return Err(CompositionInputFailure::NestedFieldUndeclared {
                    identity: construction.identity.clone(),
                    field: field.clone(),
                });
            };
            if !input
                .invocation_domain
                .permitted_constructions
                .iter()
                .any(|rule| &rule.identity == nested && rule.type_ref == field.slot.type_ref)
            {
                return Err(CompositionInputFailure::NestedConstructionMismatch {
                    identity: construction.identity.clone(),
                    field: field.wire_name.clone(),
                    nested: nested.clone(),
                    type_ref: field.slot.type_ref.clone(),
                });
            }
            if construction_reachable(&input.invocation_domain.permitted_constructions, nested)
                .contains(construction.identity.as_str())
            {
                return Err(CompositionInputFailure::CyclicConstruction {
                    identity: construction.identity.clone(),
                });
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
            || site_signature(input, before).is_none()
            || site_signature(input, after).is_none()
        {
            return Err(CompositionInputFailure::ExplicitSiteOrderInvalid {
                before: before.clone(),
                after: after.clone(),
            });
        }
    }
    for goal in input.goal.final_resources.iter().chain(
        input
            .goal
            .failures
            .iter()
            .flat_map(|embedding| &embedding.final_resources),
    ) {
        if declared_lot(input, &goal.lot).is_none() {
            return Err(CompositionInputFailure::InvalidResourceDeclaration(
                "terminal resource lot".into(),
            ));
        }
    }
    Ok(())
}
fn verify_empty_closure_input<'g>(
    graph: &'g SemanticGraph,
    refs: &[TypeRef],
) -> Result<CheckedEmptyTypes<'g>, CompositionInputFailure> {
    verify_empty_types(graph, refs).map_err(CompositionInputFailure::InvalidEmptyTypeClosure)
}
pub fn prepare_direct_composition<'g>(
    graph: &'g SemanticGraph,
    input: CompositionInput,
    operation_checker: OperationChecker<'g>,
    operation_meaning: OperationMeaning<'g>,
) -> Result<PreparedCompositionInput<'g>, CompositionInputFailure> {
    validate_composition_input(graph, &input, &operation_checker)?;
    let empty_refs = empty_types(graph);
    verify_empty_closure_input(graph, &empty_refs)?;
    Ok(PreparedCompositionInput {
        graph,
        input,
        operation_checker,
        operation_meaning,
        empty_refs,
        validator: PreparedValidator::new(graph, FormatWorkspace::empty()),
    })
}
fn failure_origin_defined(input: &CompositionInput, origin: &FailureOrigin) -> bool {
    match origin {
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
    }
}
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LotDeclaration {
    pub token_type: TypeRef,
    pub producer: ResourceProducer,
    pub revision: Nat,
    pub quantity: Nat,
    pub provenance: String,
}
pub fn declared_lot(
    input: &CompositionInput,
    reference: &ResourceLotRef,
) -> Option<LotDeclaration> {
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
    pub rank: BigUint,
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
#[derive(Clone, Copy)]
pub struct AdmittedComposition<'a, 'g> {
    prepared: &'a PreparedCompositionInput<'g>,
    plan: &'a CompositionPlan,
}
impl<'a, 'g> AdmittedComposition<'a, 'g> {
    pub(crate) fn from_admission(
        prepared: &'a PreparedCompositionInput<'g>,
        plan: &'a CompositionPlan,
    ) -> Self {
        Self { prepared, plan }
    }
    pub fn prepared(&self) -> &'a PreparedCompositionInput<'g> {
        self.prepared
    }
    pub fn plan(&self) -> &'a CompositionPlan {
        self.plan
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
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum UnresolvedObligation {
    Type {
        value: Option<ValueRef>,
        obligations: Vec<TypeObligation>,
    },
    Meaning(Vec<SemanticObligation>),
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
        limit: Nat,
    },
    UnresolvedUniqueness,
}

#[derive(Debug, Clone, PartialEq)]
pub struct CompositionReasonFailure {
    pub provenance: CompositionProvenance,
    pub obligations: Vec<UnresolvedObligation>,
    pub residuals: neco_quotient_certificate::ResidualSet<UnresolvedObligation>,
    pub classifications: Vec<ReasonDisposition>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CompositionProvenance {
    pub operation: String,
    pub input_identity: String,
    pub input_revision: String,
}

#[derive(Debug, Clone, PartialEq)]
pub struct CompositionJudgment<V> {
    pub provenance: CompositionProvenance,
    pub value: V,
}

pub type CompositionEvaluation<V> = Result<
    neco_quotient_certificate::RefinementOutcome<
        CompositionJudgment<V>,
        UnresolvedObligation,
        Vec<UnresolvedObligation>,
    >,
    CompositionReasonFailure,
>;

pub fn classified_atoms(
    obligations: &[UnresolvedObligation],
) -> Vec<(UnresolvedObligation, ReasonDisposition)> {
    fn expand(obligation: &UnresolvedObligation) -> Vec<(UnresolvedObligation, ReasonDisposition)> {
        use UnresolvedObligation as O;
        match obligation {
            O::Meaning(reasons) => reasons
                .iter()
                .map(|reason| {
                    (
                        O::Meaning(vec![reason.clone()]),
                        reason.reason.disposition(),
                    )
                })
                .collect(),
            O::Type { value, obligations } => obligations
                .iter()
                .flat_map(|obligation| {
                    let wrap = |reason| O::Type {
                        value: value.clone(),
                        obligations: vec![TypeObligation {
                            pair: obligation.pair.clone(),
                            path: obligation.path.clone(),
                            reason,
                        }],
                    };
                    match &obligation.reason {
                        TypeObligationReason::Meaning(reasons) if reasons.is_empty() => {
                            vec![(wrap(obligation.reason.clone()), ReasonDisposition::Failed)]
                        }
                        TypeObligationReason::Meaning(reasons) => reasons
                            .iter()
                            .map(|reason| {
                                (
                                    wrap(TypeObligationReason::Meaning(vec![reason.clone()])),
                                    reason.reason.disposition(),
                                )
                            })
                            .collect(),
                        TypeObligationReason::ObligationBoundExhausted => {
                            vec![(wrap(obligation.reason.clone()), ReasonDisposition::Stopped)]
                        }
                        TypeObligationReason::ConstraintImplication
                        | TypeObligationReason::Presence
                        | TypeObligationReason::UnionRemainder
                        | TypeObligationReason::Inhabitation
                        | TypeObligationReason::ExtraField(_) => {
                            vec![(wrap(obligation.reason.clone()), ReasonDisposition::Residual)]
                        }
                    }
                })
                .collect(),
            O::Inhabitation { .. } | O::BranchInhabitation | O::UnresolvedUniqueness => {
                vec![(obligation.clone(), ReasonDisposition::Residual)]
            }
            O::StateBoundExhausted
            | O::BindingBoundExhausted
            | O::BranchBoundExhausted
            | O::ResourceSolverUnknown(_)
            | O::ResourceCapacityBound { .. } => {
                vec![(obligation.clone(), ReasonDisposition::Stopped)]
            }
        }
    }
    obligations
        .iter()
        .flat_map(|reason| {
            let expanded = expand(reason);
            if expanded.is_empty() {
                vec![(reason.clone(), ReasonDisposition::Failed)]
            } else {
                expanded
            }
        })
        .collect()
}

pub fn classify_unresolved_obligations(
    provenance: CompositionProvenance,
    obligations: Vec<UnresolvedObligation>,
) -> CompositionEvaluation<Vec<UnresolvedObligation>> {
    use neco_quotient_certificate::{RefinementOutcome, ResidualSet};
    let classified = classified_atoms(&obligations);
    let residuals = ResidualSet::new(
        classified
            .iter()
            .filter(|(_, class)| *class == ReasonDisposition::Residual)
            .map(|(reason, _)| reason.clone()),
    );
    let classifications: Vec<_> = classified.iter().map(|(_, class)| *class).collect();
    if obligations.is_empty() || classifications.contains(&ReasonDisposition::Failed) {
        Err(CompositionReasonFailure {
            provenance,
            obligations,
            residuals,
            classifications,
        })
    } else {
        let cause: Vec<_> = classified
            .into_iter()
            .filter(|(_, class)| *class == ReasonDisposition::Stopped)
            .map(|(reason, _)| reason)
            .collect();
        if cause.is_empty() {
            Ok(RefinementOutcome::Residual {
                value: CompositionJudgment {
                    provenance,
                    value: obligations,
                },
                residuals,
            })
        } else {
            Ok(RefinementOutcome::Stopped {
                value: CompositionJudgment {
                    provenance,
                    value: obligations,
                },
                residuals,
                cause,
            })
        }
    }
}

pub fn encode_tuple(parts: &[&str]) -> String {
    let mut result = String::new();
    for part in parts {
        result.push_str(&part.len().to_string());
        result.push(':');
        result.push_str(part);
    }
    result
}
pub fn function_identity(reference: &FunctionRef) -> String {
    encode_tuple(&[
        &reference.identity,
        &reference.revision,
        &reference.content_digest,
    ])
}
pub fn project_owned(
    profile: &VersionedSemanticProfile,
    value: &SlotValue,
    path: &[PathStep],
) -> SlotValue {
    let view = match value {
        SlotValue::Absent => SlotValue::Absent,
        SlotValue::Null => SlotValue::Null,
        SlotValue::Present(value) => SlotValue::Present(JsonValueView::from_json(value)),
    };
    match project_value_view(profile, view, path) {
        SlotValue::Absent => SlotValue::Absent,
        SlotValue::Null => SlotValue::Null,
        SlotValue::Present(value) => SlotValue::Present(value.to_owned()),
    }
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
pub struct PreparedGuard<'g> {
    declaration: DeclaredGuard,
    validator: PreparedValidator<'g>,
    profile: PreparedProfile<'g>,
}

pub enum GuardArmView<'a> {
    Absent,
    Null,
    Present,
    Accepted,
    Rejected,
    Variant(&'a str),
}

impl GuardArmView<'_> {
    pub fn into_owned(self) -> GuardArm {
        match self {
            GuardArmView::Absent => GuardArm::Absent,
            GuardArmView::Null => GuardArm::Null,
            GuardArmView::Present => GuardArm::Present,
            GuardArmView::Accepted => GuardArm::Accepted,
            GuardArmView::Rejected => GuardArm::Rejected,
            GuardArmView::Variant(tag) => GuardArm::Variant(tag.to_owned()),
        }
    }
}

fn missing_guard_evidence(reason: &str) -> WitnessFailure {
    WitnessFailure::MissingEvidence(reason.to_owned())
}

impl<'g> PreparedGuard<'g> {
    pub fn new(validator: &PreparedValidator<'g>, declaration: DeclaredGuard) -> Self {
        Self {
            validator: validator.with_empty_workspace(),
            profile: PreparedProfile::new(validator.graph().profile()),
            declaration,
        }
    }

    pub fn evaluate<'a>(
        &'a mut self,
        contract: &SlotContract,
        inspected: SlotValue<JsonValueView<'a>>,
    ) -> Result<GuardArmView<'a>, WitnessFailure>
    where
        'g: 'a,
    {
        let PreparedGuard {
            declaration,
            validator,
            profile,
        } = self;
        let declaration: &'a DeclaredGuard = declaration;
        match &declaration.kind {
            GuardKind::Validate(target) => match validator.decide_view_slot(target, inspected) {
                BorrowedValueDecision::Accepted => Ok(GuardArmView::Accepted),
                BorrowedValueDecision::Rejected(_) => Ok(GuardArmView::Rejected),
                BorrowedValueDecision::Unresolved(_) => {
                    Err(missing_guard_evidence("validation guard meaning"))
                }
            },
            GuardKind::Presence => Ok(match inspected {
                SlotValue::Absent => GuardArmView::Absent,
                SlotValue::Null => GuardArmView::Null,
                SlotValue::Present(_) => GuardArmView::Present,
            }),
            GuardKind::Variants => match inspected {
                SlotValue::Absent => Ok(GuardArmView::Absent),
                SlotValue::Null => Ok(GuardArmView::Null),
                SlotValue::Present(value) if value.kind() == ValueKind::Object => {
                    let graph = validator.graph();
                    let key = graph
                        .profile()
                        .tag
                        .as_ref()
                        .map_or("", |tag| tag.key.as_str());
                    if value.member(key).and_then(JsonValueView::as_str).is_none() {
                        return Err(missing_guard_evidence("union discriminator"));
                    }
                    let Some(TypeShape::TaggedUnion(spec)) =
                        resolved_shape(graph, &contract.type_ref)
                    else {
                        return Err(missing_guard_evidence("union guard source"));
                    };
                    let Some(branch) = select_union_branch_view(
                        profile,
                        &mut FormatWorkspace::empty(),
                        spec,
                        value,
                    ) else {
                        return Err(missing_guard_evidence("union branch selection"));
                    };
                    Ok(GuardArmView::Variant(branch.wire_tag.as_str()))
                }
                SlotValue::Present(_) => Err(missing_guard_evidence("union guard value")),
            },
        }
    }
}

pub fn default_resource_token_bound() -> Nat {
    Nat::from(100_000_usize)
}

#[cfg(test)]
mod distinct_tests {
    use super::distinct;

    #[test]
    fn distinct_keeps_the_first_occurrence_as_lean_erase_dups() {
        assert_eq!(distinct([3u8, 1, 3, 2, 1]), vec![3, 1, 2]);
        assert_eq!(distinct(Vec::<u8>::new()), Vec::<u8>::new());
    }
}

#[cfg(test)]
mod dfa_sample_tests {
    use super::dfa_shortest_word;
    use crate::semantic_types::{DfaSpec, DfaTransition};
    use num_bigint::BigUint;

    #[test]
    fn dfa_shortest_word_takes_code_points_above_one_byte() {
        let spec = DfaSpec {
            state_count: BigUint::from(2u8),
            initial_state: BigUint::from(0u8),
            accepting_states: vec![BigUint::from(1u8)],
            transitions: vec![DfaTransition {
                from_state: BigUint::from(0u8),
                first: BigUint::from(0x3042u32),
                last: BigUint::from(0x3042u32),
                to_state: BigUint::from(1u8),
            }],
        };
        assert_eq!(dfa_shortest_word(&spec), Some("あ".to_owned()));
    }
}
