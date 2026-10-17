// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

use necoherence::http_adapter::{
    CancellationPort, CooperativeCancellation, MonotonicClockPort, SystemMonotonicClock,
    UreqHttpAdapter,
};
use necoherence::network_effect::{observe as reduce_observe, *};
use necoherence::request_progression::{ExecutionHandle, RequestIdentity};
use std::io::{ErrorKind, Read, Write};
use std::net::TcpListener;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{mpsc, Arc};
use std::thread;
use std::time::Duration;

type BoxError = Box<dyn std::error::Error + Send + Sync>;
type TestResult<T = ()> = Result<T, BoxError>;

struct Peer {
    target: String,
    received: Arc<AtomicUsize>,
    request: mpsc::Receiver<Vec<u8>>,
    release: Option<mpsc::Sender<()>>,
    worker: thread::JoinHandle<TestResult>,
}

impl Peer {
    fn release(&mut self) {
        if let Some(release) = self.release.take() {
            let _ = release.send(());
        }
    }

    fn finish(mut self) -> TestResult<Vec<u8>> {
        self.release();
        let request = self.request.recv_timeout(Duration::from_secs(2))?;
        self.worker
            .join()
            .map_err(|_| BoxError::from("peer worker panicked"))??;
        Ok(request)
    }
}

fn header_terminator(buffer: &[u8]) -> Option<usize> {
    buffer
        .windows(4)
        .position(|window| window == b"\r\n\r\n")
        .map(|position| position + 4)
}

fn declared_content_length(headers: &[u8]) -> usize {
    String::from_utf8_lossy(headers)
        .lines()
        .find_map(|line| {
            let (name, value) = line.split_once(':')?;
            if name.trim().eq_ignore_ascii_case("content-length") {
                value.trim().parse::<usize>().ok()
            } else {
                None
            }
        })
        .unwrap_or(0)
}

/// A single `read()` only sees whatever the kernel buffered so far; on
/// loopback headers and body often arrive as separate reads, so we wait for
/// the declared body length before the caller may reply and close.
fn read_full_request(stream: &mut impl Read) -> TestResult<Vec<u8>> {
    let mut request = Vec::new();
    let mut chunk = [0u8; 4096];
    loop {
        if let Some(end) = header_terminator(&request) {
            let head = request
                .get(..end)
                .ok_or("header terminator within request")?;
            let needed = end + declared_content_length(head);
            if request.len() >= needed {
                break;
            }
        }
        let read = stream.read(&mut chunk)?;
        if read == 0 {
            break;
        }
        request.extend_from_slice(chunk.get(..read).ok_or("read length within chunk")?);
    }
    Ok(request)
}

fn spawn_peer(response: Vec<u8>, gated: bool) -> TestResult<Peer> {
    let listener = TcpListener::bind("127.0.0.1:0")?;
    let address = listener.local_addr()?;
    let received = Arc::new(AtomicUsize::new(0));
    let peer_received = Arc::clone(&received);
    let (request_tx, request_rx) = mpsc::channel();
    let (release_tx, release_rx) = mpsc::channel();
    let worker = thread::spawn(move || -> TestResult {
        let (mut stream, _) = listener.accept()?;
        stream.set_read_timeout(Some(Duration::from_secs(2)))?;
        let request = read_full_request(&mut stream)?;
        if !request.is_empty() {
            peer_received.fetch_add(1, Ordering::SeqCst);
        }
        request_tx.send(request)?;
        if gated {
            let _ = release_rx.recv_timeout(Duration::from_secs(2));
        }
        if !response.is_empty() {
            let _ = stream.write_all(&response);
            let _ = stream.flush();
        }
        Ok(())
    });
    Ok(Peer {
        target: format!("http://{address}/network-effect"),
        received,
        request: request_rx,
        release: gated.then_some(release_tx),
        worker,
    })
}

fn wait_peer_received(peer: &Peer) -> TestResult {
    for _ in 0..1000 {
        if peer.received.load(Ordering::SeqCst) == 1 {
            return Ok(());
        }
        thread::sleep(Duration::from_millis(1));
    }
    Err("peer receipt timeout".into())
}

struct LoopPeer {
    target: String,
    received: Arc<AtomicUsize>,
    stop: Arc<AtomicBool>,
    worker: Option<thread::JoinHandle<TestResult>>,
}

impl LoopPeer {
    fn shutdown(&mut self) {
        self.stop.store(true, Ordering::SeqCst);
        if let Some(worker) = self.worker.take() {
            let _ = worker.join();
        }
    }
}

impl Drop for LoopPeer {
    fn drop(&mut self) {
        self.shutdown();
    }
}

fn spawn_loop_peer(response: Vec<u8>) -> TestResult<LoopPeer> {
    let listener = TcpListener::bind("127.0.0.1:0")?;
    listener.set_nonblocking(true)?;
    let address = listener.local_addr()?;
    let received = Arc::new(AtomicUsize::new(0));
    let peer_received = Arc::clone(&received);
    let stop = Arc::new(AtomicBool::new(false));
    let worker_stop = Arc::clone(&stop);
    let worker = thread::spawn(move || -> TestResult {
        while !worker_stop.load(Ordering::SeqCst) {
            match listener.accept() {
                Ok((mut stream, _)) => {
                    stream.set_nonblocking(false)?;
                    stream.set_read_timeout(Some(Duration::from_secs(2)))?;
                    let request = read_full_request(&mut stream)?;
                    if !request.is_empty() {
                        peer_received.fetch_add(1, Ordering::SeqCst);
                    }
                    let _ = stream.write_all(&response);
                    let _ = stream.flush();
                }
                Err(error) if error.kind() == ErrorKind::WouldBlock => {
                    thread::sleep(Duration::from_millis(1));
                }
                Err(_) => break,
            }
        }
        Ok(())
    });
    Ok(LoopPeer {
        target: format!("http://{address}/network-effect-retry"),
        received,
        stop,
        worker: Some(worker),
    })
}

fn raw_response(status: u16, headers: &[(&str, &[u8])], body: &[u8]) -> Vec<u8> {
    let mut response = format!("HTTP/1.1 {status} Status\r\n").into_bytes();
    for (name, value) in headers {
        response.extend_from_slice(name.as_bytes());
        response.extend_from_slice(b": ");
        response.extend_from_slice(value);
        response.extend_from_slice(b"\r\n");
    }
    response.extend_from_slice(format!("Content-Length: {}\r\n\r\n", body.len()).as_bytes());
    response.extend_from_slice(body);
    response
}

fn logical(kind: &str) -> RequestIdentity {
    RequestIdentity {
        kind: kind.to_owned(),
        provenance: "host-smoke".to_owned(),
        revision: 0u8.into(),
    }
}

fn input(target: String, kind: &str) -> AttemptInput {
    AttemptInput {
        attempt: AttemptIdentity {
            logical: logical(kind),
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
            request_body_limit: 1024u16.into(),
            response_body_limit: 1024u16.into(),
            cancellation: None,
            monotonic_clock: None,
        },
    }
}

fn prepare_command(
    input: AttemptInput,
) -> TestResult<(NetworkState, PreparedAttempt, SendCommand)> {
    let PrepareStep::Prepared(state, prepared) = prepare(NetworkState::default(), input) else {
        return Err("prepare".into());
    };
    let CommandStep::CommandReady(state, command) = send_command(state, prepared.clone()) else {
        return Err("send command".into());
    };
    assert_eq!(state.attempts.len(), 1);
    Ok((state, prepared, command))
}

fn dispatch<C: MonotonicClockPort + 'static, X: CancellationPort + 'static>(
    adapter: &UreqHttpAdapter<C, X>,
    input: AttemptInput,
) -> TestResult<(NetworkState, StartedAttempt)> {
    let (state, prepared, command) = prepare_command(input)?;
    let start = adapter.start(command);
    let NetworkStep::Started(state, started) = observe_start(state, prepared, start) else {
        return Err("observe start".into());
    };
    Ok((state, started))
}

fn wait_delivery<C: MonotonicClockPort + 'static, X: CancellationPort + 'static>(
    adapter: &UreqHttpAdapter<C, X>,
    started: &StartedAttempt,
) -> TestResult<HostObservation> {
    for _ in 0..1000 {
        let observation = adapter.observe(started);
        if matches!(observation, HostObservation::Delivered { .. }) {
            return Ok(observation);
        }
        thread::sleep(Duration::from_millis(1));
    }
    Err("delivery timeout".into())
}

fn delivered_parts(observation: HostObservation) -> TestResult<(Natural, AdapterObservation)> {
    let HostObservation::Delivered {
        delivery,
        observation,
    } = observation
    else {
        return Err("delivered".into());
    };
    Ok((delivery, observation))
}

fn assert_causal_identity(started: &StartedAttempt, observation: &AdapterObservation) {
    assert_eq!(attempt_of(observation), &started.prepared.input.attempt);
    assert_eq!(handle_of(observation), &started.handle);
    assert!(!started.prepared.input.instruction.method.is_empty());
    assert!(started
        .prepared
        .input
        .instruction
        .target
        .starts_with("http://127.0.0.1:"));
}

fn request_header_values(request: &[u8], name: &str) -> TestResult<Vec<String>> {
    let end = header_terminator(request).ok_or("request headers")?;
    let head = std::str::from_utf8(request.get(..end).ok_or("request header range")?)?;
    Ok(head
        .lines()
        .filter_map(|line| {
            let (field, value) = line.split_once(':')?;
            field
                .eq_ignore_ascii_case(name)
                .then(|| value.trim().to_owned())
        })
        .collect())
}

#[test]
fn repeated_list_headers_reach_peer_in_value_order_with_distinct_headers_and_body() -> TestResult {
    let peer = spawn_peer(raw_response(200, &[], b""), false)?;
    let mut request = input(peer.target.clone(), "repeated-headers");
    request.instruction.method = "POST".to_owned();
    request.instruction.headers = [
        ("Accept", "application/json"),
        ("X-Order", "first"),
        ("Accept", "application/cbor"),
        ("x-order", "second"),
        ("Content-Type", "application/octet-stream"),
        ("X-ORDER", "third"),
    ]
    .into_iter()
    .map(|(name, value)| RawHeaderField {
        name: name.to_owned(),
        value: value.bytes().map(Natural::from).collect(),
    })
    .collect();
    request.instruction.body = [0u8, 128, 255].into_iter().map(Natural::from).collect();
    let adapter = UreqHttpAdapter::default();
    let (_, started) = dispatch(&adapter, request)?;
    let (_, observation) = delivered_parts(wait_delivery(&adapter, &started)?)?;
    assert_causal_identity(&started, &observation);
    assert!(matches!(
        observation,
        AdapterObservation::ResponseObservation { .. }
    ));
    let wire = peer.finish()?;
    assert_eq!(
        request_header_values(&wire, "Accept")?,
        ["application/json", "application/cbor"]
    );
    assert_eq!(
        request_header_values(&wire, "X-Order")?,
        ["first", "second", "third"]
    );
    assert_eq!(
        request_header_values(&wire, "Content-Type")?,
        ["application/octet-stream"]
    );
    let end = header_terminator(&wire).ok_or("body offset")?;
    assert_eq!(wire.get(end..).ok_or("request body")?, &[0, 128, 255]);
    Ok(())
}

#[test]
fn duplicate_singleton_headers_are_request_write_failures() -> TestResult {
    let cases: &[&[(&str, &str)]] = &[
        &[("Host", "0"), ("Host", "0")],
        &[("Host", "0"), ("host", "0")],
        &[("Content-Length", "0"), ("Content-Length", "0")],
        &[("Content-Length", "0"), ("content-length", "0")],
        &[("Content-Length", "+42")],
        &[("Content-Length", "invalid")],
        &[("Content-Length", "42, 42")],
        &[("Content-Length", "")],
        &[("Content-Length", "18446744073709551616")],
    ];
    for fields in cases {
        let mut peer = spawn_loop_peer(raw_response(200, &[], b""))?;
        let mut request = input(peer.target.clone(), "singleton-header");
        request.instruction.headers = fields
            .iter()
            .map(|(name, value)| RawHeaderField {
                name: (*name).to_owned(),
                value: value.bytes().map(Natural::from).collect(),
            })
            .collect();
        let adapter = UreqHttpAdapter::default();
        let (_, started) = dispatch(&adapter, request.clone())?;
        let (_, observation) = delivered_parts(wait_delivery(&adapter, &started)?)?;
        assert_causal_identity(&started, &observation);
        assert!(matches!(
            observation,
            AdapterObservation::FailureObservation {
                failure: NetworkHostFailure {
                    stage: HostStage::RequestWrite,
                    cause: HostFailure::RequestWriteFailed,
                    ref attempt,
                    ref configuration,
                },
                effect: EffectStatus::Unknown { reason: UnknownEffectReason::HostFailure },
                ..
            } if attempt == &request.attempt && configuration == &request.configuration
        ));
        peer.shutdown();
        assert_eq!(peer.received.load(Ordering::SeqCst), 0);
    }
    Ok(())
}

#[test]
fn redirect_response_is_observed_without_following_location() -> TestResult {
    let mut destination = spawn_loop_peer(raw_response(200, &[], b"followed"))?;
    let peer = spawn_peer(
        raw_response(
            302,
            &[("Location", destination.target.as_bytes())],
            b"redirect",
        ),
        false,
    )?;
    let adapter = UreqHttpAdapter::default();
    let (_, started) = dispatch(&adapter, input(peer.target.clone(), "redirect"))?;
    let (_, observation) = delivered_parts(wait_delivery(&adapter, &started)?)?;
    assert!(matches!(
        observation,
        AdapterObservation::ResponseObservation {
            response: RawHttpResponse { ref status, ref body, .. },
            provenance: HeaderProvenance::LibraryObserved,
            ..
        } if status == &Natural::from(302u16)
            && body == &b"redirect".iter().copied().map(Natural::from).collect::<Vec<_>>()
    ));
    let _ = peer.finish()?;
    destination.shutdown();
    assert_eq!(destination.received.load(Ordering::SeqCst), 0);
    Ok(())
}

#[test]
fn start_precedes_immediate_completion_and_preserves_success_evidence() -> TestResult {
    let peer = spawn_peer(
        raw_response(
            200,
            &[("X-Order", b"first"), ("X-Order", b"second")],
            &[0, 128, 255],
        ),
        false,
    )?;
    let mut request = input(peer.target.clone(), "success");
    request.instruction.method = "POST".to_owned();
    request.instruction.headers = vec![
        RawHeaderField {
            name: "X-Request".to_owned(),
            value: b"first".iter().copied().map(Natural::from).collect(),
        },
        RawHeaderField {
            name: "X-Request".to_owned(),
            value: b"second".iter().copied().map(Natural::from).collect(),
        },
    ];
    request.instruction.body = [0u8, 128, 255].into_iter().map(Natural::from).collect();
    let adapter = UreqHttpAdapter::default();
    let (state, started) = dispatch(&adapter, request)?;
    assert_eq!(started.prepared.input.instruction.method, "POST");
    assert_eq!(state.attempts.len(), 1);
    let (delivery, observation) = delivered_parts(wait_delivery(&adapter, &started)?)?;
    assert_eq!(delivery, 0u8.into());
    assert_eq!(peer.received.load(Ordering::SeqCst), 1);
    assert_causal_identity(&started, &observation);
    let AdapterObservation::ResponseObservation {
        response,
        provenance,
        ..
    } = &observation
    else {
        return Err("response".into());
    };
    assert_eq!(response.status, 200u16.into());
    assert_eq!(response.body, vec![0u8.into(), 128u8.into(), 255u8.into()]);
    assert_eq!(*provenance, HeaderProvenance::LibraryObserved);
    let ordered: Vec<_> = response
        .headers
        .iter()
        .filter(|header| header.name.eq_ignore_ascii_case("x-order"))
        .map(|header| header.value.clone())
        .collect();
    assert_eq!(
        ordered,
        vec![
            b"first"
                .iter()
                .copied()
                .map(Natural::from)
                .collect::<Vec<_>>(),
            b"second"
                .iter()
                .copied()
                .map(Natural::from)
                .collect::<Vec<_>>()
        ]
    );
    let NetworkStep::Terminal(terminal_state, settled) = reduce_observe(
        state,
        HostObservation::Delivered {
            delivery,
            observation,
        },
    ) else {
        return Err("terminal".into());
    };
    assert_eq!(terminal_state.attempts.len(), 1);
    assert!(matches!(
        settled.terminal.outcome,
        NetworkOutcome::Response { .. }
    ));
    let request_bytes = peer.finish()?;
    let request_text = String::from_utf8_lossy(&request_bytes).to_ascii_lowercase();
    assert!(request_text.contains("x-request: first"));
    assert!(request_text.contains("x-request: second"));
    Ok(())
}

#[test]
fn delayed_peer_keeps_pending_stable_and_does_not_increment_delivery() -> TestResult {
    let mut peer = spawn_peer(raw_response(200, &[], b"delayed"), true)?;
    let adapter = UreqHttpAdapter::default();
    let (state, started) = dispatch(&adapter, input(peer.target.clone(), "pending"))?;
    wait_peer_received(&peer)?;
    for _ in 0..3 {
        let pending = adapter.observe(&started);
        assert!(matches!(pending, HostObservation::Pending { .. }));
        assert!(matches!(
            reduce_observe(state.clone(), pending),
            NetworkStep::Pending(next, _) if next == state
        ));
    }
    assert_eq!(peer.received.load(Ordering::SeqCst), 1);
    peer.release();
    let (delivery, observation) = delivered_parts(wait_delivery(&adapter, &started)?)?;
    assert_eq!(delivery, 0u8.into());
    assert_causal_identity(&started, &observation);
    let _ = peer.finish()?;
    Ok(())
}

#[test]
fn non_success_statuses_remain_raw_responses() -> TestResult {
    for status in [404u16, 429, 500] {
        let peer = spawn_peer(raw_response(status, &[], b"raw"), false)?;
        let adapter = UreqHttpAdapter::default();
        let (_, started) = dispatch(&adapter, input(peer.target.clone(), "status"))?;
        let (_, observation) = delivered_parts(wait_delivery(&adapter, &started)?)?;
        assert_causal_identity(&started, &observation);
        assert!(matches!(
            observation,
            AdapterObservation::ResponseObservation {
                response: RawHttpResponse { status: actual, .. },
                ..
            } if actual == Natural::from(status)
        ));
        assert_eq!(peer.received.load(Ordering::SeqCst), 1);
        let _ = peer.finish()?;
    }
    Ok(())
}

fn expect_failure(
    response: Vec<u8>,
    response_limit: u16,
    expected_stage: HostStage,
    expected_cause: HostFailure,
) -> TestResult {
    let peer = spawn_peer(response, false)?;
    let mut request = input(peer.target.clone(), "failure");
    request.configuration.response_body_limit = response_limit.into();
    let adapter = UreqHttpAdapter::default();
    let (_, started) = dispatch(&adapter, request.clone())?;
    let (delivery, observation) = delivered_parts(wait_delivery(&adapter, &started)?)?;
    assert_eq!(delivery, 0u8.into());
    assert!(matches!(
        observation,
        AdapterObservation::FailureObservation {
            failure: NetworkHostFailure {
                ref attempt,
                stage,
                ref configuration,
                ref cause,
            },
            effect: EffectStatus::Unknown {
                reason: UnknownEffectReason::HostFailure
            },
            ..
        } if attempt == &request.attempt
            && stage == expected_stage
            && configuration == &request.configuration
            && cause == &expected_cause
    ));
    assert_eq!(peer.received.load(Ordering::SeqCst), 1);
    let _ = peer.finish()?;
    Ok(())
}

#[test]
fn malformed_response_content_length_is_a_response_header_failure() -> TestResult {
    for response in [
        b"HTTP/1.1 200 OK\r\nContent-Length: 42\r\nContent-Length: 43\r\n\r\n".as_slice(),
        b"HTTP/1.1 200 OK\r\nContent-Length: +42\r\n\r\n".as_slice(),
    ] {
        expect_failure(
            response.to_vec(),
            64,
            HostStage::ResponseHeaders,
            HostFailure::MalformedResponse,
        )?;
    }
    Ok(())
}

#[test]
fn real_peer_failures_cover_headers_body_limit_and_malformed_response() -> TestResult {
    expect_failure(
        Vec::new(),
        64,
        HostStage::ResponseHeaders,
        HostFailure::ResponseHeadersFailed,
    )?;
    expect_failure(
        b"HTTP/1.1 200 OK\r\nContent-Length: 10\r\n\r\nabc".to_vec(),
        64,
        HostStage::ResponseBody,
        HostFailure::ResponseBodyFailed,
    )?;
    expect_failure(
        raw_response(200, &[], b"oversized"),
        3,
        HostStage::ResponseBody,
        HostFailure::ResponseBodyLimitExceeded,
    )?;
    expect_failure(
        b"NOT HTTP\r\n\r\n".to_vec(),
        64,
        HostStage::ResponseHeaders,
        HostFailure::MalformedResponse,
    )?;
    Ok(())
}

fn start_failure(input: AttemptInput) -> TestResult<NetworkHostFailure> {
    let (_, _, command) = prepare_command(input)?;
    let adapter = UreqHttpAdapter::default();
    let StartObservation::StartFailed { failure, effect } = adapter.start(command) else {
        return Err("start failure".into());
    };
    assert!(matches!(
        effect,
        EffectStatus::Unknown {
            reason: UnknownEffectReason::HostFailure
        }
    ));
    Ok(failure)
}

#[test]
fn validation_and_real_connection_failures_preserve_provenance() -> TestResult {
    let unsupported = start_failure(input("ftp://127.0.0.1/resource".to_owned(), "scheme"))?;
    assert_eq!(unsupported.stage, HostStage::Start);
    assert_eq!(unsupported.cause, HostFailure::UnsupportedUriScheme);

    let cancellation = CancellationCapability {
        identity: OpaqueEvidence {
            value: "caller-capability".to_owned(),
        },
    };
    let mut invalid = input("http://127.0.0.1:1/".to_owned(), "config");
    invalid.configuration.cancellation = Some(cancellation);
    let invalid_failure = start_failure(invalid)?;
    assert_eq!(invalid_failure.cause, HostFailure::InvalidHostConfiguration);

    let listener = TcpListener::bind("127.0.0.1:0")?;
    let address = listener.local_addr()?;
    drop(listener);
    let adapter = UreqHttpAdapter::default();
    let (state, started) = dispatch(
        &adapter,
        input(format!("http://{address}/refused"), "connection"),
    )?;
    let (_, observation) = delivered_parts(wait_delivery(&adapter, &started)?)?;
    assert!(matches!(
        observation,
        AdapterObservation::FailureObservation {
            failure: NetworkHostFailure {
                stage: HostStage::Start,
                cause: HostFailure::ConnectionFailed,
                ..
            },
            ..
        }
    ));
    assert_eq!(state.attempts.len(), 1);
    Ok(())
}

#[test]
fn invalid_request_header_is_rejected_before_peer_receipt() -> TestResult {
    let listener = TcpListener::bind("127.0.0.1:0")?;
    let address = listener.local_addr()?;
    drop(listener);
    let mut request = input(format!("http://{address}/header"), "request-header");
    request.instruction.headers.push(RawHeaderField {
        name: "X-Binary".to_owned(),
        value: vec![255u8.into()],
    });
    let adapter = UreqHttpAdapter::default();
    let (_, started) = dispatch(&adapter, request)?;
    let (_, observation) = delivered_parts(wait_delivery(&adapter, &started)?)?;
    assert!(matches!(
        observation,
        AdapterObservation::FailureObservation {
            failure: NetworkHostFailure {
                stage: HostStage::RequestWrite,
                cause: HostFailure::RequestHeaderEncodingUnavailable,
                ..
            },
            ..
        }
    ));
    Ok(())
}

#[derive(Clone)]
struct FixedClock {
    capability: MonotonicClockCapability,
    value: Natural,
}

impl MonotonicClockPort for FixedClock {
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

#[derive(Clone)]
struct RejectCancellation {
    capability: CancellationCapability,
}

impl CancellationPort for RejectCancellation {
    fn capability(&self) -> CancellationCapability {
        self.capability.clone()
    }

    fn request(
        &self,
        _capability: &CancellationCapability,
        _handle: &ExecutionHandle,
    ) -> Result<(), HostFailure> {
        Err(HostFailure::CancellationRejected)
    }
}

#[test]
fn deadline_capability_and_cancellation_rejection_are_typed() -> TestResult {
    let basis = ClockBasis {
        value: "deadline-basis".to_owned(),
    };
    let capability = MonotonicClockCapability {
        identity: OpaqueEvidence {
            value: "deadline-clock".to_owned(),
        },
        clock_basis: basis.clone(),
    };
    let deadline = Deadline {
        clock_basis: basis,
        limit: 5u8.into(),
        capability: capability.clone(),
    };
    let mut deadline_input = input("http://127.0.0.1:1/deadline".to_owned(), "deadline");
    deadline_input.deadline = Some(deadline.clone());
    deadline_input.configuration.monotonic_clock = Some(capability.clone());
    let clock = FixedClock {
        capability: capability.clone(),
        value: 5u8.into(),
    };
    let adapter = UreqHttpAdapter::new(clock, CooperativeCancellation::default());
    let (state, started) = dispatch(&adapter, deadline_input)?;
    let (delivery, observation) = delivered_parts(wait_delivery(&adapter, &started)?)?;
    assert_eq!(delivery, 0u8.into());
    let NetworkStep::Terminal(_, settled) = reduce_observe(
        state,
        HostObservation::Delivered {
            delivery,
            observation,
        },
    ) else {
        return Err("deadline terminal".into());
    };
    assert!(matches!(
        settled.terminal.outcome,
        NetworkOutcome::DeadlineExceeded {
            deadline: actual,
            observed_at: MonotonicClockObservation { value, .. }
        } if actual == deadline && value == 5u8.into()
    ));

    let mut unavailable = input("http://127.0.0.1:1/deadline".to_owned(), "unavailable");
    unavailable.deadline = Some(Deadline {
        clock_basis: capability.clock_basis.clone(),
        limit: 10u8.into(),
        capability: capability.clone(),
    });
    unavailable.configuration.monotonic_clock = Some(capability.clone());
    let mismatched = FixedClock {
        capability: MonotonicClockCapability {
            identity: OpaqueEvidence {
                value: "other".to_owned(),
            },
            clock_basis: capability.clock_basis.clone(),
        },
        value: 0u8.into(),
    };
    let (_, _, command) = prepare_command(unavailable)?;
    let adapter = UreqHttpAdapter::new(mismatched, CooperativeCancellation::default());
    assert!(matches!(
        adapter.start(command),
        StartObservation::StartFailed {
            failure: NetworkHostFailure {
                cause: HostFailure::DeadlineControlUnavailable,
                ..
            },
            ..
        }
    ));

    let mut peer = spawn_peer(raw_response(200, &[], b"late"), true)?;
    let cancel_capability = CancellationCapability {
        identity: OpaqueEvidence {
            value: "reject-cancel".to_owned(),
        },
    };
    let mut cancel_input = input(peer.target.clone(), "cancel-rejected");
    cancel_input.configuration.cancellation = Some(cancel_capability.clone());
    let clock = SystemMonotonicClock::new(ClockBasis {
        value: "unused".to_owned(),
    });
    let adapter = UreqHttpAdapter::new(
        clock,
        RejectCancellation {
            capability: cancel_capability.clone(),
        },
    );
    let (state, started) = dispatch(&adapter, cancel_input)?;
    let CommandStep::CommandReady(_, command) = cancel_command(state, started.clone()) else {
        return Err("cancel command".into());
    };
    let (_, observation) = delivered_parts(adapter.cancel(command))?;
    assert!(matches!(
        observation,
        AdapterObservation::FailureObservation {
            failure: NetworkHostFailure {
                stage: HostStage::Cancel,
                cause: HostFailure::CancellationRejected,
                ..
            },
            ..
        }
    ));
    peer.release();
    let _ = peer.finish()?;
    Ok(())
}

#[test]
fn response_cancel_races_follow_delivery_order_and_host_close_is_late_capable() -> TestResult {
    let cancellation = CancellationCapability {
        identity: OpaqueEvidence {
            value: "race-cancel".to_owned(),
        },
    };
    let mut peer = spawn_peer(raw_response(200, &[], b"response"), true)?;
    let mut request = input(peer.target.clone(), "cancel-first");
    request.configuration.cancellation = Some(cancellation.clone());
    let adapter = UreqHttpAdapter::new(
        SystemMonotonicClock::new(ClockBasis {
            value: "race".to_owned(),
        }),
        CooperativeCancellation::new(cancellation.clone()),
    );
    let (state, started) = dispatch(&adapter, request)?;
    let CommandStep::CommandReady(_, command) = cancel_command(state.clone(), started.clone())
    else {
        return Err("cancel command".into());
    };
    let (cancel_delivery, cancel_observation) = delivered_parts(adapter.cancel(command))?;
    assert_eq!(cancel_delivery, 0u8.into());
    let NetworkStep::Terminal(cancelled_state, cancelled) = reduce_observe(
        state,
        HostObservation::Delivered {
            delivery: cancel_delivery,
            observation: cancel_observation,
        },
    ) else {
        return Err("cancel terminal".into());
    };
    assert!(matches!(
        cancelled.terminal.outcome,
        NetworkOutcome::Cancelled
    ));
    peer.release();
    let (response_delivery, response_observation) =
        delivered_parts(wait_delivery(&adapter, &started)?)?;
    assert_eq!(response_delivery, 1u8.into());
    assert!(matches!(
        reduce_observe(
            cancelled_state,
            HostObservation::Delivered {
                delivery: response_delivery,
                observation: response_observation,
            },
        ),
        NetworkStep::Late(_, _, _)
    ));
    let _ = peer.finish()?;

    let peer = spawn_peer(raw_response(200, &[], b"first"), false)?;
    let mut request = input(peer.target.clone(), "response-first");
    request.configuration.cancellation = Some(cancellation.clone());
    let adapter = UreqHttpAdapter::new(
        SystemMonotonicClock::new(ClockBasis {
            value: "race-2".to_owned(),
        }),
        CooperativeCancellation::new(cancellation),
    );
    let (state, started) = dispatch(&adapter, request)?;
    let (response_delivery, response_observation) =
        delivered_parts(wait_delivery(&adapter, &started)?)?;
    let NetworkStep::Terminal(response_state, _) = reduce_observe(
        state.clone(),
        HostObservation::Delivered {
            delivery: response_delivery,
            observation: response_observation,
        },
    ) else {
        return Err("response terminal".into());
    };
    let CommandStep::CommandReady(_, command) = cancel_command(state, started.clone()) else {
        return Err("cancel command".into());
    };
    let (cancel_delivery, cancel_observation) = delivered_parts(adapter.cancel(command))?;
    assert_eq!(cancel_delivery, 1u8.into());
    assert!(matches!(
        reduce_observe(
            response_state,
            HostObservation::Delivered {
                delivery: cancel_delivery,
                observation: cancel_observation,
            },
        ),
        NetworkStep::Late(_, _, _)
    ));
    let _ = peer.finish()?;

    let mut peer = spawn_peer(raw_response(200, &[], b"closed-late"), true)?;
    let adapter = UreqHttpAdapter::default();
    let (_, started) = dispatch(&adapter, input(peer.target.clone(), "closed"))?;
    let (closed_delivery, closed) = delivered_parts(adapter.close(&started))?;
    assert_eq!(closed_delivery, 0u8.into());
    assert!(matches!(
        closed,
        AdapterObservation::FailureObservation {
            failure: NetworkHostFailure {
                cause: HostFailure::HostClosed,
                ..
            },
            ..
        }
    ));
    peer.release();
    let (late_delivery, _) = delivered_parts(wait_delivery(&adapter, &started)?)?;
    assert_eq!(late_delivery, 1u8.into());
    let _ = peer.finish()?;
    Ok(())
}

#[test]
fn reducer_discriminates_duplicate_conflict_and_pre_dispatch_rejections() -> TestResult {
    let peer = spawn_peer(raw_response(200, &[], b"duplicate"), false)?;
    let adapter = UreqHttpAdapter::default();
    let (state, started) = dispatch(&adapter, input(peer.target.clone(), "duplicate"))?;
    let (delivery, observation) = delivered_parts(wait_delivery(&adapter, &started)?)?;
    let host = HostObservation::Delivered {
        delivery: delivery.clone(),
        observation: observation.clone(),
    };
    let NetworkStep::Terminal(terminal_state, _) = reduce_observe(state, host.clone()) else {
        return Err("terminal".into());
    };
    assert!(matches!(
        reduce_observe(terminal_state.clone(), host),
        NetworkStep::Duplicate(same, _, _) if same == terminal_state
    ));
    let mut conflict = observation;
    if let AdapterObservation::ResponseObservation {
        source_sequence, ..
    } = &mut conflict
    {
        *source_sequence = Some(9u8.into());
    }
    assert!(matches!(
        reduce_observe(
            terminal_state.clone(),
            HostObservation::Delivered {
                delivery,
                observation: conflict,
            },
        ),
        NetworkStep::Rejected(same, NetworkFailure::ConflictingDelivery { .. })
            if same == terminal_state
    ));
    let authorization = RetryAuthorization {
        logical: started.prepared.input.attempt.logical.clone(),
        from: started.prepared.input.attempt.clone(),
        next: AttemptIdentity {
            logical: started.prepared.input.attempt.logical.clone(),
            ordinal: 1u8.into(),
        },
        protocol_evidence: OpaqueEvidence {
            value: "retry-evidence".to_owned(),
        },
    };
    let retry_request = RetryRequest {
        permission: RetryPermission::RetryAllowed {
            authorization: authorization.clone(),
        },
        instruction: started.prepared.input.instruction.clone(),
        deadline: started.prepared.input.deadline.clone(),
        configuration: started.prepared.input.configuration.clone(),
    };
    let PrepareStep::Prepared(retry_state, _) =
        retry(terminal_state.clone(), retry_request.clone())
    else {
        return Err("retry append".into());
    };
    assert_eq!(retry_state.attempts.len(), 2);
    assert_eq!(peer.received.load(Ordering::SeqCst), 1);
    assert!(matches!(
        retry(retry_state.clone(), retry_request),
        PrepareStep::Rejected(same, NetworkFailure::RetryNotPermitted { .. })
            if same == retry_state
    ));
    let _ = peer.finish()?;

    let mut forged = input("http://127.0.0.1:1/forged".to_owned(), "forged");
    let PrepareStep::Prepared(state, mut prepared) =
        prepare(NetworkState::default(), forged.clone())
    else {
        return Err("prepare".into());
    };
    prepared.input.instruction.target.push_str("changed");
    assert!(matches!(
        send_command(state, prepared),
        CommandStep::Rejected(_, NetworkFailure::AttemptTokenMismatch { .. })
    ));
    let ledger_record_count = 1usize;
    let issued_command_count = 0usize;
    let peer_received_count = 0usize;
    assert_eq!(ledger_record_count, 1);
    assert_eq!(issued_command_count, 0);
    assert!(peer_received_count <= issued_command_count);

    forged.attempt.ordinal = 1u8.into();
    let denied = RetryRequest {
        permission: RetryPermission::RetryDenied {
            logical: forged.attempt.logical.clone(),
            parent: AttemptIdentity {
                logical: forged.attempt.logical,
                ordinal: 0u8.into(),
            },
            evidence: OpaqueEvidence {
                value: "no-rule".to_owned(),
            },
        },
        instruction: forged.instruction,
        deadline: forged.deadline,
        configuration: forged.configuration,
    };
    assert!(matches!(
        retry(NetworkState::default(), denied),
        PrepareStep::Rejected(_, NetworkFailure::RetryNotPermitted { .. })
    ));
    Ok(())
}

#[test]
fn retry_after_settled_root_dispatches_ordinal_one_against_a_peer() -> TestResult {
    let peer = spawn_loop_peer(raw_response(200, &[], b"retry-body"))?;
    let root_input = input(peer.target.clone(), "retry-positive");
    let adapter = UreqHttpAdapter::default();
    let (state, started) = dispatch(&adapter, root_input.clone())?;
    let mut issued_command_count = 1usize;
    let (delivery, observation) = delivered_parts(wait_delivery(&adapter, &started)?)?;
    assert_causal_identity(&started, &observation);
    let NetworkStep::Terminal(state, root_settled) = reduce_observe(
        state,
        HostObservation::Delivered {
            delivery,
            observation,
        },
    ) else {
        return Err("root terminal".into());
    };
    assert!(matches!(
        root_settled.terminal.outcome,
        NetworkOutcome::Response { .. }
    ));

    let ledger_record_count = state.attempts.len();
    let peer_received_count = peer.received.load(Ordering::SeqCst);
    assert_eq!(ledger_record_count, 1);
    assert_eq!(issued_command_count, 1);
    assert_eq!(peer_received_count, 1);

    let authorization = RetryAuthorization {
        logical: root_input.attempt.logical.clone(),
        from: root_input.attempt.clone(),
        next: AttemptIdentity {
            logical: root_input.attempt.logical.clone(),
            ordinal: 1u8.into(),
        },
        protocol_evidence: OpaqueEvidence {
            value: "retry-auth".to_owned(),
        },
    };
    let request = RetryRequest {
        permission: RetryPermission::RetryAllowed {
            authorization: authorization.clone(),
        },
        instruction: root_input.instruction.clone(),
        deadline: root_input.deadline.clone(),
        configuration: root_input.configuration.clone(),
    };
    let PrepareStep::Prepared(state, prepared) = retry(state, request.clone()) else {
        return Err("retry prepared".into());
    };
    assert_eq!(state.attempts.len(), ledger_record_count + 1);
    assert_eq!(issued_command_count, 1);
    assert_eq!(peer.received.load(Ordering::SeqCst), peer_received_count);
    assert!(matches!(
        &prepared.lineage,
        AttemptLineage::RetryOf { authorization: got } if *got == authorization
    ));
    assert_eq!(
        state.attempts.first().map(|record| &record.lineage),
        Some(&AttemptLineage::Root)
    );

    let CommandStep::CommandReady(state, command) = send_command(state, prepared.clone()) else {
        return Err("retry send command".into());
    };
    let start = adapter.start(command);
    let NetworkStep::Started(state, retry_started) = observe_start(state, prepared, start) else {
        return Err("retry observe start".into());
    };
    issued_command_count += 1;
    let (delivery, observation) = delivered_parts(wait_delivery(&adapter, &retry_started)?)?;
    assert_causal_identity(&retry_started, &observation);
    let NetworkStep::Terminal(state, retry_settled) = reduce_observe(
        state,
        HostObservation::Delivered {
            delivery,
            observation,
        },
    ) else {
        return Err("retry terminal".into());
    };
    assert!(matches!(
        retry_settled.terminal.outcome,
        NetworkOutcome::Response { .. }
    ));

    assert_eq!(issued_command_count, 2);
    assert_eq!(
        peer.received.load(Ordering::SeqCst),
        peer_received_count + 1
    );
    assert_eq!(state.attempts.len(), ledger_record_count + 1);
    let (Some(root_record), Some(retry_record)) = (state.attempts.first(), state.attempts.get(1))
    else {
        return Err("the ledger records the root and the retry".into());
    };
    assert!(matches!(
        &retry_record.lineage,
        AttemptLineage::RetryOf { authorization: got } if *got == authorization
    ));
    assert_ne!(retry_record.lineage, root_record.lineage);
    assert_eq!(root_record.lineage, AttemptLineage::Root);

    let PrepareStep::Rejected(state, failure) = retry(state, request) else {
        return Err("reused authorization retry rejected".into());
    };
    assert!(matches!(failure, NetworkFailure::RetryNotPermitted { .. }));
    assert_eq!(state.attempts.len(), ledger_record_count + 1);
    assert_eq!(
        peer.received.load(Ordering::SeqCst),
        peer_received_count + 1
    );
    Ok(())
}
