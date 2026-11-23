// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: AGPL-3.0-only

use necoherence::semantic_exchange::decode_expected_signature_basis;
use necoherence_generator::boundary_failure::generator_failure_value;
use necoherence_generator::renderer::{render_signature_exchange_for, JavaTarget, Target};
use serde_json::{json, Value};
use std::io::Write;
use std::process::ExitCode;

struct Options {
    target: Target,
    expected: String,
    input: String,
    output: String,
}

fn failed(reason: &str) -> Value {
    json!({"result": "failed", "failure": {"kind": "request", "reason": reason}})
}

fn parse(arguments: Vec<String>) -> Result<Options, &'static str> {
    let mut target = None;
    let mut expected = None;
    let mut input = None;
    let mut output = None;
    let mut runtime = None;
    let mut java_package = None;
    let mut java_class = None;
    let mut values = arguments.into_iter();
    while let Some(flag) = values.next() {
        let value = values.next().ok_or("argument")?;
        match flag.as_str() {
            "--target" => target = Some(value),
            "--expected" => expected = Some(value),
            "--input" => input = Some(value),
            "--output" => output = Some(value),
            "--runtime" => runtime = Some(value),
            "--java-package" => java_package = Some(value),
            "--java-class" => java_class = Some(value),
            _ => return Err("argument"),
        }
    }
    let target = match target.as_deref() {
        Some("rust") => Target::Rust,
        Some("python") => Target::Python,
        Some("typescript") => Target::TypeScript {
            runtime_module: runtime.unwrap_or_else(|| "necoherence".to_owned()),
        },
        Some("java") => Target::Java(JavaTarget {
            package_name: java_package.ok_or("java_package")?,
            class_name: java_class.ok_or("java_class")?,
        }),
        Some("gleam") => Target::Gleam,
        _ => return Err("target"),
    };
    Ok(Options {
        target,
        expected: expected.ok_or("expected")?,
        input: input.ok_or("input")?,
        output: output.ok_or("output")?,
    })
}

fn run() -> Result<(), Value> {
    let options = parse(std::env::args().skip(1).collect()).map_err(failed)?;
    let expected_text =
        std::fs::read_to_string(&options.expected).map_err(|_| failed("expected_file"))?;
    let expected =
        decode_expected_signature_basis(&expected_text).map_err(|_| failed("expected_basis"))?;
    let input_text = std::fs::read_to_string(&options.input).map_err(|_| failed("input_file"))?;
    let rendered = render_signature_exchange_for(&options.target, &expected, &input_text).map_err(
        |failure| json!({"result": "failed", "failure": generator_failure_value(&failure)}),
    )?;
    std::fs::write(&options.output, rendered).map_err(|_| failed("output_file"))
}

fn main() -> ExitCode {
    match run() {
        Ok(()) => ExitCode::SUCCESS,
        Err(value) => {
            let _ = writeln!(std::io::stderr(), "{value}");
            ExitCode::FAILURE
        }
    }
}
