// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

use super::*;
use necoherence::request_progression::RequestIdentity;
use necoherence::RetentionReason;

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
        prepare(NetworkState::default(), Arc::new(input.clone()))
    else {
        return Err("prepare");
    };
    assert_eq!(network_attempts(&state).len(), 1);
    let CommandStep::CommandReady(_, command) = send_command(state, prepared) else {
        return Err("send command");
    };
    assert_eq!(*command.prepared.input, input);
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
        TestHostFault::BootstrapFailure => (HostStage::Start, HostFailure::ExecutionStartFailed),
        TestHostFault::WorkerFailure => {
            (HostStage::ResponseHeaders, HostFailure::HostRuntimeFailure)
        }
    }
}

use std::io::Write as _;
use std::net::{TcpListener, TcpStream};
use std::sync::atomic::AtomicUsize;
use std::time::Duration;

type TestResult<T = ()> = Result<T, Box<dyn std::error::Error + Send + Sync>>;

struct KeepAlivePeer {
    target: String,
    accepted: Arc<AtomicUsize>,
    stop: Arc<AtomicBool>,
    gate: Arc<AtomicBool>,
    worker: Option<thread::JoinHandle<()>>,
}

impl KeepAlivePeer {
    fn start(gated: bool) -> TestResult<Self> {
        let listener = TcpListener::bind("127.0.0.1:0")?;
        listener.set_nonblocking(true)?;
        let address = listener.local_addr()?;
        let accepted = Arc::new(AtomicUsize::new(0));
        let stop = Arc::new(AtomicBool::new(false));
        let gate = Arc::new(AtomicBool::new(!gated));
        let worker = {
            let accepted = Arc::clone(&accepted);
            let stop = Arc::clone(&stop);
            let gate = Arc::clone(&gate);
            thread::spawn(move || {
                while !stop.load(Ordering::SeqCst) {
                    match listener.accept() {
                        Ok((stream, _)) => {
                            accepted.fetch_add(1, Ordering::SeqCst);
                            let stop = Arc::clone(&stop);
                            let gate = Arc::clone(&gate);
                            thread::spawn(move || {
                                let _ = serve_connection(stream, &stop, &gate);
                            });
                        }
                        Err(_) => thread::sleep(Duration::from_millis(1)),
                    }
                }
            })
        };
        Ok(Self {
            target: format!("http://{address}/shared-agent"),
            accepted,
            stop,
            gate,
            worker: Some(worker),
        })
    }

    fn release(&self) {
        self.gate.store(true, Ordering::SeqCst);
    }

    fn accepted(&self) -> usize {
        self.accepted.load(Ordering::SeqCst)
    }
}

impl Drop for KeepAlivePeer {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::SeqCst);
        if let Some(worker) = self.worker.take() {
            let _ = worker.join();
        }
    }
}

fn serve_connection(mut stream: TcpStream, stop: &AtomicBool, gate: &AtomicBool) -> TestResult {
    stream.set_nonblocking(false)?;
    stream.set_read_timeout(Some(Duration::from_millis(50)))?;
    let mut buffer: Vec<u8> = Vec::new();
    let mut chunk = [0u8; 1024];
    while !stop.load(Ordering::SeqCst) {
        match stream.read(&mut chunk) {
            Ok(0) => return Ok(()),
            Ok(read) => buffer.extend_from_slice(chunk.get(..read).unwrap_or_default()),
            Err(error)
                if matches!(
                    error.kind(),
                    std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut
                ) => {}
            Err(_) => return Ok(()),
        }
        while let Some(end) = buffer.windows(4).position(|window| window == b"\r\n\r\n") {
            buffer.drain(..end + 4);
            while !gate.load(Ordering::SeqCst) {
                if stop.load(Ordering::SeqCst) {
                    return Ok(());
                }
                thread::sleep(Duration::from_millis(1));
            }
            stream.write_all(b"HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n")?;
        }
    }
    Ok(())
}

fn started_attempt<C: MonotonicClockPort + 'static, X: CancellationPort + 'static>(
    adapter: &UreqHttpAdapter<C, X>,
    target: &str,
) -> TestResult<StartedAttempt> {
    let mut attempt = input();
    attempt.instruction.target = target.to_owned();
    let PrepareStep::Prepared(state, prepared) =
        prepare(NetworkState::default(), Arc::new(attempt))
    else {
        return Err("prepare".into());
    };
    let CommandStep::CommandReady(_, command) = send_command(state, prepared) else {
        return Err("send command".into());
    };
    let prepared = command.prepared.clone();
    match adapter.start(command) {
        StartObservation::Started { handle, .. } => Ok(StartedAttempt { prepared, handle }),
        StartObservation::StartFailed { .. } => Err("start failed".into()),
    }
}

fn await_delivery<C: MonotonicClockPort + 'static, X: CancellationPort + 'static>(
    adapter: &UreqHttpAdapter<C, X>,
    started: &StartedAttempt,
) -> TestResult<HostObservation> {
    for _ in 0..20_000 {
        let observation = adapter.observe(started)?;
        if matches!(observation, HostObservation::Delivered { .. }) {
            return Ok(observation);
        }
        thread::sleep(Duration::from_micros(200));
    }
    Err("delivery timeout".into())
}

fn dispatched<C: MonotonicClockPort + 'static, X: CancellationPort + 'static>(
    adapter: &UreqHttpAdapter<C, X>,
    target: &str,
    cancellation: Option<CancellationCapability>,
) -> TestResult<(NetworkState, StartedAttempt)> {
    let mut attempt = input();
    attempt.instruction.target = target.to_owned();
    attempt.configuration.cancellation = cancellation;
    let PrepareStep::Prepared(state, prepared) =
        prepare(NetworkState::default(), Arc::new(attempt))
    else {
        return Err("prepare".into());
    };
    let CommandStep::CommandReady(state, command) = send_command(state, prepared.clone()) else {
        return Err("send command".into());
    };
    let start = adapter.start(command);
    let NetworkStep::Started(state, started) = observe_start(state, prepared, start) else {
        return Err("observe start".into());
    };
    Ok((state, started))
}

type HostRecordDecision = ErasureDecision<AttemptIdentity, (), (), (), HostRecordObservation>;

fn reasons_of(
    decision: &HostRecordDecision,
) -> Option<&Vec<RetentionReason<AttemptIdentity, (), HostRecordObservation>>> {
    match decision {
        ErasureDecision::Retain(reasons) => Some(reasons),
        _ => None,
    }
}

fn effect_outstanding(decision: &HostRecordDecision) -> bool {
    reasons_of(decision).is_some_and(|reasons| {
        reasons
            .iter()
            .any(|reason| matches!(reason, RetentionReason::OutstandingEffect(_)))
    })
}

fn release_when_idle<C: MonotonicClockPort + 'static, X: CancellationPort + 'static>(
    adapter: &UreqHttpAdapter<C, X>,
    state: &NetworkState,
    started: &StartedAttempt,
) -> TestResult<HostRecordDecision> {
    for _ in 0..20_000 {
        let decision = adapter.release(state, started);
        if !effect_outstanding(&decision) {
            return Ok(decision);
        }
        thread::sleep(Duration::from_micros(200));
    }
    Err("worker still running".into())
}

fn drain_requests(total: usize, unreleased: usize) -> TestResult<usize> {
    let peer = KeepAlivePeer::start(false)?;
    let adapter = UreqHttpAdapter::default();
    for index in 0..total {
        let (state, started) = dispatched(&adapter, &peer.target, None)?;
        let delivered = await_delivery(&adapter, &started)?;
        let NetworkStep::Terminal(state, _) = observe(state, delivered) else {
            return Err("terminal".into());
        };
        if index >= unreleased {
            let decision = release_when_idle(&adapter, &state, &started)?;
            assert!(matches!(decision, ErasureDecision::Dematerialize(_)));
        }
    }
    Ok(adapter.record_count())
}

#[test]
fn released_records_leave_no_registration_after_two_thousand_requests() -> TestResult {
    assert_eq!(drain_requests(2000, 0)?, 0);
    Ok(())
}

#[test]
fn unreleased_records_remain_registered() -> TestResult {
    assert_eq!(drain_requests(40, 3)?, 3);
    Ok(())
}

#[test]
fn release_retains_only_future_use_before_terminal() -> TestResult {
    let peer = KeepAlivePeer::start(false)?;
    let adapter = UreqHttpAdapter::default();
    let (state, started) = dispatched(&adapter, &peer.target, None)?;
    await_delivery(&adapter, &started)?;
    let decision = release_when_idle(&adapter, &state, &started)?;
    let attempt = started.prepared.input.attempt.clone();
    assert!(matches!(
        reasons_of(&decision),
        Some(reasons) if *reasons == vec![RetentionReason::FutureUse(attempt)]
    ));
    assert_eq!(adapter.record_count(), 1);
    Ok(())
}

fn await_stopped<C: MonotonicClockPort + 'static, X: CancellationPort + 'static>(
    adapter: &UreqHttpAdapter<C, X>,
    started: &StartedAttempt,
) -> TestResult {
    for _ in 0..2000 {
        match adapter.execution(&started.handle) {
            Some(execution) if execution.is_running() => {
                thread::sleep(Duration::from_millis(1));
            }
            _ => return Ok(()),
        }
    }
    Err("worker still running".into())
}

fn await_request_at_peer(peer: &KeepAlivePeer) -> TestResult {
    for _ in 0..2000 {
        if peer.accepted() >= 1 {
            thread::sleep(Duration::from_millis(30));
            return Ok(());
        }
        thread::sleep(Duration::from_millis(1));
    }
    Err("peer never accepted".into())
}

fn assert_pending<C: MonotonicClockPort + 'static, X: CancellationPort + 'static>(
    adapter: &UreqHttpAdapter<C, X>,
    started: &StartedAttempt,
) -> TestResult {
    assert!(matches!(
        adapter.observe(started)?,
        HostObservation::Pending { .. }
    ));
    Ok(())
}

struct SteppedClock {
    capability: MonotonicClockCapability,
    value: Arc<AtomicU64>,
}

impl MonotonicClockPort for SteppedClock {
    fn capability(&self) -> MonotonicClockCapability {
        self.capability.clone()
    }

    fn observe(&self) -> Result<MonotonicClockObservation, HostFailure> {
        Ok(MonotonicClockObservation {
            clock_basis: self.capability.clock_basis.clone(),
            value: self.value.load(Ordering::SeqCst).into(),
        })
    }
}

fn stepped_clock(value: &Arc<AtomicU64>) -> (SteppedClock, Deadline) {
    let capability = MonotonicClockCapability {
        identity: OpaqueEvidence {
            value: "stepped-clock".to_owned(),
        },
        clock_basis: ClockBasis {
            value: "stepped".to_owned(),
        },
    };
    let deadline = Deadline {
        clock_basis: capability.clock_basis.clone(),
        limit: 1000u64.into(),
        capability: capability.clone(),
    };
    (
        SteppedClock {
            capability,
            value: Arc::clone(value),
        },
        deadline,
    )
}

fn dispatched_with_deadline<C: MonotonicClockPort + 'static, X: CancellationPort + 'static>(
    adapter: &UreqHttpAdapter<C, X>,
    target: &str,
    deadline: Deadline,
) -> TestResult<(NetworkState, StartedAttempt)> {
    let mut attempt = input();
    attempt.instruction.target = target.to_owned();
    attempt.configuration.monotonic_clock = Some(deadline.capability.clone());
    attempt.deadline = Some(deadline);
    let PrepareStep::Prepared(state, prepared) =
        prepare(NetworkState::default(), Arc::new(attempt))
    else {
        return Err("prepare".into());
    };
    let CommandStep::CommandReady(state, command) = send_command(state, prepared.clone()) else {
        return Err("send command".into());
    };
    let start = adapter.start(command);
    let NetworkStep::Started(state, started) = observe_start(state, prepared, start) else {
        return Err("observe start".into());
    };
    Ok((state, started))
}

#[test]
fn deadline_observation_interrupts_a_held_request() -> TestResult {
    let value = Arc::new(AtomicU64::new(0));
    let (clock, deadline) = stepped_clock(&value);
    let peer = KeepAlivePeer::start(true)?;
    let adapter = UreqHttpAdapter::new(clock, CooperativeCancellation::default());
    let (state, started) = dispatched_with_deadline(&adapter, &peer.target, deadline)?;
    await_request_at_peer(&peer)?;
    assert_pending(&adapter, &started)?;
    value.store(1000, Ordering::SeqCst);
    let observed = adapter.observe(&started)?;
    assert!(matches!(
        &observed,
        HostObservation::Delivered {
            observation: AdapterObservation::DeadlineObservation { .. },
            ..
        }
    ));
    await_stopped(&adapter, &started)?;
    assert_pending(&adapter, &started)?;
    let NetworkStep::Terminal(state, _) = observe(state, observed) else {
        return Err("deadline terminal".into());
    };
    let decision = adapter.release(&state, &started);
    assert!(matches!(decision, ErasureDecision::Dematerialize(_)));
    assert_eq!(adapter.record_count(), 0);
    Ok(())
}

fn assert_no_late_observation<C: MonotonicClockPort + 'static, X: CancellationPort + 'static>(
    adapter: &UreqHttpAdapter<C, X>,
    started: &StartedAttempt,
    peer: &KeepAlivePeer,
) -> TestResult {
    peer.release();
    thread::sleep(Duration::from_millis(150));
    assert_pending(adapter, started)?;
    assert_pending(adapter, started)?;
    Ok(())
}

struct ScriptedClock {
    capability: MonotonicClockCapability,
    reported_basis: ClockBasis,
    value: Arc<AtomicU64>,
    calls: Arc<AtomicUsize>,
    fail_on: usize,
    panics: bool,
}

impl MonotonicClockPort for ScriptedClock {
    fn capability(&self) -> MonotonicClockCapability {
        self.capability.clone()
    }

    fn observe(&self) -> Result<MonotonicClockObservation, HostFailure> {
        let call = self.calls.fetch_add(1, Ordering::SeqCst) + 1;
        if call == self.fail_on {
            assert!(!self.panics, "clock observe failure");
            return Err(HostFailure::HostRuntimeFailure);
        }
        Ok(MonotonicClockObservation {
            clock_basis: self.reported_basis.clone(),
            value: self.value.load(Ordering::SeqCst).into(),
        })
    }
}

fn scripted_clock(
    value: &Arc<AtomicU64>,
    calls: &Arc<AtomicUsize>,
    reported_basis: Option<&str>,
    fail_on: usize,
) -> (ScriptedClock, Deadline) {
    let (stepped, deadline) = stepped_clock(value);
    let reported = reported_basis.map_or_else(
        || stepped.capability.clock_basis.clone(),
        |basis| ClockBasis {
            value: basis.to_owned(),
        },
    );
    (
        ScriptedClock {
            capability: stepped.capability,
            reported_basis: reported,
            value: Arc::clone(value),
            calls: Arc::clone(calls),
            fail_on,
            panics: false,
        },
        deadline,
    )
}

#[test]
fn a_clock_with_another_basis_never_reaches_the_deadline() -> TestResult {
    let value = Arc::new(AtomicU64::new(5000));
    let calls = Arc::new(AtomicUsize::new(0));
    let (clock, deadline) = scripted_clock(&value, &calls, Some("other-basis"), 0);
    let peer = KeepAlivePeer::start(true)?;
    let adapter = UreqHttpAdapter::new(clock, CooperativeCancellation::default());
    let (_, started) = dispatched_with_deadline(&adapter, &peer.target, deadline)?;
    await_request_at_peer(&peer)?;
    assert_pending(&adapter, &started)?;
    assert_pending(&adapter, &started)?;
    assert!(calls.load(Ordering::SeqCst) >= 2);
    peer.release();
    let delivered = await_delivery(&adapter, &started)?;
    assert!(matches!(
        delivered,
        HostObservation::Delivered {
            observation: AdapterObservation::ResponseObservation { .. },
            ..
        }
    ));
    Ok(())
}

#[test]
fn a_clock_one_below_the_limit_is_pending_and_the_limit_reaches_the_deadline() -> TestResult {
    let value = Arc::new(AtomicU64::new(999));
    let calls = Arc::new(AtomicUsize::new(0));
    let (clock, deadline) = scripted_clock(&value, &calls, None, 0);
    let peer = KeepAlivePeer::start(true)?;
    let adapter = UreqHttpAdapter::new(clock, CooperativeCancellation::default());
    let (_, started) = dispatched_with_deadline(&adapter, &peer.target, deadline)?;
    await_request_at_peer(&peer)?;
    assert_pending(&adapter, &started)?;
    value.store(1000, Ordering::SeqCst);
    assert!(matches!(
        adapter.observe(&started)?,
        HostObservation::Delivered {
            observation: AdapterObservation::DeadlineObservation { .. },
            ..
        }
    ));
    Ok(())
}

#[test]
fn a_clock_at_the_limit_from_the_start_sends_no_request() -> TestResult {
    let value = Arc::new(AtomicU64::new(1000));
    let (clock, deadline) = stepped_clock(&value);
    let peer = KeepAlivePeer::start(true)?;
    let adapter = UreqHttpAdapter::new(clock, CooperativeCancellation::default());
    let (_, started) = dispatched_with_deadline(&adapter, &peer.target, deadline)?;
    await_stopped(&adapter, &started)?;
    thread::sleep(Duration::from_millis(300));
    assert_eq!(peer.accepted(), 0);
    assert!(matches!(
        await_delivery(&adapter, &started)?,
        HostObservation::Delivered {
            observation: AdapterObservation::DeadlineObservation { .. },
            ..
        }
    ));
    assert_pending(&adapter, &started)?;
    Ok(())
}

fn assert_one_clock_failure(fail_on: usize) -> TestResult {
    assert_one_clock_failure_by(fail_on, false)
}

fn assert_one_clock_failure_by(fail_on: usize, panics: bool) -> TestResult {
    let value = Arc::new(AtomicU64::new(0));
    let calls = Arc::new(AtomicUsize::new(0));
    let (mut clock, deadline) = scripted_clock(&value, &calls, None, fail_on);
    clock.panics = panics;
    let peer = KeepAlivePeer::start(true)?;
    let adapter = UreqHttpAdapter::new(clock, CooperativeCancellation::default());
    let (_, started) = dispatched_with_deadline(&adapter, &peer.target, deadline)?;
    if fail_on > 1 {
        await_request_at_peer(&peer)?;
    } else {
        let execution = adapter.execution(&started.handle).ok_or("execution")?;
        for _ in 0..2000 {
            if execution.has_queued() {
                break;
            }
            thread::sleep(Duration::from_millis(1));
        }
    }
    let first = await_delivery(&adapter, &started)?;
    let HostObservation::Delivered {
        observation:
            AdapterObservation::FailureObservation {
                failure, effect, ..
            },
        ..
    } = first
    else {
        return Err("failure observation".into());
    };
    assert_eq!(failure.stage, HostStage::Deadline);
    assert!(matches!(failure.cause, HostFailure::HostRuntimeFailure));
    assert!(matches!(
        effect,
        EffectStatus::Unknown {
            reason: UnknownEffectReason::HostFailure
        }
    ));
    let calls_after_first = calls.load(Ordering::SeqCst);
    assert_eq!(calls_after_first, fail_on);
    for _ in 0..5 {
        assert_pending(&adapter, &started)?;
        thread::sleep(Duration::from_millis(5));
    }
    assert_eq!(calls.load(Ordering::SeqCst), calls_after_first);
    await_stopped(&adapter, &started)?;
    if fail_on == 1 {
        assert_eq!(peer.accepted(), 0);
    }
    assert_no_late_observation(&adapter, &started, &peer)
}

#[test]
fn a_clock_failure_on_the_first_observation_is_one_deadline_failure() -> TestResult {
    assert_one_clock_failure(1)
}

#[test]
fn a_clock_failure_on_a_later_observation_is_one_deadline_failure() -> TestResult {
    assert_one_clock_failure(2)
}

#[test]
fn a_clock_panic_on_the_first_observation_is_one_deadline_failure() -> TestResult {
    assert_one_clock_failure_by(1, true)
}

#[test]
fn a_clock_panic_on_a_later_observation_is_one_deadline_failure() -> TestResult {
    assert_one_clock_failure_by(2, true)
}

#[derive(Clone)]
struct PanickingCancellation {
    inner: CooperativeCancellation,
    capability_calls: Arc<AtomicUsize>,
    panic_capability_from: usize,
    panic_request: bool,
}

impl CancellationPort for PanickingCancellation {
    fn capability(&self) -> CancellationCapability {
        let call = self.capability_calls.fetch_add(1, Ordering::SeqCst) + 1;
        assert!(call < self.panic_capability_from, "capability failure");
        self.inner.capability()
    }

    fn request(&self, handle: &ExecutionHandle) -> Result<(), HostFailure> {
        assert!(!self.panic_request, "request failure");
        self.inner.request(handle)
    }
}

fn assert_one_cancel_failure(panic_capability_from: usize, panic_request: bool) -> TestResult {
    let inner = CooperativeCancellation::default();
    let capability = inner.capability();
    let adapter = UreqHttpAdapter::new(
        SystemMonotonicClock::new(ClockBasis {
            value: "cancel-panic-test".to_owned(),
        }),
        PanickingCancellation {
            inner,
            capability_calls: Arc::new(AtomicUsize::new(0)),
            panic_capability_from,
            panic_request,
        },
    );
    let peer = KeepAlivePeer::start(true)?;
    let (state, started) = dispatched(&adapter, &peer.target, Some(capability))?;
    await_request_at_peer(&peer)?;
    let CommandStep::CommandReady(_, command) = cancel_command(state, started.clone()) else {
        return Err("cancel command".into());
    };
    let HostObservation::Delivered {
        observation: AdapterObservation::FailureObservation { failure, .. },
        ..
    } = adapter.cancel(command)?
    else {
        return Err("failure observation".into());
    };
    assert_eq!(failure.stage, HostStage::Cancel);
    assert_eq!(failure.cause, HostFailure::HostRuntimeFailure);
    assert_pending(&adapter, &started)?;
    await_stopped(&adapter, &started)?;
    assert_no_late_observation(&adapter, &started, &peer)
}

#[test]
fn a_cancellation_capability_panic_is_one_cancel_failure() -> TestResult {
    assert_one_cancel_failure(2, false)
}

#[test]
fn a_cancellation_request_panic_is_one_cancel_failure() -> TestResult {
    assert_one_cancel_failure(usize::MAX, true)
}

#[derive(Clone)]
struct FailingCancellation {
    capability: CancellationCapability,
}

impl CancellationPort for FailingCancellation {
    fn capability(&self) -> CancellationCapability {
        self.capability.clone()
    }

    fn request(&self, _handle: &ExecutionHandle) -> Result<(), HostFailure> {
        Err(HostFailure::HostRuntimeFailure)
    }
}

#[test]
fn a_cancellation_request_failure_value_is_one_cancel_failure() -> TestResult {
    let capability = CooperativeCancellation::default().capability();
    let adapter = UreqHttpAdapter::new(
        SystemMonotonicClock::new(ClockBasis {
            value: "cancel-failure-value-test".to_owned(),
        }),
        FailingCancellation {
            capability: capability.clone(),
        },
    );
    let peer = KeepAlivePeer::start(true)?;
    let (state, started) = dispatched(&adapter, &peer.target, Some(capability))?;
    await_request_at_peer(&peer)?;
    let CommandStep::CommandReady(_, command) = cancel_command(state, started.clone()) else {
        return Err("cancel command".into());
    };
    let failed = adapter.cancel(command)?;
    assert!(matches!(
        &failed,
        HostObservation::Delivered {
            observation: AdapterObservation::FailureObservation {
                failure: NetworkHostFailure {
                    stage: HostStage::Cancel,
                    cause: HostFailure::HostRuntimeFailure,
                    ..
                },
                ..
            },
            ..
        }
    ));
    assert_failure_effect_host_failure(&failed);
    assert_pending(&adapter, &started)?;
    await_stopped(&adapter, &started)?;
    assert_no_late_observation(&adapter, &started, &peer)
}

fn start_failure_of(
    adapter: &UreqHttpAdapter<PanickingClock, PanickingCancellation>,
    attempt: AttemptInput,
) -> TestResult<NetworkHostFailure> {
    let PrepareStep::Prepared(state, prepared) =
        prepare(NetworkState::default(), Arc::new(attempt))
    else {
        return Err("prepare".into());
    };
    let CommandStep::CommandReady(_, command) = send_command(state, prepared) else {
        return Err("send command".into());
    };
    let StartObservation::StartFailed { failure, .. } = adapter.start(command) else {
        return Err("start failure".into());
    };
    assert_eq!(adapter.record_count(), 0);
    Ok(failure)
}

struct PanickingClock {
    capability: MonotonicClockCapability,
    panic_capability: bool,
}

impl MonotonicClockPort for PanickingClock {
    fn capability(&self) -> MonotonicClockCapability {
        assert!(!self.panic_capability, "clock capability failure");
        self.capability.clone()
    }

    fn observe(&self) -> Result<MonotonicClockObservation, HostFailure> {
        Ok(MonotonicClockObservation {
            clock_basis: self.capability.clock_basis.clone(),
            value: 0u8.into(),
        })
    }
}

#[test]
fn a_clock_capability_panic_at_start_is_a_start_failure() -> TestResult {
    let value = Arc::new(AtomicU64::new(0));
    let (stepped, deadline) = stepped_clock(&value);
    let adapter = UreqHttpAdapter::new(
        PanickingClock {
            capability: stepped.capability,
            panic_capability: true,
        },
        PanickingCancellation {
            inner: CooperativeCancellation::default(),
            capability_calls: Arc::new(AtomicUsize::new(0)),
            panic_capability_from: usize::MAX,
            panic_request: false,
        },
    );
    let mut attempt = input();
    attempt.configuration.monotonic_clock = Some(deadline.capability.clone());
    attempt.deadline = Some(deadline);
    let failure = start_failure_of(&adapter, attempt)?;
    assert_eq!(failure.stage, HostStage::Start);
    assert_eq!(failure.cause, HostFailure::HostRuntimeFailure);
    Ok(())
}

#[test]
fn a_cancellation_capability_panic_at_start_is_a_start_failure() -> TestResult {
    let value = Arc::new(AtomicU64::new(0));
    let (stepped, _) = stepped_clock(&value);
    let inner = CooperativeCancellation::default();
    let capability = inner.capability();
    let adapter = UreqHttpAdapter::new(
        PanickingClock {
            capability: stepped.capability,
            panic_capability: false,
        },
        PanickingCancellation {
            inner,
            capability_calls: Arc::new(AtomicUsize::new(0)),
            panic_capability_from: 1,
            panic_request: false,
        },
    );
    let mut attempt = input();
    attempt.configuration.cancellation = Some(capability);
    let failure = start_failure_of(&adapter, attempt)?;
    assert_eq!(failure.stage, HostStage::Start);
    assert_eq!(failure.cause, HostFailure::HostRuntimeFailure);
    Ok(())
}

#[test]
fn cancel_interrupts_a_held_request() -> TestResult {
    let capability = CooperativeCancellation::default().capability();
    let peer = KeepAlivePeer::start(true)?;
    let adapter = UreqHttpAdapter::default();
    let (state, started) = dispatched(&adapter, &peer.target, Some(capability.clone()))?;
    await_request_at_peer(&peer)?;
    let CommandStep::CommandReady(_, command) = cancel_command(state.clone(), started.clone())
    else {
        return Err("cancel command".into());
    };
    let cancelled = adapter.cancel(command)?;
    assert!(matches!(
        &cancelled,
        HostObservation::Delivered {
            observation: AdapterObservation::CancellationObservation { .. },
            ..
        }
    ));
    await_stopped(&adapter, &started)?;
    assert_pending(&adapter, &started)?;
    let NetworkStep::Terminal(state, _) = observe(state, cancelled) else {
        return Err("cancel terminal".into());
    };
    let decision = adapter.release(&state, &started);
    assert!(matches!(decision, ErasureDecision::Dematerialize(_)));
    assert_eq!(adapter.record_count(), 0);
    Ok(())
}

#[test]
fn close_interrupts_a_held_request() -> TestResult {
    let peer = KeepAlivePeer::start(true)?;
    let adapter = UreqHttpAdapter::default();
    let (state, started) = dispatched(&adapter, &peer.target, None)?;
    await_request_at_peer(&peer)?;
    let closed = adapter.close(&started)?;
    assert!(matches!(
        &closed,
        HostObservation::Delivered {
            observation: AdapterObservation::FailureObservation {
                failure: NetworkHostFailure {
                    cause: HostFailure::HostClosed,
                    ..
                },
                ..
            },
            ..
        }
    ));
    await_stopped(&adapter, &started)?;
    assert_pending(&adapter, &started)?;
    let NetworkStep::Terminal(state, _) = observe(state, closed) else {
        return Err("close terminal".into());
    };
    let decision = adapter.release(&state, &started);
    assert!(matches!(decision, ErasureDecision::Dematerialize(_)));
    assert_eq!(adapter.record_count(), 0);
    Ok(())
}

#[test]
fn a_rejected_cancel_interrupts_the_request_and_no_late_observation_follows() -> TestResult {
    let (adapter, capability) = rejecting_adapter();
    let peer = KeepAlivePeer::start(true)?;
    let (state, started) = dispatched(&adapter, &peer.target, Some(capability))?;
    await_request_at_peer(&peer)?;
    let CommandStep::CommandReady(_, command) = cancel_command(state, started.clone()) else {
        return Err("cancel command".into());
    };
    let rejected = adapter.cancel(command)?;
    assert_cancel_rejected(&rejected);
    assert_failure_effect_host_failure(&rejected);
    await_stopped(&adapter, &started)?;
    assert_no_late_observation(&adapter, &started, &peer)
}

fn assert_failure_effect_host_failure(observation: &HostObservation) {
    assert!(matches!(
        observation,
        HostObservation::Delivered {
            observation: AdapterObservation::FailureObservation {
                effect: EffectStatus::Unknown {
                    reason: UnknownEffectReason::HostFailure
                },
                ..
            },
            ..
        }
    ));
}

#[derive(Clone)]
struct RejectingCancellation {
    capability: CancellationCapability,
}

impl CancellationPort for RejectingCancellation {
    fn capability(&self) -> CancellationCapability {
        self.capability.clone()
    }

    fn request(&self, _handle: &ExecutionHandle) -> Result<(), HostFailure> {
        Err(HostFailure::CancellationRejected)
    }
}

fn rejecting_adapter() -> (
    UreqHttpAdapter<SystemMonotonicClock, RejectingCancellation>,
    CancellationCapability,
) {
    let capability = CooperativeCancellation::default().capability();
    let adapter = UreqHttpAdapter::new(
        SystemMonotonicClock::new(ClockBasis {
            value: "rejecting-test".to_owned(),
        }),
        RejectingCancellation {
            capability: capability.clone(),
        },
    );
    (adapter, capability)
}

fn assert_cancel_rejected(observation: &HostObservation) {
    assert!(matches!(
        observation,
        HostObservation::Delivered {
            observation: AdapterObservation::FailureObservation {
                failure: NetworkHostFailure {
                    stage: HostStage::Cancel,
                    cause: HostFailure::CancellationRejected,
                    ..
                },
                ..
            },
            ..
        }
    ));
}

#[test]
fn a_rejected_cancel_right_after_the_start_never_leaves_a_response_behind_it() -> TestResult {
    let peer = KeepAlivePeer::start(false)?;
    let (adapter, capability) = rejecting_adapter();
    for _ in 0..200 {
        let (state, started) = dispatched(&adapter, &peer.target, Some(capability.clone()))?;
        let CommandStep::CommandReady(_, command) = cancel_command(state, started.clone()) else {
            return Err("cancel command".into());
        };
        let mut kinds = vec![adapter.cancel(command)?];
        await_stopped(&adapter, &started)?;
        loop {
            let next = adapter.observe(&started)?;
            if matches!(next, HostObservation::Pending { .. }) {
                break;
            }
            kinds.push(next);
        }
        let responses = kinds
            .iter()
            .map(|kind| {
                matches!(
                    kind,
                    HostObservation::Delivered {
                        observation: AdapterObservation::ResponseObservation { .. },
                        ..
                    }
                )
            })
            .collect::<Vec<_>>();
        if !matches!(responses.as_slice(), [true] | [false] | [true, false]) {
            return Err(format!("unexpected observations {responses:?}").into());
        }
        for (kind, response) in kinds.iter().zip(&responses) {
            if !response {
                assert_cancel_rejected(kind);
            }
        }
    }
    Ok(())
}

#[test]
fn release_after_the_terminal_observation_removes_the_record_within_the_limit() -> TestResult {
    let peer = KeepAlivePeer::start(true)?;
    let (adapter, capability) = rejecting_adapter();
    let (state, started) = dispatched(&adapter, &peer.target, Some(capability))?;
    await_request_at_peer(&peer)?;
    let CommandStep::CommandReady(state, command) = cancel_command(state, started.clone()) else {
        return Err("cancel command".into());
    };
    let rejected = adapter.cancel(command)?;
    assert_cancel_rejected(&rejected);
    let NetworkStep::Terminal(state, _) = observe(state, rejected) else {
        return Err("rejected cancel terminal".into());
    };
    let decision = adapter.release(&state, &started);
    assert!(matches!(
        decision,
        ErasureDecision::Retain(_) | ErasureDecision::Dematerialize(_)
    ));
    for _ in 0..2000 {
        if adapter.record_count() == 0 {
            break;
        }
        thread::sleep(Duration::from_millis(1));
    }
    assert_eq!(adapter.record_count(), 0);
    peer.release();
    Ok(())
}

#[test]
fn release_while_the_core_still_awaits_keeps_the_record_and_no_late_observation_follows(
) -> TestResult {
    let peer = KeepAlivePeer::start(true)?;
    let (adapter, capability) = rejecting_adapter();
    let (state, started) = dispatched(&adapter, &peer.target, Some(capability))?;
    await_request_at_peer(&peer)?;
    let CommandStep::CommandReady(state, command) = cancel_command(state, started.clone()) else {
        return Err("cancel command".into());
    };
    let rejected = adapter.cancel(command)?;
    assert_cancel_rejected(&rejected);
    await_stopped(&adapter, &started)?;
    let decision = adapter.release(&state, &started);
    assert!(matches!(decision, ErasureDecision::Retain(_)));
    assert_eq!(adapter.record_count(), 1);
    assert_no_late_observation(&adapter, &started, &peer)
}

#[test]
fn release_with_a_state_lacking_the_record_does_not_interrupt() -> TestResult {
    let peer = KeepAlivePeer::start(true)?;
    let adapter = UreqHttpAdapter::default();
    let (state, started) = dispatched(&adapter, &peer.target, None)?;
    await_request_at_peer(&peer)?;
    let decision = adapter.release(&NetworkState::default(), &started);
    assert!(matches!(decision, ErasureDecision::Retain(_)));
    let execution = adapter.execution(&started.handle).ok_or("execution")?;
    assert!(execution.is_running());
    assert_eq!(adapter.record_count(), 1);
    peer.release();
    let late = await_delivery(&adapter, &started)?;
    let NetworkStep::Terminal(_, settled) = observe(state, late) else {
        return Err("terminal".into());
    };
    assert!(matches!(
        settled.terminal.outcome,
        NetworkOutcome::Response { .. }
    ));
    Ok(())
}

#[test]
fn an_interrupted_connection_is_not_reused() -> TestResult {
    let capability = CooperativeCancellation::default().capability();
    let peer = KeepAlivePeer::start(true)?;
    let adapter = UreqHttpAdapter::default();
    let (state, started) = dispatched(&adapter, &peer.target, Some(capability))?;
    await_request_at_peer(&peer)?;
    let CommandStep::CommandReady(_, command) = cancel_command(state, started.clone()) else {
        return Err("cancel command".into());
    };
    adapter.cancel(command)?;
    await_stopped(&adapter, &started)?;
    peer.release();
    let next = started_attempt(&adapter, &peer.target)?;
    let HostObservation::Delivered { observation, .. } = await_delivery(&adapter, &next)? else {
        return Err("delivered".into());
    };
    assert!(matches!(
        observation,
        AdapterObservation::ResponseObservation { .. }
    ));
    assert_eq!(peer.accepted(), 2);
    Ok(())
}

#[derive(Debug)]
struct HeldResolver {
    entered: Arc<AtomicBool>,
    calls: Arc<AtomicUsize>,
    open: Arc<(Mutex<bool>, Condvar)>,
    forward: bool,
}

impl ureq::unversioned::resolver::Resolver for HeldResolver {
    fn resolve(
        &self,
        uri: &ureq::http::Uri,
        config: &ureq::config::Config,
        timeout: ureq::unversioned::transport::NextTimeout,
    ) -> Result<ureq::unversioned::resolver::ResolvedSocketAddrs, ureq::Error> {
        self.calls.fetch_add(1, Ordering::SeqCst);
        self.entered.store(true, Ordering::SeqCst);
        let (flag, changed) = &*self.open;
        let mut open = flag.lock().map_err(|_| ureq::Error::HostNotFound)?;
        while !*open {
            open = changed.wait(open).map_err(|_| ureq::Error::HostNotFound)?;
        }
        drop(open);
        if self.forward {
            ureq::unversioned::resolver::DefaultResolver::default().resolve(uri, config, timeout)
        } else {
            Err(ureq::Error::HostNotFound)
        }
    }
}

#[derive(Clone)]
struct CountingCancellation {
    inner: CooperativeCancellation,
    calls: Arc<AtomicUsize>,
}

impl CancellationPort for CountingCancellation {
    fn capability(&self) -> CancellationCapability {
        self.inner.capability()
    }

    fn request(&self, _handle: &ExecutionHandle) -> Result<(), HostFailure> {
        self.calls.fetch_add(1, Ordering::SeqCst);
        Ok(())
    }
}

fn counting_adapter() -> (
    UreqHttpAdapter<SystemMonotonicClock, CountingCancellation>,
    Arc<AtomicUsize>,
) {
    let calls = Arc::new(AtomicUsize::new(0));
    let adapter = UreqHttpAdapter::new(
        SystemMonotonicClock::new(ClockBasis {
            value: "counting-test".to_owned(),
        }),
        CountingCancellation {
            inner: CooperativeCancellation::default(),
            calls: Arc::clone(&calls),
        },
    );
    (adapter, calls)
}

#[test]
fn a_matching_cancel_calls_the_port_once() -> TestResult {
    let capability = CooperativeCancellation::default().capability();
    let peer = KeepAlivePeer::start(true)?;
    let (adapter, calls) = counting_adapter();
    let (_, started) = dispatched(&adapter, &peer.target, Some(capability.clone()))?;
    await_request_at_peer(&peer)?;
    let cancelled = adapter.cancel(CancelCommand {
        attempt: started.prepared.input.attempt.clone(),
        handle: started.handle.clone(),
        capability,
    })?;
    assert!(matches!(
        cancelled,
        HostObservation::Delivered {
            observation: AdapterObservation::CancellationObservation { .. },
            ..
        }
    ));
    assert_eq!(calls.load(Ordering::SeqCst), 1);
    peer.release();
    Ok(())
}

#[test]
fn a_cancel_with_a_foreign_capability_never_reaches_the_port() -> TestResult {
    let capability = CooperativeCancellation::default().capability();
    let peer = KeepAlivePeer::start(true)?;
    let (adapter, calls) = counting_adapter();
    let (_, started) = dispatched(&adapter, &peer.target, Some(capability))?;
    await_request_at_peer(&peer)?;
    let rejected = adapter.cancel(CancelCommand {
        attempt: started.prepared.input.attempt.clone(),
        handle: started.handle.clone(),
        capability: CancellationCapability {
            identity: OpaqueEvidence {
                value: "other-cancellation".to_owned(),
            },
        },
    })?;
    let HostObservation::Delivered {
        observation: AdapterObservation::FailureObservation { failure, .. },
        ..
    } = rejected
    else {
        return Err("failure observation".into());
    };
    assert_eq!(failure.cause, HostFailure::CancellationRejected);
    assert_eq!(failure.stage, HostStage::Cancel);
    assert_eq!(calls.load(Ordering::SeqCst), 0);
    await_stopped(&adapter, &started)?;
    assert_no_late_observation(&adapter, &started, &peer)
}

#[test]
fn a_cancel_with_a_foreign_handle_is_unknown_and_never_reaches_the_port() -> TestResult {
    let capability = CooperativeCancellation::default().capability();
    let peer = KeepAlivePeer::start(true)?;
    let (adapter, calls) = counting_adapter();
    let (_, started) = dispatched(&adapter, &peer.target, Some(capability.clone()))?;
    await_request_at_peer(&peer)?;
    let foreign = ExecutionHandle {
        value: "foreign-handle".into(),
    };
    assert_eq!(
        adapter.cancel(CancelCommand {
            attempt: started.prepared.input.attempt.clone(),
            handle: foreign.clone(),
            capability,
        }),
        Err(UnknownExecution { handle: foreign })
    );
    assert_eq!(calls.load(Ordering::SeqCst), 0);
    peer.release();
    Ok(())
}

#[test]
fn cancel_interrupts_a_name_resolution() -> TestResult {
    let capability = CooperativeCancellation::default().capability();
    let entered = Arc::new(AtomicBool::new(false));
    let open = Arc::new((Mutex::new(false), Condvar::new()));
    let adapter = UreqHttpAdapter::with_resolver(
        SystemMonotonicClock::new(ClockBasis {
            value: "resolver-test".to_owned(),
        }),
        CooperativeCancellation::default(),
        HeldResolver {
            entered: Arc::clone(&entered),
            calls: Arc::new(AtomicUsize::new(0)),
            open: Arc::clone(&open),
            forward: false,
        },
    );
    let (state, started) = dispatched(&adapter, "http://held-name.invalid:80/", Some(capability))?;
    for _ in 0..2000 {
        if entered.load(Ordering::SeqCst) {
            break;
        }
        thread::sleep(Duration::from_millis(1));
    }
    assert!(entered.load(Ordering::SeqCst));
    let CommandStep::CommandReady(_, command) = cancel_command(state, started.clone()) else {
        return Err("cancel command".into());
    };
    adapter.cancel(command)?;
    await_stopped(&adapter, &started)?;
    assert_pending(&adapter, &started)?;
    let (flag, changed) = &*open;
    if let Ok(mut open) = flag.lock() {
        *open = true;
    }
    changed.notify_all();
    Ok(())
}

#[test]
fn cancel_interrupts_a_held_connect() -> TestResult {
    let capability = CooperativeCancellation::default().capability();
    let peer = KeepAlivePeer::start(false)?;
    let calls = Arc::new(AtomicUsize::new(0));
    let open = Arc::new((Mutex::new(false), Condvar::new()));
    let adapter = {
        let calls = Arc::clone(&calls);
        let open = Arc::clone(&open);
        UreqHttpAdapter::with_connect(
            SystemMonotonicClock::new(ClockBasis {
                value: "connect-test".to_owned(),
            }),
            CooperativeCancellation::default(),
            ureq::unversioned::resolver::DefaultResolver::default(),
            move |address| {
                calls.fetch_add(1, Ordering::SeqCst);
                let (flag, changed) = &*open;
                let mut held = flag.lock().map_err(|_| std::io::ErrorKind::Other)?;
                while !*held {
                    held = changed.wait(held).map_err(|_| std::io::ErrorKind::Other)?;
                }
                drop(held);
                TcpStream::connect(address)
            },
        )
    };
    let (state, started) = dispatched(&adapter, &peer.target, Some(capability))?;
    wait_for("the connect to be held", || {
        calls.load(Ordering::SeqCst) == 1
    })?;
    assert_pending(&adapter, &started)?;
    let CommandStep::CommandReady(state, command) = cancel_command(state, started.clone()) else {
        return Err("cancel command".into());
    };
    let began = std::time::Instant::now();
    let cancelled = adapter.cancel(command)?;
    assert!(matches!(
        cancelled,
        HostObservation::Delivered {
            observation: AdapterObservation::CancellationObservation { .. },
            ..
        }
    ));
    let NetworkStep::Terminal(state, _) = observe(state, cancelled) else {
        return Err("cancel terminal".into());
    };
    await_stopped(&adapter, &started)?;
    assert!(began.elapsed() < Duration::from_secs(2));
    let decision = adapter.release(&state, &started);
    assert!(matches!(decision, ErasureDecision::Dematerialize(_)));
    assert_eq!(adapter.record_count(), 0);
    let (flag, changed) = &*open;
    if let Ok(mut held) = flag.lock() {
        *held = true;
    }
    changed.notify_all();
    Ok(())
}

type HeldAdapter = UreqHttpAdapter<SystemMonotonicClock, CooperativeCancellation>;

struct HeldNames {
    calls: Arc<AtomicUsize>,
    open: Arc<(Mutex<bool>, Condvar)>,
}

impl HeldNames {
    fn release(&self) {
        let (flag, changed) = &*self.open;
        if let Ok(mut open) = flag.lock() {
            *open = true;
        }
        changed.notify_all();
    }

    fn calls(&self) -> usize {
        self.calls.load(Ordering::SeqCst)
    }
}

impl Drop for HeldNames {
    fn drop(&mut self) {
        self.release();
    }
}

fn held_names(forward: bool) -> (HeldAdapter, HeldNames) {
    let calls = Arc::new(AtomicUsize::new(0));
    let open = Arc::new((Mutex::new(false), Condvar::new()));
    let adapter = UreqHttpAdapter::with_resolver(
        SystemMonotonicClock::new(ClockBasis {
            value: "held-names".to_owned(),
        }),
        CooperativeCancellation::default(),
        HeldResolver {
            entered: Arc::new(AtomicBool::new(false)),
            calls: Arc::clone(&calls),
            open: Arc::clone(&open),
            forward,
        },
    );
    (adapter, HeldNames { calls, open })
}

fn wait_for(what: &str, ready: impl Fn() -> bool) -> TestResult {
    for _ in 0..5000 {
        if ready() {
            return Ok(());
        }
        thread::sleep(Duration::from_millis(1));
    }
    Err(format!("timed out waiting for {what}").into())
}

fn cancel_started(
    adapter: &HeldAdapter,
    state: NetworkState,
    started: &StartedAttempt,
) -> TestResult {
    let CommandStep::CommandReady(_, command) = cancel_command(state, started.clone()) else {
        return Err("cancel command".into());
    };
    let cancelled = adapter.cancel(command)?;
    assert!(matches!(
        cancelled,
        HostObservation::Delivered {
            observation: AdapterObservation::CancellationObservation { .. },
            ..
        }
    ));
    await_stopped(adapter, started)
}

fn assert_response(observation: HostObservation) {
    assert!(matches!(
        observation,
        HostObservation::Delivered {
            observation: AdapterObservation::ResponseObservation { .. },
            ..
        }
    ));
}

#[test]
fn blocking_work_beyond_the_limit_runs_on_a_bounded_pool() -> TestResult {
    let capability = CooperativeCancellation::default().capability();
    let peer = KeepAlivePeer::start(true)?;
    let adapter = UreqHttpAdapter::default();
    let limit = adapter.blocking.limit();
    let mut started = Vec::new();
    for _ in 0..limit + 4 {
        let (_, attempt) = dispatched(&adapter, &peer.target, Some(capability.clone()))?;
        started.push(attempt);
    }
    wait_for("the peer to accept", || peer.accepted() >= limit)?;
    peer.release();
    for attempt in &started {
        assert_response(await_delivery(&adapter, attempt)?);
    }
    assert!(adapter.blocking.spawned() >= 1);
    assert!(adapter.blocking.spawned() <= limit);
    Ok(())
}

#[test]
fn cancelled_resolutions_beyond_the_limit_keep_the_pool_bounded() -> TestResult {
    let capability = CooperativeCancellation::default().capability();
    let peer = KeepAlivePeer::start(false)?;
    let port = peer
        .target
        .rsplit_once(':')
        .and_then(|(_, tail)| tail.split_once('/'))
        .map(|(port, _)| port.to_owned())
        .ok_or("peer port")?;
    let target = format!("http://localhost:{port}/shared-agent");
    let (adapter, names) = held_names(true);
    let limit = adapter.blocking.limit();
    for wave in 0..3 {
        let mut attempts = Vec::new();
        for _ in 0..limit {
            attempts.push(dispatched(&adapter, &target, Some(capability.clone()))?);
        }
        if wave == 0 {
            wait_for("every thread to hold a resolution", || {
                names.calls() == limit
            })?;
        } else {
            wait_for("the waiting jobs to queue", || {
                adapter.blocking.queued() == wave * limit
            })?;
        }
        for (state, attempt) in attempts {
            cancel_started(&adapter, state, &attempt)?;
        }
    }
    assert!(adapter.blocking.spawned() <= limit);
    names.release();
    wait_for("the queue to drain", || adapter.blocking.queued() == 0)?;
    let started = started_attempt(&adapter, &target)?;
    assert_response(await_delivery(&adapter, &started)?);
    assert!(adapter.blocking.spawned() <= limit);
    Ok(())
}

#[test]
fn a_job_cancelled_in_the_queue_never_resolves() -> TestResult {
    let capability = CooperativeCancellation::default().capability();
    let (adapter, names) = held_names(false);
    let limit = adapter.blocking.limit();
    let mut attempts = Vec::new();
    for _ in 0..limit {
        attempts.push(dispatched(
            &adapter,
            "http://held-name.invalid:80/",
            Some(capability.clone()),
        )?);
    }
    wait_for("every thread to hold a resolution", || {
        names.calls() == limit
    })?;
    for (state, attempt) in attempts {
        cancel_started(&adapter, state, &attempt)?;
    }
    let (state, queued) = dispatched(&adapter, "http://held-name.invalid:80/", Some(capability))?;
    wait_for("the job to queue", || adapter.blocking.queued() == 1)?;
    cancel_started(&adapter, state, &queued)?;
    names.release();
    wait_for("the queue to drain", || adapter.blocking.queued() == 0)?;
    thread::sleep(Duration::from_millis(200));
    assert_eq!(names.calls(), limit);
    Ok(())
}

#[test]
fn released_and_unknown_handles_return_unknown_execution() -> TestResult {
    let capability = CooperativeCancellation::default().capability();
    let peer = KeepAlivePeer::start(false)?;
    let adapter = UreqHttpAdapter::default();
    let (state, started) = dispatched(&adapter, &peer.target, Some(capability.clone()))?;
    let delivered = await_delivery(&adapter, &started)?;
    let NetworkStep::Terminal(state, _) = observe(state, delivered) else {
        return Err("terminal".into());
    };
    let decision = release_when_idle(&adapter, &state, &started)?;
    assert!(matches!(decision, ErasureDecision::Dematerialize(_)));
    let unknown = UnknownExecution {
        handle: started.handle.clone(),
    };
    assert_eq!(adapter.observe(&started), Err(unknown.clone()));
    assert_eq!(adapter.close(&started), Err(unknown.clone()));
    assert_eq!(
        adapter.cancel(CancelCommand {
            attempt: started.prepared.input.attempt.clone(),
            handle: started.handle.clone(),
            capability,
        }),
        Err(unknown)
    );
    let never_started = StartedAttempt {
        prepared: started.prepared.clone(),
        handle: ExecutionHandle {
            value: "never-started".into(),
        },
    };
    assert_eq!(
        adapter.observe(&never_started),
        Err(UnknownExecution {
            handle: never_started.handle.clone()
        })
    );
    Ok(())
}

#[test]
fn one_hundred_requests_to_one_host_reuse_one_connection() -> TestResult {
    let peer = KeepAlivePeer::start(false)?;
    let adapter = UreqHttpAdapter::default();
    for _ in 0..100 {
        let started = started_attempt(&adapter, &peer.target)?;
        let HostObservation::Delivered { observation, .. } = await_delivery(&adapter, &started)?
        else {
            return Err("delivered".into());
        };
        assert!(matches!(
            observation,
            AdapterObservation::ResponseObservation { .. }
        ));
    }
    assert_eq!(peer.accepted(), 1);
    Ok(())
}

#[test]
fn requests_beyond_the_worker_limit_stay_pending_then_complete() -> TestResult {
    let capability = CooperativeCancellation::default().capability();
    let peer = KeepAlivePeer::start(true)?;
    let adapter = UreqHttpAdapter::default();
    let total = worker_limit() + 4;
    let mut started = Vec::new();
    for _ in 0..total {
        let mut attempt = input();
        attempt.instruction.target = peer.target.clone();
        attempt.configuration.cancellation = Some(capability.clone());
        let PrepareStep::Prepared(state, prepared) =
            prepare(NetworkState::default(), Arc::new(attempt))
        else {
            return Err("prepare".into());
        };
        let CommandStep::CommandReady(_, command) = send_command(state, prepared) else {
            return Err("send command".into());
        };
        let prepared = command.prepared.clone();
        let StartObservation::Started { handle, .. } = adapter.start(command) else {
            return Err("start failed".into());
        };
        started.push(StartedAttempt { prepared, handle });
    }
    for _ in 0..200 {
        if peer.accepted() >= worker_limit() {
            break;
        }
        thread::sleep(Duration::from_millis(5));
    }
    thread::sleep(Duration::from_millis(100));
    assert!(peer.accepted() <= worker_limit());
    for attempt in &started {
        assert!(matches!(
            adapter.observe(attempt)?,
            HostObservation::Pending { .. }
        ));
    }

    let cancelled = started.get(total - 2).ok_or("queued attempt")?;
    let HostObservation::Delivered {
        delivery,
        observation: AdapterObservation::CancellationObservation { .. },
    } = adapter.cancel(CancelCommand {
        attempt: cancelled.prepared.input.attempt.clone(),
        handle: cancelled.handle.clone(),
        capability: capability.clone(),
    })?
    else {
        return Err("queued cancel".into());
    };
    assert_eq!(delivery, 0u8.into());
    let closed = started.get(total - 1).ok_or("queued attempt")?;
    let HostObservation::Delivered {
        delivery,
        observation:
            AdapterObservation::FailureObservation {
                failure:
                    NetworkHostFailure {
                        cause: HostFailure::HostClosed,
                        ..
                    },
                ..
            },
    } = adapter.close(closed)?
    else {
        return Err("queued close".into());
    };
    assert_eq!(delivery, 0u8.into());

    peer.release();
    for attempt in started.iter().take(total - 2) {
        await_delivery(&adapter, attempt)?;
    }
    for attempt in started.iter().skip(total - 2) {
        await_stopped(&adapter, attempt)?;
        assert!(matches!(
            adapter.observe(attempt)?,
            HostObservation::Pending { .. }
        ));
    }
    Ok(())
}

#[derive(Debug)]
struct PanickingResolver;

impl ureq::unversioned::resolver::Resolver for PanickingResolver {
    fn resolve(
        &self,
        _uri: &ureq::http::Uri,
        _config: &ureq::config::Config,
        _timeout: ureq::unversioned::transport::NextTimeout,
    ) -> Result<ureq::unversioned::resolver::ResolvedSocketAddrs, ureq::Error> {
        assert_eq!(1 + 1, 3, "resolver failure");
        Err(ureq::Error::HostNotFound)
    }
}

#[test]
fn an_unclassified_failure_in_the_worker_keeps_the_stage_it_reached() -> TestResult {
    let adapter = UreqHttpAdapter::with_resolver(
        SystemMonotonicClock::new(ClockBasis {
            value: "resolver-panic-test".to_owned(),
        }),
        CooperativeCancellation::default(),
        PanickingResolver,
    );
    let (_, started) = dispatched(&adapter, "http://127.0.0.1:9/", None)?;
    let execution = adapter.execution(&started.handle).ok_or("execution")?;
    for _ in 0..20_000 {
        if execution.has_queued() {
            break;
        }
        thread::sleep(Duration::from_micros(200));
    }
    let HostObservation::Delivered {
        observation: AdapterObservation::FailureObservation { failure, .. },
        ..
    } = execution.poll()
    else {
        return Err("failure observation".into());
    };
    assert_eq!(failure.cause, HostFailure::HostRuntimeFailure);
    assert_eq!(failure.stage, HostStage::ResponseHeaders);
    Ok(())
}

#[derive(Debug)]
struct FlakyResolver {
    calls: Arc<AtomicUsize>,
}

impl ureq::unversioned::resolver::Resolver for FlakyResolver {
    fn resolve(
        &self,
        uri: &ureq::http::Uri,
        config: &ureq::config::Config,
        timeout: ureq::unversioned::transport::NextTimeout,
    ) -> Result<ureq::unversioned::resolver::ResolvedSocketAddrs, ureq::Error> {
        if self.calls.fetch_add(1, Ordering::SeqCst) == 0 {
            assert_eq!(1 + 1, 3, "resolver failure");
        }
        ureq::unversioned::resolver::DefaultResolver::default().resolve(uri, config, timeout)
    }
}

fn assert_worker_failure_and_release<
    C: MonotonicClockPort + 'static,
    X: CancellationPort + 'static,
>(
    adapter: &UreqHttpAdapter<C, X>,
    target: &str,
) -> TestResult {
    let (state, started) = dispatched(adapter, target, None)?;
    let delivered = await_delivery(adapter, &started)?;
    let HostObservation::Delivered {
        observation: AdapterObservation::FailureObservation { failure, .. },
        ..
    } = &delivered
    else {
        return Err("failure observation".into());
    };
    assert_eq!(failure.cause, HostFailure::HostRuntimeFailure);
    assert_eq!(failure.stage, HostStage::ResponseHeaders);
    let NetworkStep::Terminal(state, _) = observe(state, delivered) else {
        return Err("terminal".into());
    };
    let decision = release_when_idle(adapter, &state, &started)?;
    assert!(matches!(decision, ErasureDecision::Dematerialize(_)));
    assert_eq!(adapter.record_count(), 0);
    Ok(())
}

#[test]
fn a_name_resolution_panic_without_a_deadline_is_a_worker_failure() -> TestResult {
    let adapter = UreqHttpAdapter::with_resolver(
        SystemMonotonicClock::new(ClockBasis {
            value: "resolution-panic-test".to_owned(),
        }),
        CooperativeCancellation::default(),
        PanickingResolver,
    );
    assert_worker_failure_and_release(&adapter, "http://localhost:9/")
}

#[test]
fn a_connect_panic_without_a_deadline_is_a_worker_failure() -> TestResult {
    let peer = KeepAlivePeer::start(false)?;
    let adapter = UreqHttpAdapter::with_connect(
        SystemMonotonicClock::new(ClockBasis {
            value: "connect-panic-test".to_owned(),
        }),
        CooperativeCancellation::default(),
        ureq::unversioned::resolver::DefaultResolver::default(),
        |_| {
            assert_eq!(1 + 1, 3, "connect failure");
            Err(std::io::ErrorKind::Other.into())
        },
    );
    assert_worker_failure_and_release(&adapter, &peer.target)
}

#[test]
fn the_pool_accepts_work_after_a_name_resolution_panic() -> TestResult {
    let peer = KeepAlivePeer::start(false)?;
    let port = peer.target.rsplit(':').next().ok_or("port")?;
    let target = format!("http://localhost:{port}");
    let adapter = UreqHttpAdapter::with_resolver(
        SystemMonotonicClock::new(ClockBasis {
            value: "resolution-recovery-test".to_owned(),
        }),
        CooperativeCancellation::default(),
        FlakyResolver {
            calls: Arc::new(AtomicUsize::new(0)),
        },
    );
    assert_worker_failure_and_release(&adapter, &target)?;
    let (_, started) = dispatched(&adapter, &target, None)?;
    let HostObservation::Delivered {
        observation: AdapterObservation::FailureObservation { .. },
        ..
    } = await_delivery(&adapter, &started)?
    else {
        return Ok(());
    };
    Err("second request failed".into())
}

#[test]
fn the_pool_accepts_work_after_a_connect_panic() -> TestResult {
    let peer = KeepAlivePeer::start(false)?;
    let calls = Arc::new(AtomicUsize::new(0));
    let adapter = {
        let calls = Arc::clone(&calls);
        UreqHttpAdapter::with_connect(
            SystemMonotonicClock::new(ClockBasis {
                value: "connect-recovery-test".to_owned(),
            }),
            CooperativeCancellation::default(),
            ureq::unversioned::resolver::DefaultResolver::default(),
            move |address| {
                if calls.fetch_add(1, Ordering::SeqCst) == 0 {
                    assert_eq!(1 + 1, 3, "connect failure");
                }
                TcpStream::connect(address)
            },
        )
    };
    assert_worker_failure_and_release(&adapter, &peer.target)?;
    let (_, started) = dispatched(&adapter, &peer.target, None)?;
    let HostObservation::Delivered {
        observation: AdapterObservation::FailureObservation { .. },
        ..
    } = await_delivery(&adapter, &started)?
    else {
        return Ok(());
    };
    Err("second request failed".into())
}

#[test]
fn an_unclassified_transport_error_keeps_the_current_stage() {
    let error = ureq::Error::TooManyRedirects;
    assert_eq!(
        classify_transport(&error, HostStage::ResponseHeaders),
        (HostStage::ResponseHeaders, HostFailure::HostRuntimeFailure)
    );
    assert_eq!(
        classify_transport(&error, HostStage::ResponseBody),
        (HostStage::ResponseBody, HostFailure::HostRuntimeFailure)
    );
    let io = std::io::Error::other("unclassified");
    assert_eq!(
        classify_io_transport(&io, HostStage::RequestWrite),
        (HostStage::RequestWrite, HostFailure::HostRuntimeFailure)
    );
}

#[test]
fn start_checks_run_in_the_fixed_order() {
    let adapter = UreqHttpAdapter::default();
    let clock = SystemMonotonicClock::new(ClockBasis {
        value: "order".to_owned(),
    })
    .capability();
    let foreign_cancel = CancellationCapability {
        identity: OpaqueEvidence {
            value: "foreign".to_owned(),
        },
    };
    let mut attempt = input();
    attempt.configuration.request_body_limit = 4u8.into();
    attempt.configuration.cancellation = Some(foreign_cancel);
    attempt.deadline = Some(Deadline {
        clock_basis: clock.clock_basis.clone(),
        limit: 1u8.into(),
        capability: clock.clone(),
    });
    attempt.configuration.monotonic_clock = Some(clock);
    attempt.instruction.target = "ftp://127.0.0.1/".to_owned();
    attempt.instruction.body = vec![0u8; 8];
    assert_eq!(
        adapter.start_validation_failure(&attempt),
        Some(HostFailure::UnsupportedUriScheme)
    );
    attempt.instruction.target = "http://127.0.0.1/".to_owned();
    assert_eq!(
        adapter.start_validation_failure(&attempt),
        Some(HostFailure::InvalidHostConfiguration)
    );
    attempt.instruction.body = Vec::new();
    assert_eq!(
        adapter.start_validation_failure(&attempt),
        Some(HostFailure::DeadlineControlUnavailable)
    );
    attempt.deadline = None;
    attempt.configuration.monotonic_clock = None;
    assert_eq!(
        adapter.start_validation_failure(&attempt),
        Some(HostFailure::InvalidHostConfiguration)
    );
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
                value: "test-handle".into(),
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
            let (outer, failure) = classify_test_fault(TestHostFault::LibraryTimeout(stage, cause));
            assert_eq!(outer, stage);
            assert_eq!(failure, HostFailure::Timeout { stage, cause });
            let input = issued_input()?;
            let observation = failure_observation(
                &input,
                &ExecutionHandle {
                    value: "timeout-handle".into(),
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

const WAITER_LIMIT: Duration = Duration::from_secs(5);

fn spawn_waiter<C, X>(
    adapter: &Arc<UreqHttpAdapter<C, X>>,
    started: &StartedAttempt,
) -> TestResult<mpsc::Receiver<bool>>
where
    C: MonotonicClockPort + Send + Sync + 'static,
    X: CancellationPort + Send + Sync + 'static,
{
    let baseline = adapter.observe_calls.load(Ordering::SeqCst);
    let (sender, receiver) = mpsc::channel();
    let waiter = Arc::clone(adapter);
    let handle = started.handle.clone();
    let started = started.clone();
    thread::spawn(move || {
        let unknown = matches!(
            waiter.wait_observation(&started),
            Err(WaitFailure::Unknown(UnknownExecution { handle: unknown })) if unknown == handle
        );
        let _ = sender.send(unknown);
    });
    for _ in 0..5000 {
        if adapter.observe_calls.load(Ordering::SeqCst) > baseline {
            return Ok(receiver);
        }
        thread::sleep(Duration::from_millis(1));
    }
    Err("waiter never started waiting".into())
}

fn assert_waiter_returns_unknown(receiver: &mpsc::Receiver<bool>) -> TestResult {
    let unknown = receiver
        .recv_timeout(WAITER_LIMIT)
        .map_err(|_| "waiter did not return within the limit")?;
    assert!(unknown);
    Ok(())
}

#[test]
fn a_waiter_returns_unknown_when_the_record_is_removed_after_a_terminal_release() -> TestResult {
    let peer = KeepAlivePeer::start(true)?;
    let (adapter, capability) = rejecting_adapter();
    let adapter = Arc::new(adapter);
    let (state, started) = dispatched(&*adapter, &peer.target, Some(capability))?;
    await_request_at_peer(&peer)?;
    let CommandStep::CommandReady(state, command) = cancel_command(state, started.clone()) else {
        return Err("cancel command".into());
    };
    let rejected = adapter.cancel(command)?;
    assert_cancel_rejected(&rejected);
    let NetworkStep::Terminal(state, _) = observe(state, rejected) else {
        return Err("rejected cancel terminal".into());
    };
    let receiver = spawn_waiter(&adapter, &started)?;
    let decision = adapter.release(&state, &started);
    assert!(matches!(
        decision,
        ErasureDecision::Retain(_) | ErasureDecision::Dematerialize(_)
    ));
    assert_waiter_returns_unknown(&receiver)?;
    assert_eq!(adapter.record_count(), 0);
    Ok(())
}

#[test]
fn a_waiter_returns_unknown_when_a_finished_worker_is_released_and_dematerialized() -> TestResult {
    let peer = KeepAlivePeer::start(false)?;
    let adapter = Arc::new(UreqHttpAdapter::default());
    let (state, started) = dispatched(&*adapter, &peer.target, None)?;
    let delivered = await_delivery(&*adapter, &started)?;
    let NetworkStep::Terminal(state, _) = observe(state, delivered) else {
        return Err("terminal".into());
    };
    for _ in 0..5000 {
        let finished = adapter
            .execution(&started.handle)
            .is_some_and(|execution| execution.lifecycle() == Lifecycle::Finished);
        if finished {
            break;
        }
        thread::sleep(Duration::from_millis(1));
    }
    let execution = adapter.execution(&started.handle).ok_or("execution")?;
    assert_eq!(execution.lifecycle(), Lifecycle::Finished);
    drop(execution);
    let receiver = spawn_waiter(&adapter, &started)?;
    let decision = adapter.release(&state, &started);
    assert!(matches!(decision, ErasureDecision::Dematerialize(_)));
    assert_waiter_returns_unknown(&receiver)?;
    assert_eq!(adapter.record_count(), 0);
    Ok(())
}

#[test]
fn release_right_after_terminal_removes_the_record_once_over_many_trials() -> TestResult {
    let peer = KeepAlivePeer::start(false)?;
    let adapter = UreqHttpAdapter::default();
    for _ in 0..300 {
        let (state, started) = dispatched(&adapter, &peer.target, None)?;
        let delivered = await_delivery(&adapter, &started)?;
        let NetworkStep::Terminal(state, _) = observe(state, delivered) else {
            return Err("terminal".into());
        };
        let decision = adapter.release(&state, &started);
        assert!(!matches!(decision, ErasureDecision::Rejected(_)));
        let mut waited = 0;
        while adapter.record_count() != 0 && waited < 5000 {
            thread::sleep(Duration::from_millis(1));
            waited += 1;
        }
        assert_eq!(adapter.record_count(), 0);
        assert!(matches!(
            adapter.observe(&started),
            Err(UnknownExecution { .. })
        ));
    }
    Ok(())
}
