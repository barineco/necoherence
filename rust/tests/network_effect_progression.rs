// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

use necoherence::http_adapter::UreqHttpAdapter;
use necoherence::network_effect::{observe as observe_network, *};
use necoherence::request_progression::RequestIdentity;
use std::io::{Read, Write};
use std::net::TcpListener;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;
use std::thread;
use std::time::Duration;

#[test]
fn typed_terminal_and_counts_remain_available_for_progression_projection(
) -> Result<(), Box<dyn std::error::Error>> {
    let listener = TcpListener::bind("127.0.0.1:0")?;
    let address = listener.local_addr()?;
    let peer_received = Arc::new(AtomicUsize::new(0));
    let peer_count = Arc::clone(&peer_received);
    let peer = thread::spawn(move || -> std::io::Result<()> {
        let (mut stream, _) = listener.accept()?;
        let mut request = [0u8; 1024];
        let read = stream.read(&mut request)?;
        if read > 0 {
            peer_count.fetch_add(1, Ordering::SeqCst);
        }
        stream.write_all(b"HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n")
    });

    let identity = RequestIdentity {
        kind: "progression".into(),
        provenance: "test".into(),
        revision: 0u8.into(),
    };
    let input = AttemptInput {
        attempt: AttemptIdentity {
            logical: identity,
            ordinal: 0u8.into(),
        },
        instruction: HttpWireInstruction {
            method: "GET".into(),
            target: format!("http://{address}/progression"),
            headers: vec![],
            body: vec![],
        },
        deadline: None,
        configuration: HostConfiguration {
            request_body_limit: 0u8.into(),
            response_body_limit: 0u8.into(),
            cancellation: None,
            monotonic_clock: None,
        },
    };
    let PrepareStep::Prepared(state, prepared) = prepare(NetworkState::default(), input) else {
        return Err("prepare".into());
    };
    let ledger_record_count = state.attempts.len();
    let CommandStep::CommandReady(state, command) = send_command(state, prepared.clone()) else {
        return Err("command".into());
    };
    let issued_command_count = 1usize;
    let adapter = UreqHttpAdapter::default();
    let start = adapter.start(command);
    let NetworkStep::Started(state, started) = observe_start(state, prepared.clone(), start) else {
        return Err("start".into());
    };
    let host = loop {
        match adapter.observe(&started) {
            delivered @ HostObservation::Delivered { .. } => break delivered,
            HostObservation::Pending { .. } => thread::sleep(Duration::from_millis(1)),
        }
    };
    let NetworkStep::Terminal(state, settled) = observe_network(state, host) else {
        return Err("terminal".into());
    };
    peer.join().map_err(|_| "peer thread panicked")??;

    assert_eq!(ledger_record_count, 1);
    assert_eq!(issued_command_count, 1);
    assert_eq!(peer_received.load(Ordering::SeqCst), 1);
    assert!(peer_received.load(Ordering::SeqCst) <= issued_command_count);
    assert_eq!(settled.prepared.input.attempt, prepared.input.attempt);
    assert_eq!(settled.handle.as_ref(), Some(&started.handle));
    assert_eq!(
        lookup_attempt(&state, &prepared.input.attempt).map(|record| record.input.clone()),
        Some(prepared.input)
    );
    assert!(matches!(
        settled.terminal.outcome,
        NetworkOutcome::Response {
            response: RawHttpResponse { status, .. },
            provenance: HeaderProvenance::LibraryObserved,
        } if status == 200u16.into()
    ));
    Ok(())
}
