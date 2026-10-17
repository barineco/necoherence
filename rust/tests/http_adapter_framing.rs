// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

#![allow(clippy::indexing_slicing)]

use necoherence::http_adapter::UreqHttpAdapter;
use necoherence::network_effect::*;
use necoherence::request_progression::RequestIdentity;
use std::io::{Read, Write};
use std::net::TcpListener;
use std::thread;
use std::time::{Duration, Instant};

type TestResult<T = ()> = Result<T, Box<dyn std::error::Error + Send + Sync>>;

fn capture_request(method: &str, body: &[u8]) -> TestResult<Vec<u8>> {
    let listener = TcpListener::bind("127.0.0.1:0")?;
    listener.set_nonblocking(true)?;
    let address = listener.local_addr()?;
    let worker = thread::spawn(move || -> TestResult<Vec<u8>> {
        let deadline = Instant::now() + Duration::from_secs(5);
        let mut stream = loop {
            match listener.accept() {
                Ok((stream, _)) => break stream,
                Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                    if Instant::now() >= deadline {
                        return Err("request accept timeout".into());
                    }
                    thread::sleep(Duration::from_millis(1));
                }
                Err(error) => return Err(error.into()),
            }
        };
        stream.set_nonblocking(false)?;
        stream.set_read_timeout(Some(Duration::from_secs(5)))?;
        stream.set_write_timeout(Some(Duration::from_secs(5)))?;
        let mut raw = Vec::new();
        let mut buffer = [0; 4096];
        loop {
            if let Some(end) = raw.windows(4).position(|bytes| bytes == b"\r\n\r\n") {
                let header_end = end + 4;
                let headers = std::str::from_utf8(&raw[..header_end])?;
                let length = headers
                    .lines()
                    .filter_map(|line| line.split_once(':'))
                    .find(|(name, _)| name.eq_ignore_ascii_case("content-length"))
                    .map(|(_, value)| value.trim().parse::<usize>())
                    .transpose()?
                    .unwrap_or(0);
                if raw.len() >= header_end + length {
                    break;
                }
            }
            let count = stream.read(&mut buffer)?;
            if count == 0 {
                return Err("request ended before declared body".into());
            }
            raw.extend_from_slice(&buffer[..count]);
        }
        stream.write_all(b"HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")?;
        Ok(raw)
    });
    let input = AttemptInput {
        attempt: AttemptIdentity {
            logical: RequestIdentity {
                kind: "http-framing".to_owned(),
                provenance: "loopback".to_owned(),
                revision: 0u8.into(),
            },
            ordinal: 0u8.into(),
        },
        instruction: HttpWireInstruction {
            method: method.to_owned(),
            target: format!("http://{address}/framing"),
            headers: Vec::new(),
            body: body.iter().copied().map(Natural::from).collect(),
        },
        deadline: None,
        configuration: HostConfiguration {
            request_body_limit: 1024u16.into(),
            response_body_limit: 1024u16.into(),
            cancellation: None,
            monotonic_clock: None,
        },
    };
    let PrepareStep::Prepared(state, prepared) = prepare(NetworkState::default(), input) else {
        return Err("prepare failed".into());
    };
    let CommandStep::CommandReady(state, command) = send_command(state, prepared.clone()) else {
        return Err("send command failed".into());
    };
    let adapter = UreqHttpAdapter::default();
    let start = adapter.start(command);
    let NetworkStep::Started(_, started) = observe_start(state, prepared, start) else {
        return Err("start failed".into());
    };
    let raw = worker.join().map_err(|_| "listener panicked")??;
    let deadline = Instant::now() + Duration::from_secs(5);
    loop {
        match adapter.observe(&started) {
            HostObservation::Delivered { observation, .. } => {
                assert!(
                    matches!(observation, AdapterObservation::ResponseObservation { .. }),
                    "{observation:?}"
                );
                break;
            }
            _ if Instant::now() >= deadline => return Err("response observation timeout".into()),
            _ => thread::sleep(Duration::from_millis(1)),
        }
    }
    Ok(raw)
}

fn framing_headers(raw: &[u8]) -> TestResult<Vec<(String, String)>> {
    let end = raw
        .windows(4)
        .position(|bytes| bytes == b"\r\n\r\n")
        .ok_or("missing header terminator")?;
    let headers = std::str::from_utf8(&raw[..end])?;
    println!("{headers}\r\n");
    Ok(headers
        .lines()
        .filter_map(|line| line.split_once(':'))
        .filter(|(name, _)| {
            name.eq_ignore_ascii_case("content-length")
                || name.eq_ignore_ascii_case("transfer-encoding")
        })
        .map(|(name, value)| (name.to_ascii_lowercase(), value.trim().to_owned()))
        .collect())
}

#[test]
fn empty_body_methods_send_only_zero_content_length() -> TestResult {
    for method in ["POST", "PUT", "PATCH"] {
        let raw = capture_request(method, b"")?;
        assert_eq!(
            framing_headers(&raw)?,
            vec![("content-length".to_owned(), "0".to_owned())],
            "{method}"
        );
        assert!(raw.ends_with(b"\r\n\r\n"));
    }
    Ok(())
}

#[test]
fn empty_bodyless_methods_send_no_framing_headers() -> TestResult {
    for method in ["GET", "HEAD", "DELETE", "OPTIONS"] {
        let raw = capture_request(method, b"")?;
        assert!(framing_headers(&raw)?.is_empty(), "{method}");
        assert!(raw.ends_with(b"\r\n\r\n"));
    }
    Ok(())
}

#[test]
fn nonempty_post_content_length_matches_received_body() -> TestResult {
    let body = b"framing payload";
    let raw = capture_request("POST", body)?;
    assert_eq!(
        framing_headers(&raw)?,
        vec![("content-length".to_owned(), body.len().to_string())]
    );
    let end = raw
        .windows(4)
        .position(|bytes| bytes == b"\r\n\r\n")
        .ok_or("missing header terminator")?;
    assert_eq!(&raw[end + 4..], body);
    Ok(())
}
