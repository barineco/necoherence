// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: AGPL-3.0-only

use super::syntax::{identifier, json_literal, python_bool, text_literal};
use super::{
    field, invalid, list, lookup, nullable, required, tag, text, type_id, Emitter, Result,
};
use serde_json::{json, Value};

const SLOT_HELPERS: &[&str] = &[
    "def _decode_slot(value, decoder, required, nullable, value_failure):",
    "    try:",
    "        if isinstance(value, _composition.PresentValue): return decoder(value.value)",
    "    except _ValueFailure as failure:",
    "        return _execution.ValueFailure(failure) if value_failure else _execution.InvalidPlan('provider input representation')",
    "    if isinstance(value, _composition.AbsentValue) and not required: return ABSENT",
    "    if isinstance(value, _composition.NullValue) and nullable: return None",
    "    return _execution.InvalidPlan('provider input representation')",
    "",
    "def _encode_slot(value, encoder, required, nullable, condition):",
    "    if isinstance(value, Absent):",
    "        return _composition.ABSENT_VALUE if not required else _execution.InvalidPlan(condition)",
    "    if value is None and nullable: return _composition.NULL_VALUE",
    "    try:",
    "        return _composition.PresentValue(encoder(value))",
    "    except _ValueFailure:",
    "        return _execution.InvalidPlan(condition)",
    "",
];

const RUN_TYPES: &[&str] = &[
    "@dataclass(frozen=True, slots=True)",
    "class RunCompleted:",
    "    result: Result",
    "    network: _network.NetworkState",
    "",
    "@dataclass(frozen=True, slots=True)",
    "class RunPending:",
    "    execution: _execution.Execution",
    "    instruction: _execution.NetworkInstruction",
    "",
    "RunProgress: TypeAlias = RunCompleted | RunPending",
    "",
    "@dataclass(frozen=True, slots=True)",
    "class InitializePreparation:",
    "    failure: _composition.CompositionInputFailure",
    "",
    "@dataclass(frozen=True, slots=True)",
    "class InitializeAdmission:",
    "    failure: _admission.AdmissionFailure",
    "",
    "InitializeFailure: TypeAlias = InitializePreparation | InitializeAdmission",
    "",
    "@dataclass(frozen=True, slots=True)",
    "class StartExecution:",
    "    failure: _execution.RunFailure",
    "",
];

const PROGRESS_FUNCTIONS: &[&str] = &[
    "def _map_progress(progress):",
    "    if isinstance(progress, _execution.RunFailure): return progress",
    "    if isinstance(progress, _execution.Completed):",
    "        result = _decode_result(progress.result)",
    "        if isinstance(result, _execution.ExecutionFailure): return _execution.RunFailure(result, progress.network)",
    "        return RunCompleted(result, progress.network)",
    "    if isinstance(progress, _execution.Pending): return RunPending(progress.execution, progress.instruction)",
    "    return _execution.InvalidPlan('execution progress representation')",
    "",
];

fn source_tag(item: &Value) -> Option<&str> {
    item.get("source")
        .and_then(|source| source.get("tag"))
        .and_then(Value::as_str)
}

fn attribute_of<'v>(fields: &'v [(String, String)], identity: &str) -> Result<&'v str> {
    lookup(fields, identity).map(String::as_str)
}

type Outcome<'a> = (&'a Value, String, Vec<(String, String)>);

fn external_outcomes(outcomes: &[Outcome<'_>]) -> Result<Vec<(String, String)>> {
    let mut external = Vec::new();
    for (outcome, outcome_name, _) in outcomes {
        if tag(field(outcome, "cause")?)? == "ExternalCondition"
            && tag(field(outcome, "form")?)? == "DeclaredFailure"
        {
            external.push((outcome_name.clone(), text(outcome, "id")?.to_owned()));
        }
    }
    Ok(external)
}

struct ProviderRow<'a> {
    signature: &'a Value,
    arguments_name: String,
    argument_fields: Vec<(String, String)>,
    outcomes: Vec<Outcome<'a>>,
    alias: String,
}

impl Emitter<'_> {
    pub(super) fn composition(&mut self) -> Result<()> {
        let Some(composition) = self.composition else {
            return Ok(());
        };
        let problem = field(composition, "problem")?;
        let identity = text(problem, "identity")?.to_owned();
        let initial: Vec<Value> = list(problem, "initial_inputs")?
            .iter()
            .filter(|item| source_tag(item) == Some("Argument"))
            .cloned()
            .collect();
        let signatures: &[Value] = match problem.get("signatures") {
            Some(value) => value
                .as_array()
                .map(Vec::as_slice)
                .ok_or_else(|| invalid("generated signatures"))?,
            None => &[],
        };
        let goal = field(problem, "goal")?;
        let outputs = list(goal, "outputs")?;
        let failures = list(goal, "failures")?;

        for line in SLOT_HELPERS {
            self.push(*line);
        }

        let mut provider_rows: Vec<ProviderRow<'_>> = Vec::new();
        for (index, signature) in signatures.iter().enumerate() {
            let arguments_name = format!("ProviderArguments{index}");
            let argument_fields =
                self.typed_port_class(&arguments_name, list(signature, "inputs")?)?;
            let mut outcomes = Vec::new();
            for (arm, outcome) in list(signature, "outcomes")?.iter().enumerate() {
                let outcome_name = format!("Outcome{index}K{arm}");
                let outcome_fields =
                    self.typed_port_class(&outcome_name, list(outcome, "value_ports")?)?;
                self.push(format!(
                    "{outcome_name}.outcome_id = {}",
                    text_literal(text(outcome, "id")?)
                ));
                self.push("");
                outcomes.push((outcome, outcome_name, outcome_fields));
            }
            let alias = format!("Outcome{index}");
            let alias_members: Vec<String> = outcomes
                .iter()
                .map(|(_, outcome_name, _)| outcome_name.clone())
                .collect();
            self.push(format!(
                "{alias}: TypeAlias = {}",
                alias_members.join(" | ")
            ));
            self.push("");
            provider_rows.push(ProviderRow {
                signature,
                arguments_name,
                argument_fields,
                outcomes,
                alias,
            });
        }

        self.push("@dataclass(frozen=True, slots=True, kw_only=True)");
        self.push("class Providers:");
        if provider_rows.is_empty() {
            self.push("    pass");
        }
        for (index, row) in provider_rows.iter().enumerate() {
            let annotation = if tag(field(row.signature, "effect")?)? == "HttpRequestResponse" {
                format!(
                    "_execution.NetworkBinding[{}, {}]",
                    row.arguments_name, row.alias
                )
            } else {
                format!(
                    "Callable[[{}], {} | _execution.ExecutionFailure]",
                    row.arguments_name, row.alias
                )
            };
            self.push(format!("    call{index}: {annotation}"));
        }
        self.push("");

        let initial_fields = self.typed_port_class("Arguments", &initial)?;
        let outputs_owned: Vec<Value> = outputs.to_vec();
        let success_fields = self.typed_port_class("ResultSuccess", &outputs_owned)?;
        let mut failure_rows: Vec<(&Value, String)> = Vec::new();
        for (index, failure) in failures.iter().enumerate() {
            let name = format!("ResultFailure{index}");
            self.typed_port_class(
                &name,
                &[json!({"id": "value", "contract": field(failure, "contract")?.clone()})],
            )?;
            failure_rows.push((failure, name));
        }
        let mut result_names = vec!["ResultSuccess".to_owned()];
        result_names.extend(failure_rows.iter().map(|(_, name)| name.clone()));
        self.push(format!("Result: TypeAlias = {}", result_names.join(" | ")));
        self.push("");
        for line in RUN_TYPES {
            self.push(*line);
        }

        for (index, row) in provider_rows.iter().enumerate() {
            self.push(format!("def _provider_arguments{index}(ports):"));
            let inputs = list(row.signature, "inputs")?;
            for (port_index, port) in inputs.iter().enumerate() {
                let found = format!("raw{port_index}");
                self.push(format!(
                    "    {found} = next((value for identity, value in ports if identity.value == {}), None)",
                    text_literal(text(port, "id")?)
                ));
                self.push(format!(
                    "    if {found} is None: return _execution.InvalidPlan('missing provider input')"
                ));
                self.decode_lines(
                    &format!("value{port_index}"),
                    field(port, "contract")?,
                    &found,
                    "    ",
                    false,
                )?;
            }
            let mut values = Vec::new();
            for (port_index, port) in inputs.iter().enumerate() {
                values.push(format!(
                    "{}=value{port_index}",
                    attribute_of(&row.argument_fields, text(port, "id")?)?
                ));
            }
            self.push(format!(
                "    return {}({})",
                row.arguments_name,
                values.join(", ")
            ));
            self.push("");

            self.push(format!("def _provider_result{index}(result):"));
            for (outcome, outcome_name, outcome_fields) in &row.outcomes {
                self.push(format!("    if isinstance(result, {outcome_name}):"));
                self.push("        values = []");
                for (port_index, port) in list(outcome, "value_ports")?.iter().enumerate() {
                    let port_id = text(port, "id")?;
                    let attribute = attribute_of(outcome_fields, port_id)?;
                    self.encode_lines(
                        &format!("value{port_index}"),
                        field(port, "contract")?,
                        &format!("result.{attribute}"),
                        "provider result representation",
                        "        ",
                        false,
                    )?;
                    self.push(format!(
                        "        values.append((_composition.PortId({}), value{port_index}))",
                        text_literal(port_id)
                    ));
                }
                self.push(format!(
                    "        return _execution.CallResult(_composition.OutcomeId({}), tuple(values))",
                    text_literal(text(outcome, "id")?)
                ));
            }
            self.push("    return _execution.InvalidPlan('provider result representation')");
            self.push("");

            let http = tag(field(row.signature, "effect")?)? == "HttpRequestResponse";
            if http {
                let external = external_outcomes(&row.outcomes)?;
                let external_values: Vec<String> = external
                    .iter()
                    .map(|(outcome_name, outcome_id)| {
                        format!("({outcome_name}, {})", text_literal(outcome_id))
                    })
                    .collect();
                let trailing = if external_values.is_empty() { "" } else { "," };
                self.push(format!("def _provider_prepare{index}(binding, ports):"));
                self.push(format!("    arguments = _provider_arguments{index}(ports)"));
                self.push(
                    "    if isinstance(arguments, _execution.ExecutionFailure): return arguments",
                );
                self.push("    prepared = binding.prepare(arguments)");
                self.push(
                    "    if isinstance(prepared, _execution.ExecutionFailure): return prepared",
                );
                self.push("    if isinstance(prepared, _execution.ReadyCall): return prepared");
                self.push("    if not isinstance(prepared, _execution.CompletedCall): return _execution.InvalidPlan('provider preparation representation')");
                self.push("    outcome = prepared.result");
                self.push(format!(
                    "    matching = next((identity for outcome_type, identity in ({}{trailing}) if type(outcome) is outcome_type), None)",
                    external_values.join(", ")
                ));
                self.push("    if matching is None or binding.outcome_id(outcome) != matching: return _execution.InvalidPlan('undeclared external completion')");
                self.push(format!("    result = _provider_result{index}(outcome)"));
                self.push("    return result if isinstance(result, _execution.ExecutionFailure) else _execution.CompletedCall(result)");
                self.push("");
                self.push(format!("def _provider_decode{index}(binding, response):"));
                self.push("    result = binding.transport.decode(response)");
                self.push("    if isinstance(result, _execution.ExecutionFailure): return result");
                self.push(format!("    return _provider_result{index}(result)"));
                self.push("");
            } else {
                self.push(format!("def _provider_call{index}(callback, ports):"));
                self.push(format!("    arguments = _provider_arguments{index}(ports)"));
                self.push(
                    "    if isinstance(arguments, _execution.ExecutionFailure): return arguments",
                );
                self.push("    result = callback(arguments)");
                self.push("    if isinstance(result, _execution.ExecutionFailure): return result");
                self.push(format!("    return _provider_result{index}(result)"));
                self.push("");
            }
        }

        self.push(format!(
            "_COMPOSITION_LIBRARY = {}",
            json_literal(self.library)
        ));
        self.push(format!(
            "_GENERATION_BASIS = {}",
            text_literal(&self.basis.to_string())
        ));
        self.push(format!(
            "_GENERATION_DOCUMENT = {}",
            text_literal(self.exchange_text)
        ));
        self.push(format!(
            "_COMPOSITION_PROBLEM_WIRE = {}",
            json_literal(problem)
        ));
        self.push("_COMPOSITION_PROBLEM, _COMPOSITION_CAUSES = _wire.decode_problem(_COMPOSITION_LIBRARY, _COMPOSITION_PROBLEM_WIRE)");
        self.push("");

        self.push("def _provider_list(prepared, providers):");
        self.push("    values = []");
        for (index, row) in provider_rows.iter().enumerate() {
            let implementation = if tag(field(row.signature, "effect")?)? == "HttpRequestResponse" {
                format!(
                    "_execution.PreparedHttpProvider(_execution.PreparedNetworkOwner(lambda ports: _provider_prepare{index}(providers.call{index}, ports), lambda response: _provider_decode{index}(providers.call{index}, response)))"
                )
            } else {
                format!(
                    "_execution.PureProvider(lambda ports: _provider_call{index}(providers.call{index}, ports))"
                )
            };
            self.push(format!(
                "    values.append(_execution.Provider(prepared.input.signatures[{index}].reference, {implementation}))"
            ));
        }
        self.push("    return tuple(values)");
        self.push("");

        self.push("def _decode_result(result):");
        self.push("    if isinstance(result, _execution.Success):");
        for (index, output) in outputs.iter().enumerate() {
            let output_id = text(output, "id")?;
            self.push(format!(
                "        raw{index} = next((value for identity, value in result.outputs if identity.value == {}), None)",
                text_literal(output_id)
            ));
            self.push(format!(
                "        if raw{index} is None: return _execution.InvalidPlan('goal output missing')"
            ));
            self.decode_lines(
                &format!("value{index}"),
                field(output, "contract")?,
                &format!("raw{index}"),
                "        ",
                true,
            )?;
        }
        let mut success_values = Vec::new();
        for (index, output) in outputs.iter().enumerate() {
            success_values.push(format!(
                "{}=value{index}",
                attribute_of(&success_fields, text(output, "id")?)?
            ));
        }
        self.push(format!(
            "        return ResultSuccess({})",
            success_values.join(", ")
        ));
        self.push("    if isinstance(result, _execution.DeclaredFailure):");
        for (failure, name) in &failure_rows {
            self.push(format!(
                "        if result.embedding.value == {}:",
                text_literal(text(failure, "id")?)
            ));
            self.decode_lines(
                "value",
                field(failure, "contract")?,
                "result.value",
                "            ",
                true,
            )?;
            self.push(format!("            return {name}(value=value)"));
        }
        self.push("        return _execution.InvalidPlan('failure output missing')");
        self.push("    return _execution.InvalidPlan('execution result representation')");
        self.push("");
        for line in PROGRESS_FUNCTIONS {
            self.push(*line);
        }

        self.push("def initialize():");
        self.push("    try:");
        self.push("        return _admission.admit_signature_generation(_admission.decode_expected_signature_basis(_GENERATION_BASIS), _GENERATION_DOCUMENT)");
        self.push(
            "    except _admission.CompositionInput as error: return InitializePreparation(error.cause)",
        );
        self.push(
            "    except _admission.AdmissionFailure as error: return InitializeAdmission(error)",
        );
        self.push("");
        self.push(
            "def run(generation: _admission.CheckedSignatureGeneration, providers: Providers, arguments: Arguments, network: _network.NetworkState):",
        );
        self.push("    admitted = generation.admitted_composition");
        self.push("    values = []");
        for (index, item) in initial.iter().enumerate() {
            let item_id = text(item, "id")?;
            let attribute = attribute_of(&initial_fields, item_id)?.to_owned();
            self.encode_lines(
                &format!("value{index}"),
                field(item, "contract")?,
                &format!("arguments.{attribute}"),
                "argument representation",
                "    ",
                true,
            )?;
            self.push(format!(
                "    values.append((_composition.InputId({}), value{index}))",
                text_literal(item_id)
            ));
        }
        self.push("    progress = _map_progress(_execution.start(admitted, _provider_list(admitted.prepared, providers), tuple(values), network))");
        self.push("    return StartExecution(progress) if isinstance(progress, _execution.RunFailure) else progress");
        self.push("");
        self.push("def resume(execution: _execution.Execution, observation: _execution.ExecutionObservation):");
        self.push("    return _map_progress(_execution.resume(execution, observation))");
        self.push("");
        self.set_composition_entry(&identity);
        Ok(())
    }

    fn set_composition_entry(&mut self, identity: &str) {
        super::set_entry(
            &mut self.entry_values,
            identity.to_owned(),
            "run".to_owned(),
        );
        super::set_entry(
            &mut self.entry_shapes,
            identity.to_owned(),
            ("Arguments".to_owned(), "Result".to_owned()),
        );
    }

    fn typed_port_class(&mut self, name: &str, ports: &[Value]) -> Result<Vec<(String, String)>> {
        self.push("@dataclass(frozen=True, slots=True, kw_only=True)");
        self.push(format!("class {name}:"));
        let mut fields = Vec::new();
        for port in ports {
            let port_id = text(port, "id")?;
            let attribute = identifier(port_id);
            let default = if required(field(port, "contract")?)? {
                ""
            } else {
                " = ABSENT"
            };
            self.push(format!("    {attribute}: object{default}"));
            fields.push((port_id.to_owned(), attribute));
        }
        if ports.is_empty() {
            self.push("    pass");
        }
        self.push("");
        self.push("    def __post_init__(self):");
        if ports.is_empty() {
            self.push("        pass");
        }
        for port in ports {
            let attribute = identifier(text(port, "id")?);
            let contract = field(port, "contract")?;
            let identity = type_id(contract)?;
            let encoder = self.child_function(identity, "encode_")?;
            self.push(format!("        if isinstance(self.{attribute}, Absent):"));
            if required(contract)? {
                self.push(format!(
                    "            raise _ValueFailure(_ctx.reference({}), (), MISSING_REQUIRED, ABSENT_VALUE)",
                    text_literal(identity)
                ));
            } else {
                self.push("            pass");
            }
            self.push(format!(
                "        elif self.{attribute} is None and {}:",
                python_bool(nullable(contract)?)
            ));
            self.push("            pass");
            self.push("        else:");
            self.push(format!("            {encoder}(self.{attribute})"));
        }
        self.push("");
        Ok(fields)
    }

    fn decode_lines(
        &mut self,
        target: &str,
        contract: &Value,
        source: &str,
        indent: &str,
        value_failure: bool,
    ) -> Result<()> {
        let decoder = self.child_function(type_id(contract)?, "_decode_")?;
        self.push(format!(
            "{indent}{target} = _decode_slot({source}, {decoder}, {}, {}, {})",
            python_bool(required(contract)?),
            python_bool(nullable(contract)?),
            python_bool(value_failure)
        ));
        self.push(format!(
            "{indent}if isinstance({target}, _execution.ExecutionFailure): return {target}"
        ));
        Ok(())
    }

    fn encode_lines(
        &mut self,
        target: &str,
        contract: &Value,
        source: &str,
        condition: &str,
        indent: &str,
        start_failure: bool,
    ) -> Result<()> {
        let encoder = self.child_function(type_id(contract)?, "encode_")?;
        let failure = if start_failure {
            format!("StartExecution(_execution.RunFailure({target}, network))")
        } else {
            target.to_owned()
        };
        self.push(format!(
            "{indent}{target} = _encode_slot({source}, {encoder}, {}, {}, {})",
            python_bool(required(contract)?),
            python_bool(nullable(contract)?),
            text_literal(condition)
        ));
        self.push(format!(
            "{indent}if isinstance({target}, _execution.ExecutionFailure): return {failure}"
        ));
        Ok(())
    }
}
