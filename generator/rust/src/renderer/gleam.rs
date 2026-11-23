// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: AGPL-3.0-only

mod collisions;
mod execution;
mod identifiers;
mod signatures;
mod types;
mod wire;

use super::{check_meaning, RenderFailure};
use identifiers::{quote, Names};
use necoherence::semantic_exchange::{encode_signature_basis, encode_type_signatures, Wire};
use necoherence::signature_admission::CheckedSignatureGeneration;
use serde_json::Value;
use wire::{field, invalid, list, text, Result};

fn parse(text: &str) -> Result<Value> {
    serde_json::from_str(text).map_err(|_| invalid("generated JSON"))
}

fn requirement(basis: &Value) -> Result<String> {
    let profile = field(basis, "profile")?;
    let problem = match field(basis, "problem_sha256")? {
        Value::Null => "None".to_owned(),
        value => format!("Some({})", quote(value.as_str().unwrap_or_default())),
    };
    let observations = match field(basis, "observations_sha256")? {
        Value::Null => "None".to_owned(),
        value => format!("Some({})", quote(value.as_str().unwrap_or_default())),
    };
    Ok(format!(
        "signatures.GenerationRequirement({}, {}, {}, types.ProfileRef({}, {}, {}), {}, {}, {}, {}, {}, {})",
        quote(text(basis, "signature_schema")?),
        quote(text(basis, "library_identity")?),
        quote(text(basis, "library_revision")?),
        quote(text(profile, "identity")?),
        quote(text(profile, "revision")?),
        quote(text(profile, "content_digest")?),
        quote(text(basis, "graph_sha256")?),
        quote(text(basis, "provenance_sha256")?),
        quote(text(basis, "metadata_sha256")?),
        problem,
        observations,
        quote(text(basis, "entrypoints_sha256")?),
    ))
}

fn context_header(
    composition: bool,
    basis_text: &str,
    exchange_text: &str,
    basis: &Value,
) -> Result<Vec<String>> {
    let lines: Vec<String> = if composition {
        vec![
            format!("const embedded_basis = {}", quote(basis_text)),
            format!("const embedded_generation = {}", quote(exchange_text)),
            "pub opaque type Context { Context(checked: signatures.CheckedGeneration, prepared: validation.PreparedGraph) }".to_owned(),
            "pub fn initialize() -> Result(Context, signatures.AdmissionFailure) {".to_owned(),
            "  use checked <- result.try(signatures.admit_generation(embedded_basis, embedded_generation))".to_owned(),
            "  Ok(Context(checked, signatures.checked_prepared(checked)))".to_owned(),
            "}".to_owned(),
            "fn prepared(context: Context) -> validation.PreparedGraph { context.prepared }".to_owned(),
            "fn graph(context: Context) -> types.SemanticGraph { validation.prepared_graph(context.prepared) }".to_owned(),
            "fn context_library(context: Context) -> signatures.AdmittedLibrary { signatures.checked_library(context.checked) }".to_owned(),
            "fn context_validate_outcome(context: Context, definition: String, output: runtime.OutcomeValues) -> Result(Nil, signatures.Failure) { signatures.validate_outcome(context_library(context), definition, output) }".to_owned(),
            "fn context_encode_outcome(context: Context, definition: String, output: runtime.OutcomeValues) -> Result(String, signatures.Failure) { signatures.encode_outcome(context_library(context), definition, output) }".to_owned(),
            "fn context_decode_outcome(context: Context, definition: String, wire: String) -> Result(runtime.OutcomeValues, signatures.Failure) { signatures.decode_outcome(context_library(context), definition, wire) }".to_owned(),
            "pub fn annotations(context: Context, target: signatures.Target) -> List(signatures.Annotation) { signatures.annotations(context_library(context), target) }".to_owned(),
            "pub fn groups(context: Context) -> List(signatures.DefinitionGroup) { signatures.groups(context_library(context)) }".to_owned(),
        ]
    } else {
        vec![
            format!("fn required_generation() -> signatures.GenerationRequirement {{ {} }}", requirement(basis)?),
            "pub opaque type Context { Context(checked: signatures.CheckedGeneration, prepared: validation.PreparedGraph) }".to_owned(),
            "pub fn initialize(checked: signatures.CheckedGeneration) -> Result(Context, signatures.GenerationBasisMismatch) {".to_owned(),
            "  let held = signatures.generation_requirement(checked)".to_owned(),
            "  let required = required_generation()".to_owned(),
            "  use _ <- result.try(case held == required {".to_owned(),
            "    True -> Ok(Nil)".to_owned(),
            "    False -> Error(signatures.GenerationBasisMismatch(held, required))".to_owned(),
            "  })".to_owned(),
            "  Ok(Context(checked, signatures.checked_prepared(checked)))".to_owned(),
            "}".to_owned(),
            "fn prepared(context: Context) -> validation.PreparedGraph { context.prepared }".to_owned(),
            "fn graph(context: Context) -> types.SemanticGraph { validation.prepared_graph(context.prepared) }".to_owned(),
            "fn context_library(context: Context) -> signatures.AdmittedLibrary { signatures.checked_library(context.checked) }".to_owned(),
            "fn context_validate_outcome(context: Context, definition: String, output: runtime.OutcomeValues) -> Result(Nil, signatures.Failure) { signatures.validate_outcome(signatures.checked_library(context.checked), definition, output) }".to_owned(),
            "fn context_encode_outcome(context: Context, definition: String, output: runtime.OutcomeValues) -> Result(String, signatures.Failure) { signatures.encode_outcome(signatures.checked_library(context.checked), definition, output) }".to_owned(),
            "fn context_decode_outcome(context: Context, definition: String, wire: String) -> Result(runtime.OutcomeValues, signatures.Failure) { signatures.decode_outcome(signatures.checked_library(context.checked), definition, wire) }".to_owned(),
            "pub fn annotations(context: Context, target: signatures.Target) -> List(signatures.Annotation) { signatures.annotations(signatures.checked_library(context.checked), target) }".to_owned(),
            "pub fn groups(context: Context) -> List(signatures.DefinitionGroup) { signatures.groups(signatures.checked_library(context.checked)) }".to_owned(),
            "pub fn checked_generation(context: Context) -> signatures.CheckedGeneration { context.checked }".to_owned(),
        ]
    };
    Ok(lines)
}

fn header(
    composition: bool,
    basis_text: &str,
    exchange_text: &str,
    basis: &Value,
) -> Result<Vec<String>> {
    let mut lines: Vec<String> = [
        "import gleam/option.{type Option, None, Some}",
        "import gleam/result",
        "import gleam/list",
        "import necoherence/exact_json as kdl",
        "import necoherence/semantic_types as types",
        "import necoherence/composition_plan as composition",
        "import necoherence/semantic_signatures as signatures",
        "import necoherence/semantic_generation_runtime as runtime",
        "import necoherence/semantic_generation_values as values",
        "import necoherence/semantic_validation as validation",
        "import necoherence/typed_mapping as resource",
        "import necoherence/semantic_generation_decode as decode",
        "import necoherence/semantic_generation_native as native",
        "import necoherence/semantic_signature_http as http",
        "import necoherence/network_effect as network",
        "pub type ValueFailure = runtime.ValueFailure",
    ]
    .iter()
    .map(|line| (*line).to_owned())
    .collect();
    lines.splice(0..0, super::generated_header_lines("//"));
    lines.extend(context_header(
        composition,
        basis_text,
        exchange_text,
        basis,
    )?);
    lines.push("fn representation(reference: types.TypeRef) -> Result(a, ValueFailure) { Error(runtime.Representation(reference, \"generated value representation\")) }".to_owned());
    Ok(lines)
}

pub(super) fn render_generation(
    checked: &CheckedSignatureGeneration,
    expected: &necoherence::type_signatures::ExpectedSignatureBasis,
    exchange_text: &str,
) -> std::result::Result<String, RenderFailure> {
    let input = checked.input();
    let composition = checked.composition().is_some();
    if !composition {
        check_meaning(checked.graph())?;
    }
    let basis_text = encode_signature_basis(&input.basis)
        .map_err(|failure| RenderFailure::Generation(Box::new(failure)))?;
    let basis = parse(&basis_text)?;
    let expected_text = necoherence::semantic_exchange::encode_expected_signature_basis(expected)
        .map_err(|failure| RenderFailure::Generation(Box::new(failure)))?;
    let graph =
        serde_json::to_value(Wire(checked.graph())).map_err(|_| invalid("generated graph"))?;
    let nodes = list(&graph, "nodes")?;
    let names = Names::new(nodes)?;
    let mut sorted = nodes
        .iter()
        .map(|node| Ok((text(field(node, "reference")?, "definition_name")?, node)))
        .collect::<Result<Vec<_>>>()?;
    sorted.sort_by(|left, right| left.0.cmp(right.0));
    let named = sorted
        .iter()
        .map(|(_, node)| Ok((*node, identifiers::type_name_of(field(node, "reference")?)?)))
        .collect::<Result<Vec<_>>>()?;
    let profile = field(&graph, "profile")?;
    let library = parse(
        &encode_type_signatures(&input.signatures)
            .map_err(|failure| RenderFailure::Generation(Box::new(failure)))?,
    )?;
    let exchange = parse(exchange_text)?;
    let composition_value = exchange.get("composition").filter(|value| !value.is_null());
    let overrides = match composition_value {
        Some(composition) => outcome_overrides(field(composition, "problem")?)?,
        None => Vec::new(),
    };
    let definitions = signatures::definitions(&library, &overrides)?;
    let mut identifiers = collisions::concrete(&named)?;
    identifiers.extend(collisions::reserved());
    if let Some(composition) = composition_value {
        identifiers.extend(collisions::execution(field(composition, "problem")?)?);
    }
    identifiers.extend(collisions::signatures(&definitions, &names)?);
    collisions::check(&identifiers)?;
    let mut lines = header(composition, &expected_text, exchange_text, &basis)?;
    for (node, type_name) in &named {
        lines.extend(types::render_type(node, type_name, &names, profile)?);
    }
    lines.extend(signatures::render_definitions(&definitions, &names)?);
    if let Some(composition) = composition_value {
        let composition_text =
            serde_json::to_string(composition).map_err(|_| invalid("generated composition"))?;
        lines.extend(execution::render(
            field(composition, "problem")?,
            &composition_text,
            &names,
        )?);
    }
    Ok(lines.join("\n") + "\n")
}

fn outcome_overrides(problem: &Value) -> Result<Vec<(String, Value)>> {
    list(problem, "signatures")?
        .iter()
        .filter(|signature| {
            field(signature, "form")
                .ok()
                .and_then(|form| form.get("tag"))
                .and_then(Value::as_str)
                == Some("Operation")
        })
        .map(|signature| {
            let form = field(signature, "form")?;
            Ok((
                text(form, "value")?.to_owned(),
                field(signature, "outcomes")?.clone(),
            ))
        })
        .collect()
}
