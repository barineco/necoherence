// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

use necoherence::network_effect::*;
use necoherence::request_progression::{ExecutionHandle, RequestIdentity};
use necoherence_http_adapter::{
    CancellationPort, CooperativeCancellation, MonotonicClockPort, SystemMonotonicClock,
    UreqHttpAdapter,
};
use serde::Deserialize;
use serde_json::{json, Value};
use std::io::{self, BufRead, Write};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::thread::sleep;
use std::time::{Duration, Instant};

#[derive(Deserialize)]
struct Row {
    constructor: String,
    #[serde(rename = "testOnly")]
    test_only: bool,
    #[serde(rename = "peerHost")]
    peer_host: String,
    #[serde(rename = "peerPort")]
    peer_port: u16,
    #[serde(rename = "timeoutStage")]
    timeout_stage: Option<String>,
    #[serde(rename = "timeoutCause")]
    timeout_cause: Option<String>,
    #[serde(default)]
    scheme: Option<String>,
    #[serde(default, rename = "bodyLength")]
    body_length: Option<usize>,
    #[serde(default)]
    deadline: Option<String>,
    #[serde(default)]
    cancellation: Option<String>,
    #[serde(default, rename = "foreignCommand")]
    foreign_command: bool,
    #[serde(default, rename = "clockFailure")]
    clock_failure: bool,
    #[serde(default, rename = "deadlineReached")]
    deadline_reached: bool,
}

fn failing_capability() -> MonotonicClockCapability {
    MonotonicClockCapability {
        identity: OpaqueEvidence {
            value: "matrix-failing-clock".to_owned(),
        },
        clock_basis: ClockBasis {
            value: "matrix".to_owned(),
        },
    }
}

struct FailingClock {
    armed: Arc<AtomicBool>,
    reached: bool,
}

impl MonotonicClockPort for FailingClock {
    fn capability(&self) -> MonotonicClockCapability {
        failing_capability()
    }
    fn observe(&self) -> Result<MonotonicClockObservation, HostFailure> {
        if self.armed.load(Ordering::SeqCst) {
            return Err(HostFailure::HostRuntimeFailure);
        }
        Ok(MonotonicClockObservation {
            clock_basis: failing_capability().clock_basis,
            value: if self.reached {
                1_000_000_000_000_000_000u64.into()
            } else {
                0u8.into()
            },
        })
    }
}

const SCENARIO: &str = "Scenario";

fn scenario_clock() -> SystemMonotonicClock {
    SystemMonotonicClock::new(ClockBasis {
        value: "matrix".to_owned(),
    })
}

fn scenario_input(row: &Row) -> AttemptInput {
    let scheme = row.scheme.as_deref().unwrap_or("http");
    let target = format!(
        "{scheme}://{}:{}/host-failure-matrix",
        row.peer_host, row.peer_port
    );
    let mut input = base_input(row, target);
    input.instruction.method = "POST".to_owned();
    input.instruction.body = vec![b'x'; row.body_length.unwrap_or(0)];
    input.configuration.response_body_limit = 64u8.into();
    let clock_capability = match row.deadline.as_deref() {
        Some("adapter") => Some(scenario_clock().capability()),
        Some("foreign") => Some(MonotonicClockCapability {
            identity: OpaqueEvidence {
                value: "foreign-clock".to_owned(),
            },
            clock_basis: ClockBasis {
                value: "foreign-basis".to_owned(),
            },
        }),
        _ => None,
    };
    if let Some(capability) = clock_capability {
        input.deadline = Some(Deadline {
            clock_basis: capability.clock_basis.clone(),
            limit: 1_000_000_000_000_000_000u64.into(),
            capability: capability.clone(),
        });
        input.configuration.monotonic_clock = Some(capability);
    }
    input.configuration.cancellation = match row.cancellation.as_deref() {
        Some("adapter") => Some(CooperativeCancellation::default().capability()),
        Some("foreign") => Some(CancellationCapability {
            identity: OpaqueEvidence {
                value: "foreign-cancel".to_owned(),
            },
        }),
        _ => None,
    };
    input
}

struct RejectingCancellation {
    capability: CancellationCapability,
    accept: bool,
}

impl CancellationPort for RejectingCancellation {
    fn capability(&self) -> CancellationCapability {
        self.capability.clone()
    }
    fn request(&self, _handle: &ExecutionHandle) -> Result<(), HostFailure> {
        if self.accept {
            Ok(())
        } else {
            Err(HostFailure::CancellationRejected)
        }
    }
}

fn stage_of(name: &str) -> HostStage {
    match name {
        "Start" => HostStage::Start,
        "RequestWrite" => HostStage::RequestWrite,
        "ResponseHeaders" => HostStage::ResponseHeaders,
        "ResponseBody" => HostStage::ResponseBody,
        "Cancel" => HostStage::Cancel,
        "Deadline" => HostStage::Deadline,
        other => panic!("unknown HostStage: {other}"),
    }
}

fn cause_of(name: &str) -> HostTimeoutCause {
    match name {
        "LibraryReported" => HostTimeoutCause::LibraryReported,
        "SocketReported" => HostTimeoutCause::SocketReported,
        "PoolAcquisition" => HostTimeoutCause::PoolAcquisition,
        "HostOperation" => HostTimeoutCause::HostOperation,
        other => panic!("unknown HostTimeoutCause: {other}"),
    }
}

fn stage_name(stage: &HostStage) -> &'static str {
    match stage {
        HostStage::Start => "Start",
        HostStage::RequestWrite => "RequestWrite",
        HostStage::ResponseHeaders => "ResponseHeaders",
        HostStage::ResponseBody => "ResponseBody",
        HostStage::Cancel => "Cancel",
        HostStage::Deadline => "Deadline",
    }
}

fn cause_name(cause: &HostTimeoutCause) -> &'static str {
    match cause {
        HostTimeoutCause::LibraryReported => "LibraryReported",
        HostTimeoutCause::SocketReported => "SocketReported",
        HostTimeoutCause::PoolAcquisition => "PoolAcquisition",
        HostTimeoutCause::HostOperation => "HostOperation",
    }
}

fn identity(kind: &str) -> RequestIdentity {
    RequestIdentity {
        kind: kind.to_owned(),
        provenance: "host-failure-matrix".to_owned(),
        revision: 0u8.into(),
    }
}

fn base_input(row: &Row, target: String) -> AttemptInput {
    AttemptInput {
        attempt: AttemptIdentity {
            logical: identity(&row.constructor),
            ordinal: 0u8.into(),
        },
        instruction: HttpWireInstruction {
            method: "GET".to_owned(),
            target,
            headers: Vec::new(),
            body: Vec::new(),
        },
        deadline: None,
        configuration: HostConfiguration {
            request_body_limit: 256u16.into(),
            response_body_limit: 16u16.into(),
            cancellation: None,
            monotonic_clock: None,
        },
    }
}

fn build_input(row: &Row) -> (AttemptInput, bool) {
    if row.constructor == SCENARIO {
        return (scenario_input(row), false);
    }
    let peer_target = format!(
        "http://{}:{}/host-failure-matrix",
        row.peer_host, row.peer_port
    );
    let mut input = base_input(row, peer_target);
    let mut reject_cancellation = false;
    match row.constructor.as_str() {
        "UnsupportedUriScheme" => {
            input.instruction.target = format!(
                "ftp://{}:{}/host-failure-matrix",
                row.peer_host, row.peer_port
            );
        }
        "InvalidHostConfiguration" => {
            let capability = CancellationCapability {
                identity: OpaqueEvidence {
                    value: "matrix-mismatched-cancel".to_owned(),
                },
            };
            input.configuration.cancellation = Some(capability);
        }
        "RequestHeaderEncodingUnavailable" => {
            input.instruction.headers = vec![RawHeaderField {
                name: "x-forged".to_owned(),
                value: vec![128u8],
            }];
        }
        "DeadlineControlUnavailable" => {
            let capability = MonotonicClockCapability {
                identity: OpaqueEvidence {
                    value: "matrix-mismatched-clock".to_owned(),
                },
                clock_basis: ClockBasis {
                    value: "matrix".to_owned(),
                },
            };
            input.deadline = Some(Deadline {
                clock_basis: ClockBasis {
                    value: "matrix".to_owned(),
                },
                limit: 5u8.into(),
                capability: capability.clone(),
            });
            input.configuration.monotonic_clock = Some(capability);
        }
        "HostRuntimeFailure" | "DeadlineExceeded" if row.clock_failure || row.deadline_reached => {
            let capability = failing_capability();
            input.deadline = Some(Deadline {
                clock_basis: capability.clock_basis.clone(),
                limit: 1_000_000_000_000_000_000u64.into(),
                capability: capability.clone(),
            });
            input.configuration.monotonic_clock = Some(capability);
        }
        "CancellationRejected" => {
            let capability = CancellationCapability {
                identity: OpaqueEvidence {
                    value: "matrix-cancel".to_owned(),
                },
            };
            input.configuration.cancellation = Some(capability);
            reject_cancellation = true;
        }
        "ResponseBodyLimitExceeded" => {
            input.configuration.response_body_limit = 4u8.into();
        }
        _ => {}
    }
    (input, reject_cancellation)
}

fn direct_failure(
    constructor: &str,
    timeout_stage: Option<&str>,
    timeout_cause: Option<&str>,
) -> (HostStage, HostFailure) {
    match constructor {
        "ExecutionStartFailed" => (HostStage::Start, HostFailure::ExecutionStartFailed),
        "NameResolutionFailed" => (HostStage::Start, HostFailure::NameResolutionFailed),
        "RequestWriteFailed" => (HostStage::RequestWrite, HostFailure::RequestWriteFailed),
        "HeaderRepresentationUnavailable" => (
            HostStage::ResponseHeaders,
            HostFailure::HeaderRepresentationUnavailable,
        ),
        "HostRuntimeFailure" => (HostStage::ResponseBody, HostFailure::HostRuntimeFailure),
        "Timeout" => {
            let stage = stage_of(timeout_stage.expect("timeoutStage required"));
            let cause = cause_of(timeout_cause.expect("timeoutCause required"));
            (stage, HostFailure::Timeout { stage, cause })
        }
        other => panic!("unknown test-only constructor: {other}"),
    }
}

fn outcome_report(
    handle: &str,
    ledger_record_count: usize,
    issued_command_count: usize,
    terminal_or_pending: &NetworkStep,
) -> Value {
    match terminal_or_pending {
        NetworkStep::Terminal(_, settled) => report_from_terminal(
            handle,
            ledger_record_count,
            issued_command_count,
            &settled.terminal,
        ),
        NetworkStep::Started(_, _) | NetworkStep::Pending(_, _) => json!({
            "ledgerRecordCount": ledger_record_count,
            "issuedCommandCount": issued_command_count,
            "outcomeTag": "Pending",
            "stage": Value::Null,
            "cause": Value::Null,
            "innerStage": Value::Null,
            "innerCause": Value::Null,
            "effect": "Unknown",
            "handle": handle,
        }),
        NetworkStep::Rejected(_, failure) => json!({
            "ledgerRecordCount": ledger_record_count,
            "issuedCommandCount": issued_command_count,
            "outcomeTag": "LedgerRejected",
            "cause": format!("{failure:?}"),
            "effect": Value::Null,
            "handle": handle,
        }),
        other => json!({
            "error": format!("unexpected NetworkStep: {other:?}"),
        }),
    }
}

fn report_from_terminal(
    handle: &str,
    ledger_record_count: usize,
    issued_command_count: usize,
    terminal: &NetworkTerminal,
) -> Value {
    let effect_tag = match &terminal.effect {
        EffectStatus::NoEffect { .. } => "NoEffect",
        EffectStatus::EffectOccurred { .. } => "EffectOccurred",
        EffectStatus::Unknown { .. } => "Unknown",
    };
    let effect_reason = match &terminal.effect {
        EffectStatus::Unknown { reason } => Some(format!("{reason:?}")),
        _ => None,
    };
    match &terminal.outcome {
        NetworkOutcome::Failed { failure } => {
            let (inner_stage, inner_cause) = match &failure.cause {
                HostFailure::Timeout { stage, cause } => {
                    (Some(stage_name(stage)), Some(cause_name(cause)))
                }
                _ => (None, None),
            };
            json!({
                "ledgerRecordCount": ledger_record_count,
                "issuedCommandCount": issued_command_count,
                "outcomeTag": "Failed",
                "stage": stage_name(&failure.stage),
                "cause": failure_tag(&failure.cause),
                "innerStage": inner_stage,
                "innerCause": inner_cause,
                "effect": effect_tag,
                "effectReason": effect_reason,
                "handle": handle,
            })
        }
        NetworkOutcome::Cancelled => json!({
            "ledgerRecordCount": ledger_record_count,
            "issuedCommandCount": issued_command_count,
            "outcomeTag": "Cancelled",
            "stage": "Cancel",
            "cause": "Cancelled",
            "innerStage": Value::Null,
            "innerCause": Value::Null,
            "effect": effect_tag,
            "effectReason": effect_reason,
            "handle": handle,
        }),
        other => json!({
            "ledgerRecordCount": ledger_record_count,
            "issuedCommandCount": issued_command_count,
            "outcomeTag": outcome_tag(other),
            "effect": effect_tag,
            "effectReason": effect_reason,
            "handle": handle,
        }),
    }
}

fn outcome_tag(outcome: &NetworkOutcome) -> &'static str {
    match outcome {
        NetworkOutcome::Response { .. } => "Response",
        NetworkOutcome::Failed { .. } => "Failed",
        NetworkOutcome::Cancelled => "Cancelled",
        NetworkOutcome::DeadlineExceeded { .. } => "DeadlineExceeded",
    }
}

fn failure_tag(cause: &HostFailure) -> &'static str {
    match cause {
        HostFailure::UnsupportedUriScheme => "UnsupportedUriScheme",
        HostFailure::InvalidHostConfiguration => "InvalidHostConfiguration",
        HostFailure::ExecutionStartFailed => "ExecutionStartFailed",
        HostFailure::NameResolutionFailed => "NameResolutionFailed",
        HostFailure::ConnectionFailed => "ConnectionFailed",
        HostFailure::RequestWriteFailed => "RequestWriteFailed",
        HostFailure::ResponseHeadersFailed => "ResponseHeadersFailed",
        HostFailure::ResponseBodyFailed => "ResponseBodyFailed",
        HostFailure::ResponseBodyLimitExceeded => "ResponseBodyLimitExceeded",
        HostFailure::MalformedResponse => "MalformedResponse",
        HostFailure::HeaderRepresentationUnavailable => "HeaderRepresentationUnavailable",
        HostFailure::RequestHeaderEncodingUnavailable => "RequestHeaderEncodingUnavailable",
        HostFailure::CancellationRejected => "CancellationRejected",
        HostFailure::DeadlineControlUnavailable => "DeadlineControlUnavailable",
        HostFailure::Timeout { .. } => "Timeout",
        HostFailure::HostRuntimeFailure => "HostRuntimeFailure",
        HostFailure::HostClosed => "HostClosed",
    }
}

fn run_row(row: Row) -> Value {
    let (input, reject_cancellation) = build_input(&row);
    let forged = row.constructor == SCENARIO && row.body_length.unwrap_or(0) > 256;
    let mut ledger_input = input.clone();
    if forged {
        ledger_input.instruction.body = Vec::new();
    }
    let prepare_result = prepare(NetworkState::default(), Arc::new(ledger_input));
    let (state, prepared) = match prepare_result {
        PrepareStep::Prepared(state, prepared) => (state, prepared),
        PrepareStep::Rejected(_, failure) => {
            return json!({"error": format!("prepare rejected: {failure:?}")})
        }
    };
    let ledger_record_count = network_attempts(&state).len();
    let send_result = send_command(state, prepared.clone());
    let (state, command) = match send_result {
        CommandStep::CommandReady(state, command) if forged => (
            state,
            SendCommand {
                prepared: PreparedAttempt {
                    input: Arc::new(input.clone()),
                    ..command.prepared
                },
            },
        ),
        CommandStep::CommandReady(state, command) => (state, command),
        CommandStep::Rejected(_, failure) => {
            return json!({"error": format!("send_command rejected: {failure:?}")})
        }
    };
    let issued_command_count = 1usize;

    if row.test_only {
        return run_test_only_row(
            &row,
            input,
            state,
            prepared,
            ledger_record_count,
            issued_command_count,
        );
    }
    run_real_row(
        &row,
        input,
        state,
        prepared,
        command,
        reject_cancellation,
        (ledger_record_count, issued_command_count),
    )
}

fn run_test_only_row(
    row: &Row,
    input: AttemptInput,
    state: NetworkState,
    prepared: PreparedAttempt,
    ledger_record_count: usize,
    issued_command_count: usize,
) -> Value {
    let (stage, cause) = direct_failure(
        &row.constructor,
        row.timeout_stage.as_deref(),
        row.timeout_cause.as_deref(),
    );
    if row.constructor == "ExecutionStartFailed" {
        let start_observation = StartObservation::StartFailed {
            failure: NetworkHostFailure {
                attempt: input.attempt.clone(),
                stage,
                configuration: input.configuration.clone(),
                cause,
            },
            effect: EffectStatus::Unknown {
                reason: UnknownEffectReason::HostFailure,
            },
        };
        return finish_from_start_observation(
            state,
            prepared,
            start_observation,
            ledger_record_count,
            issued_command_count,
        );
    }
    let handle = ExecutionHandle {
        value: "rust-test-only-handle".into(),
    };
    let started_observation = StartObservation::Started {
        attempt: input.attempt.clone(),
        handle: handle.clone(),
    };
    let started_step = observe_start(state, prepared, started_observation);
    let state = match started_step {
        NetworkStep::Started(state, _) => state,
        other => return json!({"error": format!("unexpected observe_start result: {other:?}")}),
    };
    let failure_observation = AdapterObservation::FailureObservation {
        attempt: input.attempt.clone(),
        handle: handle.clone(),
        source_sequence: None,
        failure: NetworkHostFailure {
            attempt: input.attempt.clone(),
            stage,
            configuration: input.configuration.clone(),
            cause,
        },
        effect: EffectStatus::Unknown {
            reason: UnknownEffectReason::HostFailure,
        },
    };
    let host_observation = HostObservation::Delivered {
        delivery: 0u8.into(),
        observation: failure_observation,
    };
    let step = observe(state, host_observation);
    outcome_report(
        &handle.value,
        ledger_record_count,
        issued_command_count,
        &step,
    )
}

fn run_real_row(
    row: &Row,
    input: AttemptInput,
    state: NetworkState,
    prepared: PreparedAttempt,
    command: SendCommand,
    reject_cancellation: bool,
    (ledger_record_count, issued_command_count): (usize, usize),
) -> Value {
    let clock = SystemMonotonicClock::new(ClockBasis {
        value: "rust-matrix".to_owned(),
    });
    if reject_cancellation {
        let capability = input
            .configuration
            .cancellation
            .clone()
            .expect("cancellation capability");
        let adapter = UreqHttpAdapter::new(
            clock,
            RejectingCancellation {
                capability: capability.clone(),
                accept: row.foreign_command,
            },
        );
        let start_observation = adapter.start(command);
        let capability = if row.foreign_command {
            CancellationCapability {
                identity: OpaqueEvidence {
                    value: "foreign-cancel".to_owned(),
                },
            }
        } else {
            capability
        };
        return match start_observation {
            StartObservation::Started { handle, .. } => {
                sleep(Duration::from_millis(50));
                let cancel_command = CancelCommand {
                    attempt: input.attempt.clone(),
                    handle: handle.clone(),
                    capability,
                };
                let Ok(observation) = adapter.cancel(cancel_command) else {
                    return json!({"error": "unknown execution"});
                };
                finish_from_host_observation(
                    state,
                    prepared,
                    input,
                    observation,
                    ledger_record_count,
                    issued_command_count,
                )
            }
            failed => finish_from_start_observation(
                state,
                prepared,
                failed,
                ledger_record_count,
                issued_command_count,
            ),
        };
    }
    if row.clock_failure || row.deadline_reached {
        let armed = Arc::new(AtomicBool::new(false));
        let adapter = UreqHttpAdapter::new(
            FailingClock {
                armed: Arc::clone(&armed),
                reached: row.deadline_reached,
            },
            CooperativeCancellation::default(),
        );
        return match adapter.start(command) {
            StartObservation::Started { handle, .. } => {
                sleep(Duration::from_millis(if row.deadline_reached {
                    300
                } else {
                    50
                }));
                armed.store(row.clock_failure, Ordering::SeqCst);
                let started = StartedAttempt {
                    prepared: prepared.clone(),
                    handle,
                };
                match adapter.observe(&started) {
                    Ok(observation @ HostObservation::Delivered { .. }) => {
                        finish_from_host_observation(
                            state,
                            prepared,
                            input,
                            observation,
                            ledger_record_count,
                            issued_command_count,
                        )
                    }
                    _ => json!({"error": "clock failure was not delivered"}),
                }
            }
            failed => finish_from_start_observation(
                state,
                prepared,
                failed,
                ledger_record_count,
                issued_command_count,
            ),
        };
    }
    let adapter = if row.constructor == SCENARIO {
        UreqHttpAdapter::new(scenario_clock(), CooperativeCancellation::default())
    } else {
        UreqHttpAdapter::default()
    };
    let start_observation = adapter.start(command);
    match start_observation {
        StartObservation::StartFailed { .. } => finish_from_start_observation(
            state,
            prepared,
            start_observation,
            ledger_record_count,
            issued_command_count,
        ),
        StartObservation::Started { handle, .. } => {
            let started = StartedAttempt {
                prepared: prepared.clone(),
                handle: handle.clone(),
            };
            if row.constructor == "HostClosed" {
                sleep(Duration::from_millis(50));
                let Ok(observation) = adapter.close(&started) else {
                    return json!({"error": "unknown execution"});
                };
                return finish_from_host_observation(
                    state,
                    prepared,
                    input,
                    observation,
                    ledger_record_count,
                    issued_command_count,
                );
            }
            poll_to_terminal(
                &adapter,
                &started,
                state,
                prepared,
                input,
                ledger_record_count,
                issued_command_count,
            )
        }
    }
}

fn poll_to_terminal(
    adapter: &UreqHttpAdapter,
    started: &StartedAttempt,
    state: NetworkState,
    prepared: PreparedAttempt,
    input: AttemptInput,
    ledger_record_count: usize,
    issued_command_count: usize,
) -> Value {
    let deadline = Instant::now() + Duration::from_secs(3);
    loop {
        let Ok(observation) = adapter.observe(started) else {
            return json!({"error": "unknown execution"});
        };
        match &observation {
            HostObservation::Delivered { .. } => {
                return finish_from_host_observation(
                    state,
                    prepared,
                    input,
                    observation,
                    ledger_record_count,
                    issued_command_count,
                );
            }
            HostObservation::Pending { .. } => {
                if Instant::now() >= deadline {
                    return json!({"error": "polling timed out"});
                }
                sleep(Duration::from_millis(10));
            }
        }
    }
}

fn finish_from_start_observation(
    state: NetworkState,
    prepared: PreparedAttempt,
    start_observation: StartObservation,
    ledger_record_count: usize,
    issued_command_count: usize,
) -> Value {
    let step = observe_start(state, prepared, start_observation);
    match step {
        NetworkStep::Terminal(_, settled) => report_from_terminal(
            "start-failed",
            ledger_record_count,
            issued_command_count,
            &settled.terminal,
        ),
        NetworkStep::Rejected(_, failure) => json!({
            "ledgerRecordCount": ledger_record_count,
            "issuedCommandCount": issued_command_count,
            "outcomeTag": "LedgerRejected",
            "cause": format!("{failure:?}"),
            "effect": Value::Null,
            "handle": "start-failed",
        }),
        other => json!({"error": format!("unexpected observe_start result: {other:?}")}),
    }
}

fn finish_from_host_observation(
    state: NetworkState,
    prepared: PreparedAttempt,
    input: AttemptInput,
    observation: HostObservation,
    ledger_record_count: usize,
    issued_command_count: usize,
) -> Value {
    let started_step = observe_start(
        state,
        prepared,
        StartObservation::Started {
            attempt: input.attempt.clone(),
            handle: handle_of(&observation),
        },
    );
    let state = match started_step {
        NetworkStep::Started(state, _) => state,
        other => return json!({"error": format!("unexpected observe_start result: {other:?}")}),
    };
    let step = observe(state, observation);
    outcome_report(
        &handle_of_step(&step),
        ledger_record_count,
        issued_command_count,
        &step,
    )
}

fn handle_of(observation: &HostObservation) -> ExecutionHandle {
    match observation {
        HostObservation::Pending { handle, .. } => handle.clone(),
        HostObservation::Delivered { observation, .. } => match observation {
            AdapterObservation::ResponseObservation { handle, .. }
            | AdapterObservation::FailureObservation { handle, .. }
            | AdapterObservation::CancellationObservation { handle, .. }
            | AdapterObservation::DeadlineObservation { handle, .. } => handle.clone(),
        },
    }
}

fn handle_of_step(step: &NetworkStep) -> String {
    match step {
        NetworkStep::Terminal(_, settled) | NetworkStep::Late(_, settled, _) => settled
            .handle
            .as_ref()
            .map(|handle| handle.value.to_string())
            .unwrap_or_default(),
        NetworkStep::Started(_, started) | NetworkStep::Pending(_, started) => {
            started.handle.value.to_string()
        }
        _ => String::new(),
    }
}

fn main() {
    let stdin = io::stdin();
    let stdout = io::stdout();
    let mut out = stdout.lock();
    for line in stdin.lock().lines() {
        let line = line.expect("read stdin line");
        if line.trim().is_empty() {
            continue;
        }
        let row: Row = match serde_json::from_str(&line) {
            Ok(row) => row,
            Err(error) => {
                writeln!(out, "{}", json!({"error": format!("invalid row: {error}")}))
                    .expect("write stdout");
                continue;
            }
        };
        let report = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| run_row(row)))
            .unwrap_or_else(|panic| json!({"error": format!("row panic: {panic:?}")}));
        writeln!(out, "{}", report).expect("write stdout");
        out.flush().expect("flush stdout");
    }
}
