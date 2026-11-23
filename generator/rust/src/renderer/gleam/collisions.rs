// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: AGPL-3.0-only

use super::identifiers::{lower, lower_identifier, ref_name, upper_identifier, Names};
use super::types::default_literal;
use super::wire::{field, list, tag, text, Result};
use crate::renderer::RenderFailure;
use serde_json::Value;
use std::collections::HashMap;

#[derive(Clone, PartialEq, Eq, Hash)]
enum Namespace {
    Type,
    Constructor,
    Value,
    Label(String),
}

impl Namespace {
    fn describe(&self) -> String {
        match self {
            Self::Type => "type".to_owned(),
            Self::Constructor => "constructor".to_owned(),
            Self::Value => "value".to_owned(),
            Self::Label(owner) => format!("label of {owner}"),
        }
    }
}

pub(super) struct Identifier {
    namespace: Namespace,
    name: String,
    origin: String,
}

fn push(out: &mut Vec<Identifier>, namespace: Namespace, name: impl Into<String>, origin: &str) {
    out.push(Identifier {
        namespace,
        name: name.into(),
        origin: origin.to_owned(),
    });
}

fn is_http(contract: &Value) -> Result<bool> {
    Ok(tag(field(contract, "effect")?)? == "HttpRequestResponse")
}

pub(super) fn concrete(named: &[(&Value, String)]) -> Result<Vec<Identifier>> {
    let mut out = Vec::new();
    for (node, type_name) in named {
        let shape = field(node, "shape")?;
        let origin = format!("type {type_name}");
        let origin = origin.as_str();
        let base = lower(type_name);
        let mut values = vec![
            ref_name(type_name),
            format!("value_{base}"),
            format!("new_{base}"),
            format!("from_value_{base}"),
            format!("to_value_{base}"),
            format!("decode_{base}"),
            format!("encode_{base}"),
            format!("with_defaults_{base}"),
            format!("pack_{base}"),
            format!("unpack_{base}"),
        ];
        if default_literal(shape)?.is_some() {
            values.push(format!("default_{base}"));
        }
        let payload = format!("{type_name}Payload");
        match tag(shape)? {
            "Product" => {
                let spec = field(shape, "value")?;
                push(&mut out, Namespace::Type, payload.clone(), origin);
                push(&mut out, Namespace::Constructor, payload.clone(), origin);
                push(
                    &mut out,
                    Namespace::Label(payload.clone()),
                    "extras",
                    origin,
                );
                for member in list(spec, "fields")? {
                    push(
                        &mut out,
                        Namespace::Label(payload.clone()),
                        lower_identifier(text(member, "wire_name")?, "field"),
                        origin,
                    );
                }
            }
            "TaggedUnion" => {
                let spec = field(shape, "value")?;
                push(&mut out, Namespace::Type, payload.clone(), origin);
                for branch in list(spec, "branches")? {
                    let identifier = format!(
                        "{type_name}{}",
                        upper_identifier(text(branch, "wire_tag")?, "Variant")
                    );
                    push(&mut out, Namespace::Constructor, identifier.clone(), origin);
                    push(&mut out, Namespace::Label(identifier), "value", origin);
                }
            }
            _ => {}
        }
        push(&mut out, Namespace::Type, type_name.clone(), origin);
        push(&mut out, Namespace::Constructor, type_name.clone(), origin);
        push(
            &mut out,
            Namespace::Label(type_name.clone()),
            "value",
            origin,
        );
        if matches!(tag(shape)?, "Bytes" | "RawBody") {
            push(
                &mut out,
                Namespace::Label(type_name.clone()),
                "wire",
                origin,
            );
        }
        for value in values {
            push(&mut out, Namespace::Value, value, origin);
        }
    }
    Ok(out)
}

pub(super) fn reserved() -> Vec<Identifier> {
    let mut out = Vec::new();
    let origin = "reserved";
    for name in [
        "Option",
        "Result",
        "List",
        "String",
        "Int",
        "Bool",
        "Nil",
        "ValueFailure",
        "Context",
    ] {
        push(&mut out, Namespace::Type, name, origin);
    }
    for name in ["None", "Some", "Ok", "Error", "True", "False", "Context"] {
        push(&mut out, Namespace::Constructor, name, origin);
    }
    for name in [
        "required_generation",
        "initialize",
        "graph",
        "prepared",
        "context_library",
        "context_validate_outcome",
        "context_encode_outcome",
        "context_decode_outcome",
        "checked_execution",
        "representation",
        "annotations",
        "groups",
        "checked_generation",
        "start",
        "resume",
    ] {
        push(&mut out, Namespace::Value, name, origin);
    }
    push(
        &mut out,
        Namespace::Label("Context".to_owned()),
        "checked",
        origin,
    );
    push(
        &mut out,
        Namespace::Label("Context".to_owned()),
        "prepared",
        origin,
    );
    out
}

pub(super) fn execution(problem: &Value) -> Result<Vec<Identifier>> {
    let origin = "execution";
    let mut out = Vec::new();
    let mut providers = Vec::new();
    for (index, signature) in list(problem, "signatures")?.iter().enumerate() {
        let http = is_http(signature)?;
        let outcomes = list(signature, "outcomes")?.len();
        let mut types = vec![
            format!("Provider{index}Arguments"),
            format!("Provider{index}Outcome"),
        ];
        let mut constructors = vec![format!("Provider{index}Arguments")];
        constructors
            .extend((0..outcomes).map(|outcome| format!("Provider{index}Outcome{outcome}")));
        let mut values = vec![
            format!("provider{index}_arguments"),
            format!("provider{index}_outcome"),
        ];
        if http {
            types.push(format!("Provider{index}Http"));
            types.push(format!("Provider{index}HttpAttempt"));
            constructors.extend([
                format!("Provider{index}Http"),
                format!("Provider{index}HttpAttemptReady"),
                format!("Provider{index}HttpAttemptCompleted"),
            ]);
            values.push(format!("provider{index}_outcome_contracts"));
        }
        providers.push((types, constructors, values));
    }
    for name in ["Providers", "Arguments", "CompositionResult", "RunProgress"] {
        push(&mut out, Namespace::Type, name, origin);
    }
    for name in [
        "Providers",
        "Arguments",
        "Success",
        "Completed",
        "Pending",
        "CompositionAbsent",
    ] {
        push(&mut out, Namespace::Constructor, name, origin);
    }
    for name in [
        "embedded_basis",
        "embedded_generation",
        "provider_list",
        "argument_list",
        "decode_result",
        "map_progress",
        "run",
    ] {
        push(&mut out, Namespace::Value, name, origin);
    }
    for (types, constructors, values) in providers {
        for name in types {
            push(&mut out, Namespace::Type, name, origin);
        }
        for name in constructors {
            push(&mut out, Namespace::Constructor, name, origin);
        }
        for name in values {
            push(&mut out, Namespace::Value, name, origin);
        }
    }
    for index in 0..list(field(problem, "goal")?, "failures")?.len() {
        push(
            &mut out,
            Namespace::Constructor,
            format!("Failure{index}"),
            origin,
        );
    }
    Ok(out)
}

pub(super) fn signatures(definitions: &[Value], names: &Names) -> Result<Vec<Identifier>> {
    let mut out = Vec::new();
    for definition in definitions {
        let id = text(definition, "id")?;
        let wire = text(definition, "wire_identity")?;
        let origin = format!("signature {id}");
        let origin = origin.as_str();
        let upper = upper_identifier(wire, "Signature");
        let name = lower_identifier(wire, "signature");
        let shape = field(definition, "shape")?;
        match tag(shape)? {
            "Value" | "Message" => {
                let child = names.by_id(text(shape, "value")?)?;
                push(
                    &mut out,
                    Namespace::Value,
                    format!("{name}_identity"),
                    origin,
                );
                if upper != child {
                    push(&mut out, Namespace::Type, upper.clone(), origin);
                }
                if name != lower(child) {
                    push(&mut out, Namespace::Value, format!("decode_{name}"), origin);
                    push(&mut out, Namespace::Value, format!("encode_{name}"), origin);
                }
            }
            "Symbol" => push(&mut out, Namespace::Value, name.clone(), origin),
            "Operation" => {
                let contract = field(shape, "value")?;
                let input_type = format!("{upper}Input");
                let outcome_type = format!("{upper}Outcome");
                push(&mut out, Namespace::Type, input_type.clone(), origin);
                push(&mut out, Namespace::Type, outcome_type.clone(), origin);
                push(&mut out, Namespace::Constructor, input_type.clone(), origin);
                let http = is_http(contract)?;
                if http {
                    push(&mut out, Namespace::Type, format!("{upper}Binding"), origin);
                }
                for port in list(contract, "inputs")? {
                    push(
                        &mut out,
                        Namespace::Label(input_type.clone()),
                        lower_identifier(text(port, "id")?, "port"),
                        origin,
                    );
                }
                for outcome in list(contract, "outcomes")? {
                    let constructor = format!(
                        "{outcome_type}{}",
                        upper_identifier(text(outcome, "id")?, "Variant")
                    );
                    push(
                        &mut out,
                        Namespace::Constructor,
                        constructor.clone(),
                        origin,
                    );
                    for port in list(outcome, "value_ports")? {
                        push(
                            &mut out,
                            Namespace::Label(constructor.clone()),
                            lower_identifier(text(port, "id")?, "port"),
                            origin,
                        );
                    }
                }
                let mut values = vec![
                    format!("{name}_identity"),
                    format!("{name}_outcome_id"),
                    format!("validate_{name}_input"),
                    format!("validate_{name}_outcome"),
                    format!("to_outcome_{name}"),
                    format!("from_outcome_{name}"),
                    format!("unpack_outcome_{name}"),
                    format!("encode_{name}_outcome"),
                    format!("decode_{name}_outcome"),
                ];
                if http {
                    values.push(format!("call_{name}"));
                }
                for value in values {
                    push(&mut out, Namespace::Value, value, origin);
                }
            }
            _ => return Err(super::wire::invalid("generated definition shape")),
        }
    }
    Ok(out)
}

pub(super) fn check(identifiers: &[Identifier]) -> std::result::Result<(), RenderFailure> {
    let mut seen: HashMap<(&Namespace, &str), &str> = HashMap::new();
    for identifier in identifiers {
        let key = (&identifier.namespace, identifier.name.as_str());
        if let Some(first) = seen.get(&key) {
            return Err(RenderFailure::IdentifierCollision {
                namespace: identifier.namespace.describe(),
                name: identifier.name.clone(),
                first: (*first).to_owned(),
                second: identifier.origin.clone(),
            });
        }
        seen.insert(key, identifier.origin.as_str());
    }
    Ok(())
}
