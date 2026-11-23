// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

use neco_quotient_retention::{ErasureDecision, MissingInput, RetentionReason};
use necoherence::network_effect::{observe as observe_network, *};
use serde::de::DeserializeOwned;
use serde::Deserialize;
use serde_json::{json, Map, Value};
use std::io::{self, Read, Write};
use std::sync::Arc;

#[derive(Deserialize)]
struct StateInvocation {
    operation: String,
    state: NetworkState,
}

#[derive(Deserialize)]
struct PrepareInvocation {
    state: NetworkState,
    input: AttemptInput,
}

#[derive(Deserialize)]
struct SendCommandInvocation {
    state: NetworkState,
    prepared: PreparedAttempt,
}

#[derive(Deserialize)]
struct CancelCommandInvocation {
    state: NetworkState,
    started: StartedAttempt,
}

#[derive(Deserialize)]
struct ObserveStartInvocation {
    state: NetworkState,
    prepared: PreparedAttempt,
    observation: StartObservation,
}

#[derive(Deserialize)]
struct ObserveInvocation {
    state: NetworkState,
    observation: HostObservation,
}

#[derive(Deserialize)]
struct AnnotateEffectInvocation {
    state: NetworkState,
    effect: EffectObservation,
}

#[derive(Deserialize)]
struct RetryInvocation {
    state: NetworkState,
    request: RetryRequest,
}

#[derive(Deserialize)]
struct ReleaseHostRecordInvocation {
    state: NetworkState,
    attempt: AttemptIdentity,
    running: bool,
}

#[derive(Deserialize)]
struct HostSettledInvocation {
    state: NetworkState,
    attempt: AttemptIdentity,
}

fn host_record_observation_name(observation: &HostRecordObservation) -> &'static str {
    match observation {
        HostRecordObservation::Undelivered => "undelivered",
        HostRecordObservation::DeliveryOrdinal => "deliveryOrdinal",
    }
}

fn retention_reason_output(
    reason: &RetentionReason<AttemptIdentity, (), HostRecordObservation>,
) -> Result<Value, String> {
    let attempt_reason = |tag: &str, attempt: &AttemptIdentity| -> Result<Value, String> {
        Ok(json!({"tag": tag, "attempt": encoded(attempt)?}))
    };
    match reason {
        RetentionReason::ActiveBasis(_) => Ok(json!({"tag": "activeBasis"})),
        RetentionReason::BranchRoot(attempt) => attempt_reason("branchRoot", attempt),
        RetentionReason::FutureUse(attempt) => attempt_reason("futureUse", attempt),
        RetentionReason::OutstandingEffect(attempt) => attempt_reason("outstandingEffect", attempt),
        RetentionReason::OutstandingSignal(attempt) => attempt_reason("outstandingSignal", attempt),
        RetentionReason::ExternalReobservation => Ok(json!({"tag": "externalReobservation"})),
        RetentionReason::ObservationNotPreserved(observation) => Ok(
            json!({"tag": "observationNotPreserved", "observation": host_record_observation_name(observation)}),
        ),
    }
}

fn release_output(
    decision: ErasureDecision<AttemptIdentity, (), (), (), HostRecordObservation>,
) -> Result<Value, String> {
    match decision {
        ErasureDecision::Dematerialize(witness) => Ok(json!({
            "result": "Dematerialize",
            "witness": {
                "target": encoded(&witness.target)?,
                "removedObservations": witness
                    .removed_observations
                    .iter()
                    .map(|observation| Value::String(host_record_observation_name(observation).to_owned()))
                    .collect::<Vec<_>>(),
            },
        })),
        ErasureDecision::Retain(reasons) => Ok(json!({
            "result": "Retain",
            "reasons": reasons
                .iter()
                .map(retention_reason_output)
                .collect::<Result<Vec<_>, _>>()?,
        })),
        ErasureDecision::Rejected(missing) => Ok(json!({
            "result": "MissingInput",
            "missing": match missing {
                MissingInput::RemovedObservationsUndeclared => "removedObservationsUndeclared",
                MissingInput::RecoverabilityUnknown => "recoverabilityUnknown",
            },
        })),
    }
}

fn invalid(error: impl ToString) -> Value {
    json!({"result": "InvalidInvocation", "error": error.to_string()})
}

fn decode<T: DeserializeOwned>(invocation: &Value) -> Result<T, String> {
    serde_json::from_value(invocation.clone()).map_err(|error| error.to_string())
}

fn encoded<T: serde::Serialize>(value: T) -> Result<Value, String> {
    serde_json::to_value(value).map_err(|error| error.to_string())
}

fn object(result: &str) -> Map<String, Value> {
    let mut output = Map::new();
    output.insert("result".to_owned(), Value::String(result.to_owned()));
    output
}

fn rejected(state: NetworkState, failure: NetworkFailure) -> Result<Value, String> {
    let mut output = object("Rejected");
    output.insert("state".to_owned(), encoded(state)?);
    output.insert("failure".to_owned(), encoded(failure)?);
    Ok(Value::Object(output))
}

fn read_output(step: ReadStateStep) -> Result<Value, String> {
    match step {
        ReadStateStep::Read(state) => {
            let mut output = object("Read");
            output.insert("state".to_owned(), encoded(state)?);
            Ok(Value::Object(output))
        }
        ReadStateStep::Rejected(state, failure) => rejected(state, failure),
    }
}

fn prepare_output(step: PrepareStep) -> Result<Value, String> {
    match step {
        PrepareStep::Prepared(state, prepared) => {
            let mut output = object("Prepared");
            output.insert("state".to_owned(), encoded(state)?);
            output.insert("prepared".to_owned(), encoded(prepared)?);
            Ok(Value::Object(output))
        }
        PrepareStep::Rejected(state, failure) => rejected(state, failure),
    }
}

fn command_output<T: serde::Serialize>(step: CommandStep<T>) -> Result<Value, String> {
    match step {
        CommandStep::CommandReady(state, command) => {
            let mut output = object("CommandReady");
            output.insert("state".to_owned(), encoded(state)?);
            output.insert("command".to_owned(), encoded(command)?);
            Ok(Value::Object(output))
        }
        CommandStep::Rejected(state, failure) => rejected(state, failure),
    }
}

fn network_output(step: NetworkStep) -> Result<Value, String> {
    match step {
        NetworkStep::Started(state, started) => {
            let mut output = object("Started");
            output.insert("state".to_owned(), encoded(state)?);
            output.insert("started".to_owned(), encoded(started)?);
            Ok(Value::Object(output))
        }
        NetworkStep::Pending(state, started) => {
            let mut output = object("Pending");
            output.insert("state".to_owned(), encoded(state)?);
            output.insert("started".to_owned(), encoded(started)?);
            Ok(Value::Object(output))
        }
        NetworkStep::Terminal(state, settled) => {
            let mut output = object("Terminal");
            output.insert("state".to_owned(), encoded(state)?);
            output.insert("settled".to_owned(), encoded(settled)?);
            Ok(Value::Object(output))
        }
        NetworkStep::Late(state, settled, late) => {
            let mut output = object("Late");
            output.insert("state".to_owned(), encoded(state)?);
            output.insert("settled".to_owned(), encoded(settled)?);
            output.insert("late".to_owned(), encoded(late)?);
            Ok(Value::Object(output))
        }
        NetworkStep::Duplicate(state, attempt, delivery) => {
            let mut output = object("Duplicate");
            output.insert("state".to_owned(), encoded(state)?);
            output.insert("attempt".to_owned(), encoded(attempt)?);
            output.insert("delivery".to_owned(), encoded(delivery)?);
            Ok(Value::Object(output))
        }
        NetworkStep::Rejected(state, failure) => rejected(state, failure),
    }
}

fn state_output(step: StateStep) -> Result<Value, String> {
    match step {
        StateStep::Applied(state) => {
            let mut output = object("Applied");
            output.insert("state".to_owned(), encoded(state)?);
            Ok(Value::Object(output))
        }
        StateStep::Rejected(state, failure) => rejected(state, failure),
    }
}

#[derive(Deserialize)]
struct RecordsInvocation {
    operation: String,
    state: StateRecords,
}

#[derive(Deserialize)]
struct StateRecords {
    attempts: Vec<AttemptRecord>,
}

fn invalid_state_output(
    invocation: &Value,
    operation: &str,
    attempts: Vec<AttemptRecord>,
    violation: NetworkStateViolation,
) -> Result<Value, String> {
    let failure = match operation {
        "sendCommand" => {
            let prepared: PreparedAttempt = decode(&invocation["prepared"])?;
            if attempts.iter().any(|record| {
                record.input == prepared.input
                    && record.chain == prepared.chain
                    && record.disposition == AttemptDisposition::CommandIssued
            }) {
                NetworkFailure::CommandAlreadyIssued {
                    attempt: prepared.input.attempt.clone(),
                }
            } else {
                NetworkFailure::InvalidNetworkState { violation }
            }
        }
        "retry" => {
            let request: RetryRequest = decode(&invocation["request"])?;
            let attempt = match request.permission {
                RetryPermission::RetryAllowed { authorization } => authorization.from,
                RetryPermission::RetryDenied { parent, .. } => parent,
            };
            NetworkFailure::RetryNotPermitted { attempt }
        }
        "readNetworkState" | "prepare" | "cancelCommand" | "observeStart" | "observe"
        | "annotateEffect" => NetworkFailure::InvalidNetworkState { violation },
        other => return Err(format!("operation: unknown value {other}")),
    };
    let mut output = object("Rejected");
    output.insert(
        "state".to_owned(),
        json!({ "attempts": encoded(attempts)? }),
    );
    output.insert("failure".to_owned(), encoded(failure)?);
    Ok(Value::Object(output))
}

fn dispatch(invocation: Value) -> Result<Value, String> {
    let records: RecordsInvocation = decode(&invocation)?;
    if let Err(violation) = network_state_of(records.state.attempts.clone()) {
        return invalid_state_output(
            &invocation,
            &records.operation,
            records.state.attempts,
            violation,
        );
    }
    let envelope: StateInvocation = decode(&invocation)?;
    match envelope.operation.as_str() {
        "readNetworkState" => read_output(read_network_state(envelope.state)),
        "prepare" => {
            let invocation: PrepareInvocation = decode(&invocation)?;
            prepare_output(prepare(invocation.state, Arc::new(invocation.input)))
        }
        "sendCommand" => {
            let invocation: SendCommandInvocation = decode(&invocation)?;
            command_output(send_command(invocation.state, invocation.prepared))
        }
        "cancelCommand" => {
            let invocation: CancelCommandInvocation = decode(&invocation)?;
            command_output(cancel_command(invocation.state, invocation.started))
        }
        "observeStart" => {
            let invocation: ObserveStartInvocation = decode(&invocation)?;
            network_output(observe_start(
                invocation.state,
                invocation.prepared,
                invocation.observation,
            ))
        }
        "observe" => {
            let invocation: ObserveInvocation = decode(&invocation)?;
            network_output(observe_network(invocation.state, invocation.observation))
        }
        "annotateEffect" => {
            let invocation: AnnotateEffectInvocation = decode(&invocation)?;
            state_output(annotate_effect(invocation.state, invocation.effect))
        }
        "retry" => {
            let invocation: RetryInvocation = decode(&invocation)?;
            prepare_output(retry(invocation.state, invocation.request))
        }
        "releaseHostRecord" => {
            let invocation: ReleaseHostRecordInvocation = decode(&invocation)?;
            let running = invocation.running;
            release_output(release_host_record(
                &invocation.state,
                |_| running,
                &invocation.attempt,
            ))
        }
        "hostSettled" => {
            let invocation: HostSettledInvocation = decode(&invocation)?;
            Ok(json!({
                "result": "HostSettled",
                "value": host_settled(&invocation.state, &invocation.attempt),
            }))
        }
        other => Err(format!("operation: unknown value {other}")),
    }
}

fn is_high_surrogate(code: u32) -> bool {
    (0xD800..=0xDBFF).contains(&code)
}

fn is_low_surrogate(code: u32) -> bool {
    (0xDC00..=0xDFFF).contains(&code)
}

fn hex4(chars: &[char], start: usize) -> Option<u32> {
    let raw: String = chars.get(start..start + 4)?.iter().collect();
    u32::from_str_radix(&raw, 16).ok()
}

fn span(chars: &[char], start: usize, length: usize) -> String {
    chars
        .get(start..start + length)
        .map(|part| part.iter().collect())
        .unwrap_or_default()
}

fn sanitize_lone_surrogates(input: &str) -> String {
    let chars: Vec<char> = input.chars().collect();
    let mut out = String::with_capacity(input.len());
    let mut index = 0;
    while let Some(&current) = chars.get(index) {
        if current != '\\' {
            out.push(current);
            index += 1;
            continue;
        }
        let Some(&next) = chars.get(index + 1) else {
            out.push('\\');
            index += 1;
            continue;
        };
        if next != 'u' {
            out.push('\\');
            out.push(next);
            index += 2;
            continue;
        }
        let Some(code) = hex4(&chars, index + 2) else {
            out.push('\\');
            out.push('u');
            index += 2;
            continue;
        };
        if is_high_surrogate(code) {
            let pair = chars.get(index + 6) == Some(&'\\')
                && chars.get(index + 7) == Some(&'u')
                && hex4(&chars, index + 8).is_some_and(is_low_surrogate);
            if pair {
                out.push_str(&span(&chars, index, 12));
                index += 12;
            } else {
                out.push_str("\\ufffd");
                index += 6;
            }
        } else if is_low_surrogate(code) {
            out.push_str("\\ufffd");
            index += 6;
        } else {
            out.push_str(&span(&chars, index, 6));
            index += 6;
        }
    }
    out
}

fn main() {
    let mut input = String::new();
    let output = match io::stdin().read_to_string(&mut input) {
        Ok(_) => match serde_json::from_str::<Value>(&sanitize_lone_surrogates(&input)) {
            Ok(invocation) => dispatch(invocation).unwrap_or_else(invalid),
            Err(error) => invalid(error),
        },
        Err(error) => invalid(error),
    };
    let mut stdout = io::stdout().lock();
    let _ = writeln!(stdout, "{output}");
}
