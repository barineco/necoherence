// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: AGPL-3.0-only
#![allow(clippy::expect_used, clippy::unwrap_used)]

use std::io::Write;
use std::process::{Command, Stdio};

const SCENARIOS: [(&str, &str); 5] = [
    ("pure", "execution-pure.json"),
    ("http", "execution-http.json"),
    ("presence", "execution-presence.json"),
    ("pair", "execution-pair.json"),
    ("pair_http", "execution-pair-http.json"),
];

#[test]
fn adapter_fixtures_equal_the_generated_admission_documents() {
    let mut child = Command::new(env!("CARGO_BIN_EXE_generate"))
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .spawn()
        .unwrap();
    let request =
        serde_json::json!({ "scenarios": SCENARIOS.map(|(scenario, _)| scenario) }).to_string();
    child
        .stdin
        .take()
        .unwrap()
        .write_all(request.as_bytes())
        .unwrap();
    let output = child.wait_with_output().unwrap();
    assert!(output.status.success());
    let generated: serde_json::Value = serde_json::from_slice(&output.stdout).unwrap();
    for (scenario, file) in SCENARIOS {
        let path = format!(
            "{}/../../../packages/rust/adapter/tests/fixtures/{file}",
            env!("CARGO_MANIFEST_DIR")
        );
        let fixture = std::fs::read_to_string(&path).unwrap();
        assert_eq!(
            generated[scenario].as_str().unwrap(),
            fixture,
            "fixture {path} differs from the generated document"
        );
    }
}
