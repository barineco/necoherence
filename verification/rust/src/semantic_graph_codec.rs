// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: AGPL-3.0-only

use necoherence::exact_json::JsonValue;
use necoherence::semantic_exchange::{
    decode_wire_text_at, parse_exchange_text, GenerationFailure, WireDecode,
};
use necoherence::semantic_types::{
    SemanticGraph, StringSpec, TypeNode, TypeRef, TypeShape, VersionedSemanticProfile,
};

pub fn decode_semantic_graph(text: &str, path: &str) -> Result<SemanticGraph, GenerationFailure> {
    let graph: SemanticGraph = decode_wire_text_at(text, path)?;
    necoherence::semantic_validation::check_profile(&graph.profile)
        .map_err(GenerationFailure::Profile)?;
    Ok(graph)
}

/// Decodes the graph of the public validation entry as the Lean runner reads it.
pub fn decode_public_validation_graph(
    text: &str,
    path: &str,
) -> Result<SemanticGraph, GenerationFailure> {
    let value = parse_exchange_text(text).map_err(|failure| match failure {
        GenerationFailure::Syntax { message, .. } | GenerationFailure::InvalidJson(message) => {
            syntax(path, &message)
        }
        other => other,
    })?;
    let members = object_members(&value, path, &["profile", "nodes", "source_refs"])?;
    let profile = VersionedSemanticProfile::decode_wire(
        field(members, path, "profile")?,
        &field_path(path, "profile"),
    )?;
    let nodes = match field(members, path, "nodes")? {
        JsonValue::Arr(items) => items
            .iter()
            .enumerate()
            .map(|(index, item)| decode_string_node(item, &format!("{path}.nodes[{index}]")))
            .collect::<Result<Vec<_>, _>>()?,
        _ => return Err(syntax(&field_path(path, "nodes"), "array expected")),
    };
    let graph = SemanticGraph {
        profile,
        nodes,
        source_refs: vec![],
    };
    necoherence::semantic_validation::check_profile(&graph.profile)
        .map_err(GenerationFailure::Profile)?;
    Ok(graph)
}

fn decode_string_node(value: &JsonValue, path: &str) -> Result<TypeNode, GenerationFailure> {
    let members = object_members(
        value,
        path,
        &[
            "reference",
            "shape",
            "description",
            "attributes",
            "extensions",
        ],
    )?;
    let shape = decode_string_shape(field(members, path, "shape")?, &field_path(path, "shape"))?;
    let reference = TypeRef::decode_wire(
        field(members, path, "reference")?,
        &field_path(path, "reference"),
    )?;
    Ok(TypeNode {
        reference,
        shape,
        description: None,
        attributes: vec![],
        extensions: vec![],
    })
}

fn decode_string_shape(value: &JsonValue, path: &str) -> Result<TypeShape, GenerationFailure> {
    match tag(value, path)? {
        "String" => {
            let members = object_members(value, path, &["tag", "value"])?;
            StringSpec::decode_wire(field(members, path, "value")?, &field_path(path, "value"))
                .map(TypeShape::String)
        }
        other => Err(GenerationFailure::UnknownTag {
            path: field_path(path, "tag"),
            tag: other.to_owned(),
        }),
    }
}

fn tag<'a>(value: &'a JsonValue, path: &str) -> Result<&'a str, GenerationFailure> {
    let members = match value {
        JsonValue::Obj(members) => members,
        _ => return Err(syntax(&field_path(path, "tag"), "object expected")),
    };
    match field(members, path, "tag")? {
        JsonValue::Str(tag) => Ok(tag),
        _ => Err(syntax(&field_path(path, "tag"), "String expected")),
    }
}

fn object_members<'a>(
    value: &'a JsonValue,
    path: &str,
    names: &[&str],
) -> Result<&'a [(String, JsonValue)], GenerationFailure> {
    let members = match value {
        JsonValue::Obj(members) => members,
        _ => return Err(syntax(path, "object expected")),
    };
    let mut actual: Vec<&str> = members.iter().map(|(name, _)| name.as_str()).collect();
    actual.sort_unstable();
    if let Some(name) = actual.into_iter().find(|name| !names.contains(name)) {
        return Err(GenerationFailure::UnknownField {
            path: field_path(path, name),
            field: name.to_owned(),
        });
    }
    if let Some(name) = names
        .iter()
        .copied()
        .find(|name| !members.iter().any(|(key, _)| key.as_str() == *name))
    {
        return Err(syntax(&field_path(path, name), "missing field"));
    }
    Ok(members)
}

fn field<'a>(
    members: &'a [(String, JsonValue)],
    path: &str,
    name: &str,
) -> Result<&'a JsonValue, GenerationFailure> {
    members
        .iter()
        .find(|(key, _)| key.as_str() == name)
        .map(|(_, value)| value)
        .ok_or_else(|| {
            syntax(
                &field_path(path, name),
                &format!("property not found: {name}"),
            )
        })
}

fn field_path(path: &str, name: &str) -> String {
    format!("{path}.{name}")
}

fn syntax(path: &str, message: &str) -> GenerationFailure {
    GenerationFailure::Syntax {
        path: path.to_owned(),
        message: message.to_owned(),
    }
}
