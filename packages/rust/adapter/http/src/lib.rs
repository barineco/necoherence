// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

use necoherence::network_effect::*;
use necoherence::request_progression::ExecutionHandle;
use necoherence::semantic_execution::{
    resume, ExecutionObservation, ExecutionResult, NetworkInstruction, Progress, RunFailure,
};
use necoherence::ErasureDecision;
use std::cell::Cell;
use std::collections::{HashMap, VecDeque};
use std::io::{ErrorKind, Read};
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::sync::atomic::{AtomicBool, AtomicU64, AtomicU8, Ordering};
use std::sync::{mpsc, Arc, Condvar, Mutex};
use std::thread;
use std::time::{Duration, Instant};
use ureq::unversioned::resolver::{DefaultResolver, Resolver};
use ureq::unversioned::transport::{ConnectProxyConnector, Connector, RustlsConnector};

pub trait MonotonicClockPort: Send + Sync {
    fn capability(&self) -> MonotonicClockCapability;
    fn observe(&self) -> Result<MonotonicClockObservation, HostFailure>;
    fn until(&self, _limit: &Natural) -> Option<Duration> {
        None
    }
}

pub trait CancellationPort: Send + Sync {
    fn capability(&self) -> CancellationCapability;
    fn request(&self, handle: &ExecutionHandle) -> Result<(), HostFailure>;
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

    fn until(&self, limit: &Natural) -> Option<Duration> {
        let now = u64::try_from(self.origin.elapsed().as_millis()).unwrap_or(u64::MAX);
        let limit = limit.to_u64().unwrap_or(u64::MAX);
        Some(Duration::from_millis(limit.saturating_sub(now)))
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

    fn request(&self, _handle: &ExecutionHandle) -> Result<(), HostFailure> {
        Ok(())
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[repr(u8)]
enum Lifecycle {
    Running,
    RunningSettled,
    Finished,
    Released,
}

impl Lifecycle {
    fn from_raw(raw: u8) -> Self {
        match raw {
            0 => Self::Running,
            1 => Self::RunningSettled,
            2 => Self::Finished,
            _ => Self::Released,
        }
    }
}

struct Execution {
    input: AttemptInput,
    handle: ExecutionHandle,
    queue: Mutex<VecDeque<AdapterObservation>>,
    delivery: AtomicU64,
    deadline_emitted: AtomicBool,
    lifecycle: AtomicU8,
    gate: Mutex<()>,
    changed: Condvar,
    interrupt: Arc<interrupt::Interrupt>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct UnknownExecution {
    pub handle: ExecutionHandle,
}

impl std::fmt::Display for UnknownExecution {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(formatter, "unknown execution {}", self.handle.value)
    }
}

impl std::error::Error for UnknownExecution {}

type Registry = Arc<Mutex<HashMap<String, Arc<Execution>>>>;

struct RunningGuard(Arc<Execution>, Registry);

impl Drop for RunningGuard {
    fn drop(&mut self) {
        if self.0.finish() {
            self.0.detach(&self.1);
        }
        self.0.notify();
    }
}

impl Execution {
    fn lifecycle(&self) -> Lifecycle {
        Lifecycle::from_raw(self.lifecycle.load(Ordering::SeqCst))
    }

    fn transition(&self, next: impl Fn(Lifecycle) -> Option<Lifecycle>) -> Option<Lifecycle> {
        self.lifecycle
            .fetch_update(Ordering::SeqCst, Ordering::SeqCst, |raw| {
                next(Lifecycle::from_raw(raw)).map(|state| state as u8)
            })
            .ok()
            .map(Lifecycle::from_raw)
    }

    fn is_running(&self) -> bool {
        matches!(
            self.lifecycle(),
            Lifecycle::Running | Lifecycle::RunningSettled
        )
    }

    fn is_released(&self) -> bool {
        self.lifecycle() == Lifecycle::Released
    }

    fn finish(&self) -> bool {
        let previous = self.transition(|state| match state {
            Lifecycle::Running => Some(Lifecycle::Finished),
            Lifecycle::RunningSettled => Some(Lifecycle::Released),
            Lifecycle::Finished | Lifecycle::Released => None,
        });
        previous == Some(Lifecycle::RunningSettled)
    }

    fn settle(&self) -> bool {
        let previous = self.transition(|state| match state {
            Lifecycle::Running => Some(Lifecycle::RunningSettled),
            Lifecycle::Finished => Some(Lifecycle::Released),
            Lifecycle::RunningSettled | Lifecycle::Released => None,
        });
        previous == Some(Lifecycle::Finished)
    }

    fn discard(&self) -> bool {
        self.transition(|state| match state {
            Lifecycle::Released => None,
            _ => Some(Lifecycle::Released),
        })
        .is_some()
    }

    fn detach(&self, registry: &Registry) {
        if let Ok(mut executions) = registry.lock() {
            executions.remove(self.handle.value.as_ref());
        }
        self.notify();
    }

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
        self.notify();
    }

    fn push_unless_interrupted(&self, observation: AdapterObservation) {
        self.interrupt.unless_stopped(|| self.push(observation));
    }

    fn push_then_interrupt(&self, observation: AdapterObservation) {
        self.interrupt.stop_after(|| self.push(observation));
    }

    fn notify(&self) {
        drop(self.gate.lock());
        self.changed.notify_all();
    }

    fn has_queued(&self) -> bool {
        self.queue.lock().map_or(true, |queue| !queue.is_empty())
    }

    fn wait_until(&self, ready: impl Fn(&Self) -> bool) {
        let Ok(mut guard) = self.gate.lock() else {
            return;
        };
        while !ready(self) {
            guard = match self.changed.wait(guard) {
                Ok(guard) => guard,
                Err(_) => return,
            };
        }
    }

    fn wait_until_for(&self, ready: impl Fn(&Self) -> bool, limit: Duration) {
        let Ok(guard) = self.gate.lock() else {
            return;
        };
        let _ = self
            .changed
            .wait_timeout_while(guard, limit, |_| !ready(self));
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

type Job = Box<dyn FnOnce() + Send + 'static>;

struct WorkerPool {
    sender: mpsc::Sender<Job>,
}

impl WorkerPool {
    fn new(size: usize) -> std::io::Result<Self> {
        let (sender, receiver) = mpsc::channel::<Job>();
        let receiver = Arc::new(Mutex::new(receiver));
        for index in 0..size {
            let receiver = Arc::clone(&receiver);
            thread::Builder::new()
                .name(format!("rust-network-worker-{index}"))
                .spawn(move || loop {
                    let next = match receiver.lock() {
                        Ok(guard) => guard.recv(),
                        Err(_) => return,
                    };
                    match next {
                        Ok(job) => {
                            let _ = catch_unwind(AssertUnwindSafe(job));
                        }
                        Err(_) => return,
                    }
                })?;
        }
        Ok(Self { sender })
    }

    fn submit(&self, job: Job) -> bool {
        self.sender.send(job).is_ok()
    }
}

fn worker_limit() -> usize {
    thread::available_parallelism().map_or(1, std::num::NonZero::get)
}

pub struct UreqHttpAdapter<C = SystemMonotonicClock, X = CooperativeCancellation> {
    clock: Arc<C>,
    cancellation: Arc<X>,
    executions: Registry,
    next_handle: AtomicU64,
    agent: ureq::Agent,
    pool: Option<WorkerPool>,
    #[cfg(test)]
    blocking: Arc<interrupt::BlockingPool>,
    #[cfg(test)]
    observe_calls: AtomicU64,
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
        Self::assemble(clock, cancellation, |blocking| {
            let tcp = interrupt::InterruptibleTcp::new(Arc::clone(&blocking));
            build_agent(DefaultResolver::default(), blocking, tcp)
        })
    }

    #[cfg(test)]
    fn with_resolver(clock: C, cancellation: X, resolver: impl Resolver) -> Self {
        Self::assemble(clock, cancellation, |blocking| {
            let tcp = interrupt::InterruptibleTcp::new(Arc::clone(&blocking));
            build_agent(resolver, blocking, tcp)
        })
    }

    #[cfg(test)]
    fn with_connect(
        clock: C,
        cancellation: X,
        resolver: impl Resolver,
        connect: impl Fn(std::net::SocketAddr) -> std::io::Result<std::net::TcpStream>
            + Send
            + Sync
            + 'static,
    ) -> Self {
        Self::assemble(clock, cancellation, |blocking| {
            let tcp = interrupt::InterruptibleTcp::new(Arc::clone(&blocking)).dialing(connect);
            build_agent(resolver, blocking, tcp)
        })
    }

    fn assemble(
        clock: C,
        cancellation: X,
        make_agent: impl FnOnce(Arc<interrupt::BlockingPool>) -> ureq::Agent,
    ) -> Self {
        let blocking = Arc::new(interrupt::BlockingPool::new(worker_limit()));
        let agent = make_agent(Arc::clone(&blocking));
        Self {
            clock: Arc::new(clock),
            cancellation: Arc::new(cancellation),
            executions: Arc::new(Mutex::new(HashMap::new())),
            next_handle: AtomicU64::new(1),
            agent,
            pool: WorkerPool::new(worker_limit()).ok(),
            #[cfg(test)]
            blocking,
            #[cfg(test)]
            observe_calls: AtomicU64::new(0),
        }
    }

    pub fn start(&self, command: SendCommand) -> StartObservation {
        let input = Arc::unwrap_or_clone(command.prepared.input);
        if let Some(cause) = self.start_validation_failure(&input) {
            return start_failed(input, cause);
        }

        let handle = ExecutionHandle {
            value: format!(
                "rust-network-{}",
                self.next_handle.fetch_add(1, Ordering::Relaxed)
            )
            .into(),
        };
        let execution = Arc::new(Execution {
            input: input.clone(),
            handle: handle.clone(),
            queue: Mutex::new(VecDeque::new()),
            delivery: AtomicU64::new(0),
            deadline_emitted: AtomicBool::new(false),
            lifecycle: AtomicU8::new(Lifecycle::Running as u8),
            gate: Mutex::new(()),
            changed: Condvar::new(),
            interrupt: interrupt::Interrupt::new(),
        });
        if let Ok(mut executions) = self.executions.lock() {
            executions.insert(handle.value.to_string(), Arc::clone(&execution));
        } else {
            return start_failed(input, HostFailure::ExecutionStartFailed);
        }

        let clock = Arc::clone(&self.clock);
        let agent = self.agent.clone();
        let running_guard = RunningGuard(Arc::clone(&execution), Arc::clone(&self.executions));
        let job: Job = Box::new(move || {
            let worker_execution = Arc::clone(&running_guard.0);
            let scope = interrupt::Scope::enter(&worker_execution.interrupt);
            let stage = Cell::new(HostStage::RequestWrite);
            let (observation, from_deadline) = catch_unwind(AssertUnwindSafe(|| {
                match initial_deadline_observation(&worker_execution, clock.as_ref()) {
                    Some(observation) => (observation, true),
                    None => (
                        request_observation(
                            &worker_execution.input,
                            &worker_execution.handle,
                            &agent,
                            &stage,
                        ),
                        false,
                    ),
                }
            }))
            .unwrap_or_else(|_| {
                (
                    failure_observation(
                        &worker_execution.input,
                        &worker_execution.handle,
                        stage.get(),
                        HostFailure::HostRuntimeFailure,
                    ),
                    false,
                )
            });
            if !from_deadline {
                worker_execution.push_unless_interrupted(observation);
            } else if !worker_execution
                .deadline_emitted
                .swap(true, Ordering::AcqRel)
            {
                worker_execution.push_then_interrupt(observation);
            }
            drop(scope);
            drop(worker_execution);
            drop(running_guard);
        });

        if !self.pool.as_ref().is_some_and(|pool| pool.submit(job)) {
            if let Ok(mut executions) = self.executions.lock() {
                executions.remove(handle.value.as_ref());
            }
            return start_failed(input, HostFailure::ExecutionStartFailed);
        }

        StartObservation::Started {
            attempt: execution.input.attempt.clone(),
            handle,
        }
    }

    pub fn observe(&self, started: &StartedAttempt) -> Result<HostObservation, UnknownExecution> {
        #[cfg(test)]
        self.observe_calls.fetch_add(1, Ordering::Relaxed);
        let Some(execution) = self.execution(&started.handle) else {
            return Err(UnknownExecution {
                handle: started.handle.clone(),
            });
        };
        let first = execution.poll();
        if matches!(first, HostObservation::Delivered { .. }) {
            return Ok(first);
        }
        self.enqueue_deadline_if_reached(&execution);
        Ok(execution.poll())
    }

    pub fn cancel(&self, command: CancelCommand) -> Result<HostObservation, UnknownExecution> {
        let Some(execution) = self.execution(&command.handle) else {
            return Err(UnknownExecution {
                handle: command.handle,
            });
        };

        let requested = match port_call(|| Ok(self.cancellation.capability())) {
            Ok(capability) if command.capability == capability => {
                port_call(|| self.cancellation.request(&command.handle))
            }
            Ok(_) => Err(HostFailure::CancellationRejected),
            Err(cause) => Err(cause),
        };
        match requested {
            Ok(()) => execution.push_then_interrupt(AdapterObservation::CancellationObservation {
                attempt: command.attempt,
                handle: command.handle,
                source_sequence: None,
                effect: EffectStatus::Unknown {
                    reason: UnknownEffectReason::Cancellation,
                },
            }),
            Err(cause) => execution.push_then_interrupt(failure_observation(
                &execution.input,
                &execution.handle,
                stage_for_cause(HostStage::Cancel, &cause),
                cause,
            )),
        }
        Ok(execution.poll())
    }

    pub fn close(&self, started: &StartedAttempt) -> Result<HostObservation, UnknownExecution> {
        let Some(execution) = self.execution(&started.handle) else {
            return Err(UnknownExecution {
                handle: started.handle.clone(),
            });
        };
        execution.push_then_interrupt(failure_observation(
            &execution.input,
            &execution.handle,
            HostStage::Cancel,
            HostFailure::HostClosed,
        ));
        Ok(execution.poll())
    }

    pub fn release(
        &self,
        state: &NetworkState,
        started: &StartedAttempt,
    ) -> ErasureDecision<AttemptIdentity, (), (), (), HostRecordObservation> {
        let attempt = &started.prepared.input.attempt;
        let execution = self.execution(&started.handle);
        let running = execution
            .as_ref()
            .is_some_and(|execution| execution.is_running());
        let decision = release_host_record(state, |_| running, attempt);
        match &decision {
            ErasureDecision::Dematerialize(_) => {
                if let Some(execution) = execution {
                    if execution.discard() {
                        execution.detach(&self.executions);
                    }
                }
            }
            ErasureDecision::Retain(_) if host_settled(state, attempt) => {
                if let Some(execution) = execution {
                    if execution.settle() {
                        execution.detach(&self.executions);
                    }
                }
            }
            ErasureDecision::Retain(_) | ErasureDecision::Rejected(_) => {}
        }
        decision
    }

    fn wait_observation(&self, started: &StartedAttempt) -> Result<HostObservation, WaitFailure> {
        loop {
            let observation = self.observe(started).map_err(WaitFailure::Unknown)?;
            if matches!(observation, HostObservation::Delivered { .. }) {
                return Ok(observation);
            }
            let Some(execution) = self.execution(&started.handle) else {
                return Err(WaitFailure::Unknown(UnknownExecution {
                    handle: started.handle.clone(),
                }));
            };
            let ready = |execution: &Execution| execution.has_queued() || execution.is_released();
            match self.deadline_wait(&execution)? {
                Some(length) => execution.wait_until_for(ready, length),
                None => execution.wait_until(ready),
            }
        }
    }

    fn deadline_wait(&self, execution: &Execution) -> Result<Option<Duration>, WaitFailure> {
        let Some(deadline) = &execution.input.deadline else {
            return Ok(None);
        };
        if execution.deadline_emitted.load(Ordering::Acquire) {
            return Ok(None);
        }
        match catch_unwind(AssertUnwindSafe(|| self.clock.until(&deadline.limit))) {
            Ok(length) => length
                .map(|length| Some(length.max(Duration::from_millis(1))))
                .ok_or(WaitFailure::DeadlineWaitUnavailable),
            Err(_) => {
                if !execution.deadline_emitted.swap(true, Ordering::AcqRel) {
                    execution.push_then_interrupt(failure_observation(
                        &execution.input,
                        &execution.handle,
                        HostStage::Deadline,
                        HostFailure::HostRuntimeFailure,
                    ));
                }
                Ok(None)
            }
        }
    }

    fn sweep(&self, state: &NetworkState, candidates: &mut Vec<StartedAttempt>) {
        candidates.retain(|started| {
            !matches!(
                self.release(state, started),
                ErasureDecision::Dematerialize(_)
            )
        });
    }

    fn finish(&self, state: &NetworkState, candidates: Vec<StartedAttempt>) -> Vec<StartedAttempt> {
        let mut remaining = Vec::new();
        for started in candidates {
            match self.release(state, &started) {
                ErasureDecision::Dematerialize(_) => {}
                ErasureDecision::Retain(_)
                    if host_settled(state, &started.prepared.input.attempt) => {}
                _ => remaining.push(started),
            }
        }
        remaining
    }

    #[cfg(test)]
    fn record_count(&self) -> usize {
        self.executions
            .lock()
            .map_or(0, |executions| executions.len())
    }

    pub fn observe_start(&self, command: SendCommand) -> StartObservation {
        self.start(command)
    }

    fn execution(&self, handle: &ExecutionHandle) -> Option<Arc<Execution>> {
        self.executions
            .lock()
            .ok()
            .and_then(|executions| executions.get(handle.value.as_ref()).cloned())
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
            match port_call(|| Ok(self.clock.capability())) {
                Ok(capability) if capability == deadline.capability => {}
                Ok(_) => return Some(HostFailure::DeadlineControlUnavailable),
                Err(cause) => return Some(cause),
            }
        }
        if let Some(capability) = &input.configuration.cancellation {
            match port_call(|| Ok(self.cancellation.capability())) {
                Ok(port) if port == *capability => {}
                Ok(_) => return Some(HostFailure::InvalidHostConfiguration),
                Err(cause) => return Some(cause),
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
        let observation = match port_call(|| self.clock.observe()) {
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
                execution.push_then_interrupt(observation);
            }
        }
    }
}

enum WaitFailure {
    Unknown(UnknownExecution),
    DeadlineWaitUnavailable,
}

#[derive(Debug, PartialEq)]
pub struct Driven<'r> {
    pub result: ExecutionResult<'r>,
    pub retained: Vec<StartedAttempt>,
}

#[derive(Debug, PartialEq)]
pub enum DriveCause {
    Run(Box<RunFailure>),
    UnknownExecution(UnknownExecution),
    MissingInstruction,
    DeadlineWaitUnavailable,
}

#[derive(Debug, PartialEq)]
pub struct DriveFailure {
    pub cause: DriveCause,
    pub retained: Vec<StartedAttempt>,
}

pub fn drive<'r, 'g, C: MonotonicClockPort + 'static, X: CancellationPort + 'static>(
    adapter: &UreqHttpAdapter<C, X>,
    first: Progress<'r, 'g>,
) -> Result<Driven<'r>, DriveFailure> {
    let mut candidates: Vec<StartedAttempt> = Vec::new();
    let mut progress = first;
    loop {
        let (execution, instruction) = match progress {
            Progress::Completed(result, network) => {
                let retained = adapter.finish(&network, candidates);
                return Ok(Driven { result, retained });
            }
            Progress::Pending(execution, instruction) => (execution, instruction),
        };
        let (observation, handled) = match instruction {
            NetworkInstruction::Send => {
                let Some(command) = execution.send_command().cloned() else {
                    let retained = adapter.finish(execution.network_state(), candidates);
                    return Err(DriveFailure {
                        cause: DriveCause::MissingInstruction,
                        retained,
                    });
                };
                let prepared = command.prepared.clone();
                let start = adapter.start(command);
                let handled = match &start {
                    StartObservation::Started { handle, .. } => Some(StartedAttempt {
                        prepared,
                        handle: handle.clone(),
                    }),
                    _ => None,
                };
                (ExecutionObservation::Start(start), handled)
            }
            NetworkInstruction::Observe => {
                let Some(started) = execution.observed_attempt().cloned() else {
                    let retained = adapter.finish(execution.network_state(), candidates);
                    return Err(DriveFailure {
                        cause: DriveCause::MissingInstruction,
                        retained,
                    });
                };
                match adapter.wait_observation(&started) {
                    Ok(host) => (ExecutionObservation::Host(host), Some(started)),
                    Err(WaitFailure::Unknown(error)) => {
                        let retained = adapter.finish(execution.network_state(), candidates);
                        return Err(DriveFailure {
                            cause: DriveCause::UnknownExecution(error),
                            retained,
                        });
                    }
                    Err(WaitFailure::DeadlineWaitUnavailable) => {
                        let retained = adapter.finish(execution.network_state(), candidates);
                        return Err(DriveFailure {
                            cause: DriveCause::DeadlineWaitUnavailable,
                            retained,
                        });
                    }
                }
            }
        };
        progress = match resume(execution, observation) {
            Ok(next) => next,
            Err(failure) => {
                if let Some(started) = handled {
                    candidates.push(started);
                }
                let retained = adapter.finish(&failure.network, candidates);
                return Err(DriveFailure {
                    cause: DriveCause::Run(Box::new(failure)),
                    retained,
                });
            }
        };
        if let Some(started) = handled {
            if !candidates
                .iter()
                .any(|known| known.handle == started.handle)
            {
                candidates.push(started);
            }
        }
        let state = match &progress {
            Progress::Completed(_, network) => network,
            Progress::Pending(execution, _) => execution.network_state(),
        };
        adapter.sweep(state, &mut candidates);
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

fn port_call<T>(call: impl FnOnce() -> Result<T, HostFailure>) -> Result<T, HostFailure> {
    catch_unwind(AssertUnwindSafe(call)).unwrap_or(Err(HostFailure::HostRuntimeFailure))
}

fn initial_deadline_observation<C: MonotonicClockPort>(
    execution: &Execution,
    clock: &C,
) -> Option<AdapterObservation> {
    let deadline = execution.input.deadline.as_ref()?;
    match port_call(|| clock.observe()) {
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
    }
}

fn request_observation(
    input: &AttemptInput,
    handle: &ExecutionHandle,
    agent: &ureq::Agent,
    stage: &Cell<HostStage>,
) -> AdapterObservation {
    match perform_request(input, agent, stage) {
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

fn build_agent(
    resolver: impl Resolver,
    blocking: Arc<interrupt::BlockingPool>,
    tcp: interrupt::InterruptibleTcp,
) -> ureq::Agent {
    let config = ureq::Agent::config_builder()
        .tls_config(
            ureq::tls::TlsConfig::builder()
                .root_certs(ureq::tls::RootCerts::PlatformVerifier)
                .build(),
        )
        .max_redirects(0)
        .max_redirects_will_error(false)
        .http_status_as_error(false)
        .build();
    let connector =
        ().chain(ConnectProxyConnector::default())
            .chain(tcp)
            .chain(RustlsConnector::default());
    ureq::Agent::with_parts(
        config,
        connector,
        interrupt::InterruptibleResolver::new(resolver, blocking),
    )
}

fn perform_request(
    input: &AttemptInput,
    agent: &ureq::Agent,
    stage: &Cell<HostStage>,
) -> Result<(RawHttpResponse, HeaderProvenance), (HostStage, HostFailure)> {
    let body: &[u8] = &input.instruction.body;

    let mut headers = Vec::new();
    let mut host_seen = false;
    let mut content_length_seen = false;
    for field in &input.instruction.headers {
        let value = String::from_utf8(field.value.clone()).map_err(|_| {
            (
                HostStage::RequestWrite,
                HostFailure::RequestHeaderEncodingUnavailable,
            )
        })?;
        if field.name.eq_ignore_ascii_case("host") {
            if host_seen {
                return Err((HostStage::RequestWrite, HostFailure::RequestWriteFailed));
            }
            host_seen = true;
        }
        if field.name.eq_ignore_ascii_case("content-length") {
            let length = value.trim_matches([' ', '\t']);
            if content_length_seen
                || length.is_empty()
                || !length.bytes().all(|byte| byte.is_ascii_digit())
                || length.parse::<u64>().is_err()
            {
                return Err((HostStage::RequestWrite, HostFailure::RequestWriteFailed));
            }
            content_length_seen = true;
        }
        headers.push((field.name.as_str(), value));
    }
    let mut request = ureq::http::Request::builder()
        .method(input.instruction.method.as_str())
        .uri(input.instruction.target.as_str());
    for (name, value) in headers {
        request = request.header(name, value);
    }

    stage.set(HostStage::ResponseHeaders);
    let result = if body.is_empty()
        && !matches!(input.instruction.method.as_str(), "POST" | "PUT" | "PATCH")
    {
        agent.run(
            request
                .body(())
                .map_err(|_| (HostStage::RequestWrite, HostFailure::RequestWriteFailed))?,
        )
    } else {
        agent.run(
            request
                .body(body)
                .map_err(|_| (HostStage::RequestWrite, HostFailure::RequestWriteFailed))?,
        )
    };
    let response = result.map_err(|error| classify_transport(&error, stage.get()))?;
    stage.set(HostStage::ResponseBody);

    let status = Natural::from(response.status().as_u16());
    let mut headers = Vec::new();
    for (name, value) in response.headers() {
        headers.push(RawHeaderField {
            name: name.as_str().to_owned(),
            value: value.as_bytes().to_vec(),
        });
    }
    let read_limit = input
        .configuration
        .response_body_limit
        .to_u64()
        .map_or(u64::MAX, |limit| limit.saturating_add(1));
    let mut body = Vec::new();
    response
        .into_body()
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
            body,
        },
        HeaderProvenance::LibraryObserved,
    ))
}

fn classify_transport(error: &ureq::Error, current: HostStage) -> (HostStage, HostFailure) {
    match error {
        ureq::Error::BadUri(_) => (HostStage::Start, HostFailure::UnsupportedUriScheme),
        ureq::Error::RequireHttpsOnly(_) | ureq::Error::InvalidProxyUrl => {
            (HostStage::Start, HostFailure::InvalidHostConfiguration)
        }
        ureq::Error::HostNotFound => (HostStage::Start, HostFailure::NameResolutionFailed),
        ureq::Error::ConnectionFailed | ureq::Error::ConnectProxyFailed(_) => {
            (HostStage::Start, HostFailure::ConnectionFailed)
        }
        ureq::Error::Http(_) | ureq::Error::BodyExceedsLimit(_) => {
            (HostStage::RequestWrite, HostFailure::RequestWriteFailed)
        }
        ureq::Error::Protocol(error) => match error {
            ureq_proto::Error::TooManyHostHeaders
            | ureq_proto::Error::BadHostHeader
            | ureq_proto::Error::BadAuthorizationHeader
            | ureq_proto::Error::BadHeader(_)
            | ureq_proto::Error::BodyLargerThanContentLength
            | ureq_proto::Error::BodyNotAllowed
            | ureq_proto::Error::UnsupportedVersion
            | ureq_proto::Error::MethodVersionMismatch(_, _) => {
                (HostStage::RequestWrite, HostFailure::RequestWriteFailed)
            }
            _ => (HostStage::ResponseHeaders, HostFailure::MalformedResponse),
        },
        ureq::Error::Io(error) => classify_io_transport(error, current),
        ureq::Error::Timeout(_) => (
            HostStage::ResponseHeaders,
            HostFailure::Timeout {
                stage: HostStage::ResponseHeaders,
                cause: HostTimeoutCause::LibraryReported,
            },
        ),
        ureq::Error::LargeResponseHeader(_, _) => {
            (HostStage::ResponseHeaders, HostFailure::MalformedResponse)
        }
        _ => (current, HostFailure::HostRuntimeFailure),
    }
}

fn classify_io_transport(error: &std::io::Error, current: HostStage) -> (HostStage, HostFailure) {
    match error.kind() {
        ErrorKind::TimedOut | ErrorKind::WouldBlock => (
            HostStage::ResponseHeaders,
            HostFailure::Timeout {
                stage: HostStage::ResponseHeaders,
                cause: HostTimeoutCause::SocketReported,
            },
        ),
        ErrorKind::ConnectionRefused | ErrorKind::NotConnected => {
            (HostStage::Start, HostFailure::ConnectionFailed)
        }
        ErrorKind::BrokenPipe | ErrorKind::WriteZero => {
            (HostStage::RequestWrite, HostFailure::RequestWriteFailed)
        }
        ErrorKind::ConnectionAborted | ErrorKind::ConnectionReset | ErrorKind::UnexpectedEof => (
            HostStage::ResponseHeaders,
            HostFailure::ResponseHeadersFailed,
        ),
        ErrorKind::InvalidData => (HostStage::ResponseHeaders, HostFailure::MalformedResponse),
        _ => (current, HostFailure::HostRuntimeFailure),
    }
}

mod interrupt;

#[cfg(test)]
mod drive_tests;

#[cfg(test)]
mod tests;
