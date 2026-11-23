// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: AGPL-3.0-only

use super::identifiers::{
    boolean, lower, lower_identifier, quote, ref_name, upper_identifier, Names,
};
use super::wire::{field, invalid, list, tag, text, Result};
use serde_json::Value;

struct Port {
    id: String,
    variable: String,
    child: String,
    required: bool,
    nullable: bool,
}

struct Outcome {
    id: String,
    variant: String,
    ports: Vec<Port>,
    external: bool,
}

fn port(value: &Value, names: &Names) -> Result<Port> {
    let contract = field(value, "contract")?;
    let id = text(value, "id")?.to_owned();
    Ok(Port {
        variable: lower_identifier(&id, "port"),
        id,
        child: names.by_id(text(contract, "type_id")?)?.to_owned(),
        required: field(contract, "required")?
            .as_bool()
            .ok_or_else(|| invalid("generated flag"))?,
        nullable: field(contract, "nullable")?
            .as_bool()
            .ok_or_else(|| invalid("generated flag"))?,
    })
}

fn ports(values: &[Value], names: &Names) -> Result<Vec<Port>> {
    values.iter().map(|value| port(value, names)).collect()
}

fn outcome(value: &Value, names: &Names) -> Result<Outcome> {
    let id = text(value, "id")?.to_owned();
    Ok(Outcome {
        variant: upper_identifier(&id, "Variant"),
        ports: ports(list(value, "value_ports")?, names)?,
        external: field(value, "cause")?.get("tag").and_then(Value::as_str)
            == Some("ExternalCondition"),
        id,
    })
}

fn slot_types(ports: &[Port]) -> String {
    ports
        .iter()
        .map(|port| format!("{}: types.SlotValue({})", port.variable, port.child))
        .collect::<Vec<_>>()
        .join(", ")
}

fn variables(ports: &[Port]) -> String {
    ports
        .iter()
        .map(|port| port.variable.as_str())
        .collect::<Vec<_>>()
        .join(", ")
}

fn constructor(prefix: &str, outcome: &Outcome) -> String {
    let name = format!("{prefix}Outcome{}", outcome.variant);
    if outcome.ports.is_empty() {
        name
    } else {
        format!("{name}({})", slot_types(&outcome.ports))
    }
}

fn pattern(prefix: &str, outcome: &Outcome) -> String {
    let name = format!("{prefix}Outcome{}", outcome.variant);
    if outcome.ports.is_empty() {
        name
    } else {
        format!("{name}({})", variables(&outcome.ports))
    }
}

fn wildcards(outcome: &Outcome) -> String {
    if outcome.ports.is_empty() {
        String::new()
    } else {
        format!(
            "({})",
            outcome
                .ports
                .iter()
                .map(|_| "_")
                .collect::<Vec<_>>()
                .join(", ")
        )
    }
}

fn alias(definition: &Value, names: &Names, function: &str, prefix: &str) -> Result<Vec<String>> {
    let shape = field(definition, "shape")?;
    let child = names.by_id(text(shape, "value")?)?.to_owned();
    let mut lines = Vec::new();
    if prefix != child {
        lines.push(format!("pub type {prefix} = {child}"));
    }
    lines.push(format!(
        "pub const {function}_identity = {}",
        quote(text(definition, "wire_identity")?)
    ));
    if function != lower(&child) {
        lines.push(format!(
            "pub fn decode_{function}(context: Context, wire: String) -> Result({child}, ValueFailure) {{ decode_{}(context, wire) }}",
            lower(&child)
        ));
        lines.push(format!(
            "pub fn encode_{function}(context: Context, value: {child}) -> Result(String, ValueFailure) {{ encode_{}(context, value) }}",
            lower(&child)
        ));
    }
    Ok(lines)
}

fn operation(
    definition: &Value,
    contract: &Value,
    names: &Names,
    prefix: &str,
    function: &str,
) -> Result<Vec<String>> {
    let id = text(definition, "id")?;
    let wire = text(definition, "wire_identity")?;
    let inputs = ports(list(contract, "inputs")?, names)?;
    let outcomes = list(contract, "outcomes")?
        .iter()
        .map(|value| outcome(value, names))
        .collect::<Result<Vec<_>>>()?;
    let input_args = if inputs.is_empty() {
        String::new()
    } else {
        format!("({})", slot_types(&inputs))
    };
    let mut lines = vec![
        format!("pub const {function}_identity = {}", quote(wire)),
        format!("pub type {prefix}Input {{ {prefix}Input{input_args} }}"),
        format!("pub type {prefix}Outcome {{"),
    ];
    lines.extend(
        outcomes
            .iter()
            .map(|outcome| format!("  {}", constructor(prefix, outcome))),
    );
    lines.push("}".to_owned());
    lines.push(format!(
        "pub fn {function}_outcome_id(value: {prefix}Outcome) -> String {{ case value {{"
    ));
    lines.extend(outcomes.iter().map(|outcome| {
        format!(
            "  {prefix}Outcome{}{} -> {}",
            outcome.variant,
            wildcards(outcome),
            quote(&outcome.id)
        )
    }));
    lines.push("} }".to_owned());

    lines.push(format!(
        "pub fn validate_{function}_input(context: Context, input: {prefix}Input) -> Result(Nil, ValueFailure) {{"
    ));
    for port in &inputs {
        lines.push(format!(
            "  use {v} <- result.try(runtime.map_slot(input.{v}, fn(item) {{ pack_{}(context, item) }}))",
            lower(&port.child),
            v = port.variable
        ));
        lines.push(format!(
            "  use _ <- result.try(runtime.validate_slot(prepared(context), types.SlotContract({}, {}, {}), {}))",
            ref_name(&port.child),
            boolean(port.required),
            boolean(port.nullable),
            port.variable
        ));
    }
    lines.push("  Ok(Nil)".to_owned());
    lines.push("}".to_owned());

    lines.push(format!(
        "pub fn validate_{function}_outcome(context: Context, output: {prefix}Outcome) -> Result(Nil, ValueFailure) {{"
    ));
    lines.push("  case output {".to_owned());
    for outcome in &outcomes {
        lines.push(format!("    {} -> {{", pattern(prefix, outcome)));
        for port in &outcome.ports {
            lines.push(format!(
                "      use {v} <- result.try(runtime.map_slot({v}, fn(item) {{ pack_{}(context, item) }}))",
                lower(&port.child),
                v = port.variable
            ));
            lines.push(format!(
                "      use _ <- result.try(runtime.validate_slot(prepared(context), types.SlotContract({}, {}, {}), {}))",
                ref_name(&port.child),
                boolean(port.required),
                boolean(port.nullable),
                port.variable
            ));
        }
        lines.push("      Ok(Nil)".to_owned());
        lines.push("    }".to_owned());
    }
    lines.push("  }".to_owned());
    lines.push("}".to_owned());

    lines.push(format!(
        "pub fn to_outcome_{function}(context: Context, output: {prefix}Outcome) -> Result(runtime.OutcomeValues, signatures.Failure) {{"
    ));
    lines.push(format!(
        "  use _ <- result.try(result.map_error(validate_{function}_outcome(context, output), signatures.Codec))"
    ));
    lines.push("  case output {".to_owned());
    for outcome in &outcomes {
        lines.push(format!("    {} -> {{", pattern(prefix, outcome)));
        for port in &outcome.ports {
            lines.push(format!(
                "      use {v} <- result.try(result.map_error(runtime.map_slot({v}, fn(item) {{ pack_{}(context, item) }}), signatures.Codec))",
                lower(&port.child),
                v = port.variable
            ));
        }
        let entries = outcome
            .ports
            .iter()
            .map(|port| {
                format!(
                    "#(composition.PortId({}), {})",
                    quote(&port.id),
                    port.variable
                )
            })
            .collect::<Vec<_>>()
            .join(", ");
        lines.push(format!(
            "      Ok(runtime.OutcomeValues(composition.OutcomeId({}), [{entries}]))",
            quote(&outcome.id)
        ));
        lines.push("    }".to_owned());
    }
    lines.push("  }".to_owned());
    lines.push("}".to_owned());

    lines.push(format!(
        "pub fn from_outcome_{function}(context: Context, output: runtime.OutcomeValues) -> Result({prefix}Outcome, signatures.Failure) {{"
    ));
    lines.push(format!(
        "  use _ <- result.try(context_validate_outcome(context, {}, output))",
        quote(id)
    ));
    lines.push(format!("  unpack_outcome_{function}(context, output)"));
    lines.push("}".to_owned());
    lines.push(format!(
        "fn unpack_outcome_{function}(context: Context, output: runtime.OutcomeValues) -> Result({prefix}Outcome, signatures.Failure) {{"
    ));
    lines.push("  case output.outcome {".to_owned());
    for outcome in &outcomes {
        lines.push(format!(
            "    composition.OutcomeId({}) -> {{",
            quote(&outcome.id)
        ));
        for port in &outcome.ports {
            lines.push(format!(
                "      use {v} <- result.try(result.map_error(list.key_find(output.values, composition.PortId({})), fn(_) {{ signatures.syntax(\"missing outcome port\") }}))",
                quote(&port.id),
                v = port.variable
            ));
            lines.push(format!(
                "      use {v} <- result.try(result.map_error(runtime.map_slot({v}, fn(item) {{ unpack_{}(context, item) }}), signatures.Codec))",
                lower(&port.child),
                v = port.variable
            ));
        }
        let variables = if outcome.ports.is_empty() {
            String::new()
        } else {
            format!("({})", variables(&outcome.ports))
        };
        lines.push(format!(
            "      Ok({prefix}Outcome{}{variables})",
            outcome.variant
        ));
        lines.push("    }".to_owned());
    }
    lines.push("    _ -> Error(signatures.syntax(\"undeclared outcome\"))".to_owned());
    lines.push("  }".to_owned());
    lines.push("}".to_owned());
    lines.extend([
        format!(
            "pub fn encode_{function}_outcome(context: Context, output: {prefix}Outcome) -> Result(String, signatures.Failure) {{"
        ),
        format!("  use output <- result.try(to_outcome_{function}(context, output))"),
        format!("  context_encode_outcome(context, {}, output)", quote(id)),
        "}".to_owned(),
        format!(
            "pub fn decode_{function}_outcome(context: Context, wire: String) -> Result({prefix}Outcome, signatures.Failure) {{"
        ),
        format!(
            "  use output <- result.try(context_decode_outcome(context, {}, wire))",
            quote(id)
        ),
        format!("  unpack_outcome_{function}(context, output)"),
        "}".to_owned(),
    ]);

    match tag(field(contract, "effect")?)? {
        "DataOnly" => {}
        "HttpRequestResponse" => {
            let external = outcomes
                .iter()
                .filter(|outcome| outcome.external)
                .map(|outcome| quote(&outcome.id))
                .collect::<Vec<_>>()
                .join(", ");
            lines.extend([
                format!("pub type {prefix}Binding = http.Binding({prefix}Input, {prefix}Outcome)"),
                format!(
                    "pub fn prepare_{function}(context: Context, input: {prefix}Input, binding: {prefix}Binding) -> Result(http.PreparedInput({prefix}Outcome), runtime.ExecutionFailure) {{"
                ),
                format!("  http.prepare(input, binding, [{external}])"),
                "}".to_owned(),
            ]);
        }
        _ => return Err(invalid("generated effect")),
    }
    Ok(lines)
}

pub(super) fn definitions(
    library: &Value,
    outcome_overrides: &[(String, Value)],
) -> Result<Vec<Value>> {
    let mut definitions = list(library, "definitions")?
        .iter()
        .map(|definition| {
            let mut definition = definition.clone();
            let id = text(&definition, "id")?.to_owned();
            if tag(field(&definition, "shape")?)? == "Operation" {
                let mut contract = field(field(&definition, "shape")?, "value")?.clone();
                if let Some((_, outcomes)) = outcome_overrides
                    .iter()
                    .find(|(candidate, _)| *candidate == id)
                {
                    if let Some(object) = contract.as_object_mut() {
                        object.insert("outcomes".to_owned(), outcomes.clone());
                    }
                }
                if let Some(shape) = definition.get_mut("shape").and_then(Value::as_object_mut) {
                    shape.insert("value".to_owned(), contract);
                }
            }
            Ok(definition)
        })
        .collect::<Result<Vec<_>>>()?;
    definitions.sort_by(|left, right| {
        let left = left.get("id").and_then(Value::as_str).unwrap_or_default();
        let right = right.get("id").and_then(Value::as_str).unwrap_or_default();
        left.cmp(right)
    });
    Ok(definitions)
}

pub(super) fn render_definitions(definitions: &[Value], names: &Names) -> Result<Vec<String>> {
    let mut lines = Vec::new();
    for definition in definitions {
        let wire = text(definition, "wire_identity")?;
        let prefix = upper_identifier(wire, "Signature");
        let function = lower_identifier(wire, "signature");
        let shape = field(definition, "shape")?;
        match tag(shape)? {
            "Value" | "Message" => lines.extend(alias(definition, names, &function, &prefix)?),
            "Symbol" => lines.push(format!(
                "pub const {function}: String = {}",
                quote(text(shape, "value")?)
            )),
            "Operation" => {
                let contract = field(shape, "value")?;
                lines.extend(operation(definition, contract, names, &prefix, &function)?);
            }
            _ => return Err(invalid("generated definition shape")),
        }
    }
    Ok(lines)
}
