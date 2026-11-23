// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: AGPL-3.0-only

use super::identifiers::{lower, quote, Names};
use super::wire::{field, flag, list, tag, text, Result};
use serde_json::Value;

struct Contract {
    child: String,
    required: bool,
    nullable: bool,
}

fn contract_of(slot: &Value, names: &Names) -> Result<Contract> {
    Ok(Contract {
        child: names.by_id(text(slot, "type_id")?)?.to_owned(),
        required: flag(slot, "required")?,
        nullable: flag(slot, "nullable")?,
    })
}

fn port_contract(port: &Value, names: &Names) -> Result<Contract> {
    contract_of(field(port, "contract")?, names)
}

fn slot_type(contract: &Contract) -> String {
    match (contract.required, contract.nullable) {
        (true, false) => contract.child.clone(),
        (false, true) => format!("types.SlotValue({})", contract.child),
        _ => format!("Option({})", contract.child),
    }
}

fn slot_decode(contract: &Contract, raw: &str, condition: &str) -> String {
    let child = lower(&contract.child);
    let unpacked = format!(
        "unpack_{child}(context, value) |> result.map_error(fn(_) {{ runtime.InvalidPlan({}) }})",
        quote(condition)
    );
    let failed = format!("Error(runtime.InvalidPlan({}))", quote(condition));
    match (contract.required, contract.nullable) {
        (true, false) => format!(
            "case {raw} {{ types.Present(value) -> {unpacked} _ -> {failed} }}"
        ),
        (true, true) => format!(
            "case {raw} {{ types.Null -> Ok(None) types.Present(value) -> result.map({unpacked}, Some) _ -> {failed} }}"
        ),
        (false, false) => format!(
            "case {raw} {{ types.Absent -> Ok(None) types.Present(value) -> result.map({unpacked}, Some) _ -> {failed} }}"
        ),
        (false, true) => format!(
            "runtime.map_slot({raw}, fn(value) {{ unpack_{child}(context, value) }}) |> result.map_error(fn(_) {{ runtime.InvalidPlan({}) }})",
            quote(condition)
        ),
    }
}

fn slot_encode(contract: &Contract, value: &str, condition: &str) -> String {
    let child = lower(&contract.child);
    let packed = format!(
        "pack_{child}(context, value) |> result.map(types.Present) |> result.map_error(fn(_) {{ runtime.InvalidPlan({}) }})",
        quote(condition)
    );
    match (contract.required, contract.nullable) {
        (true, false) => format!("{{ let value = {value} {packed} }}"),
        (true, true) => format!(
            "case {value} {{ None -> Ok(types.Null) Some(value) -> {packed} }}"
        ),
        (false, false) => format!(
            "case {value} {{ None -> Ok(types.Absent) Some(value) -> {packed} }}"
        ),
        (false, true) => format!(
            "runtime.map_slot({value}, fn(value) {{ pack_{child}(context, value) }}) |> result.map_error(fn(_) {{ runtime.InvalidPlan({}) }})",
            quote(condition)
        ),
    }
}

fn constructor(name: &str, fields: &[(String, String)]) -> String {
    if fields.is_empty() {
        name.to_owned()
    } else {
        let entries = fields
            .iter()
            .map(|(label, value)| format!("{label}: {value}"))
            .collect::<Vec<_>>()
            .join(", ");
        format!("{name}({entries})")
    }
}

fn constructor_value(name: &str, values: &[String]) -> String {
    if values.is_empty() {
        name.to_owned()
    } else {
        format!("{name}({})", values.join(", "))
    }
}

fn function_ref(reference: &Value) -> Result<String> {
    Ok(format!(
        "composition.FunctionRef({}, {}, {})",
        quote(text(reference, "identity")?),
        quote(text(reference, "revision")?),
        quote(text(reference, "content_digest")?)
    ))
}

fn source_tag(input: &Value) -> Option<&str> {
    input
        .get("source")
        .and_then(|source| source.get("tag"))
        .and_then(Value::as_str)
}

fn is_http(signature: &Value) -> Result<bool> {
    Ok(tag(field(signature, "effect")?)? == "HttpRequestResponse")
}

fn indexed_fields(
    values: &[Value],
    prefix: &str,
    names: &Names,
    field_of: impl Fn(&Value) -> Result<&Value>,
) -> Result<Vec<(String, String)>> {
    values
        .iter()
        .enumerate()
        .map(|(index, value)| {
            let contract = contract_of(field_of(value)?, names)?;
            Ok((format!("{prefix}{index}"), slot_type(&contract)))
        })
        .collect()
}

fn provider_declarations(index: usize, signature: &Value, names: &Names) -> Result<Vec<String>> {
    let argument_name = format!("Provider{index}Arguments");
    let outcome_name = format!("Provider{index}Outcome");
    let http_name = format!("Provider{index}Http");
    let attempt_name = format!("{http_name}Attempt");
    let inputs = indexed_ports(list(signature, "inputs")?, "port", names)?;
    let mut lines = vec![
        format!("pub type {argument_name} {{"),
        format!("  {}", constructor(&argument_name, &inputs)),
        "}".to_owned(),
        format!("pub type {outcome_name} {{"),
    ];
    for (outcome_index, outcome) in list(signature, "outcomes")?.iter().enumerate() {
        let fields = indexed_ports(list(outcome, "value_ports")?, "port", names)?;
        lines.push(format!(
            "  {}",
            constructor(&format!("{outcome_name}{outcome_index}"), &fields)
        ));
    }
    lines.push("}".to_owned());
    if is_http(signature)? {
        let name = text(field(signature, "form")?, "value")?;
        lines.extend([
            format!("pub type {attempt_name} {{"),
            format!("  {attempt_name}Ready(input: network.AttemptInput)"),
            format!(
                "  {attempt_name}Completed(declared: signatures.OutcomeContract, outcome: {outcome_name})"
            ),
            "}".to_owned(),
            format!("pub type {http_name} {{"),
            format!("  {http_name}("),
            format!(
                "    prepare: fn({argument_name}) -> Result({attempt_name}, runtime.ExecutionFailure),"
            ),
            format!(
                "    decode: fn(network.RawHttpResponse) -> Result({outcome_name}, runtime.ExecutionFailure),"
            ),
            "  )".to_owned(),
            "}".to_owned(),
            format!(
                "pub fn provider{index}_outcome_contracts(context: Context) -> List(signatures.OutcomeContract) {{"
            ),
            format!(
                "  let assert Ok(definition) = list.find(signatures.definitions(context_library(context)), fn(value) {{ value.id == {} }})",
                quote(name)
            ),
            "  let assert signatures.SignatureDefinition(_, _, signatures.Operation(operation)) = definition"
                .to_owned(),
            "  operation.outcomes".to_owned(),
            "}".to_owned(),
        ]);
    }
    Ok(lines)
}

fn indexed_ports(values: &[Value], prefix: &str, names: &Names) -> Result<Vec<(String, String)>> {
    indexed_fields(values, prefix, names, |port| field(port, "contract"))
}

fn provider_conversions(index: usize, signature: &Value, names: &Names) -> Result<Vec<String>> {
    let argument_name = format!("Provider{index}Arguments");
    let outcome_name = format!("Provider{index}Outcome");
    let inputs = list(signature, "inputs")?;
    let mut decoded = Vec::new();
    for (port_index, port) in inputs.iter().enumerate() {
        decoded.push(format!(
            "  use raw{port_index} <- result.try(result.map_error(list.key_find(ports, composition.PortId({})), fn(_) {{ runtime.InvalidPlan(\"missing provider input\") }}))",
            quote(text(port, "id")?)
        ));
        decoded.push(format!(
            "  use port{port_index} <- result.try({})",
            slot_decode(
                &port_contract(port, names)?,
                &format!("raw{port_index}"),
                "provider input representation"
            )
        ));
    }
    let argument_values: Vec<String> = (0..inputs.len())
        .map(|position| format!("port{position}"))
        .collect();
    let mut outcome_arms = Vec::new();
    for (outcome_index, outcome) in list(signature, "outcomes")?.iter().enumerate() {
        let ports = list(outcome, "value_ports")?;
        let variables: Vec<String> = (0..ports.len())
            .map(|position| format!("port{position}"))
            .collect();
        let mut values = Vec::new();
        outcome_arms.push(format!(
            "    {} -> {{",
            constructor_value(&format!("{outcome_name}{outcome_index}"), &variables)
        ));
        for (port_index, port) in ports.iter().enumerate() {
            outcome_arms.push(format!(
                "      use raw{port_index} <- result.try({})",
                slot_encode(
                    &port_contract(port, names)?,
                    &format!("port{port_index}"),
                    "provider output representation"
                )
            ));
            values.push(format!(
                "#(composition.PortId({}), raw{port_index})",
                quote(text(port, "id")?)
            ));
        }
        outcome_arms.push(format!(
            "      Ok(runtime.OutcomeValues(composition.OutcomeId({}), [{}]))",
            quote(text(outcome, "id")?),
            values.join(", ")
        ));
        outcome_arms.push("    }".to_owned());
    }
    let mut lines = vec![
        format!(
            "fn provider{index}_arguments(context: Context, ports: List(#(composition.PortId, types.SlotValue(kdl.JsonValue)))) -> Result({argument_name}, runtime.ExecutionFailure) {{"
        ),
    ];
    lines.extend(decoded);
    lines.push(format!(
        "  Ok({})",
        constructor_value(&argument_name, &argument_values)
    ));
    lines.push("}".to_owned());
    lines.push(format!(
        "fn provider{index}_outcome(context: Context, outcome: {outcome_name}) -> Result(runtime.OutcomeValues, runtime.ExecutionFailure) {{"
    ));
    lines.push("  case outcome {".to_owned());
    lines.extend(outcome_arms);
    lines.push("  }".to_owned());
    lines.push("}".to_owned());
    Ok(lines)
}

fn provider_value(index: usize, signature: &Value) -> Result<String> {
    let reference = function_ref(field(signature, "reference")?)?;
    let implementation = if is_http(signature)? {
        format!(
            "runtime.PreparedHttp(runtime.PreparedNetworkOwner(fn(ports) {{ use arguments <- result.try(provider{index}_arguments(context, ports)) let Provider{index}Http(prepare, _) = providers.call{index} use attempt <- result.try(prepare(arguments)) case attempt {{ Provider{index}HttpAttemptReady(input) -> Ok(runtime.Ready(input)) Provider{index}HttpAttemptCompleted(declared, outcome) -> {{ use returned <- result.try(provider{index}_outcome(context, outcome)) case signatures.completed_valid(embedded_causes(context), {reference}, declared) && returned.outcome == declared.contract.id {{ True -> Ok(runtime.CompletedOutcome(returned)) False -> Error(runtime.InvalidPlan(\"undeclared external completion\")) }} }} }} }}, fn(response) {{ let Provider{index}Http(_, decode) = providers.call{index} use outcome <- result.try(decode(response)) provider{index}_outcome(context, outcome) }}))"
        )
    } else {
        format!(
            "runtime.Pure(fn(ports) {{ use arguments <- result.try(provider{index}_arguments(context, ports)) use outcome <- result.try(providers.call{index}(arguments)) provider{index}_outcome(context, outcome) }})"
        )
    };
    Ok(format!(
        "    runtime.Provider({reference}, {implementation}),"
    ))
}

pub(super) fn render(
    problem: &Value,
    composition_text: &str,
    names: &Names,
) -> Result<Vec<String>> {
    let signatures = list(problem, "signatures")?;
    let initial = list(problem, "initial_inputs")?;
    let goal = field(problem, "goal")?;
    let outputs = list(goal, "outputs")?;
    let failures = list(goal, "failures")?;
    let arguments: Vec<Value> = initial
        .iter()
        .filter(|input| source_tag(input) == Some("Argument"))
        .cloned()
        .collect();
    let argument_fields = indexed_fields(&arguments, "argument", names, |input| {
        field(input, "contract")
    })?;
    let goal_fields = indexed_fields(outputs, "value", names, |output| field(output, "contract"))?;
    let failure_fields = indexed_fields(failures, "Failure", names, |failure| {
        field(failure, "contract")
    })?;

    let mut lines = Vec::new();
    for (index, signature) in signatures.iter().enumerate() {
        lines.extend(provider_declarations(index, signature, names)?);
    }
    let provider_fields = signatures
        .iter()
        .enumerate()
        .map(|(index, signature)| {
            let provider_type = if is_http(signature)? {
                format!("Provider{index}Http")
            } else {
                format!(
                    "fn(Provider{index}Arguments) -> Result(Provider{index}Outcome, runtime.ExecutionFailure)"
                )
            };
            Ok((format!("call{index}"), provider_type))
        })
        .collect::<Result<Vec<_>>>()?;
    lines.push("pub type Providers {".to_owned());
    lines.push(format!("  {}", constructor("Providers", &provider_fields)));
    lines.push("}".to_owned());
    lines.push("pub type Arguments {".to_owned());
    lines.push(format!("  {}", constructor("Arguments", &argument_fields)));
    lines.push("}".to_owned());
    lines.push("pub type CompositionResult {".to_owned());
    lines.push(format!("  {}", constructor("Success", &goal_fields)));
    for (name, slot) in &failure_fields {
        lines.push(format!(
            "  {}",
            constructor(name, &[("value".to_owned(), slot.clone())])
        ));
    }
    lines.extend([
        "}".to_owned(),
        "pub type RunProgress {".to_owned(),
        "  Completed(result: CompositionResult, network: network.NetworkState)".to_owned(),
        "  Pending(execution: runtime.Execution, instruction: runtime.NetworkInstruction)"
            .to_owned(),
        "}".to_owned(),
        "pub type StartFailure {".to_owned(),
        "  Execution(failure: runtime.RunFailure)".to_owned(),
        "  CompositionAbsent".to_owned(),
        "}".to_owned(),
    ]);
    for (index, signature) in signatures.iter().enumerate() {
        lines.extend(provider_conversions(index, signature, names)?);
    }
    lines.extend([
        "const embedded_composition_wire = ".to_owned() + &quote(composition_text),
        "fn embedded_composition() -> kdl.JsonValue { let assert Ok(value) = values.parse_wire(embedded_composition_wire) value }".to_owned(),
        "fn embedded_problem(context: Context) -> #(composition.CompositionInput, List(#(composition.FunctionRef, List(signatures.OutcomeContract)))) {".to_owned(),
        "  let assert kdl.JsonValueObj(members) = embedded_composition()".to_owned(),
        "  let assert Ok(problem) = list.key_find(members, \"problem\")".to_owned(),
        "  let assert Ok(decoded) = signatures.decode_problem(context_library(context), problem)".to_owned(),
        "  decoded".to_owned(),
        "}".to_owned(),
        "fn embedded_causes(context: Context) -> List(#(composition.FunctionRef, List(signatures.OutcomeContract))) { let #(_, causes) = embedded_problem(context) causes }".to_owned(),
        "fn provider_list(context: Context, providers: Providers) -> List(runtime.Provider) {".to_owned(),
        "  [".to_owned(),
    ]);
    for (index, signature) in signatures.iter().enumerate() {
        lines.push(provider_value(index, signature)?);
    }
    lines.push("  ]".to_owned());
    lines.push("}".to_owned());
    lines.push("fn argument_list(context: Context, arguments: Arguments) -> Result(List(#(composition.InputId, types.SlotValue(kdl.JsonValue))), runtime.ExecutionFailure) {".to_owned());
    let mut argument_values = Vec::new();
    for (index, input) in arguments.iter().enumerate() {
        lines.push(format!(
            "  use argument{index} <- result.try({})",
            slot_encode(
                &port_contract(input, names)?,
                &format!("arguments.argument{index}"),
                "argument representation"
            )
        ));
        argument_values.push(format!(
            "#(composition.InputId({}), argument{index})",
            quote(text(input, "id")?)
        ));
    }
    lines.push(format!("  Ok([{}])", argument_values.join(", ")));
    lines.push("}".to_owned());
    lines.push("fn decode_result(context: Context, execution_result: runtime.ExecutionResult) -> Result(CompositionResult, runtime.ExecutionFailure) {".to_owned());
    lines.push("  case execution_result {".to_owned());
    lines.push("    runtime.Success(outputs) -> {".to_owned());
    let mut success_values = Vec::new();
    for (index, output) in outputs.iter().enumerate() {
        lines.push(format!(
            "      use raw{index} <- result.try(result.map_error(list.key_find(outputs, composition.GoalPortId({})), fn(_) {{ runtime.InvalidPlan(\"goal output missing\") }}))",
            quote(text(output, "id")?)
        ));
        lines.push(format!(
            "      use value{index} <- result.try({})",
            slot_decode(
                &port_contract(output, names)?,
                &format!("raw{index}"),
                "goal output representation"
            )
        ));
        success_values.push(format!("value{index}"));
    }
    lines.push(format!(
        "      Ok({})",
        constructor_value("Success", &success_values)
    ));
    lines.push("    }".to_owned());
    lines.push("    runtime.Failure(embedding, value) -> {".to_owned());
    lines.push("      case embedding {".to_owned());
    for (index, failure) in failures.iter().enumerate() {
        lines.push(format!(
            "        composition.FailureEmbeddingId({}) -> {{",
            quote(text(failure, "id")?)
        ));
        lines.push(format!(
            "          use decoded <- result.try({})",
            slot_decode(
                &port_contract(failure, names)?,
                "value",
                "failure output representation"
            )
        ));
        lines.push(format!("          Ok(Failure{index}(decoded))"));
        lines.push("        }".to_owned());
    }
    lines.extend([
        "        _ -> Error(runtime.InvalidPlan(\"failure output missing\"))".to_owned(),
        "      }".to_owned(),
        "    }".to_owned(),
        "  }".to_owned(),
        "}".to_owned(),
        "fn map_progress(context: Context, progress: runtime.Progress) -> Result(RunProgress, runtime.RunFailure) {".to_owned(),
        "  case progress {".to_owned(),
        "    runtime.Completed(execution_result, state) -> case decode_result(context, execution_result) {".to_owned(),
        "      Ok(value) -> Ok(Completed(value, state))".to_owned(),
        "      Error(cause) -> Error(runtime.RunFailure(cause, state))".to_owned(),
        "    }".to_owned(),
        "    runtime.Pending(execution, instruction) -> Ok(Pending(execution, instruction))".to_owned(),
        "  }".to_owned(),
        "}".to_owned(),
        "fn checked_execution(context: Context) -> Result(composition.CheckedComposition, StartFailure) {".to_owned(),
        "  case signatures.checked_composition(context.checked) {".to_owned(),
        "    Some(checked) -> Ok(checked)".to_owned(),
        "    None -> Error(CompositionAbsent)".to_owned(),
        "  }".to_owned(),
        "}".to_owned(),
        "pub fn run(context: Context, providers: Providers, arguments: Arguments, state: network.NetworkState) -> Result(RunProgress, StartFailure) {".to_owned(),
        "  use execution <- result.try(checked_execution(context))".to_owned(),
        "  use arguments <- result.try(argument_list(context, arguments) |> result.map_error(fn(cause) { Execution(runtime.RunFailure(cause, state)) }))".to_owned(),
        "  use progress <- result.try(runtime.start_composition(execution, provider_list(context, providers), arguments, state) |> result.map_error(Execution))".to_owned(),
        "  map_progress(context, progress) |> result.map_error(Execution)".to_owned(),
        "}".to_owned(),
        "pub fn resume(context: Context, execution: runtime.Execution, observation: runtime.ExecutionObservation) -> Result(RunProgress, runtime.RunFailure) {".to_owned(),
        "  use progress <- result.try(runtime.resume(execution, observation))".to_owned(),
        "  map_progress(context, progress)".to_owned(),
        "}".to_owned(),
    ]);
    Ok(lines)
}
