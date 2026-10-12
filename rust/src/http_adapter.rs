// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

use crate::network_effect::*;
use crate::request_progression::ExecutionHandle;
use std::collections::{HashMap, VecDeque};
use std::error::Error as StdError;
use std::io::{ErrorKind, Read};
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::Instant;

pub trait MonotonicClockPort: Send + Sync {
    fn capability(&self) -> MonotonicClockCapability;
    fn observe(&self) -> Result<MonotonicClockObservation, HostFailure>;
}

pub trait CancellationPort: Send + Sync {
    fn capability(&self) -> CancellationCapability;
    fn request(
        &self,
        capability: &CancellationCapability,
        handle: &ExecutionHandle,
    ) -> Result<(), HostFailure>;
}

pub struct SystemMonotonicClock {
    capability: MonotonicClockCapability,
    origin: Instant,
}

impl SystemMonotonicClock {
    pub fn new(clock_basis: ClockBasis) -> Self {
        Self {
            capability: MonotonicClockCapability {
                identity: OpaqueEvidence {
                    value: "rust-system-monotonic-clock".to_owned(),
                },
                clock_basis,
            },
            origin: Instant::now(),
        }
    }

    pub fn with_capability(capability: MonotonicClockCapability) -> Self {
        Self {
            capability,
            origin: Instant::now(),
        }
    }
}

impl MonotonicClockPort for SystemMonotonicClock {
    fn capability(&self) -> MonotonicClockCapability {
        self.capability.clone()
    }

    fn observe(&self) -> Result<MonotonicClockObservation, HostFailure> {
        Ok(MonotonicClockObservation {
            clock_basis: self.capability.clock_basis.clone(),
            value: Natural::from(self.origin.elapsed().as_millis()),
        })
    }
}

#[derive(Clone)]
pub struct CooperativeCancellation {
    capability: CancellationCapability,
}

impl Default for CooperativeCancellation {
    fn default() -> Self {
        Self {
            capability: CancellationCapability {
                identity: OpaqueEvidence {
                    value: "rust-cooperative-cancellation".to_owned(),
                },
            },
        }
    }
}

impl CooperativeCancellation {
    pub fn new(capability: CancellationCapability) -> Self {
        Self { capability }
    }
}

impl CancellationPort for CooperativeCancellation {
    fn capability(&self) -> CancellationCapability {
        self.capability.clone()
    }

    fn request(
        &self,
        capability: &CancellationCapability,
        _handle: &ExecutionHandle,
    ) -> Result<(), HostFailure> {
        if capability == &self.capability {
            Ok(())
        } else {
            Err(HostFailure::CancellationRejected)
        }
    }
}

struct Execution {
    input: AttemptInput,
    handle: ExecutionHandle,
    queue: Mutex<VecDeque<AdapterObservation>>,
    delivery: AtomicU64,
    deadline_emitted: AtomicBool,
}

impl Execution {
    fn pending(&self) -> HostObservation {
        HostObservation::Pending {
            attempt: self.input.attempt.clone(),
            handle: self.handle.clone(),
        }
    }

    fn push(&self, observation: AdapterObservation) {
        if let Ok(mut queue) = self.queue.lock() {
            queue.push_back(observation);
        }
    }

    fn poll(&self) -> HostObservation {
        let observation = self
            .queue
            .lock()
            .ok()
            .and_then(|mut queue| queue.pop_front());
        match observation {
            Some(observation) => HostObservation::Delivered {
                delivery: self.delivery.fetch_add(1, Ordering::Relaxed).into(),
                observation,
            },
            None => self.pending(),
        }
    }
}

pub struct UreqHttpAdapter<C = SystemMonotonicClock, X = CooperativeCancellation> {
    clock: Arc<C>,
    cancellation: Arc<X>,
    executions: Arc<Mutex<HashMap<String, Arc<Execution>>>>,
    next_handle: AtomicU64,
}

impl Default for UreqHttpAdapter<SystemMonotonicClock, CooperativeCancellation> {
    fn default() -> Self {
        Self::new(
            SystemMonotonicClock::new(ClockBasis {
                value: "rust-system-monotonic".to_owned(),
            }),
            CooperativeCancellation::default(),
        )
    }
}

impl<C: MonotonicClockPort + 'static, X: CancellationPort + 'static> UreqHttpAdapter<C, X> {
    pub fn new(clock: C, cancellation: X) -> Self {
        Self {
            clock: Arc::new(clock),
            cancellation: Arc::new(cancellation),
            executions: Arc::new(Mutex::new(HashMap::new())),
            next_handle: AtomicU64::new(1),
        }
    }

    pub fn start(&self, command: SendCommand) -> StartObservation {
        let input = command.prepared.input;
        if let Some(cause) = self.start_validation_failure(&input) {
            return start_failed(input, cause);
        }

        let handle = ExecutionHandle {
            value: format!(
                "rust-network-{}",
                self.next_handle.fetch_add(1, Ordering::Relaxed)
            ),
        };
        let execution = Arc::new(Execution {
            input: input.clone(),
            handle: handle.clone(),
            queue: Mutex::new(VecDeque::new()),
            delivery: AtomicU64::new(0),
            deadline_emitted: AtomicBool::new(false),
        });
        if let Ok(mut executions) = self.executions.lock() {
            executions.insert(handle.value.clone(), Arc::clone(&execution));
        } else {
            return start_failed(input, HostFailure::ExecutionStartFailed);
        }

        let clock = Arc::clone(&self.clock);
        let worker_execution = Arc::clone(&execution);
        let spawn = thread::Builder::new()
            .name(handle.value.clone())
            .spawn(move || {
                let observation = catch_unwind(AssertUnwindSafe(|| {
                    initial_deadline_observation(&worker_execution, clock.as_ref()).unwrap_or_else(
                        || request_observation(&worker_execution.input, &worker_execution.handle),
                    )
                }))
                .unwrap_or_else(|_| {
                    failure_observation(
                        &worker_execution.input,
                        &worker_execution.handle,
                        HostStage::ResponseHeaders,
                        HostFailure::HostRuntimeFailure,
                    )
                });
                worker_execution.push(observation);
            });

        if spawn.is_err() {
            if let Ok(mut executions) = self.executions.lock() {
                executions.remove(&handle.value);
            }
            return start_failed(input, HostFailure::ExecutionStartFailed);
        }

        StartObservation::Started {
            attempt: execution.input.attempt.clone(),
            handle,
        }
    }

    pub fn observe(&self, started: &StartedAttempt) -> HostObservation {
        let Some(execution) = self.execution(&started.handle) else {
            return HostObservation::Pending {
                attempt: started.prepared.input.attempt.clone(),
                handle: started.handle.clone(),
            };
        };
        let first = execution.poll();
        if matches!(first, HostObservation::Delivered { .. }) {
            return first;
        }
        self.enqueue_deadline_if_reached(&execution);
        execution.poll()
    }

    pub fn cancel(&self, command: CancelCommand) -> HostObservation {
        let Some(execution) = self.execution(&command.handle) else {
            return HostObservation::Pending {
                attempt: command.attempt,
                handle: command.handle,
            };
        };

        let observation = match self
            .cancellation
            .request(&command.capability, &command.handle)
        {
            Ok(()) => AdapterObservation::CancellationObservation {
                attempt: command.attempt,
                handle: command.handle,
                source_sequence: None,
                effect: EffectStatus::Unknown {
                    reason: UnknownEffectReason::Cancellation,
                },
            },
            Err(cause) => failure_observation(
                &execution.input,
                &execution.handle,
                stage_for_cause(HostStage::Cancel, &cause),
                cause,
            ),
        };
        execution.push(observation);
        execution.poll()
    }

    pub fn close(&self, started: &StartedAttempt) -> HostObservation {
        let Some(execution) = self.execution(&started.handle) else {
            return HostObservation::Pending {
                attempt: started.prepared.input.attempt.clone(),
                handle: started.handle.clone(),
            };
        };
        execution.push(failure_observation(
            &execution.input,
            &execution.handle,
            HostStage::ResponseHeaders,
            HostFailure::HostClosed,
        ));
        execution.poll()
    }

    pub fn observe_start(&self, command: SendCommand) -> StartObservation {
        self.start(command)
    }

    fn execution(&self, handle: &ExecutionHandle) -> Option<Arc<Execution>> {
        self.executions
            .lock()
            .ok()
            .and_then(|executions| executions.get(&handle.value).cloned())
    }

    fn start_validation_failure(&self, input: &AttemptInput) -> Option<HostFailure> {
        let scheme = input
            .instruction
            .target
            .split(':')
            .next()
            .unwrap_or_default();
        if scheme != "http" && scheme != "https" {
            return Some(HostFailure::UnsupportedUriScheme);
        }
        if !valid_attempt_input(input) {
            return Some(HostFailure::InvalidHostConfiguration);
        }
        if let Some(deadline) = &input.deadline {
            if input.configuration.monotonic_clock.as_ref() != Some(&deadline.capability)
                || self.clock.capability() != deadline.capability
            {
                return Some(HostFailure::DeadlineControlUnavailable);
            }
        }
        if let Some(capability) = &input.configuration.cancellation {
            if self.cancellation.capability() != *capability {
                return Some(HostFailure::InvalidHostConfiguration);
            }
        }
        None
    }

    fn enqueue_deadline_if_reached(&self, execution: &Execution) {
        let Some(deadline) = &execution.input.deadline else {
            return;
        };
        if execution.deadline_emitted.load(Ordering::Acquire) {
            return;
        }
        let observation = match self.clock.observe() {
            Ok(observed_at) if clock_reaches(deadline, &observed_at) => {
                Some(AdapterObservation::DeadlineObservation {
                    attempt: execution.input.attempt.clone(),
                    handle: execution.handle.clone(),
                    source_sequence: None,
                    deadline: deadline.clone(),
                    observed_at,
                    effect: EffectStatus::Unknown {
                        reason: UnknownEffectReason::Deadline,
                    },
                })
            }
            Ok(_) => None,
            Err(cause) => Some(failure_observation(
                &execution.input,
                &execution.handle,
                stage_for_cause(HostStage::Deadline, &cause),
                cause,
            )),
        };
        if let Some(observation) = observation {
            if !execution.deadline_emitted.swap(true, Ordering::AcqRel) {
                execution.push(observation);
            }
        }
    }
}

fn start_failed(input: AttemptInput, cause: HostFailure) -> StartObservation {
    StartObservation::StartFailed {
        failure: NetworkHostFailure {
            attempt: input.attempt.clone(),
            stage: HostStage::Start,
            configuration: input.configuration,
            cause,
        },
        effect: EffectStatus::Unknown {
            reason: UnknownEffectReason::HostFailure,
        },
    }
}

fn initial_deadline_observation<C: MonotonicClockPort>(
    execution: &Execution,
    clock: &C,
) -> Option<AdapterObservation> {
    let deadline = execution.input.deadline.as_ref()?;
    match clock.observe() {
        Ok(observed_at) if clock_reaches(deadline, &observed_at) => {
            execution.deadline_emitted.store(true, Ordering::Release);
            Some(AdapterObservation::DeadlineObservation {
                attempt: execution.input.attempt.clone(),
                handle: execution.handle.clone(),
                source_sequence: None,
                deadline: deadline.clone(),
                observed_at,
                effect: EffectStatus::Unknown {
                    reason: UnknownEffectReason::Deadline,
                },
            })
        }
        Ok(_) => None,
        Err(cause) => {
            execution.deadline_emitted.store(true, Ordering::Release);
            Some(failure_observation(
                &execution.input,
                &execution.handle,
                stage_for_cause(HostStage::Deadline, &cause),
                cause,
            ))
        }
    }
}

fn request_observation(input: &AttemptInput, handle: &ExecutionHandle) -> AdapterObservation {
    match perform_request(input) {
        Ok((response, provenance)) => AdapterObservation::ResponseObservation {
            attempt: input.attempt.clone(),
            handle: handle.clone(),
            source_sequence: None,
            response,
            provenance,
            effect: EffectStatus::Unknown {
                reason: UnknownEffectReason::ProtocolWitnessMissing,
            },
        },
        Err((stage, cause)) => failure_observation(input, handle, stage, cause),
    }
}

fn failure_observation(
    input: &AttemptInput,
    handle: &ExecutionHandle,
    stage: HostStage,
    cause: HostFailure,
) -> AdapterObservation {
    AdapterObservation::FailureObservation {
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
    }
}

fn stage_for_cause(default: HostStage, cause: &HostFailure) -> HostStage {
    match cause {
        HostFailure::Timeout { stage, .. } => *stage,
        _ => default,
    }
}

fn perform_request(
    input: &AttemptInput,
) -> Result<(RawHttpResponse, HeaderProvenance), (HostStage, HostFailure)> {
    let body: Vec<u8> = input
        .instruction
        .body
        .iter()
        .map(|value| value.to_u8().ok_or(()))
        .collect::<Result<_, _>>()
        .map_err(|_| (HostStage::RequestWrite, HostFailure::RequestWriteFailed))?;

    let agent = ureq::AgentBuilder::new().redirects(0).build();
    let mut request = agent.request(&input.instruction.method, &input.instruction.target);
    for field in &input.instruction.headers {
        let bytes: Vec<u8> = field
            .value
            .iter()
            .map(|value| value.to_u8().ok_or(()))
            .collect::<Result<_, _>>()
            .map_err(|_| {
                (
                    HostStage::RequestWrite,
                    HostFailure::RequestHeaderEncodingUnavailable,
                )
            })?;
        let value = String::from_utf8(bytes).map_err(|_| {
            (
                HostStage::RequestWrite,
                HostFailure::RequestHeaderEncodingUnavailable,
            )
        })?;
        request = request.set(&field.name, &value);
    }

    let result = if body.is_empty() {
        request.call()
    } else {
        request.send_bytes(&body)
    };
    let response = match result {
        Ok(response) => response,
        Err(ureq::Error::Status(_, response)) => response,
        Err(ureq::Error::Transport(transport)) => {
            return Err(classify_transport(&transport));
        }
    };

    let status = Natural::from(response.status());
    let mut headers = Vec::new();
    let mut occurrences: HashMap<String, usize> = HashMap::new();
    for name in response.headers_names() {
        let occurrence = occurrences.entry(name.clone()).or_insert(0);
        let values = response.all(&name);
        let Some(value) = values.get(*occurrence) else {
            return Err((
                HostStage::ResponseHeaders,
                HostFailure::HeaderRepresentationUnavailable,
            ));
        };
        *occurrence += 1;
        headers.push(RawHeaderField {
            name,
            value: value
                .as_bytes()
                .iter()
                .map(|byte| Natural::from(*byte))
                .collect(),
        });
    }
    let read_limit = input
        .configuration
        .response_body_limit
        .to_u64()
        .map_or(u64::MAX, |limit| limit.saturating_add(1));
    let mut body = Vec::new();
    response
        .into_reader()
        .take(read_limit)
        .read_to_end(&mut body)
        .map_err(|error| {
            let cause = if matches!(error.kind(), ErrorKind::TimedOut | ErrorKind::WouldBlock) {
                HostFailure::Timeout {
                    stage: HostStage::ResponseBody,
                    cause: HostTimeoutCause::SocketReported,
                }
            } else {
                HostFailure::ResponseBodyFailed
            };
            (HostStage::ResponseBody, cause)
        })?;
    if Natural::from(body.len()) > input.configuration.response_body_limit {
        return Err((
            HostStage::ResponseBody,
            HostFailure::ResponseBodyLimitExceeded,
        ));
    }

    Ok((
        RawHttpResponse {
            status,
            headers,
            body: body.into_iter().map(Natural::from).collect(),
        },
        HeaderProvenance::LibraryObserved,
    ))
}

fn classify_transport(transport: &ureq::Transport) -> (HostStage, HostFailure) {
    use ureq::ErrorKind;

    match transport.kind() {
        ErrorKind::InvalidUrl | ErrorKind::UnknownScheme => {
            (HostStage::Start, HostFailure::UnsupportedUriScheme)
        }
        ErrorKind::InsecureRequestHttpsOnly | ErrorKind::InvalidProxyUrl => {
            (HostStage::Start, HostFailure::InvalidHostConfiguration)
        }
        ErrorKind::Dns => (HostStage::Start, HostFailure::NameResolutionFailed),
        ErrorKind::ConnectionFailed | ErrorKind::ProxyConnect | ErrorKind::ProxyUnauthorized => {
            (HostStage::Start, HostFailure::ConnectionFailed)
        }
        ErrorKind::BadStatus | ErrorKind::BadHeader => {
            (HostStage::ResponseHeaders, HostFailure::MalformedResponse)
        }
        ErrorKind::Io => classify_io_transport(transport),
        ErrorKind::TooManyRedirects | ErrorKind::HTTP => {
            (HostStage::ResponseHeaders, HostFailure::HostRuntimeFailure)
        }
    }
}

fn classify_io_transport(transport: &ureq::Transport) -> (HostStage, HostFailure) {
    let kind = StdError::source(transport)
        .and_then(|source| source.downcast_ref::<std::io::Error>())
        .map(std::io::Error::kind);
    match kind {
        Some(ErrorKind::TimedOut | ErrorKind::WouldBlock) => (
            HostStage::ResponseHeaders,
            HostFailure::Timeout {
                stage: HostStage::ResponseHeaders,
                cause: HostTimeoutCause::SocketReported,
            },
        ),
        Some(ErrorKind::ConnectionRefused | ErrorKind::NotConnected) => {
            (HostStage::Start, HostFailure::ConnectionFailed)
        }
        Some(ErrorKind::BrokenPipe | ErrorKind::WriteZero) => {
            (HostStage::RequestWrite, HostFailure::RequestWriteFailed)
        }
        Some(
            ErrorKind::ConnectionAborted | ErrorKind::ConnectionReset | ErrorKind::UnexpectedEof,
        ) => (
            HostStage::ResponseHeaders,
            HostFailure::ResponseHeadersFailed,
        ),
        Some(ErrorKind::InvalidData) => {
            (HostStage::ResponseHeaders, HostFailure::MalformedResponse)
        }
        _ => (HostStage::ResponseHeaders, HostFailure::HostRuntimeFailure),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::request_progression::RequestIdentity;

    enum TestHostFault {
        ResolverFailure,
        PartialWriteFailure,
        HeaderCodecFailure,
        LibraryTimeout(HostStage, HostTimeoutCause),
        BootstrapFailure,
        WorkerFailure,
    }

    fn input() -> AttemptInput {
        AttemptInput {
            attempt: AttemptIdentity {
                logical: RequestIdentity {
                    kind: "adapter-test".to_owned(),
                    provenance: "runtime".to_owned(),
                    revision: 0u8.into(),
                },
                ordinal: 0u8.into(),
            },
            instruction: HttpWireInstruction {
                method: "GET".to_owned(),
                target: "http://127.0.0.1/".to_owned(),
                headers: Vec::new(),
                body: Vec::new(),
            },
            deadline: None,
            configuration: HostConfiguration {
                request_body_limit: 0u8.into(),
                response_body_limit: 16u8.into(),
                cancellation: None,
                monotonic_clock: None,
            },
        }
    }

    fn issued_input() -> Result<AttemptInput, &'static str> {
        let input = input();
        let PrepareStep::Prepared(state, prepared) =
            prepare(NetworkState::default(), input.clone())
        else {
            return Err("prepare");
        };
        assert_eq!(state.attempts.len(), 1);
        let CommandStep::CommandReady(_, command) = send_command(state, prepared) else {
            return Err("send command");
        };
        assert_eq!(command.prepared.input, input);
        let issued_command_count = 1usize;
        let peer_received_count = 0usize;
        assert!(peer_received_count <= issued_command_count);
        Ok(input)
    }

    fn classify_test_fault(fault: TestHostFault) -> (HostStage, HostFailure) {
        match fault {
            TestHostFault::ResolverFailure => (HostStage::Start, HostFailure::NameResolutionFailed),
            TestHostFault::PartialWriteFailure => {
                (HostStage::RequestWrite, HostFailure::RequestWriteFailed)
            }
            TestHostFault::HeaderCodecFailure => (
                HostStage::ResponseHeaders,
                HostFailure::HeaderRepresentationUnavailable,
            ),
            TestHostFault::LibraryTimeout(stage, cause) => {
                (stage, HostFailure::Timeout { stage, cause })
            }
            TestHostFault::BootstrapFailure => {
                (HostStage::Start, HostFailure::ExecutionStartFailed)
            }
            TestHostFault::WorkerFailure => {
                (HostStage::ResponseHeaders, HostFailure::HostRuntimeFailure)
            }
        }
    }

    #[test]
    fn test_only_fault_sources_map_to_closed_failures() -> Result<(), &'static str> {
        let cases = [
            (
                TestHostFault::ResolverFailure,
                HostStage::Start,
                HostFailure::NameResolutionFailed,
            ),
            (
                TestHostFault::PartialWriteFailure,
                HostStage::RequestWrite,
                HostFailure::RequestWriteFailed,
            ),
            (
                TestHostFault::HeaderCodecFailure,
                HostStage::ResponseHeaders,
                HostFailure::HeaderRepresentationUnavailable,
            ),
            (
                TestHostFault::WorkerFailure,
                HostStage::ResponseHeaders,
                HostFailure::HostRuntimeFailure,
            ),
        ];
        for (stimulus, expected_stage, expected_cause) in cases {
            let (stage, cause) = classify_test_fault(stimulus);
            let input = issued_input()?;
            let observation = failure_observation(
                &input,
                &ExecutionHandle {
                    value: "test-handle".to_owned(),
                },
                stage,
                cause,
            );
            assert!(matches!(
                observation,
                AdapterObservation::FailureObservation {
                    failure: NetworkHostFailure {
                        stage,
                        cause,
                        ..
                    },
                    effect: EffectStatus::Unknown {
                        reason: UnknownEffectReason::HostFailure
                    },
                    ..
                } if stage == expected_stage && cause == expected_cause
            ));
        }
        let input = issued_input()?;
        let (_, cause) = classify_test_fault(TestHostFault::BootstrapFailure);
        assert!(matches!(
            start_failed(input, cause),
            StartObservation::StartFailed {
                failure: NetworkHostFailure {
                    stage: HostStage::Start,
                    cause: HostFailure::ExecutionStartFailed,
                    ..
                },
                effect: EffectStatus::Unknown {
                    reason: UnknownEffectReason::HostFailure
                }
            }
        ));
        Ok(())
    }

    #[test]
    fn test_timeout_source_preserves_all_stage_cause_pairs() -> Result<(), &'static str> {
        let stages = [
            HostStage::Start,
            HostStage::RequestWrite,
            HostStage::ResponseHeaders,
            HostStage::ResponseBody,
            HostStage::Cancel,
            HostStage::Deadline,
        ];
        let causes = [
            HostTimeoutCause::LibraryReported,
            HostTimeoutCause::SocketReported,
            HostTimeoutCause::PoolAcquisition,
            HostTimeoutCause::HostOperation,
        ];
        let mut observed = 0usize;
        for stage in stages {
            for cause in causes {
                let (outer, failure) =
                    classify_test_fault(TestHostFault::LibraryTimeout(stage, cause));
                assert_eq!(outer, stage);
                assert_eq!(failure, HostFailure::Timeout { stage, cause });
                let input = issued_input()?;
                let observation = failure_observation(
                    &input,
                    &ExecutionHandle {
                        value: "timeout-handle".to_owned(),
                    },
                    outer,
                    failure,
                );
                assert!(matches!(
                    observation,
                    AdapterObservation::FailureObservation {
                        failure: NetworkHostFailure {
                            stage: outer_stage,
                            cause: HostFailure::Timeout {
                                stage: inner_stage,
                                cause: observed_cause
                            },
                            ..
                        },
                        ..
                    } if outer_stage == stage && inner_stage == stage && observed_cause == cause
                ));
                observed += 1;
            }
        }
        assert_eq!(observed, 24);
        Ok(())
    }
}
