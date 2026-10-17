// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

use crate::semantic_types::*;
use crate::semantic_validation::{accepts_value, meaning_obligations};

#[derive(Debug, Clone, PartialEq)]
pub struct DefaultApplication {
    pub value_path: ValuePath,
    pub type_ref: TypeRef,
    pub origin: OccurrenceRef,
    pub value: JsonValue,
}

#[derive(Debug, Clone, PartialEq)]
pub enum DefaultFailure {
    Wire(String),
    Rejected(ValueFailure),
    Unresolved(Vec<SemanticObligation>),
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
    graph: &SemanticGraph,
    reference: &TypeRef,
    value: &JsonValue,
) -> Result<(), DefaultFailure> {
    let obligations = meaning_obligations(graph, std::slice::from_ref(reference));
    if !obligations.is_empty() {
        return Err(DefaultFailure::Unresolved(obligations));
    }
    match accepts_value(graph, reference, value) {
        ValueDecision::Accepted => Ok(()),
        ValueDecision::Rejected(failure) => Err(DefaultFailure::Rejected(failure)),
        ValueDecision::Unresolved(obligations) => Err(DefaultFailure::Unresolved(obligations)),
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
    DefaultFailure::Unresolved(vec![SemanticObligation {
        type_ref: reference.clone(),
        origin: OccurrenceRef::from(reference),
        value_path: path.clone(),
        profile: graph.profile.reference.clone(),
        reason,
    }])
}
fn type_default(shape: &TypeShape) -> Option<JsonValue> {
    match shape {
        TypeShape::Boolean(spec) => spec.default_value.map(JsonValue::Bool),
        TypeShape::Integer(spec) => spec.default_value.clone().map(JsonValue::Num),
        TypeShape::String(spec) => spec.default_value.clone().map(JsonValue::Str),
        _ => None,
    }
}
fn declared_default(graph: &SemanticGraph, reference: &TypeRef) -> Option<(TypeRef, JsonValue)> {
    let mut current = reference;
    for _ in 0..graph.nodes.len() + 1 {
        match &graph.find_type(current)?.shape {
            TypeShape::Alias { target, .. } => current = target,
            shape => return type_default(shape).map(|value| (current.clone(), value)),
        }
    }
    None
}
fn size(value: &JsonValue) -> usize {
    1 + match value {
        JsonValue::Arr(items) => items.iter().map(size).sum(),
        JsonValue::Obj(members) => members.iter().map(|(_, value)| size(value)).sum(),
        _ => 0,
    }
}

fn draft(
    graph: &SemanticGraph,
    reference: &TypeRef,
    path: &ValuePath,
    value: &JsonValue,
    fuel: usize,
) -> Result<(JsonValue, Vec<DefaultApplication>), DefaultFailure> {
    if fuel == 0 {
        return Err(unresolved(
            graph,
            reference,
            path,
            SemanticReason::MembershipBound,
        ));
    }
    let node = graph
        .find_type(reference)
        .ok_or_else(|| unresolved(graph, reference, path, SemanticReason::UnresolvedType))?;
    let fuel = fuel - 1;
    let mut applications = Vec::new();
    let value = match (&node.shape, value) {
        (TypeShape::Alias { target, .. }, _) => return draft(graph, target, path, value, fuel),
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
                if let Some(branch) = spec.branches.iter().find(|branch| &branch.wire_tag == tag) {
                    return draft(graph, &branch.target, path, value, fuel);
                }
            }
            value.clone()
        }
        (TypeShape::Array(spec), JsonValue::Arr(items)) => {
            let mut output = Vec::new();
            for (index, item) in items.iter().enumerate() {
                let mut at = path.clone();
                at.push(PathStep::Index(index.into()));
                let (item, evidence) = draft(graph, &spec.item.type_ref, &at, item, fuel)?;
                output.push(item);
                applications.extend(evidence);
            }
            JsonValue::Arr(output)
        }
        (TypeShape::Product(spec), JsonValue::Obj(members)) => {
            let mut output = Vec::new();
            for (key, item) in members {
                let item = if let Some(field) =
                    spec.fields.iter().find(|field| &field.wire_name == key)
                {
                    if *item == JsonValue::Null {
                        item.clone()
                    } else {
                        let mut at = path.clone();
                        at.push(PathStep::Field(key.clone()));
                        let (item, evidence) = draft(graph, &field.slot.type_ref, &at, item, fuel)?;
                        applications.extend(evidence);
                        item
                    }
                } else {
                    item.clone()
                };
                output.push((key.clone(), item));
            }
            for field in &spec.fields {
                if members.iter().any(|(key, _)| key == &field.wire_name) {
                    continue;
                }
                if let Some((reference, item)) = declared_default(graph, &field.slot.type_ref) {
                    validate(graph, &reference, &item)?;
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

fn at<'a>(value: &'a JsonValue, path: &[PathStep], graph: &SemanticGraph) -> Option<&'a JsonValue> {
    if path.is_empty() {
        return Some(value);
    }
    if *value == JsonValue::Null {
        return Some(value);
    }
    let (step, rest) = path.split_first()?;
    match (step, value) {
        (PathStep::Field(key), JsonValue::Obj(members)) => at(
            &members.iter().find(|(name, _)| name == key)?.1,
            rest,
            graph,
        ),
        (PathStep::Index(index), JsonValue::Arr(items)) => {
            let index = usize::try_from(index).ok()?;
            at(items.get(index)?, rest, graph)
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
            at(value, rest, graph)
        }
        _ => None,
    }
}

pub fn check_default_applications(
    graph: &SemanticGraph,
    before: &JsonValue,
    after: &JsonValue,
    applications: &[DefaultApplication],
) -> bool {
    applications.iter().all(|application| {
        at(before, &application.value_path, graph).is_none()
            && at(after, &application.value_path, graph) == Some(&application.value)
            && application.origin == origin(&application.type_ref)
            && graph
                .find_type(&application.type_ref)
                .and_then(|node| type_default(&node.shape))
                == Some(application.value.clone())
    })
}

pub fn materialize_defaults(
    graph: &SemanticGraph,
    reference: &TypeRef,
    value: &JsonValue,
) -> Result<DefaultedValue, DefaultFailure> {
    let (after, applications) = draft(
        graph,
        reference,
        &vec![],
        value,
        (size(value) + 1) * (graph.nodes.len() + 1),
    )?;
    validate(graph, reference, &after)?;
    if !check_default_applications(graph, value, &after, &applications) {
        return Err(DefaultFailure::CertificateMismatch(
            "default source, absence, or result".into(),
        ));
    }
    Ok(DefaultedValue {
        value: after,
        applications,
    })
}

fn duplicate_wire_member(value: &JsonValue) -> Option<&str> {
    match value {
        JsonValue::Obj(members) => {
            let mut keys = std::collections::HashSet::new();
            for (key, _) in members {
                if !keys.insert(key.as_str()) {
                    return Some(key);
                }
            }
            members
                .iter()
                .find_map(|(_, item)| duplicate_wire_member(item))
        }
        JsonValue::Arr(items) => items.iter().find_map(duplicate_wire_member),
        _ => None,
    }
}

pub fn decode_with_defaults(
    graph: &SemanticGraph,
    reference: &TypeRef,
    text: &str,
) -> Result<DefaultedValue, DefaultFailure> {
    let value =
        serde_json::from_str(text).map_err(|error| DefaultFailure::Wire(error.to_string()))?;
    if let Some(key) = duplicate_wire_member(&value) {
        return Err(DefaultFailure::Wire(format!("DuplicateField:{key}")));
    }
    materialize_defaults(graph, reference, &value)
}
