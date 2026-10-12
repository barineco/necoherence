# SPDX-FileCopyrightText: 2026 barineco
# SPDX-License-Identifier: MIT

from __future__ import annotations

import json
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
GENERATOR = ROOT / "comparison/declaration/signature_generator/Cargo.toml"


def generate(command: str) -> str:
    result = subprocess.run(
        ["cargo", "run", "--quiet", "--manifest-path", str(GENERATOR), "--bin", "signatures", "--", command],
        cwd=ROOT, env=os.environ, check=True, capture_output=True, text=True,
    )
    return result.stdout


CONSUMER = r'''
mod declaration { include!("declaration.rs"); }
mod composed { include!("composed.rs"); }
mod synthetic { include!("synthetic.rs"); }
use necoherence::semantic_codegen_runtime::{self as rt, RuntimeFailure};

struct Transport { starts: usize, observations: usize }
impl declaration::SignatureHttpTransport for Transport {
 type Started = ();
 fn start(&mut self, _: necoherence::network_effect::AttemptInput) -> Result<Self::Started, RuntimeFailure> {
  self.starts += 1;
  panic!("synchronous completion started an effect")
 }
 fn observe(&mut self, _: &Self::Started) -> Result<necoherence::network_effect::NetworkTerminal, RuntimeFailure> {
  self.observations += 1;
  panic!("synchronous completion observed an effect")
 }
}

struct DeclarationOwner { mode: u8, effects: usize }
impl declaration::ExampleOperationBinding for DeclarationOwner {
 fn prepare(&mut self, _: &declaration::Context<'_>, _: declaration::ExampleOperationInput) -> Result<declaration::SignatureHttpPrepare<declaration::ExampleOperationResult>, RuntimeFailure> {
  let value = if self.mode == 0 {
   declaration::ExampleOperationResult::Outcome1(declaration::ExampleOperationOutcome1 { reason: Some(rt::JsonValue::Null) })
  } else {
   declaration::ExampleOperationResult::Outcome0(declaration::ExampleOperationOutcome0 { output: Some(rt::JsonValue::Bool(true)) })
  };
  let outcome_id = if self.mode == 2 { "refused" } else { value.outcome_id() };
  Ok(declaration::SignatureHttpPrepare::Completed { outcome_id, value })
 }
 fn decode(&mut self, _: &declaration::Context<'_>, _: &necoherence::network_effect::NetworkTerminal) -> Result<declaration::ExampleOperationResult, RuntimeFailure> {
  self.effects += 1;
  panic!("synchronous completion decoded a network result")
 }
}

struct Recovery { calls: Vec<String> }
impl composed::Providers for Recovery {
 fn call_provider(&mut self, function: &str, _: Vec<rt::JsonValue>) -> Result<composed::ProviderOutcome, RuntimeFailure> {
  self.calls.push(function.into());
  match function {
   "ExampleOperation" => Ok(composed::ProviderOutcome { outcome_id: "refused".into(), values: vec![rt::JsonValue::Null] }),
   "handler" => Ok(composed::ProviderOutcome { outcome_id: "handled".into(), values: vec![rt::JsonValue::Bool(false)] }),
   _ => Err(rt::representation("unknown provider")),
  }
 }
}

fn main() -> Result<(), Box<dyn std::error::Error>> {
 let generation = declaration::generation_context()?;
 necoherence::semantic_exchange::verify_generation(&generation)?;
 let expected_graph = necoherence::signature_admission::check_type_signatures(&generation.signature_input().signatures)?;
 assert!(declaration::graph(&generation) == &expected_graph);
 let cx = declaration::Context::new(&generation);
 for value in [false, true] {
  let encoded = declaration::WireValue::write_wire(&declaration::truth(value), &cx)?;
  let decoded = <declaration::truth as declaration::WireValue>::read_wire(&cx, encoded)?;
  assert!(decoded.0 == value);
 }
 let annotation = declaration::annotations(&generation).first().ok_or("group annotation")?;
 assert!(annotation.value == necoherence::semantic_types::JsonValue::Str("generated group description".into()));
 let input = declaration::ExampleOperationInput { input: Some(rt::JsonValue::Bool(true)) };
 let mut owner = DeclarationOwner { mode: 0, effects: 0 };
 let mut transport = Transport { starts: 0, observations: 0 };
 let declaration::ExampleOperationStart::Completed(outcome) = declaration::exampleoperation_call(&cx, input, &mut owner, &mut transport)? else { return Err("external completion started an effect".into()) };
 assert!(outcome.outcome_id() == "refused");
 owner.mode = 1;
 let input = declaration::ExampleOperationInput { input: Some(rt::JsonValue::Bool(false)) };
 let success_rejected = declaration::exampleoperation_call(&cx, input, &mut owner, &mut transport).is_err();
 assert!(success_rejected);
 owner.mode = 2;
 let input = declaration::ExampleOperationInput { input: Some(rt::JsonValue::Bool(false)) };
 let mismatch_rejected = declaration::exampleoperation_call(&cx, input, &mut owner, &mut transport).is_err();
 assert!(mismatch_rejected);
 assert!((owner.effects, transport.starts, transport.observations) == (0, 0, 0));

 let generation = composed::generation_context()?;
 necoherence::semantic_exchange::verify_generation(&generation)?;
 let cx = composed::Context::new(&generation);
 let mut recovery = Recovery { calls: vec![] };
 let result = composed::execute(&cx, composed::CompositionInput(vec![]), &mut recovery)?;
 let composed::CompositionOutcome::Success(output) = result else { return Err("handler did not produce success".into()) };
 assert!(output.0.last() == Some(&rt::JsonValue::Bool(false)));
 assert!(recovery.calls == ["ExampleOperation", "handler"]);

 let generation = synthetic::generation_context()?;
 necoherence::semantic_exchange::verify_generation(&generation)?;
 let cx = synthetic::Context::new(&generation);
 for (key, text) in [("kind", "example.test#main"), ("label", "preserved")] {
  let wire = rt::JsonValue::Obj(vec![(key.into(), rt::JsonValue::Str(text.into()))]);
  let value = <synthetic::truth as synthetic::WireValue>::read_wire(&cx, wire.clone())?;
  assert!(synthetic::WireValue::write_wire(&value, &cx)? == wire);
 }
 let extra = rt::JsonValue::Obj(vec![("other".into(), rt::JsonValue::Bool(true))]);
 assert!(<synthetic::truth as synthetic::WireValue>::read_wire(&cx, extra).is_err());
 Ok(())
}
'''


def run() -> None:
    without_handler = json.loads(generate("no-handler"))
    assert without_handler["status"] in {"Unreachable", "Unknown"}
    with tempfile.TemporaryDirectory(prefix="ncoh-signature-smoke-") as directory:
        path = Path(directory)
        (path / "src").mkdir()
        (path / "Cargo.toml").write_text(
            '[package]\nname="signature_generation_smoke"\nversion="0.1.0"\nedition="2021"\n'
            f'[dependencies]\nnecoherence={{path={json.dumps(str(ROOT / "rust"))}}}\n', encoding="utf-8",
        )
        (path / "src/declaration.rs").write_text(generate("render"), encoding="utf-8")
        (path / "src/composed.rs").write_text(generate("render-composition"), encoding="utf-8")
        (path / "src/synthetic.rs").write_text(generate("render-synthetic"), encoding="utf-8")
        (path / "src/main.rs").write_text(CONSUMER, encoding="utf-8")
        result = subprocess.run(["cargo", "run", "--quiet", "--manifest-path", str(path / "Cargo.toml")], cwd=ROOT, env=os.environ, capture_output=True, text=True)
        if result.returncode:
            raise RuntimeError(result.stderr)
    print(json.dumps({"rust": "passed", "roundtrip": "identity", "metadata": "preserved", "completed": "external-only", "without_handler": without_handler["status"], "with_handler": "all-results-covered", "synthetic_discriminator": "profile-defined"}, sort_keys=True))


if __name__ == "__main__":
    run()
