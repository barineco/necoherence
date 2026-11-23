// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

use crate::exact_json::json_size;
use crate::semantic_composition::{
    borrowed_slot, present_contract, verify_empty_types, CheckedEmptyTypes,
    CounterexampleCertificate, InclusionCertificate, InclusionFailure, InclusionRule, PairEntry,
    TypeObligation, TypeObligationReason, TypePair,
};
use crate::semantic_expansion::rejection_failure;
use crate::semantic_types::*;
use crate::semantic_validation::{
    self as validation, recognize_format, FormatWorkspace, PreparedValidator,
};
use num_bigint::BigUint;
use num_traits::{ToPrimitive, Zero};
use std::collections::HashSet;

#[derive(Debug)]
pub struct CheckedPairTable<'g> {
    graph: &'g SemanticGraph,
    pairs: Vec<PairEntry>,
}
impl CheckedPairTable<'_> {
    pub fn graph(&self) -> &SemanticGraph {
        self.graph
    }
    pub fn pairs(&self) -> &[PairEntry] {
        &self.pairs
    }
}
#[derive(Debug)]
pub struct CheckedInclusion<'a> {
    graph: &'a SemanticGraph,
    certificate: &'a InclusionCertificate,
}
impl CheckedInclusion<'_> {
    pub fn graph(&self) -> &SemanticGraph {
        self.graph
    }
    pub fn certificate(&self) -> &InclusionCertificate {
        self.certificate
    }
}
#[derive(Debug)]
pub struct CheckedCounterexample<'a> {
    graph: &'a SemanticGraph,
    certificate: &'a CounterexampleCertificate,
}
impl CheckedCounterexample<'_> {
    pub fn graph(&self) -> &SemanticGraph {
        self.graph
    }
    pub fn certificate(&self) -> &CounterexampleCertificate {
        self.certificate
    }
}
fn presence_included(source: &SlotContract, destination: &SlotContract) -> bool {
    (source.required || !destination.required) && (!source.nullable || destination.nullable)
}
pub(crate) fn type_pair(source: TypeRef, destination: TypeRef) -> TypePair {
    TypePair {
        source: present_contract(source),
        destination: present_contract(destination),
        source_tag: None,
    }
}
pub(crate) fn obligation(
    source: TypeRef,
    destination: TypeRef,
    reason: TypeObligationReason,
) -> TypeObligation {
    TypeObligation {
        pair: type_pair(source, destination),
        path: vec![],
        reason,
    }
}
fn table_entry<'a>(table: &'a [PairEntry], index: &BigUint) -> Option<&'a PairEntry> {
    index.to_usize().and_then(|index| table.get(index))
}
fn includes_pair(table: &[PairEntry], source: &TypeRef, destination: &TypeRef) -> bool {
    table.iter().any(|entry| {
        entry.pair.source.type_ref == *source && entry.pair.destination.type_ref == *destination
    })
}
fn child_coverage(table: &[PairEntry], entry: &PairEntry, required: &[(TypeRef, TypeRef)]) -> bool {
    let actual = entry
        .children
        .iter()
        .filter_map(|index| table_entry(table, index))
        .map(|child| {
            (
                &child.pair.source.type_ref,
                &child.pair.destination.type_ref,
            )
        })
        .collect::<Vec<_>>();
    actual.len() == entry.children.len()
        && required.iter().all(|(source, destination)| {
            actual
                .iter()
                .any(|(left, right)| *left == source && *right == destination)
        })
        && actual.iter().all(|(source, destination)| {
            required
                .iter()
                .any(|(left, right)| source == &left && destination == &right)
        })
        && required
            .iter()
            .all(|(source, destination)| includes_pair(table, source, destination))
}
fn verify_pair_entry(
    validator: &mut PreparedValidator<'_>,
    graph: &SemanticGraph,
    empty: &HashSet<TypeRef>,
    table: &[PairEntry],
    entry: &PairEntry,
    fuel: usize,
) -> Result<(), InclusionFailure> {
    let Some(remaining) = fuel.checked_sub(1) else {
        return Err(InclusionFailure::Unresolved(TypeObligation {
            pair: entry.pair.clone(),
            path: vec![],
            reason: TypeObligationReason::ObligationBoundExhausted,
        }));
    };
    let source = &entry.pair.source.type_ref;
    let destination = &entry.pair.destination.type_ref;
    let source_shape = graph.find_type(source).map(|node| &node.shape);
    let destination_shape = graph.find_type(destination).map(|node| &node.shape);
    let (Some(source_shape), Some(destination_shape)) = (source_shape, destination_shape) else {
        return Err(InclusionFailure::PairMismatch(0));
    };
    if entry.source_shape != *source_shape
        || entry.destination_shape != *destination_shape
        || entry.pair.source_tag.is_some()
    {
        return Err(InclusionFailure::PairMismatch(0));
    }
    let coverage = |required: Vec<(TypeRef, TypeRef)>| {
        if child_coverage(table, entry, &required) {
            Ok(())
        } else {
            Err(InclusionFailure::ChildCoverage(0))
        }
    };
    if empty.contains(source) {
        return if entry.rule == InclusionRule::EmptySource {
            coverage(vec![])
        } else {
            Err(InclusionFailure::RuleMismatch(0))
        };
    }
    if source_shape == destination_shape {
        return if entry.rule == InclusionRule::SameDefinedType {
            coverage(vec![])
        } else {
            Err(InclusionFailure::RuleMismatch(0))
        };
    }
    match (source_shape, destination_shape) {
        (TypeShape::Alias { target, .. }, _) => {
            if entry.rule == InclusionRule::UnfoldSource {
                coverage(vec![(target.clone(), destination.clone())])
            } else {
                Err(InclusionFailure::RuleMismatch(0))
            }
        }
        (_, TypeShape::Alias { target, .. }) => {
            if entry.rule != InclusionRule::UnfoldDestination {
                return Err(InclusionFailure::RuleMismatch(0));
            }
            coverage(vec![(source.clone(), target.clone())])?;
            let child = table
                .iter()
                .find(|item| {
                    item.pair.source.type_ref == *source
                        && item.pair.destination.type_ref == *target
                })
                .ok_or(InclusionFailure::MissingPair)?;
            verify_pair_entry(validator, graph, empty, table, child, remaining)
        }
        (TypeShape::Boolean(source_spec), TypeShape::Boolean(destination_spec))
            if entry.rule == InclusionRule::Boolean =>
        {
            coverage(vec![])?;
            if destination_spec.const_value.is_none()
                || source_spec.const_value == destination_spec.const_value
            {
                Ok(())
            } else {
                Err(InclusionFailure::Unresolved(obligation(
                    source.clone(),
                    destination.clone(),
                    TypeObligationReason::ConstraintImplication,
                )))
            }
        }
        (TypeShape::Integer(source_spec), TypeShape::Integer(destination_spec))
            if entry.rule == InclusionRule::IntegerIntersection =>
        {
            coverage(vec![])?;
            if integer_rule_check(
                validator,
                graph,
                source,
                destination,
                source_spec,
                destination_spec,
            ) {
                Ok(())
            } else {
                Err(InclusionFailure::Unresolved(obligation(
                    source.clone(),
                    destination.clone(),
                    TypeObligationReason::ConstraintImplication,
                )))
            }
        }
        (TypeShape::String(source_spec), TypeShape::String(destination_spec))
            if matches!(
                entry.rule,
                InclusionRule::FiniteStrings | InclusionRule::StringConditions
            ) =>
        {
            coverage(vec![])?;
            if string_rule_check(source_spec, destination_spec) {
                Ok(())
            } else {
                Err(InclusionFailure::Unresolved(obligation(
                    source.clone(),
                    destination.clone(),
                    TypeObligationReason::ConstraintImplication,
                )))
            }
        }
        (TypeShape::Array(source_spec), TypeShape::Array(destination_spec))
            if entry.rule == InclusionRule::Array =>
        {
            coverage(vec![(
                source_spec.item.type_ref.clone(),
                destination_spec.item.type_ref.clone(),
            )])?;
            if lower_contained_nat(&source_spec.min_length, &destination_spec.min_length)
                && upper_contained_nat(&source_spec.max_length, &destination_spec.max_length)
                && (!source_spec.item.nullable || destination_spec.item.nullable)
            {
                Ok(())
            } else {
                Err(InclusionFailure::Unresolved(obligation(
                    source.clone(),
                    destination.clone(),
                    TypeObligationReason::ConstraintImplication,
                )))
            }
        }
        (TypeShape::Product(source_spec), TypeShape::Product(destination_spec))
            if entry.rule == InclusionRule::Product =>
        {
            let pairs = product_field_pairs(graph, source_spec, destination_spec);
            coverage(pairs)?;
            if product_rule_check(validator, graph, table, source_spec, destination_spec) {
                Ok(())
            } else {
                Err(InclusionFailure::Unresolved(TypeObligation {
                    pair: entry.pair.clone(),
                    path: vec![],
                    reason: TypeObligationReason::ExtraField("product rule P".into()),
                }))
            }
        }
        (TypeShape::TaggedUnion(source_spec), TypeShape::TaggedUnion(destination_spec))
            if entry.rule == InclusionRule::SourceUnion =>
        {
            coverage(rule_u_child_pairs(source_spec, destination_spec))?;
            if rule_u_coverage(source_spec, destination_spec) {
                Ok(())
            } else {
                Err(InclusionFailure::Unresolved(obligation(
                    source.clone(),
                    destination.clone(),
                    TypeObligationReason::UnionRemainder,
                )))
            }
        }
        (TypeShape::Bytes(_), TypeShape::Bytes(_)) => {
            Err(InclusionFailure::Unresolved(obligation(
                source.clone(),
                destination.clone(),
                TypeObligationReason::ConstraintImplication,
            )))
        }
        (TypeShape::Boolean(_), TypeShape::Boolean(_))
        | (TypeShape::Integer(_), TypeShape::Integer(_))
        | (TypeShape::String(_), TypeShape::String(_))
        | (TypeShape::Array(_), TypeShape::Array(_))
        | (TypeShape::Product(_), TypeShape::Product(_))
        | (TypeShape::TaggedUnion(_), TypeShape::TaggedUnion(_)) => {
            Err(InclusionFailure::RuleMismatch(0))
        }
        _ => Err(InclusionFailure::Unresolved(obligation(
            source.clone(),
            destination.clone(),
            TypeObligationReason::ConstraintImplication,
        ))),
    }
}
fn verify_pair_table<'g>(
    validator: &mut PreparedValidator<'_>,
    graph: &'g SemanticGraph,
    empty: &CheckedEmptyTypes<'g>,
    table: &[PairEntry],
) -> Result<CheckedPairTable<'g>, InclusionFailure> {
    let empty_refs = empty.refs.iter().cloned().collect::<HashSet<_>>();
    let fuel = graph.nodes.len() + 1;
    for entry in table {
        verify_pair_entry(validator, graph, &empty_refs, table, entry, fuel)?;
    }
    Ok(CheckedPairTable {
        graph,
        pairs: table.to_vec(),
    })
}
pub fn verify_inclusion<'a>(
    graph: &'a SemanticGraph,
    source: &SlotContract,
    destination: &SlotContract,
    certificate: &'a InclusionCertificate,
) -> Result<CheckedInclusion<'a>, InclusionFailure> {
    verify_inclusion_in(
        &mut PreparedValidator::new(graph, FormatWorkspace::empty()),
        graph,
        source,
        destination,
        certificate,
    )
}
pub(crate) fn verify_inclusion_in<'a>(
    validator: &mut PreparedValidator<'_>,
    graph: &'a SemanticGraph,
    source: &SlotContract,
    destination: &SlotContract,
    certificate: &'a InclusionCertificate,
) -> Result<CheckedInclusion<'a>, InclusionFailure> {
    let root = table_entry(&certificate.pairs, &certificate.root);
    if !certificate.basis.matches(graph)
        || certificate.source != *source
        || certificate.destination != *destination
        || root.is_none_or(|root| {
            root.pair.source.type_ref != source.type_ref
                || root.pair.destination.type_ref != destination.type_ref
                || root.pair.source_tag.is_some()
        })
    {
        return Err(InclusionFailure::BasisMismatch);
    }
    let meanings = validation::meaning_obligations(
        graph,
        &[source.type_ref.clone(), destination.type_ref.clone()],
    );
    if !meanings.is_empty() {
        return Err(InclusionFailure::UndefinedMeaning(meanings));
    }
    if !presence_included(source, destination) {
        return Err(InclusionFailure::Unresolved(TypeObligation {
            pair: TypePair {
                source: source.clone(),
                destination: destination.clone(),
                source_tag: None,
            },
            path: vec![],
            reason: TypeObligationReason::Presence,
        }));
    }
    if !includes_pair(&certificate.pairs, &source.type_ref, &destination.type_ref) {
        return Err(InclusionFailure::MissingPair);
    }
    let checked_empty = verify_empty_types(graph, &certificate.empty_types)?;
    verify_pair_table(validator, graph, &checked_empty, &certificate.pairs)?;
    Ok(CheckedInclusion { graph, certificate })
}
pub fn verify_counterexample<'a>(
    graph: &'a SemanticGraph,
    source: &SlotContract,
    destination: &SlotContract,
    certificate: &'a CounterexampleCertificate,
) -> Result<CheckedCounterexample<'a>, InclusionFailure> {
    verify_counterexample_in(
        &mut PreparedValidator::new(graph, FormatWorkspace::empty()),
        graph,
        source,
        destination,
        certificate,
    )
}
pub(crate) fn verify_counterexample_in<'a>(
    validator: &mut PreparedValidator<'_>,
    graph: &'a SemanticGraph,
    source: &SlotContract,
    destination: &SlotContract,
    certificate: &'a CounterexampleCertificate,
) -> Result<CheckedCounterexample<'a>, InclusionFailure> {
    if !certificate.basis.matches(graph)
        || certificate.source != *source
        || certificate.destination != *destination
    {
        return Err(InclusionFailure::BasisMismatch);
    }
    let accepted = validator.accepts_slot(source, borrowed_slot(&certificate.value));
    if matches!(accepted, ValueDecision::Accepted)
        && destination_rejection(validator, destination, &certificate.value).as_ref()
            == Some(&certificate.destination_failure)
    {
        Ok(CheckedCounterexample { graph, certificate })
    } else {
        Err(InclusionFailure::CounterexampleMismatch)
    }
}
pub(crate) fn destination_rejection(
    validator: &mut PreparedValidator<'_>,
    destination: &SlotContract,
    value: &SlotValue,
) -> Option<ValueFailure> {
    match value {
        SlotValue::Absent => destination.required.then(|| {
            rejection_failure(
                &destination.type_ref,
                SlotValue::Absent,
                ValueCondition::MissingRequired,
            )
        }),
        SlotValue::Null => (!destination.nullable).then(|| {
            rejection_failure(
                &destination.type_ref,
                SlotValue::Null,
                ValueCondition::NullNotAllowed,
            )
        }),
        SlotValue::Present(actual) => validator.reject_value_fuel(
            (json_size(actual) + 1) * (validator.graph().nodes.len() + 1),
            &destination.type_ref,
            &[],
            actual,
        ),
    }
}
fn included_format(s: &FormatRule, d: &FormatRule) -> bool {
    s == d
        || matches!(d, FormatRule::Text)
        || matches!(d,FormatRule::Choice(v)if v.iter().any(|x|included_format(s,x)))
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
fn format_use_accepts(profile: &VersionedSemanticProfile, format: &FormatUse, text: &str) -> bool {
    format_use_rule(profile, format)
        .is_some_and(|rule| recognize_format(rule, profile.grapheme_rules.as_ref(), text))
}
fn extra_allows_key(
    profile: &VersionedSemanticProfile,
    key_format: &Option<FormatUse>,
    key: &str,
) -> bool {
    key_format
        .as_ref()
        .is_none_or(|format| format_use_accepts(profile, format, key))
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
        (BranchSelector::MemberShape(source), BranchSelector::MemberShape(destination)) => {
            source == destination
        }
        (BranchSelector::Kind(source), BranchSelector::Kind(destination)) => source == destination,
        (BranchSelector::Otherwise, BranchSelector::Otherwise) => true,
        _ => false,
    }
}
fn disjoint_from_all(destination: &UnionBranch, sources: &[UnionBranch]) -> bool {
    sources
        .iter()
        .all(|source| selector_disjoint(destination, source))
}
fn union_branch_pairs<'a>(
    source: &'a [UnionBranch],
    destination: &'a [UnionBranch],
) -> Option<Vec<(&'a TypeRef, &'a TypeRef)>> {
    match (source.split_first(), destination.split_first()) {
        (None, _) => Some(vec![]),
        (Some(_), None) => None,
        (Some((source_head, source_rest)), Some((destination_head, destination_rest))) => {
            if selectors_equal(source_head, destination_head) {
                let mut pairs = union_branch_pairs(source_rest, destination_rest)?;
                pairs.insert(0, (&source_head.target, &destination_head.target));
                Some(pairs)
            } else if disjoint_from_all(destination_head, source) {
                union_branch_pairs(source, destination_rest)
            } else {
                None
            }
        }
    }
}
pub(crate) fn lower_contained_nat(
    source: &Option<num_bigint::BigUint>,
    destination: &Option<num_bigint::BigUint>,
) -> bool {
    destination.as_ref().is_none_or(|destination| {
        source
            .as_ref()
            .map_or(destination.is_zero(), |source| destination <= source)
    })
}
fn lower_contained_int(
    source: &Option<num_bigint::BigInt>,
    destination: &Option<num_bigint::BigInt>,
) -> bool {
    destination
        .as_ref()
        .is_none_or(|bound| source.as_ref().is_some_and(|minimum| bound <= minimum))
}
fn upper_contained_int(
    source: &Option<num_bigint::BigInt>,
    destination: &Option<num_bigint::BigInt>,
) -> bool {
    destination
        .as_ref()
        .is_none_or(|bound| source.as_ref().is_some_and(|maximum| maximum <= bound))
}
pub(crate) fn upper_contained_nat(
    source: &Option<num_bigint::BigUint>,
    destination: &Option<num_bigint::BigUint>,
) -> bool {
    destination
        .as_ref()
        .is_none_or(|bound| source.as_ref().is_some_and(|maximum| maximum <= bound))
}
fn integer_number_only(graph: &SemanticGraph, spec: &IntegerSpec) -> bool {
    graph
        .profile
        .integer_domain(spec.domain.as_deref())
        .is_some_and(|binding| binding.forms.as_slice() == [IntegerForm::Number])
}
fn integer_finite(spec: &IntegerSpec) -> Option<Vec<num_bigint::BigInt>> {
    spec.const_value
        .as_ref()
        .map(|value| vec![value.clone()])
        .or_else(|| spec.enum_values.clone())
}
pub(crate) fn integer_rule_check(
    validator: &mut PreparedValidator<'_>,
    graph: &SemanticGraph,
    source_ref: &TypeRef,
    destination_ref: &TypeRef,
    source: &IntegerSpec,
    destination: &IntegerSpec,
) -> bool {
    if !integer_number_only(graph, source)
        || !integer_number_only(graph, destination)
        || source.domain != destination.domain
    {
        return false;
    }
    match integer_finite(source) {
        Some(values) => values.iter().all(|value| {
            !matches!(
                validator.accepts_value(source_ref, &JsonValue::Num(value.clone())),
                ValueDecision::Accepted
            ) || matches!(
                validator.accepts_value(destination_ref, &JsonValue::Num(value.clone())),
                ValueDecision::Accepted
            )
        }),
        None => {
            destination.const_value.is_none()
                && destination.enum_values.is_none()
                && lower_contained_int(&source.minimum, &destination.minimum)
                && upper_contained_int(&source.maximum, &destination.maximum)
        }
    }
}
fn length_bounds_included(source: &[LengthBound], destination: &[LengthBound]) -> bool {
    destination.iter().all(|target| {
        source.iter().any(|candidate| {
            candidate.unit == target.unit
                && lower_contained_nat(&candidate.minimum, &target.minimum)
                && upper_contained_nat(&candidate.maximum, &target.maximum)
        })
    })
}
pub(crate) fn string_rule_check(source: &StringSpec, destination: &StringSpec) -> bool {
    let mut source_without_lengths = source.clone();
    source_without_lengths.lengths.clear();
    let mut destination_without_lengths = destination.clone();
    destination_without_lengths.lengths.clear();
    source_without_lengths == destination_without_lengths
        && length_bounds_included(&source.lengths, &destination.lengths)
}
pub(crate) fn product_field_pairs(
    graph: &SemanticGraph,
    source: &ProductSpec,
    destination: &ProductSpec,
) -> Vec<(TypeRef, TypeRef)> {
    let mut pairs = vec![];
    for destination_field in &destination.fields {
        if let Some(source_field) = source
            .fields
            .iter()
            .find(|field| field.wire_name == destination_field.wire_name)
        {
            pairs.push((
                source_field.slot.type_ref.clone(),
                destination_field.slot.type_ref.clone(),
            ));
        } else if !destination_field.slot.required
            && graph.profile.tag.as_ref().map(|tag| &tag.key) != Some(&destination_field.wire_name)
        {
            if let ExtraMembers::Allow { value, .. } = &source.extras {
                pairs.push((
                    value.type_ref.clone(),
                    destination_field.slot.type_ref.clone(),
                ));
            }
        }
    }
    if let ExtraMembers::Allow { value, .. } = &destination.extras {
        for source_field in &source.fields {
            if !destination
                .fields
                .iter()
                .any(|field| field.wire_name == source_field.wire_name)
            {
                pairs.push((source_field.slot.type_ref.clone(), value.type_ref.clone()));
            }
        }
    }
    if let (
        ExtraMembers::Allow {
            value: source_value,
            ..
        },
        ExtraMembers::Allow {
            value: destination_value,
            ..
        },
    ) = (&source.extras, &destination.extras)
    {
        pairs.push((
            source_value.type_ref.clone(),
            destination_value.type_ref.clone(),
        ));
    }
    pairs
}
pub(crate) fn product_rule_shape_check(
    validator: &mut PreparedValidator<'_>,
    graph: &SemanticGraph,
    source: &ProductSpec,
    destination: &ProductSpec,
) -> bool {
    let tag = graph.profile.tag.as_ref().map(|tag| tag.key.as_str());
    destination.fields.iter().all(|target| match source.fields.iter().find(|field| field.wire_name == target.wire_name) {
        Some(origin) => presence_included(&origin.slot, &target.slot),
        None => !target.slot.required && tag != Some(target.wire_name.as_str()) && matches!(&source.extras, ExtraMembers::Allow { value, .. } if (!value.nullable && type_rejects_null(validator, &value.type_ref)) || target.slot.nullable),
    }) && source.fields.iter().all(|origin| {
        destination.fields.iter().any(|field| field.wire_name == origin.wire_name) || tag == Some(origin.wire_name.as_str()) || matches!(&destination.extras, ExtraMembers::Allow { key_format, value } if extra_allows_key(&graph.profile, key_format, &origin.wire_name) && (!origin.slot.nullable || value.nullable))
    }) && match (&source.extras, &destination.extras) {
        (ExtraMembers::Reject, _) => true,
        (ExtraMembers::Allow { .. }, ExtraMembers::Reject) => false,
        (ExtraMembers::Allow { key_format: source_key, value: source_value }, ExtraMembers::Allow { key_format: destination_key, value: destination_value }) => format_use_included(&graph.profile, source_key, destination_key) && (!source_value.nullable || destination_value.nullable),
    }
}
fn type_rejects_null(validator: &mut PreparedValidator<'_>, reference: &TypeRef) -> bool {
    matches!(
        validator.expand_value(reference, &[], &JsonValue::Null),
        crate::semantic_expansion::Expansion::Rejected(_)
    )
}
fn product_rule_check(
    validator: &mut PreparedValidator<'_>,
    graph: &SemanticGraph,
    table: &[PairEntry],
    source: &ProductSpec,
    destination: &ProductSpec,
) -> bool {
    product_rule_shape_check(validator, graph, source, destination)
        && product_field_pairs(graph, source, destination)
            .iter()
            .all(|(source, destination)| includes_pair(table, source, destination))
}
fn has_otherwise(branches: &[UnionBranch]) -> bool {
    branches
        .iter()
        .any(|branch| branch.selector == BranchSelector::Otherwise)
}
pub(crate) fn rule_u_coverage(source: &UnionSpec, destination: &UnionSpec) -> bool {
    if has_otherwise(&source.branches) {
        source == destination
    } else {
        union_branch_pairs(&source.branches, &destination.branches).is_some()
    }
}
pub(crate) fn rule_u_child_pairs(
    source: &UnionSpec,
    destination: &UnionSpec,
) -> Vec<(TypeRef, TypeRef)> {
    union_branch_pairs(&source.branches, &destination.branches)
        .unwrap_or_default()
        .into_iter()
        .map(|(source, destination)| (source.clone(), destination.clone()))
        .collect()
}
