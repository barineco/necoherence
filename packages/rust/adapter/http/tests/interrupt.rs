// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

use necoherence::network_effect::{observe as reduce_observe, *};
use necoherence::request_progression::RequestIdentity;
use necoherence::ErasureDecision;
use necoherence_http_adapter::{CancellationPort, CooperativeCancellation, UreqHttpAdapter};
use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;
use std::thread;
use std::time::{Duration, Instant};

type TestResult<T = ()> = Result<T, Box<dyn std::error::Error + Send + Sync>>;

#[derive(Clone, Copy)]
enum Step {
    Respond,
    HoldBeforeHeaders,
    HoldInBody,
}

struct Peer {
    target: String,
    received: Arc<AtomicUsize>,
}

fn peer(script: Vec<Step>) -> TestResult<Peer> {
    let listener = TcpListener::bind("127.0.0.1:0")?;
    let address = listener.local_addr()?;
    let received = Arc::new(AtomicUsize::new(0));
    let counter = Arc::clone(&received);
    let script = Arc::new(script);
    thread::spawn(move || {
        for stream in listener.incoming().flatten() {
            let counter = Arc::clone(&counter);
            let script = Arc::clone(&script);
            thread::spawn(move || serve(stream, &counter, &script));
        }
    });
    Ok(Peer {
        target: format!("http://{address}/interrupt"),
        received,
    })
}

fn serve(mut stream: TcpStream, counter: &AtomicUsize, script: &[Step]) {
    let mut buffer: Vec<u8> = Vec::new();
    let mut chunk = [0u8; 1024];
    loop {
        match stream.read(&mut chunk) {
            Ok(0) | Err(_) => return,
            Ok(read) => buffer.extend_from_slice(chunk.get(..read).unwrap_or_default()),
        }
        while let Some(end) = buffer.windows(4).position(|window| window == b"\r\n\r\n") {
            buffer.drain(..end + 4);
            let index = counter.fetch_add(1, Ordering::SeqCst);
            match script.get(index).copied().unwrap_or(Step::Respond) {
                Step::Respond => {
                    let _ = stream.write_all(b"HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n");
                }
                Step::HoldBeforeHeaders => {
                    while !matches!(stream.read(&mut chunk), Ok(0) | Err(_)) {}
                    return;
                }
                Step::HoldInBody => {
                    let _ =
                        stream.write_all(b"HTTP/1.1 200 OK\r\nContent-Length: 100\r\n\r\nabcde");
                    while !matches!(stream.read(&mut chunk), Ok(0) | Err(_)) {}
                    return;
                }
            }
        }
    }
}

fn dispatch(adapter: &UreqHttpAdapter, target: &str) -> TestResult<(NetworkState, StartedAttempt)> {
    let capability = CooperativeCancellation::default().capability();
    let attempt = AttemptInput {
        attempt: AttemptIdentity {
            logical: RequestIdentity {
                kind: "interrupt-test".to_owned(),
                provenance: "runtime".to_owned(),
                revision: 0u8.into(),
            },
            ordinal: 0u8.into(),
        },
        instruction: HttpWireInstruction {
            method: "GET".to_owned(),
            target: target.to_owned(),
            headers: Vec::new(),
            body: Vec::new(),
        },
        deadline: None,
        configuration: HostConfiguration {
            request_body_limit: 0u8.into(),
            response_body_limit: 16u8.into(),
            cancellation: Some(capability),
            monotonic_clock: None,
        },
    };
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

fn await_delivery(adapter: &UreqHttpAdapter, started: &StartedAttempt) -> TestResult {
    let began = Instant::now();
    while began.elapsed() < Duration::from_secs(2) {
        if matches!(adapter.observe(started)?, HostObservation::Delivered { .. }) {
            return Ok(());
        }
        thread::sleep(Duration::from_millis(1));
    }
    Err("delivery timeout".into())
}

fn wait_for_requests(peer: &Peer, count: usize) -> TestResult {
    let began = Instant::now();
    while peer.received.load(Ordering::SeqCst) < count {
        if began.elapsed() > Duration::from_secs(2) {
            return Err("peer wait".into());
        }
        thread::sleep(Duration::from_millis(1));
    }
    thread::sleep(Duration::from_millis(30));
    Ok(())
}

fn cancel_and_time(
    adapter: &UreqHttpAdapter,
    state: NetworkState,
    started: &StartedAttempt,
) -> TestResult<Duration> {
    let CommandStep::CommandReady(_, command) = cancel_command(state.clone(), started.clone())
    else {
        return Err("cancel command".into());
    };
    let began = Instant::now();
    let cancelled = adapter.cancel(command)?;
    let NetworkStep::Terminal(state, _) = reduce_observe(state, cancelled) else {
        return Err("cancel terminal".into());
    };
    while began.elapsed() < Duration::from_secs(2) {
        if matches!(
            adapter.release(&state, started),
            ErasureDecision::Dematerialize(_)
        ) {
            return Ok(began.elapsed());
        }
        thread::sleep(Duration::from_millis(1));
    }
    Err("worker still running after the cancel".into())
}

#[test]
fn a_header_wait_ends_at_the_cancel() -> TestResult {
    let peer = peer(vec![Step::HoldBeforeHeaders])?;
    let adapter = UreqHttpAdapter::default();
    let (state, started) = dispatch(&adapter, &peer.target)?;
    wait_for_requests(&peer, 1)?;
    cancel_and_time(&adapter, state, &started)?;
    Ok(())
}

#[test]
fn a_body_stall_ends_at_the_cancel() -> TestResult {
    let peer = peer(vec![Step::HoldInBody])?;
    let adapter = UreqHttpAdapter::default();
    let (state, started) = dispatch(&adapter, &peer.target)?;
    wait_for_requests(&peer, 1)?;
    cancel_and_time(&adapter, state, &started)?;
    Ok(())
}

#[test]
fn a_wait_on_a_reused_connection_ends_at_the_cancel() -> TestResult {
    let peer = peer(vec![Step::Respond, Step::HoldBeforeHeaders])?;
    let adapter = UreqHttpAdapter::default();
    let (_, first) = dispatch(&adapter, &peer.target)?;
    await_delivery(&adapter, &first)?;
    let (state, second) = dispatch(&adapter, &peer.target)?;
    wait_for_requests(&peer, 2)?;
    cancel_and_time(&adapter, state, &second)?;
    Ok(())
}
