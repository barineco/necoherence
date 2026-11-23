// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: AGPL-3.0-only

use super::problem_codec::wire_basis;
use necoherence::exact_json::JsonValue as ExchangeJson;
use necoherence::semantic_composition::*;
use necoherence::semantic_exchange::{syntax, WireDecode};
use necoherence::semantic_types::{SourceIdentity, SourceRef};
use necoherence::signature_admission::signature_type_ref;
use necoherence::signature_composition_codec::{
    array, decode_function_ref, decode_resource_lot_ref, field_path, to_exchange, Decoded,
};
use necoherence::signature_derivation_codec::decode_producer_ref;
use necoherence::type_signatures::{SignatureDefinitionShape, TypeSignatureLibrary};
use serde_json::Value;
use std::collections::VecDeque;
use std::sync::OnceLock;

const SCHEMA: &str = necoherence::semantic_exchange::COMPOSITION_DIAGNOSTICS_SCHEMA;

fn registry() -> &'static Value {
    static REGISTRY: OnceLock<Value> = OnceLock::new();
    REGISTRY.get_or_init(|| serde_json::from_str(SCHEMA).unwrap_or(Value::Null))
}

pub(crate) fn check(
    library: &TypeSignatureLibrary,
    input: &CompositionInput,
    name: &str,
    value: &ExchangeJson,
) -> Decoded<()> {
    let schema = serde_json::json!({ "$ref": format!("#/$defs/{name}") });
    validate(registry(), library, input, &schema, value)
}

fn validate(
    registry: &Value,
    library: &TypeSignatureLibrary,
    input: &CompositionInput,
    schema: &Value,
    value: &ExchangeJson,
) -> Decoded<()> {
    if schema == &Value::Bool(false) {
        return Err(syntax("$", "diagnostic extra array item"));
    }
    if schema == &Value::Bool(true) {
        return Ok(());
    }
    if let Some(reference) = schema.get("$ref").and_then(Value::as_str) {
        let name = reference.get("#/$defs/".len()..).unwrap_or("");
        let target = registry
            .get(name)
            .ok_or_else(|| syntax("$", "unresolved diagnostic schema"))?;
        validate(registry, library, input, target, value)?;
        references(library, input, name, value)?;
        return Ok(());
    }
    if let Some(expected) = schema.get("const") {
        if value != &to_exchange(expected)? {
            return Err(syntax("$", "diagnostic tag mismatch"));
        }
    }
    for key in ["oneOf", "anyOf"] {
        if let Some(variants) = schema.get(key).and_then(Value::as_array) {
            if !variants
                .iter()
                .any(|variant| validate(registry, library, input, variant, value).is_ok())
            {
                return Err(syntax("$", "diagnostic variant mismatch"));
            }
            return Ok(());
        }
    }
    if let Some(kind) = schema.get("type").and_then(Value::as_str) {
        match kind {
            "null" => {
                if value != &ExchangeJson::Null {
                    return Err(syntax("$", "diagnostic null expected"));
                }
            }
            "boolean" => {
                if !matches!(value, ExchangeJson::Bool(_)) {
                    return Err(syntax("$", "diagnostic boolean expected"));
                }
            }
            "string" => {
                let text = text_of(value, "$")?;
                if let Some(expression) = schema.get("pattern").and_then(Value::as_str) {
                    if !pattern(expression, text) {
                        return Err(syntax("$", "diagnostic string domain"));
                    }
                }
            }
            "object" => {
                let ExchangeJson::Obj(fields) = value else {
                    return Err(syntax("$", "diagnostic object expected"));
                };
                let properties = schema
                    .get("properties")
                    .and_then(Value::as_object)
                    .ok_or_else(|| syntax("$", "diagnostic properties"))?;
                let required = schema
                    .get("required")
                    .and_then(Value::as_array)
                    .ok_or_else(|| syntax("$", "diagnostic required"))?;
                for key in required {
                    let key = key
                        .as_str()
                        .ok_or_else(|| syntax("$", "diagnostic required key"))?;
                    field(value, "$", key)?;
                }
                for (key, member) in fields {
                    let property = properties
                        .get(key)
                        .ok_or_else(|| syntax("$", "diagnostic closed object field"))?;
                    validate(registry, library, input, property, member)?;
                }
            }
            "array" => {
                let ExchangeJson::Arr(values) = value else {
                    return Err(syntax("$", "diagnostic array expected"));
                };
                if let Some(minimum) = schema.get("minItems").and_then(Value::as_u64) {
                    if (values.len() as u64) < minimum {
                        return Err(syntax("$", "diagnostic short array"));
                    }
                }
                if let Some(maximum) = schema.get("maxItems").and_then(Value::as_u64) {
                    if maximum < values.len() as u64 {
                        return Err(syntax("$", "diagnostic long array"));
                    }
                }
                let prefix = schema
                    .get("prefixItems")
                    .and_then(Value::as_array)
                    .cloned()
                    .unwrap_or_default();
                for (index, item) in values.iter().enumerate() {
                    let child = match prefix.get(index) {
                        Some(child) => child,
                        None => schema
                            .get("items")
                            .ok_or_else(|| syntax("$", "diagnostic array items"))?,
                    };
                    validate(registry, library, input, child, item)?;
                }
            }
            _ => return Err(syntax("$", "unsupported diagnostic schema type")),
        }
    }
    Ok(())
}

fn pattern(expression: &str, text: &str) -> bool {
    match expression {
        "^(0|[1-9][0-9]*)$" => is_unsigned(text),
        "^(0|-?[1-9][0-9]*)$" => {
            let digits = text.strip_prefix('-').unwrap_or(text);
            is_unsigned(digits) && (digits != "0" || text == "0")
        }
        "^[0-9a-f]{64}$" => {
            text.len() == 64
                && text
                    .bytes()
                    .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
        }
        _ => serde_json::from_str::<Value>(text).is_ok_and(|value| value.is_number()),
    }
}

fn is_unsigned(text: &str) -> bool {
    text == "0"
        || (text.starts_with(|character: char| ('1'..='9').contains(&character))
            && text.bytes().all(|byte| byte.is_ascii_digit()))
}

fn field<'a>(value: &'a ExchangeJson, path: &str, name: &str) -> Decoded<&'a ExchangeJson> {
    match value {
        ExchangeJson::Obj(fields) => fields
            .iter()
            .find(|(key, _)| key == name)
            .map(|(_, value)| value)
            .ok_or_else(|| syntax(&field_path(path, name), "diagnostic field")),
        _ => Err(syntax(path, "diagnostic object expected")),
    }
}

fn text_of<'a>(value: &'a ExchangeJson, path: &str) -> Decoded<&'a str> {
    match value {
        ExchangeJson::Str(text) => Ok(text),
        _ => Err(syntax(path, "diagnostic string expected")),
    }
}

fn string_field<'a>(value: &'a ExchangeJson, path: &str, name: &str) -> Decoded<&'a str> {
    text_of(field(value, path, name)?, &field_path(path, name))
}

fn pair_key<'a>(pair: &'a ExchangeJson, path: &str) -> Decoded<&'a str> {
    match pair {
        ExchangeJson::Arr(items) => match items.first() {
            Some(key) => text_of(key, path),
            None => Err(syntax(path, "diagnostic binding pair")),
        },
        _ => Err(syntax(path, "diagnostic binding pair")),
    }
}

fn resolve_producer(input: &CompositionInput, producer: &ProducerRef) -> bool {
    match producer {
        ProducerRef::Initial(id) => input.initial_inputs.iter().any(|value| value.id == *id),
        ProducerRef::InvocationOutcome {
            site,
            outcome,
            port,
        } => input
            .invocation_domain
            .sites
            .iter()
            .find(|value| value.id == *site)
            .is_some_and(|invocation| {
                input
                    .signatures
                    .iter()
                    .find(|function| function.reference == invocation.function)
                    .is_some_and(|function| {
                        function
                            .outcomes
                            .iter()
                            .find(|candidate| candidate.id == *outcome)
                            .is_some_and(|result| {
                                result.value_ports.iter().any(|value| value.id == *port)
                            })
                    })
            }),
    }
}

fn resolve_lot(input: &CompositionInput, lot: &ResourceLotRef) -> bool {
    match lot {
        ResourceLotRef::Initial(id) => input.initial_resources.iter().any(|value| value.id == *id),
        ResourceLotRef::Produced {
            site,
            outcome,
            production,
        } => input
            .invocation_domain
            .sites
            .iter()
            .find(|value| value.id == *site)
            .is_some_and(|invocation| {
                input
                    .signatures
                    .iter()
                    .find(|function| function.reference == invocation.function)
                    .is_some_and(|function| {
                        function
                            .outcomes
                            .iter()
                            .find(|candidate| candidate.id == *outcome)
                            .is_some_and(|result| {
                                result
                                    .produced_resources
                                    .iter()
                                    .any(|value| value.id == *production)
                            })
                    })
            }),
    }
}

fn reaches_type(
    library: &TypeSignatureLibrary,
    type_id: &str,
    mut fuel: usize,
    mut pending: VecDeque<String>,
    mut seen: Vec<String>,
) -> bool {
    loop {
        if fuel == 0 {
            return false;
        }
        fuel -= 1;
        let Some(id) = pending.pop_front() else {
            return false;
        };
        if id == type_id {
            return true;
        }
        if seen.contains(&id) {
            continue;
        }
        let children = library
            .nodes
            .iter()
            .find(|node| node.id == id)
            .map(|node| node.shape.references())
            .unwrap_or_default();
        pending.extend(children.into_iter().map(str::to_owned));
        seen.push(id);
    }
}

fn target_contains_type(library: &TypeSignatureLibrary, definition: &str, type_id: &str) -> bool {
    let roots: Vec<String> = library
        .definitions
        .iter()
        .find(|candidate| candidate.id == definition)
        .map(|candidate| match &candidate.shape {
            SignatureDefinitionShape::Value(root) | SignatureDefinitionShape::Message(root) => {
                vec![root.to_string()]
            }
            _ => Vec::new(),
        })
        .unwrap_or_default();
    let bound = library.nodes.len()
        + roots.len()
        + library
            .nodes
            .iter()
            .fold(1, |count, node| count + node.shape.references().len());
    reaches_type(
        library,
        type_id,
        bound,
        roots.into_iter().collect(),
        Vec::new(),
    )
}

fn references(
    library: &TypeSignatureLibrary,
    input: &CompositionInput,
    name: &str,
    value: &ExchangeJson,
) -> Decoded<()> {
    match name {
        "TypeId" => {
            let id = text_of(value, "$")?;
            if !library.nodes.iter().any(|node| node.id == id) {
                return Err(syntax("$", "unresolved diagnostic type_id"));
            }
        }
        "DefinitionId" => {
            let id = text_of(value, "$")?;
            if !library
                .definitions
                .iter()
                .any(|definition| definition.id == id)
            {
                return Err(syntax("$", "unresolved diagnostic definition"));
            }
        }
        "FunctionRef" => {
            let reference = decode_function_ref(value, "$")?;
            if !input
                .signatures
                .iter()
                .any(|function| function.reference == reference)
            {
                return Err(syntax("$", "unresolved diagnostic function"));
            }
        }
        "ProducerRef" => {
            let producer = decode_producer_ref(value, "$")?;
            if !resolve_producer(input, &producer) {
                return Err(syntax("$", "unresolved diagnostic producer"));
            }
        }
        "ResourceLotRef" => {
            let lot = decode_resource_lot_ref(value, "$")?;
            if !resolve_lot(input, &lot) {
                return Err(syntax("$", "unresolved diagnostic lot"));
            }
        }
        "SourceRef" => {
            let reference = SourceRef::decode_wire(value, "$")?;
            let identity = SourceIdentity {
                repository: reference.repository.clone(),
                revision: reference.revision.clone(),
                path: reference.path.clone(),
                content_digest: reference.content_digest.clone(),
            };
            if reference != *signature_type_ref("").source
                && !library.sources.contains(&identity)
                && !library.profile.source_refs.contains(&identity)
            {
                return Err(syntax("$", "unresolved diagnostic source"));
            }
        }
        "ValueFailure" => {
            let definition = string_field(
                field(value, "$", "definition_ref")?,
                "$.definition_ref",
                "name",
            )?;
            if !library
                .definitions
                .iter()
                .any(|candidate| candidate.id == definition)
            {
                return Err(syntax("$", "unresolved diagnostic definition"));
            }
            let id = string_field(
                field(value, "$", "type_ref")?,
                "$.type_ref",
                "definition_name",
            )?;
            if !target_contains_type(library, definition, id) {
                return Err(syntax(
                    "$",
                    "diagnostic definition does not contain type_ref",
                ));
            }
        }
        "SemanticBasis" => {
            if !necoherence::exact_json::same_json(value, &to_exchange(&wire_basis(library)?)?) {
                return Err(syntax("$", "diagnostic basis mismatch"));
            }
        }
        "MissingSupply" => {
            let site = match field(value, "$", "site")? {
                ExchangeJson::Null => None,
                other => Some(text_of(other, "$.site")?),
            };
            let port = string_field(value, "$", "port")?;
            let valid = match site {
                None => input.goal.outputs.iter().any(|output| output.id.0 == port),
                Some(site) => input
                    .invocation_domain
                    .sites
                    .iter()
                    .find(|invocation| invocation.id.0 == site)
                    .is_some_and(|invocation| {
                        input
                            .signatures
                            .iter()
                            .find(|function| function.reference == invocation.function)
                            .is_some_and(|function| {
                                function
                                    .inputs
                                    .iter()
                                    .any(|candidate| candidate.id.0 == port)
                            })
                    }),
            };
            if !valid {
                return Err(syntax("$", "unresolved diagnostic destination"));
            }
        }
        "InvocationPlan" => {
            let site = string_field(value, "$", "site")?;
            let function = decode_function_ref(field(value, "$", "function")?, "$.function")?;
            if !input
                .invocation_domain
                .sites
                .iter()
                .any(|invocation| invocation.id.0 == site && invocation.function == function)
            {
                return Err(syntax("$", "unresolved diagnostic invocation"));
            }
            let Some(declaration) = input
                .signatures
                .iter()
                .find(|declaration| declaration.reference == function)
            else {
                return Err(syntax("$", "unresolved diagnostic function"));
            };
            for pair in array(field(value, "$", "bindings")?, "$.bindings")? {
                let id = pair_key(pair, "$.bindings")?;
                if !declaration.inputs.iter().any(|port| port.id.0 == id) {
                    return Err(syntax("$", "unresolved diagnostic input port"));
                }
            }
            for binding in array(field(value, "$", "resources")?, "$.resources")? {
                let id = string_field(binding, "$.resources", "requirement")?;
                if !declaration
                    .resource_inputs
                    .iter()
                    .any(|requirement| requirement.id.0 == id)
                {
                    return Err(syntax("$", "unresolved diagnostic resource requirement"));
                }
            }
        }
        "ReturnPlan" => {
            if string_field(value, "$", "tag")? == "Success" {
                for pair in array(field(value, "$", "value")?, "$.value")? {
                    let id = pair_key(pair, "$.value")?;
                    if !input.goal.outputs.iter().any(|output| output.id.0 == id) {
                        return Err(syntax("$", "unresolved diagnostic goal port"));
                    }
                }
            } else {
                let id = string_field(field(value, "$", "fields")?, "$.fields", "embedding")?;
                if !input
                    .goal
                    .failures
                    .iter()
                    .any(|embedding| embedding.id.0 == id)
                {
                    return Err(syntax("$", "unresolved diagnostic failure embedding"));
                }
            }
        }
        "BindingExpr" => {
            if string_field(value, "$", "tag")? == "Product" {
                let construction =
                    string_field(field(value, "$", "fields")?, "$.fields", "construction")?;
                if !input
                    .invocation_domain
                    .permitted_constructions
                    .iter()
                    .any(|rule| rule.identity == construction)
                {
                    return Err(syntax("$", "unresolved diagnostic construction"));
                }
            }
        }
        "TraceStep" => {
            let row = field(value, "$", "fields")?;
            if string_field(value, "$", "tag")? == "Guard" {
                let guard = string_field(row, "$.fields", "guard")?;
                if !input
                    .invocation_domain
                    .guards
                    .iter()
                    .any(|declaration| declaration.id.0 == guard)
                {
                    return Err(syntax("$", "unresolved diagnostic guard"));
                }
            } else {
                let invocation = field(row, "$.fields", "invocation")?;
                let function = decode_function_ref(
                    field(invocation, "$.fields.invocation", "function")?,
                    "$.fields.invocation.function",
                )?;
                let outcome = string_field(row, "$.fields", "outcome")?;
                let declared = input
                    .signatures
                    .iter()
                    .find(|declaration| declaration.reference == function)
                    .is_some_and(|declaration| {
                        declaration
                            .outcomes
                            .iter()
                            .any(|result| result.id.0 == outcome)
                    });
                if !declared {
                    return Err(syntax("$", "unresolved diagnostic outcome"));
                }
            }
        }
        _ => {}
    }
    Ok(())
}
#[cfg(test)]
#[allow(clippy::expect_used, clippy::unwrap_used, clippy::indexing_slicing)]
mod tests {
    use crate::derivation_codec::encode_slot_contract;
    use crate::diagnostics::check;
    use necoherence::exact_json::JsonValue as ExchangeJson;
    use necoherence::semantic_composition::CompositionInput;
    use necoherence::semantic_exchange::decode_signature_generation;
    use necoherence::signature_composition_codec::decode_problem;
    use necoherence::type_signatures::TypeSignatureLibrary;
    use serde_json::{json, Value};

    const FIXTURE: &str = include_str!("../tests/fixtures/composition-budget-default.json");

    fn fixture_problem() -> (TypeSignatureLibrary, CompositionInput) {
        let input =
            decode_signature_generation(FIXTURE).expect("valid signature generation fixture");
        let composition = input.composition.as_ref().expect("composition section");
        let (problem, _) =
            decode_problem(&input.signatures, &composition["problem"], "$").expect("problem");
        assert!(!problem.goal.outputs.is_empty());
        (input.signatures.as_ref().clone(), problem)
    }

    fn exchange(value: Value) -> ExchangeJson {
        necoherence::exact_json::parse_json_text(&value.to_string()).expect("exchange JSON")
    }

    #[test]
    fn accepts_missing_supply_for_goal_output() {
        let (library, problem) = fixture_problem();
        let output = problem.goal.outputs.first().expect("goal output");
        let element = json!({
            "site": null,
            "port": output.id.0,
            "contract": encode_slot_contract(&output.contract),
        });
        check(&library, &problem, "MissingSupply", &exchange(element))
            .expect("missing supply for a goal output is accepted");
    }

    #[test]
    fn rejects_missing_supply_with_unresolved_port() {
        let (library, problem) = fixture_problem();
        let output = problem.goal.outputs.first().expect("goal output");
        let element = json!({
            "site": null,
            "port": "no-such-port",
            "contract": encode_slot_contract(&output.contract),
        });
        assert!(check(&library, &problem, "MissingSupply", &exchange(element)).is_err());
    }

    #[test]
    fn rejects_missing_supply_with_extra_field() {
        let (library, problem) = fixture_problem();
        let output = problem.goal.outputs.first().expect("goal output");
        let element = json!({
            "site": null,
            "port": output.id.0,
            "contract": encode_slot_contract(&output.contract),
            "extra": true,
        });
        assert!(check(&library, &problem, "MissingSupply", &exchange(element)).is_err());
    }

    #[test]
    fn rejects_unresolved_source_ref() {
        let (library, problem) = fixture_problem();
        let element = json!({
            "repository": "unresolved",
            "revision": "1",
            "path": "unresolved.json",
            "content_digest": "0",
            "document_id": "unresolved",
            "declared_revision": null,
        });
        assert!(check(&library, &problem, "SourceRef", &exchange(element)).is_err());
    }

    #[test]
    fn rejects_superseded_four_field_source_ref() {
        let (library, problem) = fixture_problem();
        let element = json!({
            "repository": "unresolved",
            "revision": "1",
            "path": "unresolved.json",
            "content_digest": "0",
        });
        assert!(check(&library, &problem, "SourceRef", &exchange(element)).is_err());
    }

    fn projection_element(
        library: &TypeSignatureLibrary,
        problem: &CompositionInput,
        source_refs: Value,
    ) -> Value {
        let output = problem.goal.outputs.first().expect("goal output");
        let contract = encode_slot_contract(&output.contract);
        json!({
            "profile": crate::derivation_codec::native(&library.profile.reference)
                .expect("profile reference"),
            "source_refs": source_refs,
            "source": contract.clone(),
            "path": [],
            "assumptions": [],
            "destination": contract,
        })
    }

    fn source_ref_json(repository: &str) -> Value {
        json!({
            "repository": repository,
            "revision": "1",
            "path": "unresolved.json",
            "content_digest": "",
            "document_id": "unresolved",
            "declared_revision": null,
        })
    }

    #[test]
    fn accepts_projection_without_source_refs() {
        let (library, problem) = fixture_problem();
        let element = projection_element(&library, &problem, json!([]));
        check(
            &library,
            &problem,
            "ProjectionCertificate",
            &exchange(element),
        )
        .expect("projection without source refs is accepted");
    }

    #[test]
    fn rejects_projection_with_four_field_source_ref() {
        let (library, problem) = fixture_problem();
        let identity = json!({
            "repository": "unresolved",
            "revision": "1",
            "path": "unresolved.json",
            "content_digest": "",
        });
        let element = projection_element(&library, &problem, json!([identity]));
        assert!(check(
            &library,
            &problem,
            "ProjectionCertificate",
            &exchange(element)
        )
        .is_err());
    }

    #[test]
    fn rejects_projection_with_unresolved_source_ref() {
        let (library, problem) = fixture_problem();
        let element =
            projection_element(&library, &problem, json!([source_ref_json("unresolved")]));
        assert!(check(
            &library,
            &problem,
            "ProjectionCertificate",
            &exchange(element)
        )
        .is_err());
    }

    #[test]
    fn accepts_native_value_failure() {
        let (library, problem) = fixture_problem();
        let definition = library
            .definitions
            .iter()
            .find_map(|definition| match &definition.shape {
                necoherence::type_signatures::SignatureDefinitionShape::Value(root)
                | necoherence::type_signatures::SignatureDefinitionShape::Message(root) => {
                    Some((definition.id.clone(), root.clone()))
                }
                _ => None,
            })
            .expect("a value definition");
        let (definition_id, root) = definition;
        let failure = necoherence::semantic_types::ValueFailure {
            type_ref: necoherence::signature_admission::signature_type_ref(&root),
            definition_ref: necoherence::signature_admission::signature_definition_ref(
                &definition_id,
            ),
            origin: necoherence::semantic_types::OccurrenceRef {
                source: std::sync::Arc::new(
                    necoherence::signature_admission::signature_type_ref(&root)
                        .source
                        .as_ref()
                        .clone(),
                ),
                pointer: std::sync::Arc::from(Vec::<String>::new()),
            },
            value_path: Vec::new(),
            condition: necoherence::semantic_types::ValueCondition::MissingRequired,
            observed: necoherence::semantic_types::SlotValue::Absent,
            reference_trace: Vec::new(),
        };
        let element = crate::derivation_codec::native(&failure).expect("native");
        check(&library, &problem, "ValueFailure", &exchange(element))
            .expect("native ValueFailure is accepted");
    }
}
