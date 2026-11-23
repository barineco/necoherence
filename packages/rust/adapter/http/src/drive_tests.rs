// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT
#![allow(
    clippy::expect_used,
    clippy::indexing_slicing,
    clippy::panic,
    clippy::result_large_err,
    clippy::unwrap_used
)]

use super::*;
use necoherence::network_effect::NetworkState;
use necoherence::semantic_composition as composition;
use necoherence::semantic_execution as execution;
use necoherence::semantic_types::*;
use std::io::Write;
use std::net::{TcpListener, TcpStream};
use std::sync::atomic::AtomicBool;
use std::time::Duration;

#[path = "../../tests/fixtures/semantic_execution_samples.rs"]
#[allow(dead_code, unused_imports, clippy::all, clippy::pedantic)]
mod samples;

struct DelayPeer {
    target: String,
    stop: Arc<AtomicBool>,
    gate: Arc<AtomicBool>,
    worker: Option<thread::JoinHandle<()>>,
}

impl DelayPeer {
    fn start(delay: Duration) -> std::io::Result<Self> {
        Self::start_gated(delay, true)
    }

    fn start_held() -> std::io::Result<Self> {
        Self::start_gated(Duration::ZERO, false)
    }

    fn start_gated(delay: Duration, open: bool) -> std::io::Result<Self> {
        let listener = TcpListener::bind("127.0.0.1:0")?;
        listener.set_nonblocking(true)?;
        let address = listener.local_addr()?;
        let stop = Arc::new(AtomicBool::new(false));
        let gate = Arc::new(AtomicBool::new(open));
        let worker = {
            let stop = Arc::clone(&stop);
            let gate = Arc::clone(&gate);
            thread::spawn(move || {
                while !stop.load(Ordering::SeqCst) {
                    match listener.accept() {
                        Ok((stream, _)) => {
                            let gate = Arc::clone(&gate);
                            thread::spawn(move || {
                                let _ = serve(stream, delay, &gate);
                            });
                        }
                        Err(_) => thread::sleep(Duration::from_millis(1)),
                    }
                }
            })
        };
        Ok(Self {
            target: format!("http://{address}/drive"),
            stop,
            gate,
            worker: Some(worker),
        })
    }

    fn release(&self) {
        self.gate.store(true, Ordering::SeqCst);
    }
}

impl Drop for DelayPeer {
    fn drop(&mut self) {
        self.release();
        self.stop.store(true, Ordering::SeqCst);
        if let Some(worker) = self.worker.take() {
            let _ = worker.join();
        }
    }
}

fn serve(mut stream: TcpStream, delay: Duration, gate: &AtomicBool) -> std::io::Result<()> {
    stream.set_nonblocking(false)?;
    let mut buffer: Vec<u8> = Vec::new();
    let mut chunk = [0u8; 1024];
    loop {
        let read = stream.read(&mut chunk)?;
        if read == 0 {
            return Ok(());
        }
        buffer.extend_from_slice(&chunk[..read]);
        while let Some(end) = buffer.windows(4).position(|window| window == b"\r\n\r\n") {
            buffer.drain(..end + 4);
            thread::sleep(delay);
            while !gate.load(Ordering::SeqCst) {
                thread::sleep(Duration::from_millis(1));
            }
            stream.write_all(b"HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n")?;
        }
    }
}

fn provider_with(
    reference: &composition::FunctionRef,
    target: &str,
    deadline: Option<Deadline>,
) -> execution::Provider {
    let mut input = samples::attempt_input();
    input.instruction.target = target.to_owned();
    if let Some(deadline) = deadline {
        input.configuration.monotonic_clock = Some(deadline.capability.clone());
        input.deadline = Some(deadline);
    }
    let input = Arc::new(input);
    execution::Provider {
        reference: reference.clone(),
        implementation: execution::ProviderImplementation::PreparedHttp(
            execution::PreparedNetworkOwner {
                prepare: Arc::new(move |_| Ok(execution::PreparedCall::Ready(Arc::clone(&input)))),
                decode: Arc::new(|_| {
                    Ok(execution::CallResult {
                        outcome: composition::OutcomeId("success".into()),
                        outputs: vec![(
                            composition::PortId("output".into()),
                            SlotValue::Present(JsonValue::Bool(true)),
                        )],
                    })
                }),
            },
        ),
    }
}

fn with_run<T>(
    body: impl FnOnce(&execution::PreparedRun<'_>, &composition::FunctionRef) -> T,
) -> T {
    let checked = samples::admitted(samples::HTTP);
    let preparation = checked.prepare_admission().unwrap().unwrap();
    let reference = samples::operation_reference(preparation.prepared());
    let run = execution::PreparedRun::new(preparation.admitted());
    body(&run, &reference)
}

fn first<'r, 'g>(
    run: &'r execution::PreparedRun<'g>,
    reference: &composition::FunctionRef,
    target: &str,
) -> Progress<'r, 'g> {
    first_with(run, reference, target, None)
}

fn first_with<'r, 'g>(
    run: &'r execution::PreparedRun<'g>,
    reference: &composition::FunctionRef,
    target: &str,
    deadline: Option<Deadline>,
) -> Progress<'r, 'g> {
    execution::start(
        run,
        run.workspace(),
        vec![provider_with(reference, target, deadline)],
        vec![samples::argument_true()],
        NetworkState::default(),
    )
    .unwrap()
}

fn manual<'r>(adapter: &UreqHttpAdapter, first: Progress<'r, '_>) -> ExecutionResult<'r> {
    let mut progress = first;
    loop {
        match progress {
            Progress::Completed(result, _) => return result,
            Progress::Pending(pending, NetworkInstruction::Send) => {
                let command = pending.send_command().cloned().unwrap();
                let start = adapter.start(command);
                progress = resume(pending, ExecutionObservation::Start(start)).unwrap();
            }
            Progress::Pending(pending, NetworkInstruction::Observe) => {
                let started = pending.observed_attempt().cloned().unwrap();
                let host = loop {
                    match adapter.observe(&started).unwrap() {
                        delivered @ HostObservation::Delivered { .. } => break delivered,
                        HostObservation::Pending { .. } => thread::sleep(Duration::from_millis(1)),
                    }
                };
                progress = resume(pending, ExecutionObservation::Host(host)).unwrap();
            }
        }
    }
}

const REPEATS: usize = 500;

#[test]
fn drive_releases_every_record_and_matches_the_manual_loop() {
    let peer = DelayPeer::start(Duration::ZERO).unwrap();
    let adapter = UreqHttpAdapter::default();
    with_run(|run, reference| {
        let expected = manual(&adapter, first(run, reference, &peer.target));
        assert_eq!(adapter.record_count(), 1);
        for _ in 0..REPEATS {
            let driven = drive(&adapter, first(run, reference, &peer.target)).unwrap();
            assert_eq!(driven.retained, Vec::<StartedAttempt>::new());
            assert_eq!(driven.result, expected);
        }
    });
    assert_eq!(adapter.record_count(), 1);
}

#[test]
fn drive_alone_leaves_no_registration() {
    let peer = DelayPeer::start(Duration::ZERO).unwrap();
    let adapter = UreqHttpAdapter::default();
    with_run(|run, reference| {
        for _ in 0..REPEATS {
            let driven = drive(&adapter, first(run, reference, &peer.target)).unwrap();
            assert!(driven.retained.is_empty());
        }
    });
    assert_eq!(adapter.record_count(), 0);
}

fn observe_calls_for(delay: Duration) -> u64 {
    let peer = DelayPeer::start(delay).unwrap();
    let adapter = UreqHttpAdapter::default();
    with_run(|run, reference| {
        let driven = drive(&adapter, first(run, reference, &peer.target)).unwrap();
        assert!(driven.retained.is_empty());
    });
    adapter.observe_calls.load(Ordering::Relaxed)
}

#[test]
fn waiting_does_not_poll_at_a_fixed_interval() {
    let short = observe_calls_for(Duration::from_millis(150));
    let long = observe_calls_for(Duration::from_millis(300));
    assert_eq!(short, long);
    assert!(short <= 2, "{short}");
}

struct ManualClock {
    capability: MonotonicClockCapability,
    value: Natural,
}

impl MonotonicClockPort for ManualClock {
    fn capability(&self) -> MonotonicClockCapability {
        self.capability.clone()
    }

    fn observe(&self) -> Result<MonotonicClockObservation, HostFailure> {
        Ok(MonotonicClockObservation {
            clock_basis: self.capability.clock_basis.clone(),
            value: self.value.clone(),
        })
    }
}

struct UntilPanickingClock {
    capability: MonotonicClockCapability,
}

impl MonotonicClockPort for UntilPanickingClock {
    fn capability(&self) -> MonotonicClockCapability {
        self.capability.clone()
    }

    fn observe(&self) -> Result<MonotonicClockObservation, HostFailure> {
        Ok(MonotonicClockObservation {
            clock_basis: self.capability.clock_basis.clone(),
            value: 0u8.into(),
        })
    }

    fn until(&self, _limit: &Natural) -> Option<Duration> {
        assert_eq!(1 + 1, 3, "clock until failure");
        None
    }
}

#[derive(Debug, PartialEq)]
enum Seen {
    Success,
    DeadlineExceeded(Natural),
    WaitUnavailable,
    Failed(HostStage, HostFailure),
    Other,
}

fn deadline_after<C: MonotonicClockPort>(clock: &C, millis: u64) -> Deadline {
    let capability = clock.capability();
    let now = clock.observe().unwrap().value.to_u64().unwrap();
    Deadline {
        clock_basis: capability.clock_basis.clone(),
        limit: (now + millis).into(),
        capability,
    }
}

fn drive_deadline<C: MonotonicClockPort + 'static>(
    adapter: &Arc<UreqHttpAdapter<C>>,
    target: &str,
    deadline: Deadline,
    within: Duration,
) -> (Seen, usize, Duration) {
    let (sender, receiver) = mpsc::channel();
    let adapter = Arc::clone(adapter);
    let target = target.to_owned();
    thread::spawn(move || {
        let began = Instant::now();
        let seen = with_run(|run, reference| {
            match drive(
                &adapter,
                first_with(run, reference, &target, Some(deadline)),
            ) {
                Ok(driven) if matches!(driven.result, ExecutionResult::Success(_)) => {
                    (Seen::Success, driven.retained.len())
                }
                Ok(driven) => (Seen::Other, driven.retained.len()),
                Err(failure) => match failure.cause {
                    DriveCause::DeadlineWaitUnavailable => {
                        (Seen::WaitUnavailable, failure.retained.len())
                    }
                    DriveCause::Run(run_failure) => match run_failure.cause {
                        execution::ExecutionFailure::NetworkTerminal(NetworkTerminal {
                            outcome:
                                NetworkOutcome::DeadlineExceeded {
                                    observed_at: MonotonicClockObservation { value, .. },
                                    ..
                                },
                            ..
                        }) => (Seen::DeadlineExceeded(value), failure.retained.len()),
                        execution::ExecutionFailure::NetworkTerminal(NetworkTerminal {
                            outcome: NetworkOutcome::Failed { failure: host },
                            ..
                        }) => (Seen::Failed(host.stage, host.cause), failure.retained.len()),
                        _ => (Seen::Other, failure.retained.len()),
                    },
                    _ => (Seen::Other, failure.retained.len()),
                },
            }
        });
        let _ = sender.send((seen.0, seen.1, began.elapsed()));
    });
    receiver
        .recv_timeout(within)
        .unwrap_or_else(|error| panic!("drive did not return within {within:?}: {error:?}"))
}

#[test]
fn deadline_ends_a_wait_on_a_held_peer() {
    let peer = DelayPeer::start_held().unwrap();
    let adapter = Arc::new(UreqHttpAdapter::default());
    let deadline = deadline_after(adapter.clock.as_ref(), 300);
    let limit = deadline.limit.clone();
    let (seen, retained, _) =
        drive_deadline(&adapter, &peer.target, deadline, Duration::from_secs(2));
    let Seen::DeadlineExceeded(observed) = seen else {
        panic!("expected the deadline terminal: {seen:?}");
    };
    let late = observed.to_u64().unwrap() - limit.to_u64().unwrap();
    assert!(late < 250, "deadline observed {late} ms after the limit");
    assert_eq!(retained, 0);
    let began = Instant::now();
    while adapter.record_count() != 0 {
        assert!(
            began.elapsed() < Duration::from_secs(2),
            "the record stayed while the peer was held"
        );
        thread::sleep(Duration::from_millis(5));
    }
}

#[test]
fn response_before_the_deadline_completes() {
    let peer = DelayPeer::start(Duration::from_millis(100)).unwrap();
    let adapter = Arc::new(UreqHttpAdapter::default());
    let deadline = deadline_after(adapter.clock.as_ref(), 300);
    let (seen, retained, _) =
        drive_deadline(&adapter, &peer.target, deadline, Duration::from_secs(3));
    assert_eq!(seen, Seen::Success);
    assert_eq!(retained, 0);
    assert_eq!(adapter.record_count(), 0);
    let calls = adapter.observe_calls.load(Ordering::Relaxed);
    assert!(calls <= 3, "{calls}");
}

#[test]
fn a_clock_until_panic_ends_the_drive_with_a_host_failure() {
    let peer = DelayPeer::start_held().unwrap();
    let capability = MonotonicClockCapability {
        identity: OpaqueEvidence {
            value: "until-panic-clock".to_owned(),
        },
        clock_basis: ClockBasis {
            value: "until-panic".to_owned(),
        },
    };
    let clock = UntilPanickingClock { capability };
    let deadline = deadline_after(&clock, 300);
    let adapter = Arc::new(UreqHttpAdapter::new(
        clock,
        CooperativeCancellation::default(),
    ));
    let (seen, _, _) = drive_deadline(&adapter, &peer.target, deadline, Duration::from_secs(1));
    assert_eq!(
        seen,
        Seen::Failed(HostStage::Deadline, HostFailure::HostRuntimeFailure)
    );
    let began = Instant::now();
    while adapter.record_count() != 0 {
        assert!(
            began.elapsed() < Duration::from_secs(2),
            "the record stayed while the peer was held"
        );
        thread::sleep(Duration::from_millis(5));
    }
    peer.release();
}

#[test]
fn deadline_without_a_wait_length_fails_typed_without_waiting() {
    let peer = DelayPeer::start_held().unwrap();
    let capability = MonotonicClockCapability {
        identity: OpaqueEvidence {
            value: "manual-clock".to_owned(),
        },
        clock_basis: ClockBasis {
            value: "manual".to_owned(),
        },
    };
    let clock = ManualClock {
        capability,
        value: 0u8.into(),
    };
    let deadline = deadline_after(&clock, 300);
    let adapter = Arc::new(UreqHttpAdapter::new(
        clock,
        CooperativeCancellation::default(),
    ));
    let (seen, retained, _) =
        drive_deadline(&adapter, &peer.target, deadline, Duration::from_secs(1));
    assert_eq!(seen, Seen::WaitUnavailable);
    assert_eq!(retained, 1);
    peer.release();
}
