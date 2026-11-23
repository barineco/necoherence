// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: AGPL-3.0-only

mod composition;
mod surface;

use super::{check_meaning, RenderFailure};
use necoherence::semantic_exchange::{encode_type_signatures, Wire};
use necoherence::signature_admission::CheckedSignatureGeneration;
use serde::Serialize;
use serde_json::{json, Value};

pub(super) type Result<T> = std::result::Result<T, RenderFailure>;

pub(super) fn invalid(message: &str) -> RenderFailure {
    RenderFailure::InvalidCheckedPlan(message.into())
}

fn to_value<T: Serialize>(value: T) -> Result<Value> {
    serde_json::to_value(value).map_err(|_| invalid("generated wire value"))
}

fn parse(text: &str) -> Result<Value> {
    serde_json::from_str(text).map_err(|_| invalid("generated JSON"))
}

pub(super) fn field<'a>(value: &'a Value, key: &str) -> Result<&'a Value> {
    value
        .get(key)
        .ok_or_else(|| invalid(&format!("generated field {key}")))
}

pub(super) fn text<'a>(value: &'a Value, key: &str) -> Result<&'a str> {
    field(value, key)?
        .as_str()
        .ok_or_else(|| invalid("generated text"))
}

pub(super) fn list<'a>(value: &'a Value, key: &str) -> Result<&'a [Value]> {
    field(value, key)?
        .as_array()
        .map(Vec::as_slice)
        .ok_or_else(|| invalid("generated list"))
}

pub(super) fn flag(value: &Value, key: &str) -> Result<bool> {
    field(value, key)?
        .as_bool()
        .ok_or_else(|| invalid("generated flag"))
}

pub(super) fn tag(value: &Value) -> Result<&str> {
    text(value, "tag")
}

pub(super) fn js(text: &str) -> String {
    serde_json::to_string(text).unwrap_or_default()
}

fn hex(text: &str) -> String {
    text.bytes().map(|byte| format!("{byte:02x}")).collect()
}

pub(super) fn generated_name(id: &str) -> String {
    format!("N_{}", hex(id))
}

pub(super) fn type_name(id: &str) -> String {
    format!("T_{}", hex(id))
}

pub(super) fn safe(value: &str) -> String {
    let name: String = value
        .chars()
        .map(|character| {
            if character.is_ascii_alphanumeric() || character == '_' {
                character
            } else {
                '_'
            }
        })
        .collect();
    if name
        .chars()
        .next()
        .is_some_and(|character| character.is_ascii_alphabetic() || character == '_')
    {
        name
    } else {
        format!("T_{name}")
    }
}

pub(super) struct Graph {
    pub(super) value: Value,
    pub(super) nodes: Vec<Value>,
}

impl Graph {
    fn new(value: Value) -> Result<Self> {
        let nodes = list(&value, "nodes")?.to_vec();
        Ok(Self { value, nodes })
    }

    fn position(&self, reference: &Value) -> Option<usize> {
        self.nodes
            .iter()
            .position(|node| node.get("reference") == Some(reference))
    }

    pub(super) fn name(&self, reference: &Value) -> Option<String> {
        let index = self.position(reference)?;
        let definition = self
            .nodes
            .get(index)?
            .get("reference")?
            .get("definition_name")?
            .as_str()?;
        Some(format!("Type_{}_{index}", safe(definition)))
    }

    pub(super) fn shape(&self, reference: &Value) -> Option<&Value> {
        let index = self.position(reference)?;
        self.nodes.get(index)?.get("shape")
    }

    pub(super) fn index_of_id(&self, id: &str) -> Result<usize> {
        let mut matches = self.nodes.iter().enumerate().filter(|(_, node)| {
            node.get("reference")
                .and_then(|reference| reference.get("definition_name"))
                .and_then(Value::as_str)
                == Some(id)
        });
        let (index, _) = matches
            .next()
            .ok_or_else(|| invalid("generated composition type"))?;
        if matches.next().is_some() {
            return Err(invalid("generated composition type identity"));
        }
        Ok(index)
    }

    pub(super) fn name_of_id(&self, id: &str) -> Result<String> {
        Ok(format!("Type_{}_{}", safe(id), self.index_of_id(id)?))
    }

    pub(super) fn reference_of_id(&self, id: &str) -> Result<String> {
        Ok(format!("graph.nodes[{}].reference", self.index_of_id(id)?))
    }

    pub(super) fn sealed_fields(&self, form_tag: &str) -> Vec<Value> {
        let sealed = self
            .value
            .get("profile")
            .and_then(|profile| profile.get("tag"))
            .and_then(|tag| tag.get("sealed"))
            .and_then(Value::as_array);
        sealed
            .and_then(|forms| {
                forms
                    .iter()
                    .find(|form| form.get("tag").and_then(Value::as_str) == Some(form_tag))
            })
            .and_then(|form| form.get("fields"))
            .and_then(Value::as_array)
            .cloned()
            .unwrap_or_default()
    }
}

fn library_type(node: &Value) -> Result<String> {
    let shape = field(node, "shape")?;
    if tag(shape)? == "Alias" {
        return Ok(type_name(text(field(shape, "fields")?, "target")?));
    }
    let mapped = match tag(shape)? {
        "Boolean" => "Bool",
        "Integer" => "Integer",
        "Decimal" => "Decimal",
        "String" => "String",
        "Unit" => "Null",
        "Array" => "Array",
        "Product" | "TaggedUnion" | "Sealed" => "Object",
        "Bytes" | "RawBody" => "String",
        _ => return Ok("V.ExactJson".to_owned()),
    };
    Ok(format!(
        "Extract<V.ExactJson, {{ readonly tag: {} }}>",
        js(mapped)
    ))
}

fn ports(contract_list: &[Value]) -> Result<Vec<Value>> {
    contract_list
        .iter()
        .map(|port| {
            Ok(json!({
                "id": field(port, "id")?,
                "contract": field(port, "contract")?,
            }))
        })
        .collect()
}

fn supplied_contract(problem: &Value, id: &str) -> Result<Option<Value>> {
    for signature in list(problem, "signatures")? {
        let form = field(signature, "form")?;
        if tag(form)? != "Operation" || form.get("value").and_then(Value::as_str) != Some(id) {
            continue;
        }
        let outcomes = list(signature, "outcomes")?
            .iter()
            .map(|outcome| {
                Ok(json!({
                    "id": field(outcome, "id")?,
                    "form": field(outcome, "form")?,
                    "cause": field(outcome, "cause")?,
                    "value_ports": ports(list(outcome, "value_ports")?)?,
                    "produced_resources": field(outcome, "produced_resources")?,
                }))
            })
            .collect::<Result<Vec<_>>>()?;
        return Ok(Some(json!({
            "effect": field(signature, "effect")?,
            "inputs": ports(list(signature, "inputs")?)?,
            "outcomes": outcomes,
        })));
    }
    Ok(None)
}

fn operation(out: &mut String, id: &str, contract: &Value, composition: bool) -> Result<()> {
    let name = generated_name(id);
    let outcomes = list(contract, "outcomes")?;
    let union = outcomes
        .iter()
        .map(|outcome| {
            let ports = list(outcome, "value_ports")?
                .iter()
                .map(|port| {
                    let slot = field(port, "contract")?;
                    Ok(format!(
                        "{}: S.TypedSignatureSlot<{}, {}, {}>",
                        js(text(port, "id")?),
                        type_name(text(slot, "type_id")?),
                        flag(slot, "required")?,
                        flag(slot, "nullable")?
                    ))
                })
                .collect::<Result<Vec<_>>>()?
                .join("; ");
            Ok(format!(
                "{{ readonly outcome: {}; readonly values: {{ {ports} }} }}",
                js(text(outcome, "id")?)
            ))
        })
        .collect::<Result<Vec<_>>>()?
        .join(" | ");
    let inputs = list(contract, "inputs")?
        .iter()
        .map(|port| {
            let slot = field(port, "contract")?;
            Ok(format!(
                "{}: S.TypedSignatureSlot<{}, {}, {}>",
                js(text(port, "id")?),
                type_name(text(slot, "type_id")?),
                flag(slot, "required")?,
                flag(slot, "nullable")?
            ))
        })
        .collect::<Result<Vec<_>>>()?
        .join("; ");
    let contract_text = contract.to_string();
    out.push_str(&format!(
        "export type {name}Outcome = {union};\nexport const {name} = {contract_text} as const;\nexport type {name}Input = {{ {inputs} }};\n"
    ));
    let effect = tag(field(contract, "effect")?)?;
    if effect == "HttpRequestResponse" && !composition {
        let external = outcomes
            .iter()
            .filter(|outcome| {
                outcome
                    .get("cause")
                    .and_then(|cause| cause.get("tag"))
                    .and_then(Value::as_str)
                    == Some("ExternalCondition")
            })
            .filter_map(|outcome| outcome.get("id").and_then(Value::as_str))
            .map(js)
            .collect::<Vec<_>>()
            .join(" | ");
        let external = if external.is_empty() {
            "never".to_owned()
        } else {
            external
        };
        out.push_str(&format!(
            "export type {name}ExternalOutcome = Extract<{name}Outcome, {{ readonly outcome: {external} }}>;\nexport type {name}Binding = S.NetworkBinding<{name}Input, {name}Outcome>;\nexport function {name}Prepare(binding: {name}Binding, input: {name}Input) {{ return S.prepareCall({name}, binding, input); }}\n"
        ));
    }
    Ok(())
}

pub(super) fn render_generation(
    checked: &CheckedSignatureGeneration,
    expected: &necoherence::type_signatures::ExpectedSignatureBasis,
    exchange_text: &str,
    runtime: &str,
) -> Result<String> {
    let input = checked.input();
    if checked.composition().is_none() {
        check_meaning(checked.graph())?;
    }
    let library = parse(
        &encode_type_signatures(&input.signatures)
            .map_err(|failure| RenderFailure::Generation(Box::new(failure)))?,
    )?;
    let basis = parse(
        &necoherence::semantic_exchange::encode_expected_signature_basis(expected)
            .map_err(|failure| RenderFailure::Generation(Box::new(failure)))?,
    )?;
    for node in list(&library, "nodes")? {
        if tag(field(node, "shape")?)? == "Opaque" {
            return Err(RenderFailure::UndefinedType(text(node, "id")?.to_owned()));
        }
    }
    let graph = Graph::new(to_value(Wire(checked.graph()))?)?;
    let exchange = parse(exchange_text)?;
    let composition = exchange.get("composition").filter(|value| !value.is_null());
    let library_json = library.to_string();
    let mut out = format!(
        "{header}import {{ networkEffect as N, semanticComposition as C, semanticExecution as E, semanticSignatures as S, semanticValues as V, signatureCompositionWire as W }} from {};\nconst checkedLibrary = S.checkLibrary({library_json});\nexport const signatureGraph = checkedLibrary.context.graph;\nexport const annotations = checkedLibrary.library.annotations;\nexport function annotationsFor(target: S.AnnotationTarget) {{ return annotations.filter(annotation => V.same(annotation.target, target)); }}\n",
        js(runtime),
        header = super::generated_header("//")
    );
    for node in list(&library, "nodes")? {
        let id = text(node, "id")?;
        out.push_str(&format!(
            "export type {t} = {e};\nexport const {t}Codec = new S.SignatureCodec<{t}>(checkedLibrary, {j});\n",
            t = type_name(id),
            e = library_type(node)?,
            j = js(id)
        ));
    }
    for definition in list(&library, "definitions")? {
        let id = text(definition, "id")?;
        let shape = field(definition, "shape")?;
        match tag(shape)? {
            "Operation" => {
                let contract = match composition {
                    Some(problem) => {
                        let problem = field(problem, "problem")?;
                        supplied_contract(problem, id)?.unwrap_or_else(|| {
                            field(shape, "value").cloned().unwrap_or(Value::Null)
                        })
                    }
                    None => field(shape, "value")?.clone(),
                };
                operation(&mut out, id, &contract, composition.is_some())?;
            }
            "Symbol" => out.push_str(&format!(
                "export const {} = {};\n",
                generated_name(id),
                js(text(shape, "value")?)
            )),
            _ => out.push_str(&format!(
                "export const {}Codec = new S.SignatureCodec<{}>(checkedLibrary, {});\n",
                generated_name(id),
                type_name(text(shape, "value")?),
                js(text(shape, "value")?)
            )),
        }
    }
    surface::render(&mut out, &graph, &library_json, &basis.to_string())?;
    if let Some(problem) = composition {
        composition::render(&mut out, &graph, field(problem, "problem")?, exchange_text)?;
    }
    Ok(out)
}
