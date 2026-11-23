// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: AGPL-3.0-only

use super::{field, flag, generated_name, invalid, js, list, tag, text, Graph, Result};
use serde_json::Value;

const SUPPORT: &[&str] = &[
    "export type Option<T> = { readonly tag: \"None\" } | { readonly tag: \"Some\"; readonly value: T };",
    "export type Presence<T> = { readonly tag: \"Absent\" } | { readonly tag: \"Null\" } | { readonly tag: \"Present\"; readonly value: T };",
    "function representationFailure(condition: string): E.ExecutionFailure { return { tag: \"InvalidPlan\", condition }; }",
    "function valueFailure(condition: string): E.ExecutionFailure { return { tag: \"Value\", failure: { tag: \"CertificateMismatch\", condition } }; }",
    "function decodeRequired<T>(reference: V.TypeRef, value: V.ExactSlot): Decoded<T> { return value.tag === \"Present\" ? decodeCarrier(reference, value.value) as Decoded<T> : undecodable(\"validated required field\"); }",
    "function decodeNullable<T>(reference: V.TypeRef, value: V.ExactSlot): Decoded<Option<T>> { if (value.tag === \"Null\") return decoded<Option<T>>({ tag: \"None\" }); if (value.tag !== \"Present\") return undecodable(\"validated required nullable field\"); const item = decodeCarrier(reference, value.value); return item.tag === \"Failed\" ? item : decoded<Option<T>>({ tag: \"Some\", value: item.value as T }); }",
    "function decodeOptional<T>(reference: V.TypeRef, value: V.ExactSlot): Decoded<Option<T>> { if (value.tag === \"Absent\") return decoded<Option<T>>({ tag: \"None\" }); if (value.tag !== \"Present\") return undecodable(\"validated nonnullable field\"); const item = decodeCarrier(reference, value.value); return item.tag === \"Failed\" ? item : decoded<Option<T>>({ tag: \"Some\", value: item.value as T }); }",
    "function decodePresence<T>(reference: V.TypeRef, value: V.ExactSlot): Decoded<Presence<T>> { if (value.tag !== \"Present\") return decoded<Presence<T>>(value); const item = decodeCarrier(reference, value.value); return item.tag === \"Failed\" ? item : decoded<Presence<T>>({ tag: \"Present\", value: item.value as T }); }",
    "function encodeRequired(reference: V.TypeRef, value: unknown): V.ExactSlot { return { tag: \"Present\", value: encodeCarrier(reference, value) }; }",
    "function encodeNullable(reference: V.TypeRef, value: Option<unknown>): V.ExactSlot { return value.tag === \"None\" ? { tag: \"Null\" } : encodeRequired(reference, value.value); }",
    "function encodeOptional(reference: V.TypeRef, value: Option<unknown>): V.ExactSlot { return value.tag === \"None\" ? { tag: \"Absent\" } : encodeRequired(reference, value.value); }",
    "function encodePresence(reference: V.TypeRef, value: Presence<unknown>): V.ExactSlot { return value.tag === \"Present\" ? encodeRequired(reference, value.value) : value; }",
];

fn slot_type(graph: &Graph, slot: &Value) -> Result<String> {
    let name = graph.name_of_id(text(slot, "type_id")?)?;
    Ok(match (flag(slot, "required")?, flag(slot, "nullable")?) {
        (true, false) => name,
        (false, true) => format!("Presence<{name}>"),
        _ => format!("Option<{name}>"),
    })
}

fn decoder(graph: &Graph, slot: &Value, value: &str) -> Result<String> {
    let name = graph.name_of_id(text(slot, "type_id")?)?;
    let node = graph.reference_of_id(text(slot, "type_id")?)?;
    Ok(match (flag(slot, "required")?, flag(slot, "nullable")?) {
        (true, false) => format!("decodeRequired<{name}>({node}, {value})"),
        (false, true) => format!("decodePresence<{name}>({node}, {value})"),
        (true, true) => format!("decodeNullable<{name}>({node}, {value})"),
        (false, false) => format!("decodeOptional<{name}>({node}, {value})"),
    })
}

fn encoder(graph: &Graph, slot: &Value, value: &str) -> Result<String> {
    let node = graph.reference_of_id(text(slot, "type_id")?)?;
    Ok(match (flag(slot, "required")?, flag(slot, "nullable")?) {
        (true, false) => format!("encodeRequired({node}, {value})"),
        (false, true) => format!("encodePresence({node}, {value})"),
        (true, true) => format!("encodeNullable({node}, {value})"),
        (false, false) => format!("encodeOptional({node}, {value})"),
    })
}

fn tuple_type(types: &[String]) -> String {
    match types {
        [] => "void".to_owned(),
        [only] => only.clone(),
        _ => format!("readonly [{}]", types.join(", ")),
    }
}

fn tuple_value(values: &[String]) -> String {
    match values {
        [] => "undefined".to_owned(),
        [only] => only.clone(),
        _ => format!("[{}] as const", values.join(", ")),
    }
}

fn append_semicolon(lines: &mut [String]) {
    if let Some(last) = lines.last_mut() {
        last.push(';');
    }
}

fn source_tag(input: &Value) -> Option<&str> {
    input
        .get("source")
        .and_then(|source| source.get("tag"))
        .and_then(Value::as_str)
}

fn operation_name(signature: &Value) -> Result<String> {
    let form = field(signature, "form")?;
    if tag(form)? != "Operation" {
        return Err(invalid("generated HTTP operation"));
    }
    let value = field(form, "value")?;
    let name = value
        .as_str()
        .or_else(|| value.get("name").and_then(Value::as_str))
        .ok_or_else(|| invalid("generated HTTP operation"))?;
    Ok(generated_name(name))
}

pub(super) fn render(
    out: &mut String,
    graph: &Graph,
    problem: &Value,
    document: &str,
) -> Result<()> {
    let document_literal = super::js(document);
    out.push_str(&format!(
        "const problemWire: unknown = {problem};\nconst generationDocument = {document_literal};\nconst decodedProblem = W.decodeProblem(signatureLibrary, problemWire);\nconst problem: C.CompositionInput = decodedProblem.input;\n"
    ));
    let signatures = list(problem, "signatures")?;
    let initial = list(problem, "initial_inputs")?;
    let goal = field(problem, "goal")?;
    let outputs = list(goal, "outputs")?;
    let failures = list(goal, "failures")?;
    let arguments: Vec<&Value> = initial
        .iter()
        .filter(|input| source_tag(input) == Some("Argument"))
        .collect();
    let mut lines: Vec<String> = SUPPORT.iter().map(|line| (*line).to_owned()).collect();

    for (index, signature) in signatures.iter().enumerate() {
        let inputs = list(signature, "inputs")?;
        let input_types = inputs
            .iter()
            .map(|port| slot_type(graph, field(port, "contract")?))
            .collect::<Result<Vec<_>>>()?;
        lines.push(format!("export type Outcome{index} ="));
        let outcomes = list(signature, "outcomes")?;
        for (arm, outcome) in outcomes.iter().enumerate() {
            let types = list(outcome, "value_ports")?
                .iter()
                .map(|port| slot_type(graph, field(port, "contract")?))
                .collect::<Result<Vec<_>>>()?;
            lines.push(format!(
                "  | {{ readonly tag: \"K{arm}\"; readonly values: readonly [{}] }}",
                types.join(", ")
            ));
        }
        append_semicolon(&mut lines);
        lines.push(format!(
            "function decodeArguments{index}(ports: readonly (readonly [C.PortId, V.ExactSlot])[]): E.Result<{}> {{",
            tuple_type(&input_types)
        ));
        for (port_index, port) in inputs.iter().enumerate() {
            let contract = field(port, "contract")?;
            lines.push(format!(
                "  const value{port_index} = ports.find(([id]) => id === {})?.[1];",
                js(text(port, "id")?)
            ));
            lines.push(format!(
                "  if (value{port_index} === undefined) return {{ tag: \"Failed\", failure: representationFailure(\"missing provider input\") }};"
            ));
            lines.push(format!(
                "  const argument{port_index} = {};",
                decoder(graph, contract, &format!("value{port_index}"))?
            ));
            lines.push(format!(
                "  if (argument{port_index}.tag === \"Failed\") return {{ tag: \"Failed\", failure: representationFailure(\"provider input representation\") }};"
            ));
        }
        let values: Vec<String> = (0..inputs.len())
            .map(|port_index| format!("argument{port_index}.value"))
            .collect();
        lines.push(format!(
            "  return {{ tag: \"Ok\", value: {} }};",
            tuple_value(&values)
        ));
        lines.push("}".to_owned());
        lines.push(format!(
            "function encodeOutcome{index}(outcome: Outcome{index}): E.CallResult {{"
        ));
        lines.push("  switch (outcome.tag) {".to_owned());
        for (arm, outcome) in outcomes.iter().enumerate() {
            let encoded = list(outcome, "value_ports")?
                .iter()
                .enumerate()
                .map(|(port_index, port)| {
                    Ok(format!(
                        "[{}, {}] as const",
                        js(text(port, "id")?),
                        encoder(
                            graph,
                            field(port, "contract")?,
                            &format!("outcome.values[{port_index}]")
                        )?
                    ))
                })
                .collect::<Result<Vec<_>>>()?;
            lines.push(format!(
                "    case \"K{arm}\": return {{ outcome: {}, outputs: [{}] }};",
                js(text(outcome, "id")?),
                encoded.join(", ")
            ));
        }
        lines.push("  }".to_owned());
        lines.push("  const exhaustive: never = outcome; return exhaustive;".to_owned());
        lines.push("}".to_owned());
    }

    lines.push("export interface Providers {".to_owned());
    for (index, signature) in signatures.iter().enumerate() {
        let input_types = list(signature, "inputs")?
            .iter()
            .map(|port| slot_type(graph, field(port, "contract")?))
            .collect::<Result<Vec<_>>>()?;
        let provider = if tag(field(signature, "effect")?)? == "HttpRequestResponse" {
            format!(
                "S.NetworkBinding<{}, Outcome{index}>",
                tuple_type(&input_types)
            )
        } else {
            format!(
                "(arguments_: {}) => E.Result<Outcome{index}>",
                tuple_type(&input_types)
            )
        };
        lines.push(format!("  readonly call{index}: {provider};"));
    }
    lines.push("}".to_owned());
    lines.push("export interface Arguments {".to_owned());
    for (index, argument) in arguments.iter().enumerate() {
        lines.push(format!(
            "  readonly argument{index}: {};",
            slot_type(graph, field(argument, "contract")?)?
        ));
    }
    lines.push("}".to_owned());
    let goal_types = outputs
        .iter()
        .map(|goal| slot_type(graph, field(goal, "contract")?))
        .collect::<Result<Vec<_>>>()?;
    lines.push("export type Result =".to_owned());
    lines.push(format!(
        "  | {{ readonly tag: \"Success\"; readonly values: {} }}",
        tuple_type(&goal_types)
    ));
    for (index, failure) in failures.iter().enumerate() {
        lines.push(format!(
            "  | {{ readonly tag: \"Failure{index}\"; readonly value: {} }}",
            slot_type(graph, field(failure, "contract")?)?
        ));
    }
    append_semicolon(&mut lines);
    lines.extend(
        [
            "export type RunProgress =",
            "  | { readonly tag: \"Completed\"; readonly result: Result; readonly network: N.NetworkState }",
            "  | { readonly tag: \"Pending\"; readonly execution: E.Execution; readonly instruction: E.NetworkInstruction };",
            "const initializedToken = Symbol(\"generated initialization\");",
            "export class Initialized {",
            "  constructor(token: symbol, readonly generation: S.CheckedSignatureGeneration, readonly composition: E.AdmittedComposition) { if (token !== initializedToken) throw new TypeError(\"Initialized is constructed only by initialize\"); Object.freeze(this); }",
            "}",
            "export type InitializeResult = { readonly tag: \"Initialized\"; readonly initialized: Initialized } | { readonly tag: \"Failed\"; readonly failure: S.AdmissionFailure };",
            "export type RunResult = { readonly tag: \"Ok\"; readonly value: RunProgress } | { readonly tag: \"Failed\"; readonly failure: E.RunFailure };",
            "function providerList(providers: Providers): readonly E.Provider[] { return [",
        ]
        .map(|line| line.to_owned()),
    );
    for (index, signature) in signatures.iter().enumerate() {
        let reference = format!("problem.signatures[{index}].reference");
        if tag(field(signature, "effect")?)? == "HttpRequestResponse" {
            let contract = operation_name(signature)?;
            lines.push(format!(
                "  {{ reference: {reference}, implementation: {{ tag: \"PreparedHttp\", owner: {{"
            ));
            lines.push("    prepare: ports => {".to_owned());
            lines.push(format!("      const decoded = decodeArguments{index}(ports); if (decoded.tag === \"Failed\") return decoded;"));
            lines.push(format!("      const prepared = S.prepareCall({contract}, providers.call{index}, decoded.value); if (prepared.tag === \"Failed\") return prepared;"));
            lines.push(format!("      return prepared.value.tag === \"Ready\" ? {{ tag: \"Ok\", value: {{ tag: \"Ready\", input: prepared.value.value }} }} : {{ tag: \"Ok\", value: {{ tag: \"Completed\", result: encodeOutcome{index}(prepared.value.value.value) }} }};"));
            lines.push("    },".to_owned());
            lines.push(format!("    decode: response => {{ const decoded = providers.call{index}.transport.decode(response); return decoded.tag === \"Failed\" ? decoded : {{ tag: \"Ok\", value: encodeOutcome{index}(decoded.value) }}; }},"));
            lines.push("  } } },".to_owned());
        } else {
            lines.push(format!("  {{ reference: {reference}, implementation: {{ tag: \"Pure\", callback: ports => {{"));
            lines.push(format!("    const decoded = decodeArguments{index}(ports); if (decoded.tag === \"Failed\") return decoded;"));
            lines.push(format!("    const result = providers.call{index}(decoded.value); return result.tag === \"Failed\" ? result : {{ tag: \"Ok\", value: encodeOutcome{index}(result.value) }};"));
            lines.push("  } } },".to_owned());
        }
    }
    lines.push("]; }".to_owned());
    lines.push("function decodeResult(result: E.ExecutionResult): E.Result<Result> {".to_owned());
    lines.push("  if (result.tag === \"Success\") {".to_owned());
    for (index, goal) in outputs.iter().enumerate() {
        lines.push(format!(
            "    const value{index} = result.outputs.find(([id]) => id === {})?.[1];",
            js(text(goal, "id")?)
        ));
        lines.push(format!("    if (value{index} === undefined) return {{ tag: \"Failed\", failure: representationFailure(\"goal output missing\") }};"));
        lines.push(format!(
            "    const result{index} = {};",
            decoder(graph, field(goal, "contract")?, &format!("value{index}"))?
        ));
        lines.push(format!("    if (result{index}.tag === \"Failed\") return {{ tag: \"Failed\", failure: valueFailure(result{index}.condition) }};"));
    }
    let output_values: Vec<String> = (0..outputs.len())
        .map(|index| format!("result{index}.value"))
        .collect();
    lines.push(format!(
        "    return {{ tag: \"Ok\", value: {{ tag: \"Success\", values: {} }} }};",
        tuple_value(&output_values)
    ));
    lines.push("  }".to_owned());
    lines.push("  switch (result.embedding) {".to_owned());
    for (index, failure) in failures.iter().enumerate() {
        lines.push(format!(
            "    case {}: {{ const item = {}; return item.tag === \"Failed\" ? {{ tag: \"Failed\", failure: valueFailure(item.condition) }} : {{ tag: \"Ok\", value: {{ tag: \"Failure{index}\", value: item.value }} }}; }}",
            js(text(failure, "id")?),
            decoder(graph, field(failure, "contract")?, "result.value")?
        ));
    }
    lines.push("    default: return { tag: \"Failed\", failure: representationFailure(\"failure output missing\") };".to_owned());
    lines.push("  }".to_owned());
    lines.push("}".to_owned());
    lines.extend(
        [
            "function mapProgress(result: E.RunResult): RunResult {",
            "  if (result.tag === \"Failed\") return result;",
            "  if (result.value.tag === \"Pending\") return { tag: \"Ok\", value: result.value };",
            "  const decoded = decodeResult(result.value.result);",
            "  return decoded.tag === \"Failed\" ? { tag: \"Failed\", failure: { cause: decoded.failure, network: result.value.network } } : { tag: \"Ok\", value: { tag: \"Completed\", result: decoded.value, network: result.value.network } };",
            "}",
            "function argumentList(arguments_: Arguments): readonly (readonly [C.InputId, V.ExactSlot])[] { return [",
        ]
        .map(|line| line.to_owned()),
    );
    for (index, argument) in arguments.iter().enumerate() {
        lines.push(format!(
            "  [{}, {}] as const,",
            js(text(argument, "id")?),
            encoder(
                graph,
                field(argument, "contract")?,
                &format!("arguments_.argument{index}")
            )?
        ));
    }
    lines.extend(
        [
            "]; }",
            "export function initialize(): InitializeResult {",
            "  const admission = S.admitSignatureGeneration(generationBasis, generationDocument);",
            "  if (admission.tag === \"Failed\") return admission;",
            "  const composition = admission.checked.composition;",
            "  if (composition === null) return { tag: \"Failed\", failure: { tag: \"Wire\", value: { tag: \"Syntax\", path: \"$.composition\", value: \"composition is absent\" } } };",
            "  return { tag: \"Initialized\", initialized: new Initialized(initializedToken, admission.checked, composition) };",
            "}",
            "export function run(initialized: Initialized, providers: Providers, arguments_: Arguments, network: N.NetworkState): RunResult {",
            "  return mapProgress(E.start(initialized.composition, providerList(providers), argumentList(arguments_), network));",
            "}",
            "export function resume(execution: E.Execution, observation: E.ExecutionObservation): RunResult { return mapProgress(E.resume(execution, observation)); }",
        ]
        .map(|line| line.to_owned()),
    );
    for line in lines {
        out.push_str(&line);
        out.push('\n');
    }
    Ok(())
}
