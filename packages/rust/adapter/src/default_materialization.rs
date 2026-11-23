// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

use crate::exact_json::json_size;
use crate::semantic_exchange::GenerationFailure;
use crate::semantic_expansion::accepts_value_in;
use crate::semantic_prepared_validation::{NodeIndex, PreparedMetadata, PreparedValidator};
use crate::semantic_types::*;

#[derive(Debug, Clone, PartialEq)]
pub struct DefaultApplication {
    pub value_path: ValuePath,
    pub type_ref: TypeRef,
    pub origin: OccurrenceRef,
    pub value: JsonValue,
}

#[derive(Debug, Clone, PartialEq)]
pub enum DefaultFailure {
    Wire(GenerationFailure),
    Evaluation(crate::semantic_validation::ValidationFailure),
    CertificateMismatch(String),
}

#[derive(Debug, Clone, PartialEq)]
pub struct DefaultedValue {
    value: JsonValue,
    applications: Vec<DefaultApplication>,
}
impl DefaultedValue {
    pub fn value(&self) -> &JsonValue {
        &self.value
    }
    pub fn applications(&self) -> &[DefaultApplication] {
        &self.applications
    }
}

fn validate(
    metadata: &PreparedMetadata<'_>,
    reference: &TypeRef,
    value: &JsonValue,
) -> Result<(), DefaultFailure> {
    match accepts_value_in(metadata, reference, value) {
        ValueDecision::Accepted => Ok(()),
        ValueDecision::Rejected(failure) => Err(DefaultFailure::Evaluation(
            crate::semantic_validation::ValidationFailure::Value(failure),
        )),
        ValueDecision::Unresolved(obligations) => Err(DefaultFailure::Evaluation(
            crate::semantic_validation::ValidationFailure::Unresolved(obligations),
        )),
    }
}
fn origin(reference: &TypeRef) -> OccurrenceRef {
    let mut pointer = reference.pointer.to_vec();
    pointer.push("default".into());
    OccurrenceRef {
        source: reference.source.clone(),
        pointer: pointer.into(),
    }
}
fn unresolved(
    graph: &SemanticGraph,
    reference: &TypeRef,
    path: &ValuePath,
    reason: SemanticReason,
) -> DefaultFailure {
    DefaultFailure::Evaluation(crate::semantic_validation::ValidationFailure::Unresolved(
        vec![SemanticObligation {
            type_ref: reference.clone(),
            origin: OccurrenceRef::from(reference),
            value_path: path.clone(),
            profile: graph.profile.reference.clone(),
            reason,
        }],
    ))
}
fn type_default(shape: &TypeShape) -> Option<JsonValue> {
    match shape {
        TypeShape::Boolean(spec) => spec.default_value.map(JsonValue::Bool),
        TypeShape::Integer(spec) => spec.default_value.clone().map(JsonValue::Num),
        TypeShape::String(spec) => spec.default_value.clone().map(JsonValue::Str),
        _ => None,
    }
}
fn declared_default(
    graph: &SemanticGraph,
    index: &NodeIndex<'_>,
    reference: &TypeRef,
) -> Option<(usize, TypeRef, JsonValue)> {
    let mut current = reference;
    for _ in 0..graph.nodes.len() + 1 {
        let position = index.get(current)?;
        match &graph.nodes.get(position)?.shape {
            TypeShape::Alias { target, .. } => current = target,
            shape => return type_default(shape).map(|value| (position, current.clone(), value)),
        }
    }
    None
}

struct Drafter<'m, 'g> {
    graph: &'g SemanticGraph,
    metadata: &'m PreparedMetadata<'g>,
    validated: std::collections::BTreeSet<usize>,
}

impl Drafter<'_, '_> {
    fn validate_default(
        &mut self,
        position: usize,
        reference: &TypeRef,
        value: &JsonValue,
    ) -> Result<(), DefaultFailure> {
        if self.validated.contains(&position) {
            return Ok(());
        }
        validate(self.metadata, reference, value)?;
        self.validated.insert(position);
        Ok(())
    }

    fn draft(
        &mut self,
        reference: &TypeRef,
        path: &mut ValuePath,
        value: &JsonValue,
        fuel: usize,
    ) -> Result<(JsonValue, Vec<DefaultApplication>), DefaultFailure> {
        crate::stack_growth::grow(|| self.draft_frame(reference, path, value, fuel))
    }

    fn draft_frame(
        &mut self,
        reference: &TypeRef,
        path: &mut ValuePath,
        value: &JsonValue,
        fuel: usize,
    ) -> Result<(JsonValue, Vec<DefaultApplication>), DefaultFailure> {
        let graph = self.graph;
        let metadata = self.metadata;
        if fuel == 0 {
            return Err(unresolved(
                graph,
                reference,
                path,
                SemanticReason::MembershipBound,
            ));
        }
        let position = metadata.node_index(reference);
        let node = position
            .and_then(|position| graph.nodes.get(position))
            .ok_or_else(|| unresolved(graph, reference, path, SemanticReason::UnresolvedType))?;
        let fuel = fuel - 1;
        let mut applications = Vec::new();
        let value = match (&node.shape, value) {
            (TypeShape::Alias { target, .. }, _) => return self.draft(target, path, value, fuel),
            (TypeShape::TaggedUnion(spec), JsonValue::Obj(members)) => {
                let key = graph
                    .profile
                    .tag
                    .as_ref()
                    .map(|model| model.key.as_str())
                    .unwrap_or("");
                if let Some(JsonValue::Str(tag)) = members
                    .iter()
                    .find(|(name, _)| name == key)
                    .map(|(_, item)| item)
                {
                    if let Some(branch) =
                        spec.branches.iter().find(|branch| &branch.wire_tag == tag)
                    {
                        return self.draft(&branch.target, path, value, fuel);
                    }
                }
                value.clone()
            }
            (TypeShape::Array(spec), JsonValue::Arr(items)) => {
                let mut output = Vec::with_capacity(items.len());
                for (index, item) in items.iter().enumerate() {
                    path.push(PathStep::Index(index.into()));
                    let (item, evidence) = self.draft(&spec.item.type_ref, path, item, fuel)?;
                    path.pop();
                    output.push(item);
                    applications.extend(evidence);
                }
                JsonValue::Arr(output)
            }
            (TypeShape::Product(spec), JsonValue::Obj(members)) => {
                let product = metadata.product(position);
                let slot_of = |key: &str| product.and_then(|product| product.slot_of(key));
                let mut present = vec![false; spec.fields.len()];
                let mut output = Vec::with_capacity(members.len());
                for (key, item) in members {
                    let slot = slot_of(key);
                    if let Some(flag) = slot.and_then(|slot| present.get_mut(slot)) {
                        *flag = true;
                    }
                    let item = if let Some(field) = slot.and_then(|slot| spec.fields.get(slot)) {
                        if *item == JsonValue::Null {
                            item.clone()
                        } else {
                            path.push(PathStep::Field(key.clone()));
                            let (item, evidence) =
                                self.draft(&field.slot.type_ref, path, item, fuel)?;
                            path.pop();
                            applications.extend(evidence);
                            item
                        }
                    } else {
                        item.clone()
                    };
                    output.push((key.clone(), item));
                }
                for field in &spec.fields {
                    if slot_of(&field.wire_name)
                        .and_then(|slot| present.get(slot).copied())
                        .unwrap_or(false)
                    {
                        continue;
                    }
                    if let Some((position, reference, item)) =
                        declared_default(graph, metadata.index(), &field.slot.type_ref)
                    {
                        self.validate_default(position, &reference, &item)?;
                        let mut at = path.clone();
                        at.push(PathStep::Field(field.wire_name.clone()));
                        applications.push(DefaultApplication {
                            value_path: at,
                            origin: origin(&reference),
                            type_ref: reference,
                            value: item.clone(),
                        });
                        output.push((field.wire_name.clone(), item));
                    }
                }
                JsonValue::Obj(output)
            }
            _ => value.clone(),
        };
        Ok((value, applications))
    }
}

fn at<'a>(value: &'a JsonValue, path: &[PathStep], graph: &SemanticGraph) -> Option<&'a JsonValue> {
    let mut current = value;
    let mut rest = path;
    loop {
        let Some((step, tail)) = rest.split_first() else {
            return Some(current);
        };
        if *current == JsonValue::Null {
            return Some(current);
        }
        rest = tail;
        current = match (step, current) {
            (PathStep::Field(key), JsonValue::Obj(members)) => {
                &members.iter().find(|(name, _)| name == key)?.1
            }
            (PathStep::Index(index), JsonValue::Arr(items)) => {
                let index = usize::try_from(index).ok()?;
                items.get(index)?
            }
            (PathStep::Variant(tag), JsonValue::Obj(members)) => {
                let key = &graph.profile.tag.as_ref()?.key;
                if members
                    .iter()
                    .find(|(name, _)| name == key)
                    .map(|(_, item)| item)
                    != Some(&JsonValue::Str(tag.clone()))
                {
                    return None;
                }
                current
            }
            _ => return None,
        };
    }
}

pub fn check_default_applications(
    validator: &PreparedValidator<'_>,
    before: &JsonValue,
    after: &JsonValue,
    applications: &[DefaultApplication],
) -> bool {
    applications.is_empty()
        || check_applications_in(
            validator.graph(),
            validator.metadata().index(),
            before,
            after,
            applications,
        )
}

fn check_applications_in(
    graph: &SemanticGraph,
    index: &NodeIndex<'_>,
    before: &JsonValue,
    after: &JsonValue,
    applications: &[DefaultApplication],
) -> bool {
    applications.iter().all(|application| {
        at(before, &application.value_path, graph).is_none()
            && at(after, &application.value_path, graph) == Some(&application.value)
            && application.origin == origin(&application.type_ref)
            && index
                .get(&application.type_ref)
                .and_then(|position| graph.nodes.get(position))
                .and_then(|node| type_default(&node.shape))
                == Some(application.value.clone())
    })
}

pub fn materialize_defaults(
    validator: &PreparedValidator<'_>,
    reference: &TypeRef,
    value: &JsonValue,
) -> Result<DefaultedValue, DefaultFailure> {
    let graph = validator.graph();
    let metadata = validator.metadata();
    let mut drafter = Drafter {
        graph,
        metadata,
        validated: std::collections::BTreeSet::new(),
    };
    let (after, applications) = drafter.draft(
        reference,
        &mut vec![],
        value,
        (json_size(value) + 1) * (graph.nodes.len() + 1),
    )?;
    validate(metadata, reference, &after)?;
    if !check_applications_in(graph, metadata.index(), value, &after, &applications) {
        return Err(DefaultFailure::CertificateMismatch(
            "default source, absence, or result".into(),
        ));
    }
    Ok(DefaultedValue {
        value: after,
        applications,
    })
}

pub fn decode_with_defaults(
    validator: &PreparedValidator<'_>,
    reference: &TypeRef,
    text: &str,
) -> Result<DefaultedValue, DefaultFailure> {
    let value = crate::exact_json::parse_json_text(text)
        .map_err(|error| DefaultFailure::Wire(GenerationFailure::InvalidJson(error.to_string())))?;
    materialize_defaults(validator, reference, &value)
}
